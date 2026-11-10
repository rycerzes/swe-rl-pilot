"""`repo2rlenv generate`, keeping every validation stage's script and output.

Usage: python scripts/generate_logged.py <stage-log-dir> <repo2rlenv args...>

Repo2RLEnv logs only "parsed pre=0 post=0 tests" when a stage's tests never ran, which hides
why (a build that fails at an older base, a config guard error, tests that don't compile).
This wraps the stage runner and writes `<n>-<base12>.log` (exit code, then the output's last
200k characters) and `<n>-<base12>.sh` for each stage, in order.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import repo2rlenv.pipelines.pr_runtime_validate as validate
from repo2rlenv.cli import main

OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
_run = validate._Stopwatch.run
_count = {"n": 0}


def run(self, sandbox, script, timeout):
    result = _run(self, sandbox, script, timeout)
    _count["n"] += 1
    found = re.search(r"\b([0-9a-f]{40})\b", script)
    stem = f"{_count['n']:03d}-{found[1][:12] if found else 'unknown'}"
    output = result.truncated(max_chars=5_000_000)
    (OUT / f"{stem}.sh").write_text(script, encoding="utf-8")
    (OUT / f"{stem}.log").write_text(
        f"exit={getattr(result, 'exit_code', None)}\n{output[-200_000:]}", encoding="utf-8"
    )
    return result


validate._Stopwatch.run = run
sys.argv = ["repo2rlenv", *sys.argv[2:]]
sys.exit(main())
