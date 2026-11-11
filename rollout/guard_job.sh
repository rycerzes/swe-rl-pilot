#!/usr/bin/env bash
# Guard check on one HF GPU Job: the step-1 stack with every guard on, measured end to end.
#
#   hf jobs run --detach --flavor l4x1 --timeout 3h --secrets HF_TOKEN \
#       -v hf://buckets/rycerzes/swe-rl-pilot:/data vllm/vllm-openai:v0.33.0 \
#       bash -c "apt-get update -qq && apt-get install -y -qq git >/dev/null && \
#                git clone -q --depth 1 https://github.com/rycerzes/swe-rl-pilot /work/pilot && \
#                bash /work/pilot/rollout/guard_job.sh"
#
# Guards under test:
#   - [agent].user = learner on HF Sandbox (rollout/egress/pilot_harbor_egress.py, Harbor H1 fix);
#   - the egress jail: during the agent's run, TCP only to an allowlist proxy that admits the
#     capture tunnel (PILOT_EGRESS_ALLOW);
#   - atif-scan + rollout/guards/pr_runtime_pack.py on every rollout's trace, and the training
#     reward (rollout/reward.py) that turns denials and HIGH findings into 0 and infra into None;
#   - wrapped SWE-rebench tasks (separate verifier) next to ours.
#
# Phases:
#   A. Qwen3.5-4B on vLLM with token capture, one rollout per guard task;
#   B. DeepSeek-V4.1-Flash (HF router, no capture) on two tasks: it probed the grader and the
#      sandbox in a local run, so it exercises the guards;
#   C. check_capture.py (token-faithful turns with the jail on) + guard_report.py.
set -uo pipefail

MODEL="${MODEL:-Qwen/Qwen3.5-4B}"
EVAL_MODEL="${EVAL_MODEL:-deepseek-ai/DeepSeek-V4.1-Flash}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
ATIF_SCAN_REF="${ATIF_SCAN_REF:-3bbaf3c}"
OUT="/data/guard/${JOB_ID:-local}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
echo "[job] out=$OUT model=$MODEL"

pip install -q uv
cd /work/pilot
git rev-parse HEAD > "$OUT/pilot_commit"
(cd rollout && UV_PYTHON=3.12 uv sync --frozen -q) || { echo "[job] uv sync failed"; exit 1; }
RV=/work/pilot/rollout/.venv/bin
$RV/python rollout/patch_harbor.py
OPENENV_REV=$(grep -o 'OpenEnv@[0-9a-f]*' rollout/pyproject.toml | cut -d@ -f2)
git clone -q --filter=blob:none https://github.com/openenv/OpenEnv /work/OpenEnv
git -C /work/OpenEnv checkout -q "$OPENENV_REV"
export PYTHONPATH=/work/OpenEnv/envs

# atif-scan for the per-rollout guard scan, pinned.
uv tool install -q "git+https://github.com/huggingface/atif-scan@${ATIF_SCAN_REF}" \
    || { echo "[job] atif-scan install failed"; exit 1; }
export ATIF_SCAN="$(command -v atif-scan || echo "$HOME/.local/bin/atif-scan")"

CF_VERSION=2026.10.7
CF_SHA256=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872
curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-amd64"
echo "$CF_SHA256  /usr/local/bin/cloudflared" | sha256sum -c - || { echo "[job] cloudflared checksum mismatch"; exit 1; }
chmod 755 /usr/local/bin/cloudflared

$RV/python rollout/make_guard_tasks.py /work/guard-tasks | tee "$OUT/tasks.txt" \
    || { echo "[job] guard task set failed"; exit 1; }
N_TASKS=$(ls /work/guard-tasks | wc -l)

VLLM_SERVER_DEV_MODE=1 vllm serve "$MODEL" --host 127.0.0.1 --port 8000 \
    --max-model-len "$MAX_MODEL_LEN" \
    --enable-auto-tool-choice --tool-call-parser qwen3_xml \
    --reasoning-parser qwen3 \
    --default-chat-template-kwargs '{"enable_thinking": false}' \
    --logprobs-mode processed_logprobs \
    --return-tokens-as-token-ids > "$OUT/vllm.log" 2>&1 &
VLLM_PID=$!
for i in $(seq 1 240); do
    curl -sf http://127.0.0.1:8000/health >/dev/null && break
    kill -0 $VLLM_PID 2>/dev/null || { echo "[job] vLLM died"; tail -50 "$OUT/vllm.log"; exit 1; }
    sleep 5
done
curl -sf http://127.0.0.1:8000/health >/dev/null || { echo "[job] vLLM not ready"; exit 1; }

export OPENENV_HARBOR_AGENT_VERSIONS='{"mini-swe-agent":"2.4.6"}'
# The capture proxy is published as https://<random>.trycloudflare.com: the only host the
# agent may reach while it runs.
export PILOT_EGRESS_ALLOW=".trycloudflare.com"

echo "[job] phase A: $MODEL on $N_TASKS guard tasks (jail on, agent user learner)"
$RV/openenv harbor rollout --llm-url http://127.0.0.1:8000 --model "$MODEL" \
    --dataset /work/guard-tasks --task-index 0 -n "$N_TASKS" \
    --harness mini-swe-agent --sandbox hf-sandbox --expose cloudflare \
    --trials-dir "$OUT/trials-A" --out "$OUT/rollouts-A.json"
echo "[job] phase A rc=$?"

echo "[job] phase B: $EVAL_MODEL on 2 tasks (hosted, no capture)"
OPENENV_LLM_API_KEY="$HF_TOKEN" $RV/openenv harbor rollout --llm-url https://router.huggingface.co/v1 \
    --model "$EVAL_MODEL" --dataset /work/guard-tasks --task-index 0 -n 2 \
    --harness mini-swe-agent --sandbox hf-sandbox --expose cloudflare \
    --trials-dir "$OUT/trials-B" --out "$OUT/rollouts-B.json"
echo "[job] phase B rc=$?"

echo "[job] phase C: capture checks + guard report"
$RV/python rollout/check_capture.py --model "$MODEL" "$OUT/rollouts-A.json" --out "$OUT/capture.json"
echo "[job] capture rc=$?"
$RV/python rollout/guard_report.py --trials-root "$OUT" "$OUT/rollouts-A.json" "$OUT/rollouts-B.json" \
    --out "$OUT/guard.json"
echo "[job] guard report rc=$?"
echo "[job] done: $OUT"
