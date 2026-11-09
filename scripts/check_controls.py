"""Run a task's controls with Harbor and check the rewards: oracle 1.0 and resolved, nop 0.0.

Usage: python3 scripts/check_controls.py tasks/<task> [--harbor 'uvx --from harbor==0.25.0 harbor']

Runs on the published image (`docker_image`), so it checks exactly what HF Sandbox will pull.
A missing reward fails the check: the controls must be graded, not ungraded.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

EXPECTED = {"oracle": 1.0, "nop": 0.0}


def run_control(harbor: list[str], task: Path, agent: str, jobs: Path) -> dict:
    out = jobs / f"{task.name}-{agent}"
    cmd = [*harbor, "run", "-p", str(task), "-a", agent, "-e", "docker", "-o", str(out)]
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
        "resolved": details.get("resolved"),
        "parse_status": details.get("parse_status"),
        "tamper_check": details.get("tamper_check"),
        "exception": (result.get("exception_info") or {}).get("exception_type"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", type=Path)
    parser.add_argument("--harbor", default="uvx --from harbor==0.25.0 harbor")
    parser.add_argument("--jobs", type=Path, default=Path("jobs"))
    args = parser.parse_args()

    rows = [run_control(shlex.split(args.harbor), args.task, a, args.jobs) for a in EXPECTED]
    failures = []
    for row in rows:
        want = EXPECTED[row["agent"]]
        if row.get("reward") != want:
            failures.append(f"{row['agent']}: reward {row.get('reward')!r}, expected {want}")
        if row["agent"] == "oracle" and row.get("resolved") is not True:
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
