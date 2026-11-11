"""Training reward for one rollout: the verifier's reward, or None when the rollout must be dropped.

`training_reward(result, ...)` takes an `openenv harbor rollout` result record (one JSON object)
and decides, in order:

1. None, ungraded: the verifier produced no reward (sandbox or grader failure, a separate
   verifier that left the run ungraded). Infra failures must not train as 0.
2. None, agent never ran: no model turns, or a [FATAL] finding (wrong endpoint, auth, an agent
   that crashed on start, as in step 1 where a litellm import error scored 0.0).
3. Egress denials (pilot-egress.log in the trial's agent dir) are recorded in the reason, not
   scored: the jail already makes a network fix-fetch impossible, and most denials are the
   environment (in the guard job, Go fetching test dependencies the image's module cache lacked
   zeroed a real solve). Intent is scored by the guard findings below (upstream_fetch etc.).
3b. 0.0, guard finding: atif-scan with rollout/guards/pr_runtime_pack.py found a HIGH or
   CRITICAL match in the rollout's ATIF trace (git history beyond base, upstream fetches,
   grader or sandbox probing, reading its own trajectory). Pass `findings=` (from
   `guard_findings(trace)`) to apply it.
4. Step-capped and not solved: `truncated="zero"` keeps the graded 0.0, `"mask"` returns None.
   Step 1's capped rollout graded 0.0 with no marker; it's detected as n_turns >= step_limit.
5. Otherwise the verifier's reward; `binary=True` turns partial credit into 1.0 only when 1.0.

`explain(...)` returns (reward, reason) for logging and for counting drop reasons.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

GUARDS = Path(__file__).with_name("guards")
SCAN_FAIL = {"high", "critical"}

INFRA_EXCEPTIONS = {"SandboxError", "EnvironmentStartTimeoutError", "RuntimeError",
                    "TimeoutError", "ConnectionError", "HTTPError"}


def egress_denials(trial_dir: Path | None) -> int:
    """DENY lines in the proxy log Harbor collected from /logs/agent."""
    if trial_dir is None:
        return 0
    log = trial_dir / "agent" / "pilot-egress.log"
    if not log.exists():
        return 0
    return sum(1 for line in log.read_text(errors="replace").splitlines() if "\tDENY\t" in line)


def task_repo(task_name: str) -> str:
    """owner/repo from a task name like `gofiber__fiber-4577` (our tasks and SWE-rebench's)."""
    return task_name.rsplit("-", 1)[0].replace("__", "/", 1) if "__" in task_name else ""


def guard_findings(trace: Path, atif_scan: str | None = None, repo: str = "") -> list[str]:
    """HIGH/CRITICAL atif-scan matches (built-ins + the pr_runtime pack) in one ATIF trace.

    `atif_scan` is the command to run (default $ATIF_SCAN or `atif-scan`). Raises on a scanner
    error rather than returning no findings, so a broken scan can't pass a rollout silently.
    """
    cmd = shlex.split(atif_scan or os.environ.get("ATIF_SCAN", "atif-scan"))
    env = {**os.environ, "PILOT_TASK_REPO": repo,
           "PYTHONPATH": os.pathsep.join(filter(None, [str(GUARDS), os.environ.get("PYTHONPATH")]))}
    run = subprocess.run([*cmd, str(trace), "--plugin", "pr_runtime_pack:checks", "--format", "json"],
                         capture_output=True, text=True, env=env, timeout=300)
    if not run.stdout.strip().startswith("{"):
        raise RuntimeError(f"atif-scan failed on {trace}: {(run.stderr or run.stdout)[:300]}")
    report = json.loads(run.stdout)
    return sorted({a["id"] for i in report["inputs"] for a in i.get("assessments", [])
                   if a.get("status") == "match" and str(a.get("severity")).lower() in SCAN_FAIL})


def explain(result: dict, *, step_limit: int | None = None, truncated: str = "zero",
            binary: bool = False, trial_dir: Path | None = None,
            findings: list[str] | None = None) -> tuple[float | None, str]:
    reward = result.get("reward")
    if reward is None:
        return None, f"ungraded:{result.get('exception_type') or 'no_reward'}"
    if not result.get("n_turns") or any(str(f).startswith("[FATAL]") for f in result.get("findings") or []):
        return None, "agent_never_ran"
    if result.get("exception_type") in INFRA_EXCEPTIONS and not result.get("ok", True):
        return None, f"infra:{result.get('exception_type')}"
    denied = egress_denials(trial_dir)
    note = f";egress_denied={denied}" if denied else ""
    if findings:
        return 0.0, "guard:" + ",".join(findings) + note
    if step_limit and result.get("n_turns", 0) >= step_limit and reward < 1.0:
        return (None, "truncated_masked" + note) if truncated == "mask" else (0.0, "truncated" + note)
    if binary:
        return (1.0 if reward >= 1.0 else 0.0), "graded_binary" + note
    return float(reward), "graded" + note


def training_reward(result: dict, **kwargs) -> float | None:
    return explain(result, **kwargs)[0]


def main() -> int:
    """Print reward and reason for each record in the given result JSON files (a list or one)."""
    for path in sys.argv[1:]:
        data = json.loads(Path(path).read_text())
        for record in data if isinstance(data, list) else [data]:
            print(path, record.get("task_name"), *explain(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
