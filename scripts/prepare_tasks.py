"""Turn Repo2RLEnv output into tasks CI can build: inline Dockerfile + content-addressed image.

Usage (from the repo root, where `workspace/bootstrap` holds the bootstrap cache):

    gen/.venv/bin/python scripts/prepare_tasks.py workspace/gen/<dataset> tasks

For each generated task this:
  1. bakes the bootstrap recipe into `environment/Dockerfile` (Repo2RLEnv's inline mode),
     so the image builds from a public base with no local image;
  2. sets `[environment].docker_image` to `<registry>:<task>-<hash of environment/>`,
     which the build workflow pushes and HF Sandbox pulls.

The hash covers every file under `environment/`, so a changed recipe gets a new tag and an
unchanged one is never rebuilt.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
import tomllib
from pathlib import Path

import tomli_w
from repo2rlenv.registry.integration import prepare_dataset_for_push

REGISTRY = "ghcr.io/rycerzes/swe-rl-pilot"


def environment_hash(env_dir: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in env_dir.rglob("*") if p.is_file()):
        digest.update(path.relative_to(env_dir).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()[:12]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("generated", type=Path, help="a `repo2rlenv generate --out` directory")
    parser.add_argument("out", type=Path, help="where the prepared tasks go (e.g. tasks/)")
    parser.add_argument("--registry", default=REGISTRY)
    parser.add_argument("--replace", action="store_true", help="redo tasks already in `out`")
    args = parser.parse_args()

    sources = sorted(p.parent for p in args.generated.glob("*/task.toml"))
    if not args.replace:
        # Re-preparing only refreshes timestamps; leave committed tasks alone.
        sources = [s for s in sources if not (args.out / s.name).exists()]
    if not sources:
        print(f"no new tasks under {args.generated}")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        for src in sources:
            shutil.copytree(src, staging / src.name)
        result = prepare_dataset_for_push(
            staging, hf_owner="rycerzes", inline_dockerfile=True, on_message=print
        )
        if result.mode != "inline_dockerfile":
            print(f"expected inline mode, got {result.mode}", file=sys.stderr)
            return 1
        args.out.mkdir(parents=True, exist_ok=True)
        for task in sorted(p.parent for p in staging.glob("*/task.toml")):
            toml_path = task / "task.toml"
            data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
            image = f"{args.registry}:{task.name}-{environment_hash(task / 'environment')}"
            data.setdefault("environment", {})["docker_image"] = image
            toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
            dest = args.out / task.name
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(task, dest)
            print(f"{task.name}  {image}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
