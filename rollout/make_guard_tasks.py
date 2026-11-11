"""Build the guard-check task set: a few training tasks of ours plus wrapped SWE-rebench tasks.

Usage: python rollout/make_guard_tasks.py OUT_DIR [--per-repo 1] [--pool rycerzes/swe-rebench-v2.1-rl-isolated-1k]
       [--pool-tasks name1,name2]

From splits/v1.json `train`, takes the task with the fewest P2P tests from each repo (quick test
runs); from the pool dataset, the named wrapped tasks (downloaded with the caller's HF token).
Every task gets `[agent].user = "learner"`, so the agent runs unprivileged (with
rollout/egress/pilot_harbor_egress.py) and, with PILOT_EGRESS_ALLOW set, inside the egress jail.
"""

from __future__ import annotations

import argparse
import json
import shutil
import tomllib
from collections import defaultdict
from pathlib import Path

import tomli_w

ROOT = Path(__file__).resolve().parent.parent


def set_agent_user(task: Path, user: str = "learner") -> None:
    toml_path = task / "task.toml"
    data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
    data.setdefault("agent", {})["user"] = user
    toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--per-repo", type=int, default=1)
    parser.add_argument("--pool", default="rycerzes/swe-rebench-v2.1-rl-isolated-1k")
    parser.add_argument("--pool-tasks", default="pypa__packaging-662,bombsimon__wsl-45")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    split = json.loads((ROOT / "splits" / "v1.json").read_text())
    by_repo: dict[str, list[dict]] = defaultdict(list)
    for entry in split["train"]:
        by_repo[entry["repo"]].append(entry)
    for repo, entries in sorted(by_repo.items()):
        for entry in sorted(entries, key=lambda e: (e["p2p"], e["task"]))[: args.per_repo]:
            dest = args.out / entry["task"]
            shutil.copytree(ROOT / "tasks" / entry["task"], dest, dirs_exist_ok=True)
            set_agent_user(dest)
            print("ours", entry["task"], f"p2p={entry['p2p']}")

    names = [n for n in args.pool_tasks.split(",") if n]
    if names:
        from huggingface_hub import snapshot_download

        local = Path(snapshot_download(args.pool, repo_type="dataset",
                                       allow_patterns=[f"tasks/{n}/**" for n in names]))
        for name in names:
            dest = args.out / name
            shutil.copytree(local / "tasks" / name, dest, dirs_exist_ok=True)
            set_agent_user(dest)
            print("pool", name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
