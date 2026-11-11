"""Fix the train / eval split before any baseline or training run.

Usage: python3 scripts/make_split.py tasks --out splits/v1.json [--failed failed.txt]
       [--cutoff 2026-10-16] [--eval-repo getmoto/moto ...]

- eval_repo: every usable task from a repo that never trains (cross-repo generalization).
- eval_time: usable tasks from the training repos merged on or after --cutoff (newer PRs).
- train: the other usable tasks.
- excluded: instruction_ok=false (instruction leaks the tests or is too thin), and tasks listed
  in --failed (CI controls failed: oracle not 1.0/resolved, or nop not 0.0).

Each entry keeps the facts a later filter may want (merge date, tamper_check, F2P/P2P counts),
so the split can be audited without reopening every task.toml. Standard library only.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
import tomllib
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tasks", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--failed", type=Path, help="task names whose CI controls failed")
    parser.add_argument("--cutoff", default="2026-10-16", help="eval_time: merged on/after")
    parser.add_argument("--eval-repo", nargs="*", default=["getmoto/moto"])
    args = parser.parse_args()

    failed = set(args.failed.read_text().split()) if args.failed else set()
    split: dict[str, list[dict]] = {"train": [], "eval_time": [], "eval_repo": [], "excluded": []}
    for toml_path in sorted(args.tasks.glob("*/task.toml")):
        meta = tomllib.loads(toml_path.read_text(encoding="utf-8"))["metadata"]
        r2e, pilot = meta["repo2env"], meta.get("swe_rl_pilot", {})
        pr = r2e["pr_runtime"]
        repo = str(r2e.get("repo", "")).removeprefix("https://github.com/").removesuffix(".git")
        entry = {
            "task": toml_path.parent.name,
            "repo": repo,
            "merged_at": pr.get("pr_merged_at", ""),
            "tamper_check": pr.get("tamper_check"),
            "f2p": len(pr.get("fail_to_pass") or []),
            "p2p": len(pr.get("pass_to_pass") or []),
        }
        if entry["task"] in failed:
            split["excluded"].append({**entry, "reason": "controls_failed"})
        elif not pilot.get("instruction_ok", False):
            split["excluded"].append({**entry, "reason": "instruction_not_ok"})
        elif repo in args.eval_repo:
            split["eval_repo"].append(entry)
        elif entry["merged_at"][:10] >= args.cutoff:
            split["eval_time"].append(entry)
        else:
            split["train"].append(entry)

    summary = {
        name: dict(collections.Counter(e["repo"] for e in entries))
        for name, entries in split.items()
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(
            {"cutoff": args.cutoff, "eval_repos": args.eval_repo, "summary": summary, **split},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    for name, counts in summary.items():
        print(f"{name:10s} {sum(counts.values()):4d}  {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
