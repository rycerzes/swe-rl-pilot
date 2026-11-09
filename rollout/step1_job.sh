#!/usr/bin/env bash
# Step 1 on one HF GPU Job: vLLM serves the policy with token capture, OpenEnv runs mini-swe-agent
# on our tasks in HF Sandbox (agent and separate verifier), and every result lands in a bucket.
#
#   hf jobs run --flavor l4x1 --secrets HF_TOKEN --timeout 2h \
#       --volume type=bucket,source=rycerzes/swe-rl-pilot,mount_path=/data \
#       vllm/vllm-openai:v0.33.0 bash -c "curl -fsSL <raw url of this file> | bash"
#
# Tunnels: cloudflared only (pinned, checksum-verified). Never gradio/frpc.
#
# Phases:
#   0. eval rollout with a hosted model via HF Inference Providers (graded, no token capture)
#   A. full rollouts with `openenv harbor rollout` (the task's own time limit, no step cap)
#   B. one capped rollout through `openenv harbor serve` + HarborSessionFactory (truncation)
#   C. check_capture.py over all results -> summary.json
set -uo pipefail

MODEL="${MODEL:-Qwen/Qwen3.5-4B}"
REPO_REF="${REPO_REF:-main}"
FIRST_TASK="${FIRST_TASK:-4}"      # tasks are sorted by name; 4..6 = 1309, 1322, 1342
N_TASKS="${N_TASKS:-3}"
STEP_LIMIT="${STEP_LIMIT:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
OUT="/data/step1/${JOB_ID:-local}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
echo "[job] out=$OUT model=$MODEL"

# vLLM image's python stays for vLLM; OpenEnv + Harbor get their own venv from our lock.
pip install -q uv
git clone -q --depth 1 --branch "$REPO_REF" https://github.com/rycerzes/swe-rl-pilot /work/pilot
cd /work/pilot
git rev-parse HEAD > "$OUT/pilot_commit"
(cd rollout && UV_PYTHON=3.12 uv sync --frozen -q) || { echo "[job] uv sync failed"; exit 1; }
RV=/work/pilot/rollout/.venv/bin
$RV/python rollout/patch_harbor.py
# harbor_env.harness is not in the packaged wheel: use the source at the locked OpenEnv commit.
OPENENV_REV=$(grep -o 'OpenEnv@[0-9a-f]*' rollout/pyproject.toml | cut -d@ -f2)
git clone -q --filter=blob:none https://github.com/openenv/OpenEnv /work/OpenEnv
git -C /work/OpenEnv checkout -q "$OPENENV_REV"
export PYTHONPATH=/work/OpenEnv/envs

CF_VERSION=2026.10.7
CF_SHA256=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872
curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-amd64"
echo "$CF_SHA256  /usr/local/bin/cloudflared" | sha256sum -c - || { echo "[job] cloudflared checksum mismatch"; exit 1; }
chmod 755 /usr/local/bin/cloudflared

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
echo "[job] vLLM ready: $(python3 -c 'import vllm;print(vllm.__version__)')"

export OPENENV_HARBOR_AGENT_VERSIONS='{"mini-swe-agent":"2.4.6"}'
EVAL_MODEL="${EVAL_MODEL:-deepseek-ai/DeepSeek-V4.1-Flash}"

echo "[job] phase 0: eval rollout with $EVAL_MODEL (hosted, no capture)"
OPENENV_LLM_API_KEY="$HF_TOKEN" $RV/openenv harbor rollout --llm-url https://router.huggingface.co/v1 \
    --model "$EVAL_MODEL" --dataset tasks --task-index 6 \
    --harness mini-swe-agent --sandbox hf-sandbox --expose cloudflare \
    --trials-dir "$OUT/trials-0" --out "$OUT/rollouts-0.json"
echo "[job] phase 0 rc=$?"

echo "[job] phase A: full rollouts"
$RV/openenv harbor rollout --llm-url http://127.0.0.1:8000 --model "$MODEL" \
    --dataset tasks --task-index "$FIRST_TASK" -n "$N_TASKS" \
    --harness mini-swe-agent --sandbox hf-sandbox --expose cloudflare \
    --trials-dir "$OUT/trials-A" --out "$OUT/rollouts-A.json"
echo "[job] phase A rc=$?"

echo "[job] phase B: capped rollout (agent_step_limit=$STEP_LIMIT)"
MAX_CONCURRENT_ENVS=2 $RV/openenv harbor serve --dataset tasks --port 8200 --capture-port 8300 \
    --expose cloudflare > "$OUT/serve.log" 2>&1 &
for i in $(seq 1 90); do curl -s -o /dev/null http://127.0.0.1:8200/ && break; sleep 5; done
sleep 10  # the capture tunnel publishes after the HTTP server is up
$RV/python rollout/capped_rollout.py --server http://127.0.0.1:8200 --llm-url http://127.0.0.1:8000 \
    --model "$MODEL" --task-index 6 --step-limit "$STEP_LIMIT" --out "$OUT/rollouts-B.json"
echo "[job] phase B rc=$?"

echo "[job] phase C: capture checks"
$RV/python rollout/check_capture.py --model "$MODEL" "$OUT/rollouts-0.json" "$OUT/rollouts-A.json" "$OUT/rollouts-B.json" \
    --out "$OUT/summary.json"
echo "[job] phase C rc=$?"
echo "[job] done: $OUT"
