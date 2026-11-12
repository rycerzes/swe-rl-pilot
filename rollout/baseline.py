"""Step-3 baseline: K attempts per task through `openenv harbor serve` + HarborSessionFactory.

This is the training path (the one TRL's AsyncGRPO drives), not the one-shot CLI, so the baseline
runs under the same budget, sampling and capture as training:
  - sampling pinned per session to the training policy (temperature 1.0, full vocabulary);
  - `agent_step_limit` caps model calls, so a pass rate at any lower cap can be read off afterwards
    (a rollout that finished in n turns is unaffected by any cap >= n);
  - purpose="train": token capture is required, and a rollout without it is an infra failure.

Usage (inside the job, with `openenv harbor serve` up on --server):
  python rollout/baseline.py --server http://127.0.0.1:8200 --llm-url http://127.0.0.1:8000 \
      --model Qwen/Qwen3.5-4B --attempts 8 --workers 32 --step-limit 150 --agent-timeout 3600 \
      --out /data/step3/<run>

Writes, per rollout, OUT/rollouts/<task>__a<k>.json: the grade, rollout/reward.py's training
reward and reason (guard scan included), turns, tokens, timings and the conversation (for SFT if
the gate needs a warm start). Rollouts whose raw reward is 1.0 also keep the full captured result
(gzip) under OUT/full/. Existing records are skipped, so a stopped job resumes where it left off.
Order is attempt-major (every task once, then every task again, ...) so a partial run still covers
every task. Needs OpenEnv's `envs/` on PYTHONPATH and atif-scan on $ATIF_SCAN.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import random
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from harbor_env.harness import HarborSessionFactory

sys.path.insert(0, str(Path(__file__).parent))
from reward import explain, guard_findings, task_repo  # noqa: E402

SLIM_FIELDS = ("task_name", "trial_name", "reward", "rewards", "ok", "error", "exception_type",
               "n_turns", "n_roots", "budget_stop_count", "n_trainable_tokens", "multi_turn",
               "atif", "findings", "param_fixes", "wall_s", "phase_timings", "capture_level",
               "rollout_type")


def trials_root() -> Path:
    return Path(os.environ.get("OPENENV_HARBOR_TRIALS_DIR") or "/tmp/openenv-harbor-trials")


def keep_trial_artifacts(trial: Path | None, dest: Path) -> None:
    """The ATIF trace, the egress log and the verifier output: enough to re-audit a rollout."""
    if trial is None:
        return
    dest.mkdir(parents=True, exist_ok=True)
    for rel in ("agent/trajectory.json", "agent/pilot-egress.log", "result.json"):
        src = trial / rel
        if src.exists():
            shutil.copy2(src, dest / rel.replace("/", "__"))
    if (trial / "verifier").is_dir():
        shutil.copytree(trial / "verifier", dest / "verifier", dirs_exist_ok=True)


def run_one(factory: HarborSessionFactory, row: dict, attempt: int, args, out: Path) -> dict:
    name = row["task_name"]
    started = time.time()
    session = factory.create(row["prompt"])
    try:
        rc = session.wait_for_completion()
        result = session.result.model_dump() if session.result is not None else None
    finally:
        session.close()
    ended = time.time()

    record: dict = {"task": name, "attempt": attempt, "rc": rc, "started": started, "ended": ended}
    if result is None:
        record.update(training_reward=None, reason="ungraded:no_result")
    else:
        record.update({k: result.get(k) for k in SLIM_FIELDS})
        trial = next(trials_root().glob(f"**/{result.get('trial_name')}"), None) \
            if result.get("trial_name") else None
        trace = trial / "agent" / "trajectory.json" if trial else None
        findings, scan_error = None, None
        if trace is not None and trace.exists():
            try:
                findings = guard_findings(trace, repo=task_repo(name))
            except Exception as exc:  # noqa: BLE001 - recorded; the rollout is then not scored
                scan_error = str(exc)[:300]
        reward, reason = explain(result, step_limit=args.step_limit, trial_dir=trial,
                                 findings=findings)
        if scan_error or (trace is None and reward is not None):
            reward, reason = None, "guard_scan_failed" if scan_error else "no_trace"
        record.update(training_reward=reward, reason=reason, guard_findings=findings,
                      scan_error=scan_error, conversations=result.get("conversations"))
        keep_trial_artifacts(trial, out / "trials" / f"{name}__a{attempt}")
        if result.get("reward") == 1.0:
            (out / "full").mkdir(exist_ok=True)
            with gzip.open(out / "full" / f"{name}__a{attempt}.json.gz", "wt") as fh:
                json.dump(result, fh)
        if trial is not None and not args.keep_local_trials:
            shutil.rmtree(trial, ignore_errors=True)
    path = out / "rollouts" / f"{name}__a{attempt}.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(record))
    tmp.replace(path)
    return record


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--server", required=True)
    p.add_argument("--llm-url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--attempts", type=int, default=8)
    p.add_argument("--workers", type=int, default=32)
    p.add_argument("--step-limit", type=int, default=150)
    p.add_argument("--agent-timeout", type=float, default=3600.0)
    p.add_argument("--temperature", type=float, default=1.0)
    p.add_argument("--max-rollouts", type=int, default=0, help="stop after this many (0 = all)")
    p.add_argument("--abort-after", type=int, default=40,
                   help="check the infra rate once this many rollouts have finished")
    p.add_argument("--abort-infra-rate", type=float, default=0.3,
                   help="stop submitting if more than this share of finished rollouts are ungraded")
    p.add_argument("--stagger", type=float, default=3.0, help="seconds between first-wave starts")
    p.add_argument("--keep-local-trials", action="store_true")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    (args.out / "rollouts").mkdir(parents=True, exist_ok=True)
    factory = HarborSessionFactory(
        args.server, harness="mini-swe-agent", sandbox="hf-sandbox", llm_url=args.llm_url,
        model=args.model, agent_step_limit=args.step_limit, agent_timeout_sec=args.agent_timeout,
        sampling={"temperature": args.temperature}, purpose="train",
    )
    rows = factory.prompt_rows()
    rng = random.Random(args.seed)
    todo = []
    for attempt in range(args.attempts):
        wave = list(rows)
        rng.shuffle(wave)  # mix repos within each wave, same order on every resume
        todo += [(row, attempt) for row in wave
                 if not (args.out / "rollouts" / f"{row['task_name']}__a{attempt}.json").exists()]
    if args.max_rollouts:
        todo = todo[: args.max_rollouts]
    config = {k: (str(v) if isinstance(v, Path) else v) for k, v in vars(args).items()}
    (args.out / "config.json").write_text(json.dumps({**config, "tasks": len(rows)}, indent=2))
    print(f"[baseline] {len(rows)} tasks x {args.attempts} attempts, {len(todo)} to run, "
          f"{args.workers} workers", flush=True)

    lock = threading.Lock()
    done = {"n": 0, "ungraded": 0, "stop": False}

    def guarded(position, row, attempt):
        if done["stop"]:
            return None
        if position < args.workers:
            time.sleep(args.stagger * position)  # don't ask for every sandbox in the same second
        try:
            rec = run_one(factory, row, attempt, args, args.out)
        except Exception as exc:  # noqa: BLE001 - no record is written, so a resume retries it
            now = time.time()
            rec = {"task": row["task_name"], "attempt": attempt, "started": now, "ended": now,
                   "training_reward": None, "reason": f"runner_error:{type(exc).__name__}: {exc}"[:300]}
        with lock:
            done["n"] += 1
            done["ungraded"] += rec.get("training_reward") is None
            if done["n"] >= args.abort_after and done["ungraded"] / done["n"] > args.abort_infra_rate:
                if not done["stop"]:
                    print(f"[baseline] ABORT: {done['ungraded']}/{done['n']} ungraded", flush=True)
                done["stop"] = True
        print(f"[baseline] {done['n']}/{len(todo)} {rec['task']} a{rec['attempt']} "
              f"raw={rec.get('reward')} -> {rec.get('training_reward')} ({rec.get('reason')}) "
              f"turns={rec.get('n_turns')} {rec['ended'] - rec['started']:.0f}s", flush=True)
        return rec

    with ThreadPoolExecutor(args.workers) as pool:
        futures = [pool.submit(guarded, i, row, attempt) for i, (row, attempt) in enumerate(todo)]
        for fut in as_completed(futures):
            if fut.exception() is not None:
                print(f"[baseline] worker error: {fut.exception()!r}", flush=True)
    return 2 if done["stop"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
