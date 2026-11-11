"""Give prebuilt-image SWE tasks (SWE-bench-style Harbor tasks) a separate verifier.

Usage: python3 scripts/wrap_separate_verifier.py SRC_DIR OUT_DIR [--image-map map.json] [--force]

SWE-rebench V2.1 RL and the other SWE-bench-lineage pools grade in the agent's own container:
their test.sh restores only the hidden test files, so an agent-written conftest.py scored 1.0 on
9 of 10 Python tasks we sampled. This rewrites each task so that:

1. after the agent phase, a [[verifier.collect]] hook copies the agent's working tree (without
   .git) to /pilot_xfer/agent, which Harbor carries into a fresh verifier container as an
   artifact (the same transfer Repo2RLEnv tasks use for /workspace);
2. the verifier starts from the task's own image, so its working tree is the untouched base.
   tests/test.sh copies that tree aside as the pristine copy, puts the agent's tree in its
   place, and runs Repo2RLEnv's `grader_tools rebuild` (source diff only: no test files,
   ignored paths, dependency dirs or large binaries; applied to a fresh copy of the base) and
   its runner-configuration guard against the base commit;
3. the task's original test.sh (kept as tests/original_test.sh) then applies the hidden tests,
   runs them and grades as before.

The grader tools and guard come from the pinned Repo2RLEnv in gen/ (with gen/patch_repo2rlenv.py
applied). --image-map rewrites [environment].docker_image (e.g. to a GHCR mirror). --max-cpus and
--max-memory-mb cap the task's resource request (Harbor's Docker environment enforces it, and
SWE-rebench asks for 6 CPUs; GitHub runners have 4).
"""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import sys
import tomllib
from pathlib import Path

import tomli_w

WRAPPER_VERSION = 2
XFER = "/pilot_xfer/agent"
PRISTINE = "/opt/pilot/pristine"

TEST_SH = """#!/bin/bash
# swe-rl-pilot separate-verifier wrapper v{version}: rebuild the submission from the agent's
# tree on a pristine copy of this image's working tree, guard the runner configuration, then
# run the task's original grader (tests/original_test.sh).
set -uo pipefail
WD={workdir}
SCRIPT_DIR=/tests
V=/logs/verifier
mkdir -p "$V"
finish() {{  # graded|ungraded reason
  if [ "$1" = graded ]; then echo 0 > "$V/reward.txt"; else rm -f "$V/reward.txt"; fi
  printf '{{"wrapper": "{version}", "status": "%s", "reason": "%s"}}\\n' "$1" "$2" > "$V/wrapper.json"
  echo "pilot wrapper: $1 $2" >&2
  exit 0
}}
# The verifier is a fresh container from the image, so PATH is the image's. Non-Python images
# (Go, Rust, ...) ship a grader interpreter at /opt/harbor-grader/python3 (SWE-rebench V2.1).
PY=""
for p in /usr/local/bin/python3 /usr/bin/python3 /opt/harbor-grader/python3 /opt/conda/bin/python3 \
         "$(command -v python3 2>/dev/null)"; do
  [ -n "$p" ] && [ -x "$p" ] && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null \
    && {{ PY="$p"; break; }}
done
[ -n "$PY" ] || finish ungraded no_system_python
[ -d {xfer} ] || finish ungraded no_agent_tree
mkdir -p "$(dirname {pristine})" && rm -rf {pristine} && cp -a "$WD" {pristine} || finish ungraded pristine_copy_failed
BASE="$(git -C {pristine} -c safe.directory='*' rev-parse HEAD 2>/dev/null)" || finish ungraded no_base_commit
git config --global --add safe.directory '*'
# The agent's tree replaces the working tree; rebuild reads it as untrusted data and replaces
# it again with base + the agent's source diff.
rm -rf "$WD" && cp -a {xfer} "$WD" || finish ungraded agent_tree_copy_failed
SUB="$("$PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" rebuild --agent "$WD" --pristine {pristine} \\
  --copy-timeout 300 --patch-out "$V/submission.patch" --report-out "$V/submission.json")"
RC=$?
case "$RC" in
  0) ;;
  3) finish ungraded submission_rebuild_failed;;
  4) finish ungraded submission_restore_failed;;
  *) finish graded submission_rebuild_crashed;;
esac
[ "$SUB" = ok ] || finish graded "submission_$SUB"
cd "$WD" || finish ungraded no_workdir
"$PY" -B -I -S "$SCRIPT_DIR/pytest_config_guard.py" "$BASE" "$(mktemp)"
GRC=$?
[ "$GRC" -eq 0 ] || finish graded "runner_config_changed_$GRC"
printf '{{"wrapper": "{version}", "status": "ok", "base": "%s"}}\\n' "$BASE" > "$V/wrapper.json"
exec bash "$SCRIPT_DIR/original_test.sh"
"""


def gen_module(name: str) -> Path:
    import repo2rlenv.pipelines as pipelines

    return Path(pipelines.__file__).with_name(name)


def wrap(src: Path, out: Path, image_map: dict[str, str], max_cpus: int | None = None,
         max_memory_mb: int | None = None) -> None:
    data = tomllib.loads((src / "task.toml").read_text(encoding="utf-8"))
    env = data.setdefault("environment", {})
    workdir = env.get("workdir")
    if not workdir:
        raise SystemExit(f"{src.name}: no [environment].workdir")
    if (src / "tests" / "original_test.sh").exists():
        raise SystemExit(f"{src.name}: already wrapped")
    shutil.copytree(src, out)
    tests = out / "tests"
    (tests / "test.sh").rename(tests / "original_test.sh")
    (tests / "test.sh").write_text(TEST_SH.format(
        version=WRAPPER_VERSION, workdir=shlex.quote(workdir), xfer=XFER, pristine=PRISTINE))
    (tests / "test.sh").chmod(0o755)
    shutil.copyfile(gen_module("_grader_tools.py"), tests / "grader_tools.py")
    shutil.copyfile(gen_module("_pytest_config_guard.py"), tests / "pytest_config_guard.py")

    image = env.get("docker_image", "")
    env["docker_image"] = image_map.get(image, image)
    if max_cpus and env.get("cpus", 0) > max_cpus:
        env["cpus"] = max_cpus
    if max_memory_mb and env.get("memory_mb", 0) > max_memory_mb:
        env["memory_mb"] = max_memory_mb
    data["artifacts"] = [*data.get("artifacts", []), {"source": XFER}]
    verifier = data.setdefault("verifier", {})
    verifier["environment_mode"] = "separate"
    verifier["user"] = "root"
    copy = (f"rm -rf {XFER} && mkdir -p {XFER} && "
            f"tar -C {shlex.quote(workdir)} --exclude=./.git -cf - . | tar -C {XFER} -xf -")
    verifier["collect"] = [{"command": copy, "timeout_sec": 600.0, "user": "root"}]
    pilot = data.setdefault("metadata", {}).setdefault("swe_rl_pilot", {})
    pilot["wrapped"] = {"version": WRAPPER_VERSION, "source_image": image}
    (out / "task.toml").write_text(tomli_w.dumps(data), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--image-map", type=Path)
    parser.add_argument("--force", action="store_true", help="replace tasks already in OUT")
    parser.add_argument("--max-cpus", type=int)
    parser.add_argument("--max-memory-mb", type=int)
    args = parser.parse_args()
    image_map = json.loads(args.image_map.read_text()) if args.image_map else {}
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    for toml_path in sorted(args.src.glob("*/task.toml")):
        dest = args.out / toml_path.parent.name
        if dest.exists():
            if not args.force:
                continue
            shutil.rmtree(dest)
        wrap(toml_path.parent, dest, image_map, args.max_cpus, args.max_memory_mb)
        n += 1
    print(f"wrapped {n} task(s) into {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
