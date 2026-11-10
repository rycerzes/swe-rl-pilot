"""Turn Repo2RLEnv output into tasks CI can build: inline Dockerfile + content-addressed image.

Usage (from the repo root, where `workspace/bootstrap` holds the bootstrap cache):

    gen/.venv/bin/python scripts/prepare_tasks.py workspace/gen/<dataset> tasks
    gen/.venv/bin/python scripts/prepare_tasks.py --refresh tasks   # re-apply 2-3 in place

For each generated task this:
  1. bakes the bootstrap recipe into `environment/Dockerfile` (Repo2RLEnv's inline mode),
     so the image builds from a public base with no local image;
  2. adds `scrub_history.sh` before the verifier's pristine copy, so the image keeps no git
     objects past the base commit and the build fails if any survive;
  3. sets `[environment].docker_image` to `<registry>:<task>-<hash of environment/>`,
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

REGISTRY = "ghcr.io/rycerzes/swe-rl-pilot"
SCRUB = Path(__file__).with_name("scrub_history.sh")
# The verifier rebuilds /workspace from this copy, so the scrub has to run before it.
PRISTINE_COPY = "RUN mkdir -p /opt/r2e && cp -a /workspace /opt/r2e/pristine"
SCRUB_STEP = (
    "# swe-rl-pilot: drop git objects past the base commit, fail if any survive\n"
    "COPY scrub_history.sh /tmp/scrub_history.sh\n"
    "RUN sh /tmp/scrub_history.sh && rm /tmp/scrub_history.sh\n"
)


def environment_hash(env_dir: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in env_dir.rglob("*") if p.is_file()):
        digest.update(path.relative_to(env_dir).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()[:12]


def add_scrub(task: Path) -> None:
    env = task / "environment"
    shutil.copyfile(SCRUB, env / SCRUB.name)
    dockerfile = env / "Dockerfile"
    text = dockerfile.read_text(encoding="utf-8")
    if SCRUB_STEP in text:
        return
    if text.count(PRISTINE_COPY) != 1:
        raise SystemExit(f"{task.name}: expected one `{PRISTINE_COPY}` line in the Dockerfile")
    dockerfile.write_text(text.replace(PRISTINE_COPY, SCRUB_STEP + PRISTINE_COPY), encoding="utf-8")


def set_image(task: Path, registry: str) -> str:
    toml_path = task / "task.toml"
    data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
    image = f"{registry}:{task.name}-{environment_hash(task / 'environment')}"
    data.setdefault("environment", {})["docker_image"] = image
    toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
    return image


def finish(task: Path, registry: str) -> None:
    add_scrub(task)
    print(f"{task.name}  {set_image(task, registry)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path,
                        help="GENERATED OUT, or just OUT with --refresh")
    parser.add_argument("--registry", default=REGISTRY)
    parser.add_argument("--replace", action="store_true", help="redo tasks already in `out`")
    parser.add_argument("--refresh", action="store_true",
                        help="re-apply the scrub and image tag to already prepared tasks")
    args = parser.parse_args()

    if args.refresh:
        if len(args.paths) != 1:
            parser.error("--refresh takes one directory of prepared tasks")
        for task in sorted(p.parent for p in args.paths[0].glob("*/task.toml")):
            finish(task, args.registry)
        return 0
    if len(args.paths) != 2:
        parser.error("expected GENERATED OUT")
    generated, out = args.paths

    from repo2rlenv.registry.integration import prepare_dataset_for_push

    sources = sorted(p.parent for p in generated.glob("*/task.toml"))
    if not args.replace:
        # Re-preparing only refreshes timestamps; leave committed tasks alone.
        sources = [s for s in sources if not (out / s.name).exists()]
    if not sources:
        print(f"no new tasks under {generated}")
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
        out.mkdir(parents=True, exist_ok=True)
        for task in sorted(p.parent for p in staging.glob("*/task.toml")):
            finish(task, args.registry)
            dest = out / task.name
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(task, dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
