"""Run a task's controls with Harbor and check the rewards: oracle 1.0 and resolved, nop 0.0.

Usage: python3 scripts/check_controls.py tasks/<task> [--harbor 'uvx --from harbor==0.25.0 harbor']
       [--env hf-sandbox]   # default docker; hf-sandbox needs rollout/patch_harbor.py applied
       [--attacks]          # also run scripts/attacks/<language>-*.sh as the solution: each must
                            # not score above 0 (ungraded is reported, not a failure)

Runs on the published image (`docker_image`), so it checks exactly what HF Sandbox will pull.
A missing reward fails the check: the controls must be graded, not ungraded.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EXPECTED = {"oracle": 1.0, "nop": 0.0}
ATTACKS = Path(__file__).with_name("attacks")


def task_language(task: Path) -> str:
    """From the task's Dockerfile, else from `[metadata].language` (prebuilt-image tasks)."""
    dockerfile = task / "environment" / "Dockerfile"
    if dockerfile.exists():
        return "go" if "FROM golang" in dockerfile.read_text(encoding="utf-8") else "python"
    import tomllib

    meta = tomllib.loads((task / "task.toml").read_text(encoding="utf-8")).get("metadata", {})
    return str(meta.get("language", "python")).lower()


def run_attack(harbor: list[str], task: Path, attack: Path, jobs: Path, env: str) -> dict:
    """Run `attack` as the task's solution through Harbor's oracle agent."""
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / task.name
        shutil.copytree(task, copy)
        shutil.copyfile(attack, copy / "solution" / "solve.sh")
        row = run_control(harbor, copy, "oracle", jobs / attack.stem, env)
    return {**row, "agent": f"attack:{attack.stem}"}


def run_control(harbor: list[str], task: Path, agent: str, jobs: Path, env: str) -> dict:
    out = jobs / f"{task.name}-{agent}"
    cmd = [*harbor, "run", "-p", str(task), "-a", agent, "-e", env, "-o", str(out)]
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=False)
    results = sorted(out.glob("*/*/result.json"))
    if len(results) != 1:
        return {"agent": agent, "error": f"expected one trial result, found {len(results)}"}
    trial = results[0].parent
    result = json.loads(results[0].read_text())
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    details_path = trial / "verifier" / "reward-details.json"
    details = json.loads(details_path.read_text()) if details_path.exists() else {}
    return {
        "agent": agent,
        "reward": rewards.get("reward"),
        # Only Repo2RLEnv graders write reward-details.json; others report the reward alone.
        "resolved": details.get("resolved") if details else "n/a",
        "parse_status": details.get("parse_status"),
        "tamper_check": details.get("tamper_check"),
        "exception": (result.get("exception_info") or {}).get("exception_type"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", type=Path)
    parser.add_argument("--harbor", default="uvx --from harbor==0.25.0 harbor")
    parser.add_argument("--jobs", type=Path, default=Path("jobs"))
    parser.add_argument("--env", default="docker", help="Harbor environment (docker, hf-sandbox)")
    parser.add_argument("--attacks", action="store_true", help="also run the attack solutions")
    parser.add_argument("--oracle-runs", type=int, default=1,
                        help="run the oracle this many times; every run must score 1.0 (flaky tests)")
    args = parser.parse_args()

    harbor = shlex.split(args.harbor)
    rows = [run_control(harbor, args.task, a, args.jobs, args.env) for a in EXPECTED]
    for n in range(2, args.oracle_runs + 1):
        rows.append(run_control(harbor, args.task, "oracle", args.jobs / f"oracle-{n}", args.env))
    if args.attacks:
        for attack in sorted(ATTACKS.glob(f"{task_language(args.task)}-*.sh")):
            rows.append(run_attack(harbor, args.task, attack, args.jobs, args.env))
    failures = []
    for row in rows:
        if row["agent"].startswith("attack:"):
            reward = row.get("reward")
            if reward is not None and reward > 0:
                failures.append(f"{row['agent']}: reward {reward!r}, expected 0 (weak grader)")
            continue
        want = EXPECTED[row["agent"]]
        if row.get("reward") != want:
            failures.append(f"{row['agent']}: reward {row.get('reward')!r}, expected {want}")
        if row["agent"] == "oracle" and row.get("resolved") not in (True, "n/a"):
            failures.append(f"oracle: resolved {row.get('resolved')!r}, expected True")

    lines = [f"### {args.task.name}", "", "| control | reward | resolved | parse_status | tamper_check | exception |",
             "|---|---|---|---|---|---|"]
    for row in rows:
        lines.append("| {agent} | {reward} | {resolved} | {parse_status} | {tamper_check} | {exception} |".format(
            **{k: row.get(k, "") for k in ("agent", "reward", "resolved", "parse_status", "tamper_check", "exception")}))
    lines += [""] + [f"- FAIL {f}" for f in failures] + ([] if failures else ["- PASS"]) + [""]
    summary = "\n".join(lines)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(summary + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
