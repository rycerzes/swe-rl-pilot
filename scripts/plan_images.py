"""List tasks whose image is not in the registry yet, as a GitHub Actions matrix.

Usage: python3 scripts/plan_images.py tasks [--all]

Prints `matrix=<json>` and `count=<n>` for $GITHUB_OUTPUT. `--all` lists every task, for a
rebuild or a re-check of the controls. Standard library only.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tomllib
from pathlib import Path


def image_exists(image: str) -> bool:
    probe = subprocess.run(
        ["docker", "manifest", "inspect", image], capture_output=True, text=True, check=False
    )
    return probe.returncode == 0


def main() -> int:
    root = Path(sys.argv[1])
    every = "--all" in sys.argv[2:]
    include = []
    for toml_path in sorted(root.glob("*/task.toml")):
        data = tomllib.loads(toml_path.read_text())
        # The tag CI pushes; docker_image may already be pinned to its digest.
        image = data.get("metadata", {}).get("swe_rl_pilot", {}).get("image_tag") \
            or data["environment"]["docker_image"]
        if every or not image_exists(image):
            include.append({"task": toml_path.parent.name, "image": image})
    print(f"matrix={json.dumps({'include': include})}")
    print(f"count={len(include)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
