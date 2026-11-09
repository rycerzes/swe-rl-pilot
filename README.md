# swe-rl-pilot

A small end-to-end SWE-agent RL pilot: Repo2RLEnv tasks, an unmodified coding agent in
HF Sandbox, token-faithful capture through OpenEnv `harbor_env`, TRL AsyncGRPO.

This repo holds the tasks and builds their images. HF Sandbox only starts from a prebuilt,
publicly pullable image, so each task's `environment/Dockerfile` is built here by CI.

## Layout

- `gen/`: the generation environment, pinned to a Repo2RLEnv commit (`uv sync --no-config`).
- `tasks/`: Harbor tasks. Each `task.toml` names its image in `[environment].docker_image`.
- `scripts/prepare_tasks.py`: generated output → CI-buildable tasks (inline Dockerfile,
  content-addressed image tag).
- `scripts/plan_images.py`, `scripts/check_controls.py`: used by the workflow.
- `.github/workflows/build-images.yml`: builds missing images (linux/amd64), pushes them to
  `ghcr.io/rycerzes/swe-rl-pilot`, then pulls each one anonymously and checks its controls
  (oracle 1.0 and resolved, nop 0.0) with Harbor.

## Adding tasks

```sh
cd gen && UV_NO_CONFIG=1 uv sync && cd ..
# The bootstrap cache lives in workspace/bootstrap (not committed).
gen/.venv/bin/repo2rlenv generate --repo <owner/name> --pipeline pr_runtime \
    --pipeline-opt limit=15 --llm <provider/model> --out workspace/gen/<name>
gen/.venv/bin/python scripts/prepare_tasks.py workspace/gen/<name> tasks
git add tasks && git commit && git push   # CI builds and checks the new images
```

The image tag is `<task>-<hash of environment/>`, so only changed or new tasks rebuild.
