"""Choose which prebuilt-image tasks to mirror off Docker Hub, deterministically.

Usage: python3 scripts/select_mirror.py DATASET_DIR OUT.tsv --lang python=600 --lang go=400
       [--per-repo 5] [--exclude-repo owner/name ...] [--seed 20261111]

DATASET_DIR is a `harbor download` export (one task directory per task). Keeps tasks with no
`quality_flags`, at most --per-repo per repository (breadth over depth), none from the excluded
repos (our own Repo2RLEnv repos, so a mirrored task can't share a PR with our eval split), and
writes `task<TAB>language<TAB>source image` for mirror-images.yml.
"""

from __future__ import annotations

import argparse
import random
import sys
import tomllib
from collections import defaultdict
from pathlib import Path

OUR_REPOS = ["gohugoio/hugo", "gofiber/fiber", "networkx/networkx", "more-itertools/more-itertools"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--lang", action="append", required=True, help="language=count")
    parser.add_argument("--per-repo", type=int, default=5)
    parser.add_argument("--exclude-repo", nargs="*", default=OUR_REPOS)
    parser.add_argument("--seed", type=int, default=20261111)
    args = parser.parse_args()

    want = {k: int(v) for k, v in (spec.split("=", 1) for spec in args.lang)}
    pools: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    for toml_path in sorted(args.dataset.glob("*/task.toml")):
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        meta = data.get("metadata", {})
        lang = meta.get("language")
        if lang not in want or meta.get("quality_flags") or meta.get("repo") in args.exclude_repo:
            continue
        image = data.get("environment", {}).get("docker_image", "")
        if "@sha256:" not in image:
            continue  # mirror only digest-pinned images, so the copy is verifiably identical
        pools[lang].append((toml_path.parent.name, meta.get("repo", ""), image))

    rng = random.Random(args.seed)
    rows = []
    for lang, count in want.items():
        per_repo: dict[str, int] = defaultdict(int)
        picked = 0
        for task, repo, image in rng.sample(pools[lang], len(pools[lang])):
            if per_repo[repo] >= args.per_repo:
                continue
            per_repo[repo] += 1
            rows.append((task, lang, image))
            picked += 1
            if picked == count:
                break
        print(f"{lang}: {picked} tasks from {len(per_repo)} repos (pool {len(pools[lang])})")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(f"{t}\t{l}\t{i}\n" for t, l, i in sorted(rows)), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
