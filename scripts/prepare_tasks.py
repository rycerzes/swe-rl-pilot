"""Turn Repo2RLEnv output into tasks CI can build: inline Dockerfile + content-addressed image.

Usage (from the repo root, where `workspace/bootstrap` holds the bootstrap cache):

    gen/.venv/bin/python scripts/prepare_tasks.py workspace/gen/<dataset> tasks
    gen/.venv/bin/python scripts/prepare_tasks.py --refresh tasks   # re-apply 2-4 in place

For each generated task this:
  1. bakes the bootstrap recipe into `environment/Dockerfile` (Repo2RLEnv's inline mode),
     so the image builds from a public base with no local image;
  2. adds `scrub_history.sh` before the verifier's pristine copy, so the image keeps no git
     objects past the base commit and the build fails if any survive; for Go recipes, first
     downloads the base commit's modules;
  3. strips PR-body sections that describe the fix or its tests from `instruction.md`, and
     records them and any hidden test the instruction still names under
     `[metadata.swe_rl_pilot]`;
  4. sets `[environment].docker_image` to `<registry>:<task>-<hash of environment/>`,
     which the build workflow pushes and HF Sandbox pulls.

The hash covers every file under `environment/`, so a changed recipe gets a new tag and an
unchanged one is never rebuilt.
"""

from __future__ import annotations

import argparse
import hashlib
import re
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


# The recipe downloads Go modules at the bootstrap ref; the grader then runs the tests with a
# read-only module cache, so a base that needs other versions builds nothing. Fetch the base's
# own modules once the tree is at the base commit.
GO_MODULES_STEP = (
    "# swe-rl-pilot: this base commit's Go modules (the test user can't fetch them)\n"
    "RUN cd /workspace && PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod go mod download\n"
)


def add_scrub(task: Path) -> None:
    env = task / "environment"
    shutil.copyfile(SCRUB, env / SCRUB.name)
    dockerfile = env / "Dockerfile"
    text = dockerfile.read_text(encoding="utf-8")
    if SCRUB_STEP not in text:
        if text.count(PRISTINE_COPY) != 1:
            raise SystemExit(f"{task.name}: expected one `{PRISTINE_COPY}` line in the Dockerfile")
        text = text.replace(PRISTINE_COPY, SCRUB_STEP + PRISTINE_COPY)
    if "go mod download" in text and GO_MODULES_STEP not in text:
        text = text.replace(SCRUB_STEP, GO_MODULES_STEP + SCRUB_STEP)
    dockerfile.write_text(text, encoding="utf-8")


def set_image(task: Path, registry: str) -> str:
    toml_path = task / "task.toml"
    data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
    image = f"{registry}:{task.name}-{environment_hash(task / 'environment')}"
    data.setdefault("environment", {})["docker_image"] = image
    toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
    return image


# PR-body sections that describe the fix or the tests that grade it. Repo2RLEnv drops
# checklist/changelog/testing/test-plan sections but not these; in our first 7 tasks, 5 had a
# `Changes` section (one ends "Use an `is None` check instead of truthiness") and 3 named the
# hidden tests under `Checks and tests`.
_LEAKY_HEADING = re.compile(
    r"(?:proposed\s+|summary\s+of\s+|description\s+of\s+(?:the\s+)?)?changes?(?:\s+made)?"
    r"|what\s+(?:this|the)\s+pr\s+does\b.*|what\s+changed|solutions?\b.*|(?:the\s+)?fix(?:es)?\b.*"
    r"|implementation(?:\s+details?)?|approach|how\s+(?:it|this)\s+works|technical\s+details?"
    r"|checks?(?:\s+and\s+tests?)?|tests?(?:\s+added.*)?|testing\b.*|test\s+plan|verification"
    r"|validation|how\s+(?:has\s+this\s+been|was\s+this|to)\s+test(?:ed)?\b.*",
    re.IGNORECASE,
)
_MD_HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
_BOLD_HEADING = re.compile(r"^\s*\*\*([^*]+?)\*\*\s*:?\s*$")
_KEEP = {"issue", "description", "task"}  # the instruction template's own headings
MIN_DESCRIPTION_WORDS = 30


def _heading(line: str) -> tuple[int, str] | None:
    if m := _MD_HEADING.match(line):
        return len(m[1]), m[2]
    if m := _BOLD_HEADING.match(line):
        return 7, m[1]  # a bold line used as a heading: ends at the next heading of any kind
    return None


def strip_leaky_sections(text: str) -> tuple[str, list[str]]:
    """Drop sections whose heading names the fix or its tests, up to the next heading at the
    same or a higher level. Headings inside code fences don't count."""
    out, stripped, skip_level, fenced = [], [], None, False
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        head = None if fenced else _heading(line)
        if head and skip_level is not None and head[0] <= skip_level:
            skip_level = None
        if head and skip_level is None:
            title = head[1].strip().rstrip(":").strip()
            if title.lower() not in _KEEP and _LEAKY_HEADING.fullmatch(title):
                stripped.append(title)
                skip_level = head[0]
                continue
        if skip_level is None:
            out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "".join(out)), stripped


def screen_instruction(task: Path) -> None:
    """Strip fix/test sections from instruction.md; record them, and any hidden test it names."""
    path = task / "instruction.md"
    text, stripped = strip_leaky_sections(path.read_text(encoding="utf-8"))
    path.write_text(text, encoding="utf-8")
    toml_path = task / "task.toml"
    data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
    hidden = data["metadata"]["repo2env"]["pr_runtime"].get("fail_to_pass") or []
    names = sorted({t.split("::")[-1].split("[")[0] for t in hidden})
    named = [n for n in names if len(n) >= 6 and re.search(rf"\b{re.escape(n)}\b", text)]
    pilot = data.setdefault("metadata", {}).setdefault("swe_rl_pilot", {})
    if stripped:  # keep the record from the first pass; a refresh finds nothing left to strip
        pilot["instruction_stripped_sections"] = stripped
    pilot["instruction_names_hidden_tests"] = named
    # Stripping can leave little more than the title (1342 kept one line). Too thin to say what
    # the hidden tests expect: hold such tasks out, or rewrite them, rather than train on them.
    body = text.split("## Description", 1)[-1].rsplit("## Task", 1)[0]
    words = len(re.findall(r"\w+", body))
    pilot["instruction_description_words"] = words
    pilot["instruction_ok"] = not named and words >= MIN_DESCRIPTION_WORDS
    toml_path.write_text(tomli_w.dumps(data), encoding="utf-8")
    if stripped or named or not pilot["instruction_ok"]:
        print(f"{task.name}: stripped {stripped or '-'}; names hidden tests {named or '-'}; "
              f"{words} description words{'' if pilot['instruction_ok'] else ' -> instruction_ok=false'}")


def finish(task: Path, registry: str) -> None:
    add_scrub(task)
    screen_instruction(task)
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
