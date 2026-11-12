#!/usr/bin/env bash
# Step 3 baseline on one HF GPU Job: K attempts per task on the training path, guards on.
#
#   hf jobs run --detach --flavor a100-large --timeout 3h --secrets HF_TOKEN \
#       -e RUN=calib1 -e PER_REPO=4 -e ATTEMPTS=2 -e WORKERS=32 \
#       -v hf://buckets/rycerzes/swe-rl-pilot:/data vllm/vllm-openai:v0.33.0 \
#       bash -c "apt-get update -qq && apt-get install -y -qq git >/dev/null && \
#                git clone -q --depth 1 https://github.com/rycerzes/swe-rl-pilot /work/pilot && \
#                bash /work/pilot/rollout/step3_job.sh"
#
# Same stack as guard job 4b (vLLM 0.33 with token capture, mini-swe-agent 2.4.6, OpenEnv 029c08f8,
# Harbor 0.25 + our patches, learner user, egress jail, atif-scan guard) with three changes:
#   - rollouts go through `openenv harbor serve` + HarborSessionFactory (rollout/baseline.py), the
#     path TRL drives in training: one capture proxy and tunnel, many concurrent sessions;
#   - sampling is pinned per session (temperature 1.0, full vocabulary) and vLLM ignores the
#     model's generation config, instead of inheriting defaults;
#   - a step cap (STEP_LIMIT model calls) bounds each rollout, with the wall-clock timeout raised to
#     AGENT_TIMEOUT so a busy GPU doesn't turn slow rollouts into failures.
# Output: /data/step3/$RUN (resumable: re-run with the same RUN to finish a stopped run).
#
# Knobs (env): RUN, ATTEMPTS (8), WORKERS (32), PER_REPO (0 = all tasks), NAMES, SECTIONS
# (train,eval_time), STEP_LIMIT (150), AGENT_TIMEOUT (3600), MAX_ROLLOUTS (0), MAX_NUM_SEQS,
# GPU_PER_HOUR (for the report; a100-large 2.5).
set -uo pipefail

MODEL="${MODEL:-Qwen/Qwen3.5-4B}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
ATIF_SCAN_REF="${ATIF_SCAN_REF:-3bbaf3c}"
RUN="${RUN:-${JOB_ID:-local}}"
ATTEMPTS="${ATTEMPTS:-8}"
WORKERS="${WORKERS:-32}"
PER_REPO="${PER_REPO:-0}"
NAMES="${NAMES:-}"
SECTIONS="${SECTIONS:-train,eval_time}"
STEP_LIMIT="${STEP_LIMIT:-150}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-3600}"
MAX_ROLLOUTS="${MAX_ROLLOUTS:-0}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-$((WORKERS * 2))}"
GPU_PER_HOUR="${GPU_PER_HOUR:-2.5}"
OUT="/data/step3/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job-${JOB_ID:-local}.log") 2>&1
echo "[job] out=$OUT model=$MODEL attempts=$ATTEMPTS workers=$WORKERS step_limit=$STEP_LIMIT"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

pip install -q uv
cd /work/pilot
git rev-parse HEAD > "$OUT/pilot_commit-${JOB_ID:-local}"
(cd rollout && UV_PYTHON=3.12 uv sync --frozen -q) || { echo "[job] uv sync failed"; exit 1; }
RV=/work/pilot/rollout/.venv/bin
$RV/python rollout/patch_harbor.py
OPENENV_REV=$(grep -o 'OpenEnv@[0-9a-f]*' rollout/pyproject.toml | cut -d@ -f2)
git clone -q --filter=blob:none https://github.com/openenv/OpenEnv /work/OpenEnv
git -C /work/OpenEnv checkout -q "$OPENENV_REV"
export PYTHONPATH=/work/OpenEnv/envs

uv tool install -q "git+https://github.com/huggingface/atif-scan@${ATIF_SCAN_REF}" \
    || { echo "[job] atif-scan install failed"; exit 1; }
export ATIF_SCAN="$(command -v atif-scan || echo "$HOME/.local/bin/atif-scan")"

CF_VERSION=2026.10.7
CF_SHA256=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872
curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-amd64"
echo "$CF_SHA256  /usr/local/bin/cloudflared" | sha256sum -c - || { echo "[job] cloudflared checksum mismatch"; exit 1; }
chmod 755 /usr/local/bin/cloudflared

(cd rollout && $RV/python make_baseline_tasks.py /work/tasks --sections "$SECTIONS" \
    --per-repo "$PER_REPO" --names "$NAMES") | tee "$OUT/tasks-${JOB_ID:-local}.txt" \
    || { echo "[job] task set failed"; exit 1; }

# --generation-config vllm: no model-supplied sampling defaults; the session pins the policy.
VLLM_SERVER_DEV_MODE=1 vllm serve "$MODEL" --host 127.0.0.1 --port 8000 \
    --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" \
    --gpu-memory-utilization 0.92 --generation-config vllm \
    --enable-auto-tool-choice --tool-call-parser qwen3_xml \
    --reasoning-parser qwen3 \
    --default-chat-template-kwargs '{"enable_thinking": false}' \
    --logprobs-mode processed_logprobs \
    --return-tokens-as-token-ids > "$OUT/vllm-${JOB_ID:-local}.log" 2>&1 &
VLLM_PID=$!
for i in $(seq 1 240); do
    curl -sf http://127.0.0.1:8000/health >/dev/null && break
    kill -0 $VLLM_PID 2>/dev/null || { echo "[job] vLLM died"; tail -50 "$OUT/vllm-${JOB_ID:-local}.log"; exit 1; }
    sleep 5
done
curl -sf http://127.0.0.1:8000/health >/dev/null || { echo "[job] vLLM not ready"; exit 1; }
grep -m1 "GPU KV cache size" "$OUT/vllm-${JOB_ID:-local}.log"

export OPENENV_HARBOR_AGENT_VERSIONS='{"mini-swe-agent":"2.4.6"}'
export OPENENV_HARBOR_TRIALS_DIR=/work/trials
export PILOT_EGRESS_ALLOW=".trycloudflare.com"

MAX_CONCURRENT_ENVS=$((WORKERS + 4)) $RV/openenv harbor serve --dataset /work/tasks \
    --port 8200 --capture-port 8300 --expose cloudflare > "$OUT/serve-${JOB_ID:-local}.log" 2>&1 &
SERVE_PID=$!
for i in $(seq 1 90); do
    grep -q "trycloudflare.com" "$OUT/serve-${JOB_ID:-local}.log" 2>/dev/null && break
    kill -0 $SERVE_PID 2>/dev/null || { echo "[job] serve died"; tail -50 "$OUT/serve-${JOB_ID:-local}.log"; exit 1; }
    sleep 5
done
grep -q "trycloudflare.com" "$OUT/serve-${JOB_ID:-local}.log" || { echo "[job] capture tunnel not up"; exit 1; }
sleep 10

echo "[job] baseline"
$RV/python rollout/baseline.py --server http://127.0.0.1:8200 --llm-url http://127.0.0.1:8000 \
    --model "$MODEL" --attempts "$ATTEMPTS" --workers "$WORKERS" --step-limit "$STEP_LIMIT" \
    --agent-timeout "$AGENT_TIMEOUT" --max-rollouts "$MAX_ROLLOUTS" --out "$OUT"
echo "[job] baseline rc=$?"

$RV/python rollout/baseline_report.py "$OUT" --gpu-per-hour "$GPU_PER_HOUR" > /dev/null
echo "[job] report rc=$?"
python3 -c "import json;r=json.load(open('$OUT/report.json'));[print(k, json.dumps(r[k])) for k in ('rollouts','ungraded_rate','reasons','solve_rate','raw_solve_rate','gate','filter','solve_rate_at_cap','cost','trainable_tokens')]"
echo "[job] done: $OUT"
