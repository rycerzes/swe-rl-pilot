"""Build the step-3 baseline task set from splits/v1.json.

Usage: python rollout/make_baseline_tasks.py OUT_DIR [--sections train,eval_time]
       [--per-repo N] [--names a,b]

Copies every task of the chosen split sections (default train + eval_time: the 114 usable tasks)
into OUT_DIR and sets `[agent].user = "learner"` on each, so the agent runs unprivileged inside the
egress jail exactly as in the guard jobs and as in training. `--per-repo N` keeps the N tasks with
the fewest P2P tests per repo (the calibration slice); `--names` picks tasks by name.
Prints one line per task: section, repo, name.
"""

from __future__ import annotations

import argparse
import json
import shutil
from collections import defaultdict
from pathlib import Path

from make_guard_tasks import set_agent_user

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--sections", default="train,eval_time")
    parser.add_argument("--per-repo", type=int, default=0)
    parser.add_argument("--names", default="")
    args = parser.parse_args()

    split = json.loads((ROOT / "splits" / "v1.json").read_text())
    entries = [(section, e) for section in args.sections.split(",") for e in split[section]]
    if args.names:
        wanted = set(args.names.split(","))
        entries = [(s, e) for s, e in entries if e["task"] in wanted]
    if args.per_repo:
        by_repo: dict[str, list] = defaultdict(list)
        for s, e in entries:
            by_repo[e["repo"]].append((s, e))
        entries = [x for repo in sorted(by_repo)
                   for x in sorted(by_repo[repo], key=lambda x: (x[1]["p2p"], x[1]["task"]))[: args.per_repo]]

    args.out.mkdir(parents=True, exist_ok=True)
    for section, entry in entries:
        dest = args.out / entry["task"]
        shutil.copytree(ROOT / "tasks" / entry["task"], dest, dirs_exist_ok=True)
        set_agent_user(dest)
        print(section, entry["repo"], entry["task"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
