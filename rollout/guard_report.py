"""Per-rollout guard report: raw reward, training reward and why, egress denials, atif-scan findings.

Usage: python rollout/guard_report.py --trials-root DIR rollouts-A.json [rollouts-B.json ...]
       --out guard.json [--step-limit N]

For each rollout record, finds its Harbor trial directory (by trial_name under --trials-root),
runs rollout/reward.py's `guard_findings` on the trial's ATIF trace (agent/trajectory.json) and
`explain` with the egress log and those findings. Also reports which user the agent's commands
ran as (uid lines in its log), so the [agent].user switch is visible.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from reward import egress_denials, explain, guard_findings, task_repo  # noqa: E402


def records(path: Path) -> list[dict]:
    data = json.loads(path.read_text())
    items = data if isinstance(data, list) else [data]
    return [r.get("result", r) for r in items]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--trials-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--step-limit", type=int)
    args = parser.parse_args()

    rows = []
    for path in args.files:
        if not path.exists():
            continue
        for record in records(path):
            trial = next(args.trials_root.glob(f"**/{record.get('trial_name')}"), None)
            trace = trial / "agent" / "trajectory.json" if trial else None
            findings: list[str] | None = None
            scan_error = None
            if trace and trace.exists():
                try:
                    findings = guard_findings(trace, repo=task_repo(record.get("task_name") or ""))
                except Exception as exc:  # noqa: BLE001 - reported, never treated as clean
                    scan_error = str(exc)[:300]
            reward, reason = explain(record, trial_dir=trial, findings=findings,
                                     step_limit=args.step_limit)
            if scan_error:
                reward, reason = None, "guard_scan_failed"
            uids = sorted(set(re.findall(r"uid=\d+\((\w+)\)", (trial / "agent" / "mini-swe-agent.txt")
                                         .read_text(errors="replace")))) if trial and (
                trial / "agent" / "mini-swe-agent.txt").exists() else []
            rows.append({
                "file": path.name, "task": record.get("task_name"), "trial": record.get("trial_name"),
                "raw_reward": record.get("reward"), "n_turns": record.get("n_turns"),
                "training_reward": reward, "reason": reason,
                "egress_denied": egress_denials(trial), "findings": findings, "scan_error": scan_error,
                "agent_uids": uids,
            })
    args.out.write_text(json.dumps(rows, indent=2))
    for r in rows:
        print(f"{r['task']:45} raw={r['raw_reward']} -> {r['training_reward']} ({r['reason']}) "
              f"turns={r['n_turns']} denied={r['egress_denied']} uids={r['agent_uids']} "
              f"findings={r['findings']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
