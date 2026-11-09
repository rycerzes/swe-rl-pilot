# Step 1: one full rollout on HF (2026-11-09)

Job `6af1d9ea9737d9a9e08c9fd6` (l4x1, vllm/vllm-openai:v0.33.0, 32 min, ~$0.43), commit 8d9b9a6.
Artifacts: bucket `rycerzes/swe-rl-pilot`, `step1/6af1d9ea9737d9a9e08c9fd6-20261109T143750Z/`.
Stack: OpenEnv e83f73f2 + Harbor 0.25.0 (patched: tar --no-same-owner, litellm[mcp]), mini-swe-agent 2.4.6,
HF Sandbox (agent + separate verifier), capture proxy published with cloudflared.

| Phase | Model | Task | Result |
|---|---|---|---|
| 0 (Mac) | DeepSeek-V4.1-Flash (HF Inference Providers) | 1342 | reward 1.0, 29 turns, eval only |
| 0 (job) | DeepSeek-V4.1-Flash | 1342 | reward 1.0, 17 turns, eval only |
| A | Qwen3.5-4B on vLLM 0.33.0 | 1309 | reward 1.0, 86 turns, 690 s, 9,002 trainable tokens |
| A | Qwen3.5-4B | 1322 | SandboxError (HF Sandbox API 503), reward None |
| A | Qwen3.5-4B | 1342 | reward 1.0, 62 turns, 568 s, 10,996 trainable tokens |
| B | Qwen3.5-4B, agent_step_limit=4 | 1342 | graded 0.0, 4 turns, training trace valid |

Capture checks (all captured rollouts): every turn has prompt and completion token ids and one
logprob per completion token (finite, <= 0); every consecutive turn's prompt extends the previous
prompt + completion exactly (146/146 pairs); all finish reasons `tool_calls`; largest prompt 35k tokens.

Findings for later steps:
- Ungraded vs failed: an HF Sandbox 503 gives reward None (correct). An agent that crashes on start
  (the litellm/mcp bug before the patch) gives reward 0.0 with ok=False: the reward function must
  return None for agent crashes / zero model calls, or it trains on infra failures.
- Truncation: a step-capped rollout is graded on its partial work (0.0) with no limit marker in the
  result; detect it from n_turns == step limit and decide the policy (mask vs 0) before training.
- Difficulty: Qwen3.5-4B solved 2/2 graded tasks. more-itertools tasks may be too easy and get
  filtered out at step 3 (pass rate 1); harder repos are needed for step 2.
- Instruction leakage: task 1342's PR description names the hidden tests and what they check.
- Infra: 1 of 3 Qwen rollouts lost to an HF Sandbox 503; needs retries and an infra-failure rate.
