"""One rollout through `openenv harbor serve` + HarborSessionFactory with a model-call cap.

Checks what a trainer sees when an agent hits its limit: is the rollout still graded, is it
marked, and are the captured turns still token-complete. Needs OpenEnv's `envs/` on PYTHONPATH
(`harbor_env.harness` is not in the packaged wheel).
"""

from __future__ import annotations

import argparse
import json
import sys

from harbor_env.harness import HarborSessionFactory


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server", required=True)
    p.add_argument("--llm-url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--task-index", type=int, required=True)
    p.add_argument("--step-limit", type=int, default=4)
    p.add_argument("--agent-timeout", type=float, default=1800.0)
    p.add_argument("--out", required=True)
    a = p.parse_args()

    factory = HarborSessionFactory(
        a.server, harness="mini-swe-agent", sandbox="hf-sandbox", llm_url=a.llm_url,
        model=a.model, agent_step_limit=a.step_limit, agent_timeout_sec=a.agent_timeout,
        purpose="train",
    )
    row = next(r for r in factory.prompt_rows() if r["task_index"] == a.task_index)
    print(f"task {row['task_index']} {row['task_name']} step_limit={a.step_limit}", flush=True)
    session = factory.create(row["prompt"])
    try:
        rc = session.wait_for_completion()
        verdict = session.verify([])
        trace_ok, trace_err = True, ""
        try:
            session.fetch_training_trace()
        except Exception as exc:  # noqa: BLE001 - recorded, not raised: it is what we measure
            trace_ok, trace_err = False, f"{type(exc).__name__}: {exc}"
        result = session.result.model_dump() if session.result is not None else None
    finally:
        session.close()
    record = {"rc": rc, "env_reward": verdict.env_reward, "training_trace_ok": trace_ok,
              "training_trace_error": trace_err, "result": result}
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump([record], fh)
    print(json.dumps({k: v for k, v in record.items() if k != "result"}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
