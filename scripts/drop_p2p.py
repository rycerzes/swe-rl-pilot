"""Drop pass-to-pass tests that can't pass in the task image, and record why.

Usage: python3 scripts/drop_p2p.py --reason "<why>" --test NAME [--test NAME ...] tasks/<task> ...

Validation runs in the bootstrap image; the task image differs in ways that can break tests
unrelated to the fix (our history scrub leaves one commit; no network for git-hosted Go
modules). Such a test then fails for the reference fix too, and the oracle can't score 1.0.
Removing it from P2P (tests/p2p.json, which the verifier reads, and task.toml) keeps the task;
the removal goes under [metadata.swe_rl_pilot].p2p_dropped. F2P tests are never touched.
Matches the exact test ID. No image change, so no rebuild.
"""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path

import tomli_w


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tasks", nargs="+", type=Path)
    parser.add_argument("--test", action="append", required=True, dest="tests")
    parser.add_argument("--reason", required=True)
    args = parser.parse_args()

    drop = set(args.tests)
    for task in args.tasks:
        p2p_path = task / "tests" / "p2p.json"
        p2p = json.loads(p2p_path.read_text(encoding="utf-8"))
        gone = [t for t in p2p if t in drop]
        if not gone:
            continue
        p2p_path.write_text(json.dumps([t for t in p2p if t not in drop], indent=2) + "\n",
                            encoding="utf-8")
        toml_path = task / "task.toml"
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        pr = data["metadata"]["repo2env"]["pr_runtime"]
        if drop & set(pr.get("fail_to_pass") or []):
            raise SystemExit(f"{task.name}: refusing to drop a fail-to-pass test")
        pr["pass_to_pass"] = [t for t in pr.get("pass_to_pass") or [] if t not in drop]
        pilot = data["metadata"].setdefault("swe_rl_pilot", {})
        pilot.setdefault("p2p_dropped", []).extend({"test": t, "reason": args.reason} for t in gone)
        toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
        print(f"{task.name}: dropped {gone}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
