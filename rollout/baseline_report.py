"""Summarise a step-3 baseline run: pass rates, the training filter, the gate, and run costs.

Usage: python rollout/baseline_report.py OUT_DIR [--split splits/v1.json] [--gpu-per-hour 2.5]
       [--sandbox-per-hour 0.01]

Reads OUT_DIR/rollouts/*.json (rollout/baseline.py) and writes OUT_DIR/report.json plus
OUT_DIR/train_keep.txt. "Solved" is guard-adjusted: training reward 1.0 (resolved and no HIGH
guard finding); raw solves are reported next to it so the guard's effect is visible. Ungraded
rollouts (training reward None) are left out of pass rates and counted on their own.

- filter: train tasks with 0 < pass rate < 1 over their graded attempts (GRPO needs variance);
- gate: train solve rate, guard-adjusted, against the 10% floor from the plan;
- caps: solve rate if the step cap had been lower (a rollout solved in n turns survives any cap >= n);
- cost: rollouts/hour, wall and GPU-hours, sandbox-hours, from the run's own timestamps.
"""

from __future__ import annotations

import argparse
import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def rate(xs: list[bool]) -> float | None:
    return round(sum(xs) / len(xs), 4) if xs else None


def pct(xs: list[float], q: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("out", type=Path)
    p.add_argument("--split", type=Path, default=ROOT / "splits" / "v1.json")
    p.add_argument("--gpu-per-hour", type=float, default=2.5)
    p.add_argument("--sandbox-per-hour", type=float, default=0.01)
    p.add_argument("--floor", type=float, default=0.10)
    args = p.parse_args()

    split = json.loads(args.split.read_text())
    section_of = {e["task"]: s for s in ("train", "eval_time", "eval_repo") for e in split[s]}
    repo_of = {e["task"]: e["repo"] for s in ("train", "eval_time", "eval_repo") for e in split[s]}
    recs = [json.loads(f.read_text()) for f in sorted((args.out / "rollouts").glob("*.json"))]
    if not recs:
        raise SystemExit("no rollouts")

    graded = [r for r in recs if r.get("training_reward") is not None]
    solved = lambda r: r.get("training_reward") == 1.0  # noqa: E731
    raw_solved = lambda r: r.get("reward") == 1.0  # noqa: E731

    by_task: dict[str, list[dict]] = defaultdict(list)
    for r in graded:
        by_task[r["task"]].append(r)
    per_task = {t: {"section": section_of.get(t), "repo": repo_of.get(t), "graded": len(rs),
                    "solved": sum(map(solved, rs)), "raw_solved": sum(map(raw_solved, rs)),
                    "rate": rate([solved(r) for r in rs])} for t, rs in sorted(by_task.items())}

    def group(key) -> dict:
        g: dict[str, list[dict]] = defaultdict(list)
        for r in graded:
            g[key(r)].append(r)
        return {k: {"graded": len(v), "solve_rate": rate([solved(r) for r in v]),
                    "raw_solve_rate": rate([raw_solved(r) for r in v]),
                    "task_pass_at_k": rate([per_task[t]["solved"] > 0 for t in {r["task"] for r in v}])}
                for k, v in sorted(g.items())}

    train = [t for t, v in per_task.items() if v["section"] == "train"]
    keep = sorted(t for t in train if 0 < per_task[t]["solved"] < per_task[t]["graded"])
    train_graded = [r for r in graded if section_of.get(r["task"]) == "train"]
    train_rate = rate([solved(r) for r in train_graded])

    caps = {}
    for cap in (50, 75, 100, 125, 150, 200):
        caps[cap] = rate([solved(r) and (r.get("n_turns") or 0) <= cap for r in graded])

    starts = [r["started"] for r in recs]
    ends = [r["ended"] for r in recs]
    span_h = (max(ends) - min(starts)) / 3600
    walls = [r["ended"] - r["started"] for r in recs]
    tokens = [r.get("n_trainable_tokens") or 0 for r in graded]
    turns = [r.get("n_turns") or 0 for r in graded]
    reasons = Counter((r.get("reason") or "").split(";")[0].split(":")[0] for r in recs)
    guard_ids = Counter(f for r in recs for f in (r.get("guard_findings") or []))

    report = {
        "rollouts": len(recs), "graded": len(graded), "ungraded": len(recs) - len(graded),
        "ungraded_rate": rate([r.get("training_reward") is None for r in recs]),
        "reasons": dict(reasons.most_common()),
        "guard_zeroed": sum(1 for r in graded if (r.get("reason") or "").startswith("guard:")),
        "guard_zeroed_raw_solves": sum(1 for r in graded
                                       if raw_solved(r) and (r.get("reason") or "").startswith("guard:")),
        "guard_findings": dict(guard_ids.most_common()),
        "solve_rate": rate([solved(r) for r in graded]),
        "raw_solve_rate": rate([raw_solved(r) for r in graded]),
        "by_section": group(lambda r: section_of.get(r["task"]) or "?"),
        "by_repo": group(lambda r: repo_of.get(r["task"]) or "?"),
        "gate": {"train_solve_rate": train_rate, "floor": args.floor,
                 "pass": train_rate is not None and train_rate >= args.floor},
        "filter": {"train_tasks": len(train), "keep": len(keep),
                   "all_fail": sum(1 for t in train if per_task[t]["solved"] == 0),
                   "all_pass": sum(1 for t in train
                                   if per_task[t]["solved"] == per_task[t]["graded"] > 0)},
        "solve_rate_at_cap": caps,
        "turns": {"p50": pct(turns, .5), "p90": pct(turns, .9), "max": max(turns, default=None),
                  "at_cap": sum(1 for r in graded if (r.get("reason") or "").startswith("truncated"))},
        "trainable_tokens": {"p50": pct(tokens, .5), "p90": pct(tokens, .9), "max": max(tokens, default=None),
                             "over_250k": sum(t > 250_000 for t in tokens)},
        "cost": {"span_hours": round(span_h, 2), "rollouts_per_hour": round(len(recs) / span_h, 1),
                 "wall_s_p50": pct(walls, .5), "wall_s_p90": pct(walls, .9),
                 "gpu_usd": round(span_h * args.gpu_per_hour, 2),
                 "sandbox_hours_upper": round(sum(walls) / 3600, 1),
                 "sandbox_usd_upper": round(sum(walls) / 3600 * 2 * args.sandbox_per_hour, 2)},
        "per_task": per_task,
    }
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    (args.out / "train_keep.txt").write_text("".join(t + "\n" for t in keep))
    short = {k: v for k, v in report.items() if k != "per_task"}
    print(json.dumps(short, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
