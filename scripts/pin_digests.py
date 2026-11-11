"""Pin each task's image by digest once CI has pushed it.

Usage: python3 scripts/pin_digests.py tasks [--check]

For every task whose `[environment].docker_image` is still the content-addressed tag
(`[metadata.swe_rl_pilot].image_tag`), asks the registry for that tag's digest, anonymously
(as HF Sandbox pulls), and rewrites docker_image to `<repository>@sha256:...`. A pinned task
then runs exactly the image its controls were checked on, even if the tag moves. --check only
reports tasks that aren't pinned yet (non-zero exit if any). Needs `crane` on PATH or $CRANE.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tomllib
from pathlib import Path

import tomli_w


def main() -> int:
    root = Path(sys.argv[1])
    check = "--check" in sys.argv[2:]
    crane = os.environ.get("CRANE", "crane")
    env = {**os.environ, "DOCKER_CONFIG": "/nonexistent-anonymous"}  # resolve as an anonymous puller
    unpinned = 0
    for toml_path in sorted(root.glob("*/task.toml")):
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        image = data["environment"]["docker_image"]
        if "@sha256:" in image:
            continue
        unpinned += 1
        if check:
            print(f"unpinned: {toml_path.parent.name}")
            continue
        tag = data.get("metadata", {}).get("swe_rl_pilot", {}).get("image_tag") or image
        found = subprocess.run([crane, "digest", tag], capture_output=True, text=True, env=env)
        if found.returncode != 0:
            print(f"{toml_path.parent.name}: no digest for {tag}: {found.stderr.strip()[:200]}")
            continue
        repository = tag.rsplit(":", 1)[0]
        data["environment"]["docker_image"] = f"{repository}@{found.stdout.strip()}"
        data.setdefault("metadata", {}).setdefault("swe_rl_pilot", {})["image_tag"] = tag
        toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
        unpinned -= 1
        print(f"{toml_path.parent.name}: {data['environment']['docker_image']}")
    return 1 if check and unpinned else 0


if __name__ == "__main__":
    sys.exit(main())
