#!/bin/bash
set -uo pipefail
R2E_CHILD_PATH="$PATH"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r
umask 022
SCRIPT_DIR=/tests
mkdir -p /logs/verifier
chown 0:0 /logs/verifier && chmod 700 /logs/verifier
rm -rf /logs/verifier/run && mkdir -m 700 /logs/verifier/run
chown -R 0:0 "$SCRIPT_DIR" && chmod -R go-rwx "$SCRIPT_DIR"
r2e_open_logs() {
  find /logs/verifier -xdev \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
}
r2e_finish() {
  rm -f /logs/verifier/reward.txt /logs/verifier/reward.json
  if [ "$1" = graded ]; then
    echo "0.000000" > /logs/verifier/reward.txt
    R2E_REWARD=0.0
  else
    R2E_REWARD=null
  fi
  printf '{"reward": %s, "resolved": false, "parse_status": "%s", "eval_trustworthy": false, "evaluation_status": "%s"}' "$R2E_REWARD" "$2" "$1" > /logs/verifier/reward-details.json
  echo "R2E: $3 ($1: $2)" >&2
  r2e_open_logs
  exit 0
}
R2E_PY=""
for p in /usr/local/bin/python3 /usr/bin/python3; do [ -x "$p" ] && { R2E_PY="$p"; break; }; done
[ -n "$R2E_PY" ]
R2E_PY_RC=$?
[ "$R2E_PY_RC" -eq 0 ] || r2e_finish ungraded no_system_python 'no system python3'
R2E_SUBMISSION="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" rebuild --agent /workspace --pristine /opt/r2e/pristine --copy-timeout 120 --patch-out /logs/verifier/submission.patch --report-out /logs/verifier/submission.json)"
R2E_REBUILD_RC=$?
case "$R2E_REBUILD_RC" in
  0) ;;
  3) r2e_finish ungraded submission_rebuild_failed 'grader tools failed before reading the submission';;
  4) r2e_finish ungraded submission_restore_failed 'could not copy the image repository';;
  *) r2e_finish graded submission_rebuild_crashed 'reading the submission failed';;
esac
[ "$R2E_SUBMISSION" = ok ] || r2e_finish graded "submission_$R2E_SUBMISSION" 'submission not graded as submitted'
cd /workspace
git config --global --add safe.directory /workspace
for f in networkx/algorithms/isomorphism/tests/test_common.py networkx/algorithms/isomorphism/tests/test_vf2pp.py; do if git cat-file -e f884a12db34c39f2e6d81c5b3607caa4cbe8ea7d:"$f" 2>/dev/null; then git checkout f884a12db34c39f2e6d81c5b3607caa4cbe8ea7d -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - f884a12db34c39f2e6d81c5b3607caa4cbe8ea7d "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
"""Standalone test-runner configuration guard, embedded in native runtime tasks.

Restore runner-only files (pytest hooks and settings, and the files that
redirect cargo, rustup, go, npm, jest, vitest, mocha, babel and coverage
tools) from the pinned base before applying hidden tests. In every
package.json the keys that decide how tests load and run are restored from
base and the rest of the agent's edits kept. Other shared configuration
(pyproject.toml, setup.cfg, tox.ini) is compared semantically and never
rewritten: legitimate packaging changes must survive grading, but a changed
test section fails the guard. Cargo.toml target and package settings that
change which tests run or who drives them (harness, test, autotests, build,
[patch], ...), every package's build script (cargo runs `build.rs` before the
tests compile and it could rewrite them) and go.mod `godebug` lines must match
base; the base Cargo test and dev profiles are pinned through CARGO_PROFILE_*
variables written to the optional second argument. It runs on the image's own
Python with `-I -S`, so it can't rely on `tomli` from site-packages: on Python
before 3.11 (no `tomllib`) a small built-in reader parses the TOML it needs.
This does not isolate arbitrary code; the separate verifier and the grader
launcher do that.

Exit status: 0 ok; 2 the submission changed runner configuration it may not;
1 the guard failed on the submitted tree (e.g. a config file replaced by a
directory). The separate verifier grades both 2 and 1 as 0: the submission can
cause either.
"""

from __future__ import annotations

import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

_DEDICATED = {
    "conftest.py",
    "pytest.ini",
    ".pytest.ini",
    "pytest.toml",
    ".pytest.toml",
    # Other runners: toolchain pins, workspace overrides and registry config.
    "rust-toolchain",
    "rust-toolchain.toml",
    "go.work",
    "go.work.sum",
    ".npmrc",
    ".yarnrc",
    ".yarnrc.yml",
    ".swcrc",
}
_DEDICATED_PREFIXES = (
    "jest.config.",
    "vitest.config.",
    "vite.config.",  # vitest falls back to it
    ".mocharc",
    "babel.config.",  # babel-jest transforms the hidden tests with these
    ".babelrc",
    "ava.config.",
    ".nycrc",
    ".c8rc",
)
_SHARED = {"pyproject.toml", "setup.cfg", "tox.ini", "Cargo.toml", "go.mod"}
# Cargo settings that decide which tests exist and what drives them.
_CARGO_PACKAGE_KEYS = (
    "autotests",
    "autobins",
    "autoexamples",
    "autobenches",
    "autolib",
    "build",
    "edition",
)
_CARGO_TARGET_KEYS = ("harness", "test", "doctest", "path", "required-features")
_CARGO_TARGET_TABLES = ("lib", "test", "bin", "bench", "example")
# Cargo's defaults: the test profile inherits dev.
_CARGO_PROFILE_DEFAULTS = {"debug-assertions": True, "overflow-checks": True, "opt-level": 0}
_ENV_VALUE = re.compile(r"^[A-Za-z0-9]+$")


class AgentChange(ValueError):
    """The submission changed runner configuration it may not: a graded 0."""


# package.json keys that decide what `npm test` runs and how tests load, transpile
# and report. They are restored from base in every package.json outside
# node_modules; other keys (exports, main, dependencies, version, ...) are the
# agent's, since real fixes change them and node_modules comes from the image.
_PACKAGE_JSON_RESTORED = (
    "scripts",
    "jest",
    "babel",
    "mocha",
    "ava",
    "c8",
    "nyc",
    "jest-junit",
    "tap",
    "type",
    "imports",
    "packageManager",
    "config",
    "browserslist",
)
# These bootstrap assets can be real directories or pre-existing symlinks.
# They remain a trusted part of the execution image, not solver source.
_ROOT_DEPS = {".git", ".venv", "venv", ".tox", "node_modules"}
_NESTED_DEPS = {".git", "node_modules"}


def _dedicated(relative: Path) -> bool:
    name = relative.name
    if name in _DEDICATED or name.startswith(_DEDICATED_PREFIXES):
        return True
    # cargo reads .cargo/config(.toml) in the package and every parent directory.
    return relative.parent.name == ".cargo" and name in {"config", "config.toml"}


def restore_package_json(actual: bytes, expected: bytes) -> bytes:
    """The agent's package.json with the runner keys put back as in base.

    A file that isn't a JSON object is replaced by base's. A new package.json
    (no base) loses those keys. Unchanged content is returned byte for byte.
    """
    try:
        manifest = json.loads(actual.decode("utf-8")) if actual else {}
    except (UnicodeDecodeError, ValueError):
        manifest = None
    if not isinstance(manifest, dict):
        return expected
    original = json.loads(expected.decode("utf-8")) if expected else {}
    if not isinstance(original, dict):
        original = {}
    changed = False
    for key in _PACKAGE_JSON_RESTORED:
        if manifest.get(key) == original.get(key) and (key in manifest) == (key in original):
            continue
        changed = True
        if key in original:
            manifest[key] = original[key]
        else:
            manifest.pop(key, None)
    if not changed:
        return actual
    return (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


_TOML_BARE = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
_TOML_ESCAPES = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}


class _MiniToml:
    """A small TOML reader for Python before 3.11 (no `tomllib`): tables,
    arrays of tables, dotted keys, strings, numbers, booleans, arrays and inline
    tables. Enough for pyproject.toml's [tool.pytest] and Cargo.toml's
    settings; anything it can't read raises ValueError (a graded change)."""

    def __init__(self, text: str) -> None:
        self.s = text
        self.i = 0

    def error(self, what: str) -> ValueError:
        return ValueError(f"TOML: {what} at offset {self.i}")

    def peek(self, n: int = 1) -> str:
        return self.s[self.i : self.i + n]

    def blank(self, newlines: bool) -> None:
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t" or (newlines and c in "\r\n"):
                self.i += 1
            elif c == "#":
                end = self.s.find("\n", self.i)
                self.i = len(self.s) if end < 0 else end
            else:
                return

    def parse(self) -> dict:
        root: dict = {}
        current = root
        while True:
            self.blank(newlines=True)
            if self.i >= len(self.s):
                return root
            if self.peek(2) == "[[":
                self.i += 2
                path = self.keys()
                if self.peek(2) != "]]":
                    raise self.error("expected ]]")
                self.i += 2
                parent = self.table(root, path[:-1])
                items = parent.setdefault(path[-1], [])
                if not isinstance(items, list):
                    raise self.error("not an array of tables")
                current = {}
                items.append(current)
            elif self.peek() == "[":
                self.i += 1
                path = self.keys()
                if self.peek() != "]":
                    raise self.error("expected ]")
                self.i += 1
                current = self.table(root, path)
            else:
                self.pair(current)
            self.blank(newlines=False)
            if self.i < len(self.s) and self.s[self.i] not in "\r\n":
                raise self.error("expected a newline")

    def table(self, root: dict, path: list[str]) -> dict:
        node = root
        for name in path:
            node = node.setdefault(name, {})
            if isinstance(node, list):
                node = node[-1]
            if not isinstance(node, dict):
                raise self.error(f"{name} is not a table")
        return node

    def keys(self) -> list[str]:
        parts = []
        while True:
            self.blank(newlines=False)
            if self.peek() in ('"', "'"):
                parts.append(self.string())
            else:
                start = self.i
                while self.i < len(self.s) and self.s[self.i] in _TOML_BARE:
                    self.i += 1
                if self.i == start:
                    raise self.error("expected a key")
                parts.append(self.s[start : self.i])
            self.blank(newlines=False)
            if self.peek() != ".":
                return parts
            self.i += 1

    def pair(self, into: dict) -> None:
        path = self.keys()
        if self.peek() != "=":
            raise self.error("expected =")
        self.i += 1
        self.blank(newlines=False)
        node = self.table(into, path[:-1])
        node[path[-1]] = self.value()

    def string(self) -> str:
        quote = self.peek()
        if self.peek(3) == quote * 3:
            self.i += 3
            if self.peek() == "\n":
                self.i += 1
            end = self.s.find(quote * 3, self.i)
            if end < 0:
                raise self.error("unterminated string")
            raw, self.i = self.s[self.i : end], end + 3
            return self.unescape(raw) if quote == '"' else raw
        self.i += 1
        out = []
        while self.i < len(self.s) and self.s[self.i] != quote:
            if self.s[self.i] in "\n":
                raise self.error("newline in string")
            if quote == '"' and self.s[self.i] == "\\":
                out.append(self.s[self.i : self.i + 2])
                self.i += 2
                continue
            out.append(self.s[self.i])
            self.i += 1
        if self.i >= len(self.s):
            raise self.error("unterminated string")
        self.i += 1
        raw = "".join(out)
        return self.unescape(raw) if quote == '"' else raw

    def unescape(self, raw: str) -> str:
        out, i = [], 0
        while i < len(raw):
            c = raw[i]
            if c != "\\":
                out.append(c)
                i += 1
                continue
            code = raw[i + 1 : i + 2]
            if code in _TOML_ESCAPES:
                out.append(_TOML_ESCAPES[code])
                i += 2
            elif code in ("u", "U"):
                width = 4 if code == "u" else 8
                out.append(chr(int(raw[i + 2 : i + 2 + width], 16)))
                i += 2 + width
            elif code in ("\n", " ", "\t", "\r"):  # line-ending backslash
                i += 1
                while i < len(raw) and raw[i] in " \t\r\n":
                    i += 1
            else:
                raise self.error("bad escape")
        return "".join(out)

    def value(self):
        c = self.peek()
        if c in ('"', "'"):
            return self.string()
        if c == "[":
            self.i += 1
            items = []
            while True:
                self.blank(newlines=True)
                if self.peek() == "]":
                    self.i += 1
                    return items
                items.append(self.value())
                self.blank(newlines=True)
                if self.peek() == ",":
                    self.i += 1
                elif self.peek() != "]":
                    raise self.error("expected , or ]")
        if c == "{":
            self.i += 1
            table: dict = {}
            self.blank(newlines=False)
            if self.peek() == "}":
                self.i += 1
                return table
            while True:
                self.pair(table)
                self.blank(newlines=False)
                if self.peek() == "}":
                    self.i += 1
                    return table
                if self.peek() != ",":
                    raise self.error("expected , or }")
                self.i += 1
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in ",]}#\r\n":
            self.i += 1
        token = self.s[start : self.i].strip()
        if token in ("true", "false"):
            return token == "true"
        plain = token.replace("_", "")
        for convert in (int, float):
            try:
                return convert(plain, 0) if convert is int else convert(plain)
            except ValueError:
                continue
        if not token:
            raise self.error("expected a value")
        return token  # dates and times: compared as text


def _toml(data: bytes) -> dict:
    text = data.decode("utf-8")
    try:
        import tomllib
    except ImportError:  # Python < 3.11; site-packages (tomli) is off under -S
        return _MiniToml(text).parse()
    return tomllib.loads(text)


def _cargo_settings(data: bytes) -> dict:
    manifest = _toml(data) if data else {}
    package = manifest.get("package", {}) if isinstance(manifest.get("package"), dict) else {}
    targets = {}
    for table in _CARGO_TARGET_TABLES:
        entries = manifest.get(table)
        entries = [entries] if isinstance(entries, dict) else entries or []
        for index, entry in enumerate(entries if isinstance(entries, list) else []):
            if isinstance(entry, dict):
                name = entry.get("name", index)
                targets[f"{table}:{name}"] = {k: entry.get(k) for k in _CARGO_TARGET_KEYS}
    return {
        "package": {key: package.get(key) for key in _CARGO_PACKAGE_KEYS},
        "targets": targets,
        "patch": manifest.get("patch"),
        "replace": manifest.get("replace"),
    }


def _godebug(data: bytes) -> list[str]:
    """go.mod `godebug` directives (single lines and blocks), in order."""
    out, block = [], False
    for raw in data.decode("utf-8").splitlines():
        line = raw.split("//", 1)[0].strip()
        if block:
            if line == ")":
                block = False
            elif line:
                out.append(line)
        elif line.startswith("godebug"):
            rest = line[len("godebug") :].strip()
            if rest == "(":
                block = True
            elif rest:
                out.append(rest)
    return out


def cargo_profile_env(data: bytes) -> list[str]:
    """`CARGO_PROFILE_*` settings pinning base's test and dev profiles.

    Environment variables override Cargo.toml, so a submission's [profile]
    edits (which turn off debug assertions or overflow checks) don't apply.
    """
    profiles = _toml(data).get("profile", {}) if data else {}
    profiles = profiles if isinstance(profiles, dict) else {}
    dev = {**_CARGO_PROFILE_DEFAULTS, **(profiles.get("dev") or {})}
    test = {**dev, **(profiles.get("test") or {})}
    lines = []
    for name, table in (("DEV", dev), ("TEST", test)):
        for key in _CARGO_PROFILE_DEFAULTS:
            value = table.get(key)
            text = str(value).lower() if isinstance(value, bool) else str(value)
            if _ENV_VALUE.match(text):
                variable = key.upper().replace("-", "_")
                lines.append(f"CARGO_PROFILE_{name}_{variable}={text}")
    return lines


def _pytest_settings(name: str, data: bytes):
    if name == "Cargo.toml":
        return _cargo_settings(data)
    if name == "go.mod":
        return _godebug(data) if data else []
    if name == "pyproject.toml":
        tool = _toml(data).get("tool", {})
        if not isinstance(tool, dict):
            raise ValueError("The TOML tool table is invalid")
        return tool.get("pytest", {})
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(data.decode("utf-8"))
    return {
        section: dict(parser[section])
        for section in ("pytest", "tool:pytest")
        if parser.has_section(section)
    }


def protect(workspace: Path, base_commit: str, env_out: str = "") -> None:
    """Restore hooks; reject changed pytest settings without erasing source edits."""
    if not re.fullmatch(r"[a-fA-F0-9]{40}", base_commit):
        raise ValueError("Expected a pinned base commit")
    workspace = workspace.resolve()
    objects = workspace / ".git" / "objects"
    git = shutil.which("git", path=os.defpath)
    if git is None or not objects.is_dir():
        raise ValueError("The task's Git object store is unavailable")
    with tempfile.TemporaryDirectory(prefix="r2e-config-") as temporary:
        # Read base blobs without workspace config, replacement refs, filters,
        # hooks, global configuration or lazy network fetches.
        env = {
            "PATH": os.defpath,
            "HOME": temporary,
            "XDG_CONFIG_HOME": temporary,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
        private = Path(temporary) / "repository"
        subprocess.run(
            [git, "init", "--bare", "--quiet", "--template=", str(private)],
            env=env,
            cwd=temporary,
            check=True,
            capture_output=True,
            timeout=60,
        )
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = json.dumps(str(objects), ensure_ascii=False)

        def read(*args: str) -> bytes:
            return subprocess.run(
                [git, f"--git-dir={private}", *args],
                env=env,
                cwd=temporary,
                check=True,
                capture_output=True,
                timeout=60,
            ).stdout

        base = {}
        for entry in read("ls-tree", "-rz", base_commit).split(b"\0"):
            if not entry:
                continue
            header, raw_path = entry.split(b"\t", 1)
            mode, kind, blob = header.decode("ascii").split()
            path = Path(os.fsdecode(raw_path))
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe base path")
            if path.parts[0] not in _ROOT_DEPS and kind == "blob":
                base[path] = (mode, blob)

        def original(path: Path) -> bytes:
            item = base.get(path)
            if item is None:
                return b""
            if item[0] not in {"100644", "100755"}:
                raise ValueError("Configuration must be a regular file")
            return read("cat-file", "blob", item[1])

        candidates = {
            p for p in base if _dedicated(p) or p.name in _SHARED or p.name == "package.json"
        }
        for root, directories, files in os.walk(workspace, followlinks=False):
            directory = Path(root)
            if directory == workspace:
                directories[:] = [d for d in directories if d not in _ROOT_DEPS]
                files = [f for f in files if f not in _ROOT_DEPS]
            else:
                # Installed packages ship their own jest configs, .npmrc and
                # package.json files; they belong to the environment.
                directories[:] = [d for d in directories if d not in _NESTED_DEPS]
            for name in directories:
                path = directory / name
                if not path.is_symlink():
                    continue
                relative = path.relative_to(workspace)
                item = base.get(relative)
                # An added/retargeted directory link can hide a hook outside
                # the tree being inspected. Do not follow it or delete it.
                if (
                    item is None
                    or item[0] != "120000"
                    or os.fsencode(os.readlink(path)) != read("cat-file", "blob", item[1])
                    or not path.resolve().is_relative_to(workspace)
                    or path.resolve() == workspace
                    or path.resolve().relative_to(workspace).parts[0] in _ROOT_DEPS
                ):
                    raise AgentChange("Untrusted directory symlink in pytest workspace")
            for name in [*files, *directories]:
                relative = (directory / name).relative_to(workspace)
                if _dedicated(relative) or name in _SHARED or name == "package.json":
                    candidates.add(relative)
            # Avoid executing a sourceless or unchecked-hash cached hook.
            for name in files:
                if name == "conftest.pyc" or (
                    directory.name == "__pycache__"
                    and name.startswith("conftest.")
                    and name.endswith(".pyc")
                ):
                    (directory / name).unlink()

        for relative in sorted(candidates):
            path = workspace / relative
            # Never write through a directory symlink, even a base symlink.
            if any(parent.is_symlink() for parent in path.parents if parent != workspace):
                raise AgentChange("Symlink parent of pytest configuration")
            item = base.get(relative)
            if item is not None and item[0] == "120000":
                # swe-rl-pilot: a base symlink kept as is is not a change.
                if path.is_symlink() and os.fsencode(os.readlink(path)) == read(
                    "cat-file", "blob", item[1]
                ):
                    continue
                raise AgentChange("Symlinked runner configuration changed")
            expected = original(relative)
            if relative.name == "package.json":
                if path.is_symlink():
                    path.unlink()
                if path.exists() or relative in base:
                    actual = path.read_bytes() if path.exists() else b""
                    restored = restore_package_json(actual, expected) if actual else expected
                    if restored != actual:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(restored)
            elif _dedicated(relative):
                if path.is_symlink():
                    path.unlink()
                if relative in base:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(expected)
                elif path.exists():
                    path.unlink()
            else:
                if path.is_symlink():
                    raise AgentChange("Shared configuration must be a regular file")
                actual = path.read_bytes() if path.exists() else b""
                if actual == expected:
                    continue
                wanted = _pytest_settings(relative.name, expected)
                try:
                    found = _pytest_settings(relative.name, actual)
                except (ValueError, UnicodeDecodeError, configparser.Error) as exc:
                    raise AgentChange(f"Unreadable shared configuration: {relative}") from exc
                if found != wanted:
                    raise AgentChange("Untrusted test settings in shared configuration")

        # cargo compiles and runs a package's build script before its tests, and
        # the script can rewrite them: it must be exactly base's.
        for relative in sorted(c for c in candidates if c.name == "Cargo.toml"):
            manifest_path = workspace / relative
            if not manifest_path.is_file():
                continue
            try:
                package = _toml(manifest_path.read_bytes()).get("package")
            except (ValueError, UnicodeDecodeError) as exc:
                raise AgentChange(f"Unreadable Cargo manifest: {relative}") from exc
            if not isinstance(package, dict):
                continue  # a virtual workspace manifest
            build = package.get("build", True)
            if build is False:
                continue
            script = Path(
                os.path.normpath(relative.parent / ("build.rs" if build is True else str(build)))
            )
            if script.is_absolute() or script.parts[:1] == ("..",):
                raise AgentChange("Cargo build script outside the repository")
            target = workspace / script
            actual = target.read_bytes() if target.is_file() and not target.is_symlink() else None
            if target.is_symlink() or (actual is None and target.exists()):
                raise AgentChange("Cargo build script must be a regular file")
            expected = original(script) if script in base else None
            if actual != expected:
                raise AgentChange(f"Cargo build script changed: {script}")

        if env_out:
            root_cargo = original(Path("Cargo.toml")) if Path("Cargo.toml") in base else b""
            lines = cargo_profile_env(root_cargo) if root_cargo else []
            with open(env_out, "w", encoding="utf-8") as handle:
                handle.write("".join(f"{line}\n" for line in lines))


def main() -> int:
    try:
        protect(Path.cwd(), sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    except AgentChange as exc:
        sys.stderr.write(f"Runner configuration changed by the submission: {exc}\n")
        return 2
    except (OSError, ValueError, ImportError, subprocess.SubprocessError, configparser.Error):
        sys.stderr.write("Pytest configuration guard failed; grading was not run.\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

R2E_PYTEST_CONFIG_GUARD
R2E_RESET_RC=$?
[ "$R2E_RESET_RC" -eq 2 ] && r2e_finish graded runner_config_changed 'the submission changed runner configuration'
[ "$R2E_RESET_RC" -eq 0 ] || r2e_finish graded test_config_reset_failed 'test config reset failed'
[ -s "$R2E_GUARD_ENV" ] && { set -a; . "$R2E_GUARD_ENV"; set +a; }
git apply --verbose --reject - <<'EOF_R2E_TEST_PATCH'
diff --git a/networkx/algorithms/isomorphism/tests/test_common.py b/networkx/algorithms/isomorphism/tests/test_common.py
index e8ee7bbb95b..ff14314bb96 100644
--- a/networkx/algorithms/isomorphism/tests/test_common.py
+++ b/networkx/algorithms/isomorphism/tests/test_common.py
@@ -237,6 +237,7 @@ def vf2pp_mono_iter(G1, G2, node_label=None, edge_label=None, symmetry=False):
 morphism_funcs = is_funcs | SG_funcs | mono_funcs
 
 is_morphic_funcs = [pytest.param(fn[0], id=id) for id, fn in morphism_funcs.items()]
+mapping_funcs = [pytest.param(fn[1], id=id) for id, fn in morphism_funcs.items()]
 mono_iters = [pytest.param(fn[1], id=id) for id, fn in mono_funcs.items()]
 morphic_and_mapping = [pytest.param(*fns, id=id) for id, fns in morphism_funcs.items()]
 
@@ -504,6 +505,16 @@ def cycle6_plus_3_2paths():
 ## Self-Isomorphism (Symmetry) tests
 
 
+@pytest.mark.parametrize("morphism", mapping_funcs)
+def test_graph_input_order(morphism):
+    # see gh-8810
+    G = nx.Graph(["eh"])
+    nx.add_path(G, "abcdefg")
+    H = nx.relabel_nodes(G, {a: i for i, a in enumerate(G)})
+
+    assert list(morphism(G, H)) == [dict(zip(G, H))]
+
+
 @pytest.mark.parametrize("Gclass", graph_classes)
 @pytest.mark.parametrize("G", solo_graphs)
 @pytest.mark.parametrize("symmetry", [True, False])
diff --git a/networkx/algorithms/isomorphism/tests/test_vf2pp.py b/networkx/algorithms/isomorphism/tests/test_vf2pp.py
index ef54027ff86..96bff39e852 100644
--- a/networkx/algorithms/isomorphism/tests/test_vf2pp.py
+++ b/networkx/algorithms/isomorphism/tests/test_vf2pp.py
@@ -147,7 +147,7 @@ def test_second_graph_empty(self, graph_type):
 
 class TestGraphISOVF2pp:
     def test_custom_graph1_same_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
 
         mapped = {1: "A", 2: "B", 3: "C", 4: "D", 5: "Z", 6: "E"}
         edges1 = [(1, 2), (1, 3), (1, 4), (2, 3), (2, 6), (3, 4), (5, 1), (5, 2)]
@@ -157,8 +157,8 @@ def test_custom_graph1_same_labels(self):
         # |     | |/  | |/
         # 6     6 7   X E
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
         nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
@@ -169,28 +169,28 @@ def test_custom_graph1_same_labels(self):
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
         # Add edge making SG symmetrical
-        SG.add_edge(3, 7)
-        SG.nodes[7]["label"] = "blue"
+        FG.add_edge(3, 7)
+        FG.nodes[7]["label"] = "blue"
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
-        all_self_mappings = list(vf2pp_all_isomorphisms(SG, SG))
+        all_self_mappings = list(vf2pp_all_isomorphisms(FG, FG))
         assert len(all_self_mappings) == 2
         # check that one of the mappings is not the identity for node 2
         assert sum(1 for m in all_self_mappings if m[2] == 2) == 1
 
         # Make FG isomorphic to SG
-        FG.add_edges_from([(mapped[3], "X"), (mapped[6], mapped[5])])
-        SG.add_edge(4, 7)
-        FG.nodes["X"]["label"] = "blue"
+        SG.add_edges_from([(mapped[3], "X"), (mapped[6], mapped[5])])
+        FG.add_edge(4, 7)
+        SG.nodes["X"]["label"] = "blue"
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Re-structure maintaining isomorphism
-        SG.remove_edges_from([(1, 4), (1, 3)])
-        FG.remove_edges_from([(mapped[1], mapped[5]), (mapped[1], mapped[2])])
+        FG.remove_edges_from([(1, 4), (1, 3)])
+        SG.remove_edges_from([(mapped[1], mapped[5]), (mapped[1], mapped[2])])
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
     def test_custom_graph2_same_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
 
         mapped = {1: "A", 2: "C", 3: "D", 4: "E", 5: "G", 7: "B", 6: "F"}
         edges1 = [(1, 2), (1, 5), (5, 6), (2, 3), (2, 4), (3, 4), (4, 5), (2, 7)]
@@ -200,66 +200,66 @@ def test_custom_graph2_same_labels(self):
         #  /|/
         # 7 3
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
 
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Obtain two isomorphic subgraphs from the graph
-        FG.remove_edge(mapped[1], mapped[2])
-        FG.add_edge(mapped[1], mapped[4])
-        SH = nx.Graph(SG.subgraph([2, 3, 4, 7]))
-        FH = nx.Graph(FG.subgraph([mapped[1], mapped[4], mapped[5], mapped[6]]))
+        SG.remove_edge(mapped[1], mapped[2])
+        SG.add_edge(mapped[1], mapped[4])
+        FH = nx.Graph(FG.subgraph([2, 3, 4, 7]))
+        SH = nx.Graph(SG.subgraph([mapped[1], mapped[4], mapped[5], mapped[6]]))
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
         # Add edges maintaining isomorphism
-        SH.add_edges_from([(3, 7), (4, 7)])
-        FH.add_edges_from([(mapped[1], mapped[6]), (mapped[4], mapped[6])])
+        FH.add_edges_from([(3, 7), (4, 7)])
+        SH.add_edges_from([(mapped[1], mapped[6]), (mapped[4], mapped[6])])
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
     def test_custom_graph2_different_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
 
         mapped = {1: "A", 2: "C", 3: "D", 4: "E", 5: "G", 7: "B", 6: "F"}
         edges1 = [(1, 2), (1, 5), (5, 6), (2, 3), (2, 4), (3, 4), (4, 5), (2, 7)]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
 
         # Adding new nodes
-        SG.add_node(0)
-        FG.add_node("Z")
-        SG.nodes[0]["label"] = SG.nodes[1]["label"]
-        FG.nodes["Z"]["label"] = SG.nodes[1]["label"]
+        FG.add_node(0)
+        SG.add_node("Z")
+        FG.nodes[0]["label"] = FG.nodes[1]["label"]
+        SG.nodes["Z"]["label"] = FG.nodes[1]["label"]
         mapped.update({0: "Z"})
 
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
         # Change the color of one of the nodes
-        FG.nodes["Z"]["label"] = SG.nodes[2]["label"]
+        SG.nodes["Z"]["label"] = FG.nodes[2]["label"]
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Add an extra edge
-        SG.nodes[0]["label"] = "blue"
-        FG.nodes["Z"]["label"] = "blue"
-        SG.add_edge(0, 1)
+        FG.nodes[0]["label"] = "blue"
+        SG.nodes["Z"]["label"] = "blue"
+        FG.add_edge(0, 1)
 
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Add extra edge to both
-        FG.add_edge("Z", "A")
+        SG.add_edge("Z", "A")
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
     def test_custom_graph3_same_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
 
         mapped = {1: 9, 2: 8, 3: 7, 4: 6, 5: 3, 8: 5, 9: 4, 7: 1, 6: 2}
         #        3---4
@@ -283,60 +283,60 @@ def test_custom_graph3_same_labels(self):
             (6, 7),
             (5, 2),
         ]
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Connect nodes maintaining symmetry
-        SG.add_edges_from([(6, 9), (7, 8)])
-        FG.add_edges_from([(mapped[6], mapped[8]), (mapped[7], mapped[9])])
+        FG.add_edges_from([(6, 9), (7, 8)])
+        SG.add_edges_from([(mapped[6], mapped[8]), (mapped[7], mapped[9])])
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Make isomorphic
-        SG.add_edges_from([(6, 8), (7, 9)])
-        FG.add_edges_from([(mapped[6], mapped[9]), (mapped[7], mapped[8])])
+        FG.add_edges_from([(6, 8), (7, 9)])
+        SG.add_edges_from([(mapped[6], mapped[9]), (mapped[7], mapped[8])])
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Connect more nodes
-        SG.add_edges_from([(2, 7), (3, 6)])
-        FG.add_edges_from([(mapped[2], mapped[7]), (mapped[3], mapped[6])])
-        SG.add_node(10)
-        FG.add_node("Z")
-        SG.nodes[10]["label"] = "blue"
-        FG.nodes["Z"]["label"] = "blue"
+        FG.add_edges_from([(2, 7), (3, 6)])
+        SG.add_edges_from([(mapped[2], mapped[7]), (mapped[3], mapped[6])])
+        FG.add_node(10)
+        SG.add_node("Z")
+        FG.nodes[10]["label"] = "blue"
+        SG.nodes["Z"]["label"] = "blue"
 
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Connect the newly added node, to opposite sides of the graph
-        SG.add_edges_from([(10, 1), (10, 5), (10, 8)])
-        FG.add_edges_from([("Z", mapped[1]), ("Z", mapped[4]), ("Z", mapped[9])])
+        FG.add_edges_from([(10, 1), (10, 5), (10, 8)])
+        SG.add_edges_from([("Z", mapped[1]), ("Z", mapped[4]), ("Z", mapped[9])])
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Get two subgraphs that are not isomorphic but are easy to make
-        SH = nx.Graph(SG.subgraph([2, 3, 4, 5, 6, 7, 10]))
-        FH = nx.Graph(
-            FG.subgraph(
+        FH = nx.Graph(FG.subgraph([2, 3, 4, 5, 6, 7, 10]))
+        SH = nx.Graph(
+            SG.subgraph(
                 [mapped[4], mapped[5], mapped[6], mapped[7], mapped[8], mapped[9], "Z"]
             )
         )
         assert vf2pp_isomorphism(FH, SH, node_label="label") is None
 
         # Restructure both to make them isomorphic
-        SH.add_edges_from([(10, 2), (10, 6), (3, 6), (2, 7), (2, 6), (3, 7)])
-        FH.add_edges_from(
+        FH.add_edges_from([(10, 2), (10, 6), (3, 6), (2, 7), (2, 6), (3, 7)])
+        SH.add_edges_from(
             [("Z", mapped[7]), (mapped[6], mapped[9]), (mapped[7], mapped[8])]
         )
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
         # Add edges with opposite direction in each Graph
-        SH.add_edge(3, 5)
-        FH.add_edge(mapped[5], mapped[7])
+        FH.add_edge(3, 5)
+        SH.add_edge(mapped[5], mapped[7])
         assert vf2pp_isomorphism(FH, SH, node_label="label") is None
 
     def test_custom_graph3_different_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
 
         mapped = {1: 9, 2: 8, 3: 7, 4: 6, 5: 3, 8: 5, 9: 4, 7: 1, 6: 2}
         edges1 = [
@@ -353,50 +353,50 @@ def test_custom_graph3_different_labels(self):
             (6, 7),
             (5, 2),
         ]
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
-        # Add extra edge to SG
-        SG.add_edge(1, 7)
+        # Add extra edge to FG
+        FG.add_edge(1, 7)
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
-        # Compensate in FG
-        FG.add_edge(9, 1)
+        # Compensate in SG
+        SG.add_edge(9, 1)
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
         # Add extra node
-        SG.add_node("A")
-        FG.add_node("K")
-        SG.nodes["A"]["label"] = "green"
-        FG.nodes["K"]["label"] = "green"
+        FG.add_node("A")
+        SG.add_node("K")
+        FG.nodes["A"]["label"] = "green"
+        SG.nodes["K"]["label"] = "green"
         mapped.update({"A": "K"})
 
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
         # Connect A to one side of SG and K to the opposite
-        SG.add_edge("A", 6)
-        FG.add_edge("K", 5)
+        FG.add_edge("A", 6)
+        SG.add_edge("K", 5)
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Make the graphs symmetrical
-        SG.add_edge(1, 5)
-        SG.add_edge(2, 9)
-        FG.add_edge(9, 3)
-        FG.add_edge(8, 4)
+        FG.add_edge(1, 5)
+        FG.add_edge(2, 9)
+        SG.add_edge(9, 3)
+        SG.add_edge(8, 4)
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Assign same colors so the two opposite sides are identical
-        for node in SG.nodes():
+        for node in FG.nodes():
             color = "red"
-            SG.nodes[node]["label"] = color
-            FG.nodes[mapped[node]]["label"] = color
+            FG.nodes[node]["label"] = color
+            SG.nodes[mapped[node]]["label"] = color
 
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
@@ -406,7 +406,7 @@ def test_custom_graph4_different_labels(self):
         #    7-8 6 5        13
         #       \ /
         #        9
-        SG = nx.Graph()
+        FG = nx.Graph()
         edges1 = [
             (1, 2),
             (2, 3),
@@ -440,18 +440,18 @@ def test_custom_graph4_different_labels(self):
             13: "e",
         }
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
     def test_custom_graph4_same_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
         edges1 = [
             (1, 2),
             (2, 3),
@@ -485,51 +485,51 @@ def test_custom_graph4_same_labels(self):
             13: "e",
         }
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
-        all_self_mappings = list(vf2pp_all_isomorphisms(SG, SG))
+        all_self_mappings = list(vf2pp_all_isomorphisms(FG, FG))
         assert len(all_self_mappings) == 2
         # check that one of the mappings is not the identity for node 2
         assert sum(1 for m in all_self_mappings if m[12] == 12) == 1
 
         # Add nodes of different label
-        SG.add_node(0)
-        FG.add_node("z")
-        SG.nodes[0]["label"] = "green"
-        FG.nodes["z"]["label"] = "blue"
+        FG.add_node(0)
+        SG.add_node("z")
+        FG.nodes[0]["label"] = "green"
+        SG.nodes["z"]["label"] = "blue"
 
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Make the labels identical
-        FG.nodes["z"]["label"] = "green"
+        SG.nodes["z"]["label"] = "green"
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Change the structure of the graphs, keeping them isomorphic
-        SG.add_edge(2, 5)
-        FG.remove_edge("i", "l")
-        FG.add_edge("g", "l")
-        FG.add_edge("m", "f")
+        FG.add_edge(2, 5)
+        SG.remove_edge("i", "l")
+        SG.add_edge("g", "l")
+        SG.add_edge("m", "f")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Change the structure of the disconnected sub-graph, keeping it isomorphic
-        SG.remove_node(13)
-        FG.remove_node("d")
+        FG.remove_node(13)
+        SG.remove_node("d")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Connect the newly added node to the disconnected graph, which now is just a path of size 3
-        SG.add_edge(0, 10)
-        FG.add_edge("e", "z")
+        FG.add_edge(0, 10)
+        SG.add_edge("e", "z")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Connect the two disconnected sub-graphs, forming a single graph
-        SG.add_edge(11, 3)
-        SG.add_edge(0, 8)
-        FG.add_edge("a", "l")
-        FG.add_edge("z", "j")
+        FG.add_edge(11, 3)
+        FG.add_edge(0, 8)
+        SG.add_edge("a", "l")
+        SG.add_edge("z", "j")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
     def test_custom_graph5_same_labels(self):
@@ -543,7 +543,7 @@ def test_custom_graph5_same_labels(self):
         #    \ 7 /
         #     \|/
         #      8
-        SG = nx.Graph()
+        FG = nx.Graph()
         edges1 = [
             (1, 5),
             (1, 2),
@@ -560,20 +560,20 @@ def test_custom_graph5_same_labels(self):
         ]
         mapped = {1: "a", 2: "h", 3: "d", 4: "i", 5: "g", 6: "b", 7: "j", 8: "c"}
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
-        all_self_mappings = list(vf2pp_all_isomorphisms(SG, SG))
+        all_self_mappings = list(vf2pp_all_isomorphisms(FG, FG))
         assert len(all_self_mappings) == 48
         # check that one of the mappings is not the identity for node 2
-        assert all(sum(1 for m in all_self_mappings if m[u] == u) == 6 for u in SG)
+        assert all(sum(1 for m in all_self_mappings if m[u] == u) == 6 for u in FG)
 
         # Add different edges in each graph, maintaining symmetry
-        SG.add_edges_from([(3, 6), (2, 7), (2, 5), (1, 3), (4, 7), (6, 8)])
-        FG.add_edges_from(
+        FG.add_edges_from([(3, 6), (2, 7), (2, 5), (1, 3), (4, 7), (6, 8)])
+        SG.add_edges_from(
             [
                 (mapped[6], mapped[3]),
                 (mapped[2], mapped[7]),
@@ -586,26 +586,26 @@ def test_custom_graph5_same_labels(self):
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
         # Obtain two different but isomorphic subgraphs from SG and FG
-        SH = nx.Graph(SG.subgraph([1, 5, 8, 6, 7, 3]))
-        FH = nx.Graph(
-            FG.subgraph(
+        FH = nx.Graph(FG.subgraph([1, 5, 8, 6, 7, 3]))
+        SH = nx.Graph(
+            SG.subgraph(
                 [mapped[1], mapped[4], mapped[8], mapped[7], mapped[3], mapped[5]]
             )
         )
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
         # Delete corresponding node from the two graphs
-        SH.remove_node(8)
-        FH.remove_node(mapped[7])
+        FH.remove_node(8)
+        SH.remove_node(mapped[7])
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
         # Re-orient, maintaining isomorphism
-        SH.add_edge(1, 6)
-        SH.remove_edge(3, 6)
+        FH.add_edge(1, 6)
+        FH.remove_edge(3, 6)
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
     def test_custom_graph5_different_labels(self):
-        SG = nx.Graph()
+        FG = nx.Graph()
         edges1 = [
             (1, 5),
             (1, 2),
@@ -622,71 +622,71 @@ def test_custom_graph5_different_labels(self):
         ]
         mapped = {1: "a", 2: "h", 3: "d", 4: "i", 5: "g", 6: "b", 7: "j", 8: "c"}
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
         colors = ["red", "blue", "grey", "none", "brown", "solarized", "yellow", "pink"]
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
         # Assign different colors to matching nodes
         c = 0
-        for node in SG.nodes():
+        for node in FG.nodes():
             color1 = colors[c]
             color2 = colors[(c + 3) % len(colors)]
-            SG.nodes[node]["label"] = color1
-            FG.nodes[mapped[node]]["label"] = color2
+            FG.nodes[node]["label"] = color1
+            SG.nodes[mapped[node]]["label"] = color2
             c += 1
 
         assert vf2pp_isomorphism(FG, SG, node_label="label") is None
 
         # Get symmetrical sub-graphs of SG,FG and compare them
-        SH = SG.subgraph([1, 5])
-        FH = FG.subgraph(["i", "c"])
+        FH = FG.subgraph([1, 5])
+        SH = SG.subgraph(["i", "c"])
         c = 0
-        for node1, node2 in zip(SH.nodes(), FH.nodes()):
-            SH.nodes[node1]["label"] = "red"
-            FH.nodes[node2]["label"] = "red"
+        for node1, node2 in zip(FH.nodes(), SH.nodes()):
+            FH.nodes[node1]["label"] = "red"
+            SH.nodes[node2]["label"] = "red"
             c += 1
 
         assert vf2pp_isomorphism(FH, SH, node_label="label")
 
     def test_disconnected_graph_all_same_labels(self):
-        SG = nx.Graph()
-        SG.add_nodes_from(list(range(10)))
+        FG = nx.Graph()
+        FG.add_nodes_from(list(range(10)))
 
         mapped = {0: 9, 1: 8, 2: 7, 3: 6, 4: 5, 5: 4, 6: 3, 7: 2, 8: 1, 9: 0}
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         assert vf2pp_isomorphism(FG, SG, node_label="label")
 
     def test_disconnected_graph_all_different_labels(self):
-        SG = nx.Graph()
-        SG.add_nodes_from(list(range(10)))
+        FG = nx.Graph()
+        FG.add_nodes_from(list(range(10)))
 
         mapped = {0: 9, 1: 8, 2: 7, 3: 6, 4: 5, 5: 4, 6: 3, 7: 2, 8: 1, 9: 0}
-        FG = nx.relabel_nodes(SG, mapped)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         assert vf2pp_isomorphism(FG, SG, node_label="label") == mapped
 
     def test_disconnected_graph_some_same_labels(self):
-        SG = nx.Graph()
-        SG.add_nodes_from(list(range(10)))
+        FG = nx.Graph()
+        FG.add_nodes_from(list(range(10)))
 
         mapped = {0: 9, 1: 8, 2: 7, 3: 6, 4: 5, 5: 4, 6: 3, 7: 2, 8: 1, 9: 0}
-        FG = nx.relabel_nodes(SG, mapped)
+        SG = nx.relabel_nodes(FG, mapped)
 
         colors = [
             "white",
@@ -711,7 +711,7 @@ def test_disconnected_graph_some_same_labels(self):
 
 class TestMultiGraphISOVF2pp:
     def test_custom_multigraph1_same_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: "A", 2: "B", 3: "C", 4: "D", 5: "Z", 6: "E"}
         edges1 = [
@@ -731,40 +731,40 @@ def test_custom_multigraph1_same_labels(self):
             (5, 2),
         ]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Transfer the 2-clique to the right side of SG
-        SG.remove_edges_from([(2, 6), (2, 6)])
-        SG.add_edges_from([(3, 6), (3, 6)])
+        FG.remove_edges_from([(2, 6), (2, 6)])
+        FG.add_edges_from([(3, 6), (3, 6)])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Delete an edges, making them symmetrical, so the position of the 2-clique doesn't matter
-        FG.remove_edge(mapped[1], mapped[4])
-        SG.remove_edge(1, 4)
+        SG.remove_edge(mapped[1], mapped[4])
+        FG.remove_edge(1, 4)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Add self-loops
-        SG.add_edges_from([(5, 5), (5, 5), (1, 1)])
+        FG.add_edges_from([(5, 5), (5, 5), (1, 1)])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Compensate in FG
-        FG.add_edges_from(
+        SG.add_edges_from(
             [(mapped[1], mapped[1]), (mapped[4], mapped[4]), (mapped[4], mapped[4])]
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
     def test_custom_multigraph1_different_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: "A", 2: "B", 3: "C", 4: "D", 5: "Z", 6: "E"}
         edges1 = [
@@ -784,13 +784,13 @@ def test_custom_multigraph1_different_labels(self):
             (5, 2),
         ]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
@@ -798,31 +798,31 @@ def test_custom_multigraph1_different_labels(self):
         assert m == mapped
 
         # Re-structure SG, maintaining the degree sequence
-        SG.remove_edge(1, 4)
-        SG.add_edge(1, 5)
+        FG.remove_edge(1, 4)
+        FG.add_edge(1, 5)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Restructure FG, making it isomorphic to SG
-        FG.remove_edge("A", "D")
-        FG.add_edge("A", "Z")
+        SG.remove_edge("A", "D")
+        SG.add_edge("A", "Z")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
         assert m == mapped
 
         # Add edge from node to itself
-        SG.add_edges_from([(6, 6), (6, 6), (6, 6)])
+        FG.add_edges_from([(6, 6), (6, 6), (6, 6)])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Same for FG
-        FG.add_edges_from([("E", "E"), ("E", "E"), ("E", "E")])
+        SG.add_edges_from([("E", "E"), ("E", "E"), ("E", "E")])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
         assert m == mapped
 
     def test_custom_multigraph2_same_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: "A", 2: "C", 3: "D", 4: "E", 5: "G", 7: "B", 6: "F"}
         edges1 = [
@@ -845,49 +845,49 @@ def test_custom_multigraph2_same_labels(self):
             (2, 7),
         ]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Obtain two non-isomorphic subgraphs from the graph
-        FG.add_edge(mapped[1], mapped[4])
-        SH = nx.MultiGraph(SG.subgraph([2, 3, 4, 7]))
-        FH = nx.MultiGraph(FG.subgraph([mapped[1], mapped[4], mapped[5], mapped[6]]))
+        SG.add_edge(mapped[1], mapped[4])
+        FH = nx.MultiGraph(FG.subgraph([2, 3, 4, 7]))
+        SH = nx.MultiGraph(SG.subgraph([mapped[1], mapped[4], mapped[5], mapped[6]]))
 
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
         # Make them isomorphic
-        SH.remove_edge(3, 4)
-        SH.add_edges_from([(2, 3), (2, 4), (2, 4)])
-        FH.add_edges_from([(mapped[5], mapped[6]), (mapped[5], mapped[6])])
+        FH.remove_edge(3, 4)
+        FH.add_edges_from([(2, 3), (2, 4), (2, 4)])
+        SH.add_edges_from([(mapped[5], mapped[6]), (mapped[5], mapped[6])])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Remove triangle edge
-        SH.remove_edges_from([(2, 3), (2, 3), (2, 3)])
-        FH.remove_edges_from([(mapped[5], mapped[4])] * 3)
+        FH.remove_edges_from([(2, 3), (2, 3), (2, 3)])
+        SH.remove_edges_from([(mapped[5], mapped[4])] * 3)
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Change the edge orientation such that SH is rotated FH
-        SH.remove_edges_from([(2, 7), (2, 7)])
-        SH.add_edges_from([(3, 4), (3, 4)])
+        FH.remove_edges_from([(2, 7), (2, 7)])
+        FH.add_edges_from([(3, 4), (3, 4)])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Add extra edges maintaining degree sequence, but in a non-symmetrical manner
-        FH.add_edge(mapped[5], mapped[1])
-        SH.add_edge(3, 4)
+        SH.add_edge(mapped[5], mapped[1])
+        FH.add_edge(3, 4)
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
     def test_custom_multigraph2_different_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: "A", 2: "C", 3: "D", 4: "E", 5: "G", 7: "B", 6: "F"}
         edges1 = [
@@ -910,13 +910,13 @@ def test_custom_multigraph2_different_labels(self):
             (2, 7),
         ]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
@@ -924,35 +924,35 @@ def test_custom_multigraph2_different_labels(self):
         assert m == mapped
 
         # Re-structure SG
-        SG.remove_edge(2, 7)
-        SG.add_edge(5, 6)
+        FG.remove_edge(2, 7)
+        FG.add_edge(5, 6)
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Same for FG
-        FG.remove_edge("B", "C")
-        FG.add_edge("G", "F")
+        SG.remove_edge("B", "C")
+        SG.add_edge("G", "F")
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
         assert m == mapped
 
         # Delete node from SG and FG, keeping them isomorphic
-        SG.remove_node(3)
-        FG.remove_node("D")
+        FG.remove_node(3)
+        SG.remove_node("D")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Change SG edges
-        SG.remove_edge(1, 2)
-        SG.remove_edge(2, 7)
+        FG.remove_edge(1, 2)
+        FG.remove_edge(2, 7)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Make FG identical to SG, but with different edge orientation and different labels
-        FG.add_edges_from([("A", "C"), ("C", "E"), ("C", "E")])
-        FG.remove_edges_from(
+        SG.add_edges_from([("A", "C"), ("C", "E"), ("C", "E")])
+        SG.remove_edges_from(
             [("A", "G"), ("A", "G"), ("F", "G"), ("E", "G"), ("E", "G")]
         )
 
@@ -960,15 +960,15 @@ def test_custom_multigraph2_different_labels(self):
         assert not m
 
         # Make all labels the same, so SG and FG are also isomorphic
-        for n1, n2 in zip(SG.nodes(), FG.nodes()):
-            SG.nodes[n1]["label"] = "blue"
-            FG.nodes[n2]["label"] = "blue"
+        for n1, n2 in zip(FG.nodes(), SG.nodes()):
+            FG.nodes[n1]["label"] = "blue"
+            SG.nodes[n2]["label"] = "blue"
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
     def test_custom_multigraph3_same_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: 9, 2: 8, 3: 7, 4: 6, 5: 3, 8: 5, 9: 4, 7: 1, 6: 2}
         edges1 = [
@@ -993,17 +993,17 @@ def test_custom_multigraph3_same_labels(self):
             (6, 7),
             (5, 2),
         ]
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Connect nodes maintaining symmetry
-        SG.add_edges_from([(6, 9), (7, 8), (5, 8), (4, 9), (4, 9)])
-        FG.add_edges_from(
+        FG.add_edges_from([(6, 9), (7, 8), (5, 8), (4, 9), (4, 9)])
+        SG.add_edges_from(
             [
                 (mapped[6], mapped[8]),
                 (mapped[7], mapped[9]),
@@ -1016,8 +1016,8 @@ def test_custom_multigraph3_same_labels(self):
         assert not m
 
         # Make isomorphic
-        SG.add_edges_from([(6, 8), (6, 8), (7, 9), (7, 9), (7, 9)])
-        FG.add_edges_from(
+        FG.add_edges_from([(6, 8), (6, 8), (7, 9), (7, 9), (7, 9)])
+        SG.add_edges_from(
             [
                 (mapped[6], mapped[8]),
                 (mapped[6], mapped[9]),
@@ -1030,8 +1030,8 @@ def test_custom_multigraph3_same_labels(self):
         assert m
 
         # Connect more nodes
-        SG.add_edges_from([(2, 7), (2, 7), (3, 6), (3, 6)])
-        FG.add_edges_from(
+        FG.add_edges_from([(2, 7), (2, 7), (3, 6), (3, 6)])
+        SG.add_edges_from(
             [
                 (mapped[2], mapped[7]),
                 (mapped[2], mapped[7]),
@@ -1039,17 +1039,17 @@ def test_custom_multigraph3_same_labels(self):
                 (mapped[3], mapped[6]),
             ]
         )
-        SG.add_node(10)
-        FG.add_node("Z")
-        SG.nodes[10]["label"] = "blue"
-        FG.nodes["Z"]["label"] = "blue"
+        FG.add_node(10)
+        SG.add_node("Z")
+        FG.nodes[10]["label"] = "blue"
+        SG.nodes["Z"]["label"] = "blue"
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Connect the newly added node, to opposite sides of the graph
-        SG.add_edges_from([(10, 1), (10, 5), (10, 8), (10, 10), (10, 10)])
-        FG.add_edges_from(
+        FG.add_edges_from([(10, 1), (10, 5), (10, 8), (10, 10), (10, 10)])
+        SG.add_edges_from(
             [
                 ("Z", mapped[1]),
                 ("Z", mapped[4]),
@@ -1063,8 +1063,8 @@ def test_custom_multigraph3_same_labels(self):
 
         # We connected the new node to opposite sides, so SG must be symmetrical
         # to FG. Re-structure them to be so
-        SG.remove_edges_from([(1, 3), (4, 9), (4, 9), (7, 9)])
-        FG.remove_edges_from(
+        FG.remove_edges_from([(1, 3), (4, 9), (4, 9), (7, 9)])
+        SG.remove_edges_from(
             [
                 (mapped[1], mapped[3]),
                 (mapped[4], mapped[9]),
@@ -1076,9 +1076,9 @@ def test_custom_multigraph3_same_labels(self):
         assert m
 
         # Get two subgraphs that are not isomorphic but are easy to make
-        SH = nx.Graph(SG.subgraph([2, 3, 4, 5, 6, 7, 10]))
-        FH = nx.Graph(
-            FG.subgraph(
+        FH = nx.Graph(FG.subgraph([2, 3, 4, 5, 6, 7, 10]))
+        SH = nx.Graph(
+            SG.subgraph(
                 [mapped[4], mapped[5], mapped[6], mapped[7], mapped[8], mapped[9], "Z"]
             )
         )
@@ -1087,25 +1087,25 @@ def test_custom_multigraph3_same_labels(self):
         assert not m
 
         # Restructure both to make them isomorphic
-        SH.add_edges_from([(10, 2), (10, 6), (3, 6), (2, 7), (2, 6), (3, 7)])
-        FH.add_edges_from(
+        FH.add_edges_from([(10, 2), (10, 6), (3, 6), (2, 7), (2, 6), (3, 7)])
+        SH.add_edges_from(
             [("Z", mapped[7]), (mapped[6], mapped[9]), (mapped[7], mapped[8])]
         )
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Remove one self-loop in FH
-        FH.remove_edge("Z", "Z")
+        SH.remove_edge("Z", "Z")
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
         # Compensate in SH
-        SH.remove_edge(10, 10)
+        FH.remove_edge(10, 10)
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
     def test_custom_multigraph3_different_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
 
         mapped = {1: 9, 2: 8, 3: 7, 4: 6, 5: 3, 8: 5, 9: 4, 7: 1, 6: 2}
         edges1 = [
@@ -1131,13 +1131,13 @@ def test_custom_multigraph3_different_labels(self):
             (5, 2),
         ]
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
@@ -1145,65 +1145,65 @@ def test_custom_multigraph3_different_labels(self):
         assert m == mapped
 
         # Delete edge maintaining isomorphism
-        SG.remove_edge(4, 9)
-        FG.remove_edge(4, 6)
+        FG.remove_edge(4, 9)
+        SG.remove_edge(4, 6)
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
         assert m == mapped
 
         # Change edge orientation such that SG mirrors FG
-        SG.add_edges_from([(4, 9), (1, 2), (1, 2)])
-        SG.remove_edges_from([(1, 3), (1, 3)])
-        FG.add_edges_from([(3, 5), (7, 9)])
-        FG.remove_edge(8, 9)
+        FG.add_edges_from([(4, 9), (1, 2), (1, 2)])
+        FG.remove_edges_from([(1, 3), (1, 3)])
+        SG.add_edges_from([(3, 5), (7, 9)])
+        SG.remove_edge(8, 9)
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Make all labels the same, so SG and FG are also isomorphic
-        for n1, n2 in zip(SG.nodes(), FG.nodes()):
-            SG.nodes[n1]["label"] = "blue"
-            FG.nodes[n2]["label"] = "blue"
+        for n1, n2 in zip(FG.nodes(), SG.nodes()):
+            FG.nodes[n1]["label"] = "blue"
+            SG.nodes[n2]["label"] = "blue"
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
-        SG.add_node(10)
-        FG.add_node("Z")
-        SG.nodes[10]["label"] = "green"
-        FG.nodes["Z"]["label"] = "green"
+        FG.add_node(10)
+        SG.add_node("Z")
+        FG.nodes[10]["label"] = "green"
+        SG.nodes["Z"]["label"] = "green"
 
         # Add different number of edges between the new nodes and themselves
-        SG.add_edges_from([(10, 10), (10, 10)])
-        FG.add_edges_from([("Z", "Z")])
+        FG.add_edges_from([(10, 10), (10, 10)])
+        SG.add_edges_from([("Z", "Z")])
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Make the number of self-edges equal
-        SG.remove_edge(10, 10)
+        SG.add_edges_from([("Z", "Z")])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Connect the new node to the graph
-        SG.add_edges_from([(10, 3), (10, 4)])
-        FG.add_edges_from([("Z", 8), ("Z", 3)])
+        FG.add_edges_from([(10, 3), (10, 4)])
+        SG.add_edges_from([("Z", 8), ("Z", 3)])
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Remove central node
-        SG.remove_node(4)
-        FG.remove_node(3)
-        SG.add_edges_from([(5, 6), (5, 6), (5, 7)])
-        FG.add_edges_from([(1, 6), (1, 6), (6, 2)])
+        FG.remove_node(4)
+        SG.remove_node(3)
+        FG.add_edges_from([(5, 6), (5, 6), (5, 7)])
+        SG.add_edges_from([(1, 6), (1, 6), (6, 2)])
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
     def test_custom_multigraph4_same_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
         edges1 = [
             (1, 2),
             (1, 2),
@@ -1251,24 +1251,24 @@ def test_custom_multigraph4_same_labels(self):
             13: "e",
         }
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Add extra but corresponding edges to both graphs
-        SG.add_edges_from([(2, 2), (2, 3), (2, 8), (3, 4)])
-        FG.add_edges_from([("m", "m"), ("m", "l"), ("m", "h"), ("l", "j")])
+        FG.add_edges_from([(2, 2), (2, 3), (2, 8), (3, 4)])
+        SG.add_edges_from([("m", "m"), ("m", "l"), ("m", "h"), ("l", "j")])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Obtain subgraphs
-        SH = nx.MultiGraph(SG.subgraph([2, 3, 4, 6, 10, 11, 12, 13]))
-        FH = nx.MultiGraph(
-            FG.subgraph(
+        FH = nx.MultiGraph(FG.subgraph([2, 3, 4, 6, 10, 11, 12, 13]))
+        SH = nx.MultiGraph(
+            SG.subgraph(
                 [
                     mapped[2],
                     mapped[3],
@@ -1286,33 +1286,33 @@ def test_custom_multigraph4_same_labels(self):
         assert not m
 
         # Make them isomorphic
-        FH.remove_edges_from(
+        SH.remove_edges_from(
             [(mapped[3], mapped[2]), (mapped[9], mapped[8]), (mapped[2], mapped[2])]
         )
-        FH.add_edges_from([(mapped[9], mapped[9]), (mapped[2], mapped[8])])
+        SH.add_edges_from([(mapped[9], mapped[9]), (mapped[2], mapped[8])])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Re-structure the disconnected sub-graph
-        SH.remove_node(12)
-        FH.remove_node(mapped[12])
-        SH.add_edge(13, 13)
-        FH.add_edge(mapped[13], mapped[13])
+        FH.remove_node(12)
+        SH.remove_node(mapped[12])
+        FH.add_edge(13, 13)
+        SH.add_edge(mapped[13], mapped[13])
 
         # Connect the two disconnected components, forming a single graph
-        SH.add_edges_from([(3, 13), (6, 11)])
-        FH.add_edges_from([(mapped[8], mapped[10]), (mapped[2], mapped[11])])
+        FH.add_edges_from([(3, 13), (6, 11)])
+        SH.add_edges_from([(mapped[8], mapped[10]), (mapped[2], mapped[11])])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Change orientation of self-loops in one graph, maintaining the degree sequence
-        SH.remove_edges_from([(2, 2), (3, 6)])
-        SH.add_edges_from([(6, 6), (2, 3)])
+        FH.remove_edges_from([(2, 2), (3, 6)])
+        FH.add_edges_from([(6, 6), (2, 3)])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
     def test_custom_multigraph4_different_labels(self):
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
         edges1 = [
             (1, 2),
             (1, 2),
@@ -1357,79 +1357,79 @@ def test_custom_multigraph4_different_labels(self):
             13: "e",
         }
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m == mapped
 
         # Add extra but corresponding edges to both graphs
-        SG.add_edges_from([(2, 2), (2, 3), (2, 8), (3, 4)])
-        FG.add_edges_from([("m", "m"), ("m", "l"), ("m", "h"), ("l", "j")])
+        FG.add_edges_from([(2, 2), (2, 3), (2, 8), (3, 4)])
+        SG.add_edges_from([("m", "m"), ("m", "l"), ("m", "h"), ("l", "j")])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m == mapped
 
         # Obtain isomorphic subgraphs
-        SH = nx.MultiGraph(SG.subgraph([2, 3, 4, 6]))
-        FH = nx.MultiGraph(FG.subgraph(["m", "l", "j", "i"]))
+        FH = nx.MultiGraph(FG.subgraph([2, 3, 4, 6]))
+        SH = nx.MultiGraph(SG.subgraph(["m", "l", "j", "i"]))
 
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Delete the 3-clique, keeping only the path-graph. Also, SH mirrors FH
-        SH.remove_node(4)
-        FH.remove_node("j")
-        SH.remove_edges_from([(2, 2), (2, 3), (6, 6)])
-        FH.remove_edges_from([("l", "i"), ("m", "m"), ("m", "m")])
+        FH.remove_node(4)
+        SH.remove_node("j")
+        FH.remove_edges_from([(2, 2), (2, 3), (6, 6)])
+        SH.remove_edges_from([("l", "i"), ("m", "m"), ("m", "m")])
 
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
         # Assign the same labels so that mirroring means isomorphic
-        for n1, n2 in zip(SH.nodes(), FH.nodes()):
-            SH.nodes[n1]["label"] = "red"
-            FH.nodes[n2]["label"] = "red"
+        for n1, n2 in zip(FH.nodes(), SH.nodes()):
+            FH.nodes[n1]["label"] = "red"
+            SH.nodes[n2]["label"] = "red"
 
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Leave only one node with self-loop
-        SH.remove_nodes_from([3, 6])
-        FH.remove_nodes_from(["m", "l"])
+        FH.remove_nodes_from([3, 6])
+        SH.remove_nodes_from(["m", "l"])
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Remove one self-loop from SH
-        SH.remove_edge(2, 2)
+        FH.remove_edge(2, 2)
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert not m
 
         # Same for FH
-        FH.remove_edge("i", "i")
+        SH.remove_edge("i", "i")
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         assert m
 
         # Compose SH with the disconnected sub-graph of SG. Same for FH
-        SHG = nx.compose(SH, nx.MultiGraph(SG.subgraph([10, 11, 12, 13])))
-        FHG = nx.compose(FH, nx.MultiGraph(FG.subgraph(["a", "b", "d", "e"])))
+        FHG = nx.compose(FH, nx.MultiGraph(FG.subgraph([10, 11, 12, 13])))
+        SHG = nx.compose(SH, nx.MultiGraph(SG.subgraph(["a", "b", "d", "e"])))
 
         m = vf2pp_isomorphism(FH, SH, node_label="label")
         m = vf2pp_isomorphism(FHG, SHG, node_label="label")
         assert m
 
         # Connect the two components. Also test selfloops
-        SHG.add_edges_from([(13, 13), (13, 13), (2, 13)])
-        FHG.add_edges_from([("e", "e"), ("i", "e")])
+        FHG.add_edges_from([(13, 13), (13, 13), (2, 13)])
+        SHG.add_edges_from([("e", "e"), ("i", "e")])
         m = vf2pp_isomorphism(FHG, SHG, node_label="label")
         assert not m
 
-        FHG.add_edges_from([("e", "e")])
+        SHG.add_edges_from([("e", "e")])
         m = vf2pp_isomorphism(FHG, SHG, node_label="label")
         assert m
 
@@ -1444,7 +1444,7 @@ def test_custom_multigraph5_same_labels(self):
         #    \ 7 /
         #     \|/
         #      8
-        SG = nx.MultiGraph()
+        FG = nx.MultiGraph()
         edges1 = [
             (1, 5),
             (1, 2),
@@ -1461,19 +1461,19 @@ def test_custom_multigraph5_same_labels(self):
         ]
         mapped = {1: "a", 2: "h", 3: "d", 4: "i", 5: "g", 6: "b", 7: "j", 8: "c"}
 
-        SG.add_edges_from(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
+        FG.add_edges_from(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Add multiple edges and self-loops, maintaining isomorphism
-        SG.add_edges_from(
+        FG.add_edges_from(
             [(1, 2), (1, 2), (3, 7), (8, 8), (8, 8), (7, 8), (2, 3), (5, 6)]
         )
-        FG.add_edges_from(
+        SG.add_edges_from(
             [
                 ("a", "h"),
                 ("a", "h"),
@@ -1493,7 +1493,7 @@ def test_custom_multigraph5_same_labels(self):
         assert m
 
         # Make FG to be the rotated SG
-        FG.remove_edges_from(
+        SG.remove_edges_from(
             [
                 ("a", "h"),
                 ("a", "h"),
@@ -1505,7 +1505,7 @@ def test_custom_multigraph5_same_labels(self):
                 ("g", "b"),
             ]
         )
-        FG.add_edges_from(
+        SG.add_edges_from(
             [
                 ("d", "i"),
                 ("a", "h"),
@@ -1522,51 +1522,51 @@ def test_custom_multigraph5_same_labels(self):
         assert m
 
     def test_disconnected_multigraph_all_same_labels(self):
-        SG = nx.MultiGraph()
-        SG.add_nodes_from(list(range(10)))
-        SG.add_edges_from([(i, i) for i in range(10)])
+        FG = nx.MultiGraph()
+        FG.add_nodes_from(list(range(10)))
+        FG.add_edges_from([(i, i) for i in range(10)])
 
         mapped = {0: 9, 1: 8, 2: 7, 3: 6, 4: 5, 5: 4, 6: 3, 7: 2, 8: 1, 9: 0}
-        FG = nx.relabel_nodes(SG, mapped)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
         nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_same))), "label")
+        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_same))), "label")
 
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Add self-loops to non-mapped nodes. Should be the same, as the graph is disconnected.
-        SG.add_edges_from([(i, i) for i in range(5, 8)] * 3)
+        FG.add_edges_from([(i, i) for i in range(5, 8)] * 3)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Compensate in FG
-        FG.add_edges_from([(i, i) for i in range(3)] * 3)
+        SG.add_edges_from([(i, i) for i in range(3)] * 3)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
         # Add one more self-loop in FG
-        FG.add_edges_from([(0, 0), (1, 1), (1, 1)])
+        SG.add_edges_from([(0, 0), (1, 1), (1, 1)])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Compensate in SG
-        SG.add_edges_from([(5, 5), (7, 7), (7, 7)])
+        FG.add_edges_from([(5, 5), (7, 7), (7, 7)])
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
     def test_disconnected_multigraph_all_different_labels(self):
-        SG = nx.MultiGraph()
-        SG.add_nodes_from(list(range(10)))
-        SG.add_edges_from([(i, i) for i in range(10)])
+        FG = nx.MultiGraph()
+        FG.add_nodes_from(list(range(10)))
+        FG.add_edges_from([(i, i) for i in range(10)])
 
         mapped = {0: 9, 1: 8, 2: 7, 3: 6, 4: 5, 5: 4, 6: 3, 7: 2, 8: 1, 9: 0}
-        FG = nx.relabel_nodes(SG, mapped)
+        SG = nx.relabel_nodes(FG, mapped)
 
-        nx.set_node_attributes(SG, dict(zip(SG, it.cycle(labels_many))), "label")
+        nx.set_node_attributes(FG, dict(zip(FG, it.cycle(labels_many))), "label")
         nx.set_node_attributes(
-            FG,
-            dict(zip([mapped[n] for n in SG], it.cycle(labels_many))),
+            SG,
+            dict(zip([mapped[n] for n in FG], it.cycle(labels_many))),
             "label",
         )
         m = vf2pp_isomorphism(FG, SG, node_label="label")
@@ -1574,22 +1574,22 @@ def test_disconnected_multigraph_all_different_labels(self):
         assert m == mapped
 
         # Add self-loops to non-mapped nodes. Now it is not the same, as there are different labels
-        SG.add_edges_from([(i, i) for i in range(5, 8)] * 3)
+        FG.add_edges_from([(i, i) for i in range(5, 8)] * 3)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Add self-loops to non mapped nodes in FG as well
-        FG.add_edges_from([(mapped[i], mapped[i]) for i in range(3)] * 7)
+        SG.add_edges_from([(mapped[i], mapped[i]) for i in range(3)] * 7)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Add self-loops to mapped nodes in FG
-        FG.add_edges_from([(mapped[i], mapped[i]) for i in range(5, 8)] * 3)
+        SG.add_edges_from([(mapped[i], mapped[i]) for i in range(5, 8)] * 3)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert not m
 
         # Add self-loops to SG so that they are even in both graphs
-        SG.add_edges_from([(i, i) for i in range(3)] * 7)
+        FG.add_edges_from([(i, i) for i in range(3)] * 7)
         m = vf2pp_isomorphism(FG, SG, node_label="label")
         assert m
 
@@ -1612,14 +1612,14 @@ def test_wikipedia_graph(self):
         ]
         mapped = {1: "a", 2: "h", 3: "d", 4: "i", 5: "g", 6: "b", 7: "j", 8: "c"}
 
-        SG = nx.DiGraph(edges1)
-        FG = nx.relabel_nodes(SG, mapped)
+        FG = nx.DiGraph(edges1)
+        SG = nx.relabel_nodes(FG, mapped)
 
         assert vf2pp_isomorphism(FG, SG) == mapped
 
         # Change the direction of an edge
-        SG.remove_edge(1, 5)
-        SG.add_edge(5, 1)
+        FG.remove_edge(1, 5)
+        FG.add_edge(5, 1)
         assert vf2pp_isomorphism(FG, SG) is None
 
     def test_non_isomorphic_same_degree_sequence(self):
@@ -1658,8 +1658,8 @@ def test_non_isomorphic_same_degree_sequence(self):
             (3, 7),
         ]
 
-        SG = nx.DiGraph(edges1)
-        FG = nx.DiGraph(edges2)
+        FG = nx.DiGraph(edges1)
+        SG = nx.DiGraph(edges2)
         assert vf2pp_isomorphism(FG, SG) is None
 
 

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
mkdir -p /opt/r2e && chmod 700 /opt/r2e && rm -rf /opt/r2e/prepared && /usr/bin/timeout 120 cp -a /workspace /opt/r2e/prepared 2>/opt/r2e/prepare.err
R2E_PREPARE_RC=$?
if [ "$R2E_PREPARE_RC" -ne 0 ] && grep -q "No space left" /opt/r2e/prepare.err; then r2e_finish graded submission_no_space 'the disk filled up while preparing the test runs'; fi
[ "$R2E_PREPARE_RC" -eq 0 ] || r2e_finish ungraded mutant_setup_failed 'run setup failed'
R2E_RUNS=0; R2E_MTIME="$(date +%s)"
r2e_reset() {
  if [ "$R2E_RUNS" -gt 0 ]; then
    R2E_RESET="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" restore --pristine /opt/r2e/prepared --aside-dir /opt/r2e/aside --copy-timeout 120)"
    R2E_RESET_RC=$?
    [ "$R2E_RESET_RC" -eq 4 ] && r2e_finish ungraded submission_restore_failed 'could not copy the prepared tree'
    { [ "$R2E_RESET_RC" -eq 0 ] && [ "$R2E_RESET" = ok ]; } || r2e_finish graded test_cleanup_failed 'the test run left a tree that could not be reset'
  fi
  R2E_RUNS=$((R2E_RUNS + 1))
}
r2e_run_a() {
  r2e_reset
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path networkx/algorithms/isomorphism/tests/test_common.py --path networkx/algorithms/isomorphism/tests/test_vf2pp.py --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --timeout 120 --purge -- 'python -m pytest -v networkx/algorithms/isomorphism/tests/test_common.py networkx/algorithms/isomorphism/tests/test_vf2pp.py')"
R2E_LAUNCH_RC=$?
hash -r
mv -f /logs/verifier/run/output.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/seconds /logs/verifier/run.seconds 2>/dev/null
R2E_TIMED_OUT=0
[ "$R2E_LAUNCH_RC" -eq 0 ] || R2E_LAUNCH_OUT=failed
case "$R2E_LAUNCH_OUT" in
  timeout) TEST_EXIT_CODE=124; R2E_TIMED_OUT=1;;
  cleanup_failed) r2e_finish graded test_cleanup_failed 'test processes or files outlived the run';;
  unsafe_image) r2e_finish ungraded unsafe_image 'a path root runs code from is writable by the test user';;
  precleanup_failed) if [ "${R2E_RUNS:-0}" -gt 1 ]; then r2e_finish graded test_cleanup_failed 'an earlier test run left state that could not be removed'; else r2e_finish ungraded grader_launch_failed 'test command isolation failed'; fi;;
  ''|*[!0-9]*) r2e_finish ungraded grader_launch_failed 'test command isolation failed';;
  *) TEST_EXIT_CODE="$R2E_LAUNCH_OUT";;
esac
  R2E_A_EXIT="$TEST_EXIT_CODE"; R2E_A_TIMED_OUT="$R2E_TIMED_OUT"
  mv -f /logs/verifier/test_output.log /logs/verifier/run/run_a.log 2>/dev/null
  mv -f /logs/verifier/run.seconds /logs/verifier/run/run_a.seconds 2>/dev/null
}
r2e_run_b() {
  r2e_reset
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path networkx/algorithms/isomorphism/tests/test_common.py --path networkx/algorithms/isomorphism/tests/test_vf2pp.py --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --timeout 120 --purge -- 'python -m pytest -v networkx/algorithms/isomorphism/tests/test_common.py networkx/algorithms/isomorphism/tests/test_vf2pp.py')"
R2E_LAUNCH_RC=$?
hash -r
mv -f /logs/verifier/run/output.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/seconds /logs/verifier/run.seconds 2>/dev/null
R2E_TIMED_OUT=0
[ "$R2E_LAUNCH_RC" -eq 0 ] || R2E_LAUNCH_OUT=failed
case "$R2E_LAUNCH_OUT" in
  timeout) TEST_EXIT_CODE=124; R2E_TIMED_OUT=1;;
  cleanup_failed) r2e_finish graded test_cleanup_failed 'test processes or files outlived the run';;
  unsafe_image) r2e_finish ungraded unsafe_image 'a path root runs code from is writable by the test user';;
  precleanup_failed) if [ "${R2E_RUNS:-0}" -gt 1 ]; then r2e_finish graded test_cleanup_failed 'an earlier test run left state that could not be removed'; else r2e_finish ungraded grader_launch_failed 'test command isolation failed'; fi;;
  ''|*[!0-9]*) r2e_finish ungraded grader_launch_failed 'test command isolation failed';;
  *) TEST_EXIT_CODE="$R2E_LAUNCH_OUT";;
esac
  R2E_B_EXIT="$TEST_EXIT_CODE"; R2E_B_TIMED_OUT="$R2E_TIMED_OUT"
  mv -f /logs/verifier/test_output.log /logs/verifier/mutant_output.log 2>/dev/null
  mv -f /logs/verifier/run.seconds /logs/verifier/run_b.seconds 2>/dev/null
}
R2E_B_EXIT=1; R2E_B_TIMED_OUT=0; R2E_B_SKIPPED=0
if [ $((RANDOM % 2)) -eq 0 ]; then
  r2e_run_a
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'python -m pytest -v networkx/algorithms/isomorphism/tests/test_common.py networkx/algorithms/isomorphism/tests/test_vf2pp.py' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'python -m pytest -v networkx/algorithms/isomorphism/tests/test_common.py networkx/algorithms/isomorphism/tests/test_vf2pp.py' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
