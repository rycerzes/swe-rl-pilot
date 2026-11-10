"""Rebuild a repo's bootstrap image from its committed cache slot, so `generate` gets a cache hit.

Usage: python scripts/restore_bootstrap.py bootstrap/<owner>__<name>/<slot> [--cache-dir workspace/bootstrap]

Bootstrapping a repo runs an LLM agent once (locally, `repo2rlenv bootstrap`). Its cache slot,
`bootstrap.json` plus the reconstructed Dockerfile, is committed under `bootstrap/`. On a fresh
machine (CI) Repo2RLEnv sees the slot but not the image and would re-bootstrap. This script
copies the slot into the cache dir and builds the image from the slot's clean recipe (clone at
the bootstrap ref, then its verified `rebuild_cmds`), the same recipe inline task Dockerfiles
use, and tags it with the slot's `image_tag`.

`generate` only finds the slot if it asks for the same ref and the same image options: the slot
name ends in a hash of them (`--language`, `--base-image`). This works out which flags reproduce
that hash and prints them with the ref, for `$GITHUB_OUTPUT`:
`ref=<sha>` and `args=<flags for generate>`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from repo2rlenv.bootstrap.cache import _options_hash
from repo2rlenv.registry.integration import _build_clean_recipe


def generate_flags(slot: Path, data: dict) -> list[str]:
    """The --language/--base-image flags whose options hash matches the slot's name."""
    want = slot.name.rpartition("__")[2]
    recipe = data.get("dockerfile_reconstruction") or ""
    base = next((l.split()[1] for l in recipe.splitlines() if l.upper().startswith("FROM ")), None)
    for language in (None, data.get("language")):
        for base_image in (None, base):
            opts = {"platform": "linux/amd64", "base_image": base_image, "user_dockerfile": None,
                    "image_registry": None, "languages_hint": [language] if language else None}
            if _options_hash(opts) == want:
                return (["--language", language] if language else []) + (
                    ["--base-image", base_image] if base_image else [])
    raise SystemExit(f"{slot}: no --language/--base-image combination reproduces hash {want}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slot", type=Path)
    parser.add_argument("--cache-dir", type=Path, default=Path("workspace/bootstrap"))
    args = parser.parse_args()

    data = json.loads((args.slot / "bootstrap.json").read_text(encoding="utf-8"))
    flags = generate_flags(args.slot, data)
    owner, name = data["repo"].split("/", 1)
    recipe = _build_clean_recipe(owner, name, data)
    if recipe is None:
        print(f"{args.slot}: no rebuild_cmds, can't rebuild", file=sys.stderr)
        return 1

    dest = args.cache_dir / args.slot.parent.name / args.slot.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.slot, dest, dirs_exist_ok=True)

    with tempfile.TemporaryDirectory() as ctx:
        (Path(ctx) / "Dockerfile").write_text(recipe, encoding="utf-8")
        cmd = ["docker", "build", "--platform", "linux/amd64", "-t", data["image_tag"], ctx]
        print("+", " ".join(cmd), file=sys.stderr, flush=True)
        subprocess.run(cmd, check=True)
    print(f"ref={data['ref']}")
    print(f"args={' '.join(flags)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
