"""Step 1 checks over captured rollouts: is every trainable turn token-complete and consistent?

Usage: python check_capture.py rollouts-A.json [rollouts-B.json ...] --out summary.json

Inputs are `openenv harbor rollout --out` files (a list of HarborRolloutResult dicts) or
capped_rollout.py files (a list of {"result": ...} records). Per rollout it reports the grade
fields and, for the agent's turns:
  - token ids present for prompt and completion, and one logprob per completion token;
  - logprobs finite and <= 0;
  - loss_mask covering prompt + completion;
  - across consecutive turns, whether the next prompt extends the previous prompt + completion
    (what a token-faithful multi-turn capture should show unless the harness rewrote history);
  - finish reasons, so truncated turns are visible.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path


def common_prefix(a: list[int], b: list[int]) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def check_rollout(r: dict) -> dict:
    turns = [t for t in r.get("turns") or [] if t.get("role", "agent") == "agent"]
    problems: list[str] = []
    finish = Counter(t.get("finish_reason") or "none" for t in turns)
    for t in turns:
        p, c = t.get("prompt_token_ids") or [], t.get("completion_token_ids") or []
        lp, mask = t.get("per_token_logps") or [], t.get("loss_mask")
        k = t.get("turn")
        if t.get("trainable", True) and not t.get("discarded"):
            if not p or not c:
                problems.append(f"turn {k}: missing token ids (prompt {len(p)}, completion {len(c)})")
            if len(lp) != len(c):
                problems.append(f"turn {k}: {len(lp)} logprobs for {len(c)} completion tokens")
            if any((not math.isfinite(x)) or x > 1e-6 for x in lp):
                problems.append(f"turn {k}: logprob not finite or > 0")
            if mask is not None and len(mask) != len(p) + len(c):
                problems.append(f"turn {k}: loss_mask {len(mask)} != {len(p) + len(c)}")
    # Multi-turn consistency: turn k+1's prompt should start with turn k's prompt + completion.
    extends, prefix_fracs = 0, []
    for prev, nxt in zip(turns, turns[1:]):
        before = (prev.get("prompt_token_ids") or []) + (prev.get("completion_token_ids") or [])
        after = nxt.get("prompt_token_ids") or []
        if not before or not after:
            continue
        n = common_prefix(before, after)
        prefix_fracs.append(n / len(before))
        extends += n == len(before)
    pairs = len(prefix_fracs)
    return {
        "task": r.get("task_name"),
        "ok": r.get("ok"),
        "reward": r.get("reward"),
        "rewards": r.get("rewards"),
        "exception_type": r.get("exception_type"),
        "error": (r.get("error") or "")[:300],
        "rollout_type": r.get("rollout_type"),
        "capture_level": r.get("capture_level"),
        "n_turns": r.get("n_turns"),
        "n_agent_turns": len(turns),
        "budget_stop_count": r.get("budget_stop_count"),
        "n_trainable_tokens": r.get("n_trainable_tokens"),
        "atif": r.get("atif"),
        "wall_s": r.get("wall_s"),
        "phase_timings": r.get("phase_timings"),
        "finish_reasons": dict(finish),
        "turn_pairs": pairs,
        "turn_pairs_exact_extension": extends,
        "min_prefix_frac": min(prefix_fracs) if prefix_fracs else None,
        "token_problems": problems[:20],
        "n_token_problems": len(problems),
        "findings": (r.get("findings") or [])[:20],
    }


def load(path: Path) -> list[tuple[dict, dict]]:
    if not path.exists():
        return [({"file": str(path), "missing": True}, {})]
    data = json.loads(path.read_text())
    out = []
    for item in data:
        if "result" in item and ("rc" in item or "env_reward" in item):
            extra = {k: v for k, v in item.items() if k != "result"}
            out.append((extra, item.get("result") or {}))
        else:
            out.append(({}, item))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("files", nargs="+", type=Path)
    p.add_argument("--model", default="")
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    rows = []
    for f in a.files:
        for extra, result in load(f):
            row = {"file": f.name, **extra}
            if result:
                row.update(check_rollout(result))
            rows.append(row)
    a.out.write_text(json.dumps({"model": a.model, "rollouts": rows}, indent=2))
    for row in rows:
        print(json.dumps({k: row.get(k) for k in (
            "file", "task", "ok", "reward", "exception_type", "capture_level", "n_agent_turns",
            "finish_reasons", "turn_pairs", "turn_pairs_exact_extension", "min_prefix_frac",
            "n_token_problems", "budget_stop_count", "env_reward", "training_trace_ok", "missing")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
