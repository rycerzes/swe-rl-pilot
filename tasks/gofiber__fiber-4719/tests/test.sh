#!/bin/bash
set -uo pipefail
R2E_CHILD_PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
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
for f in ctx_test.go path_test.go router_test.go; do if git cat-file -e 73fa3b3faf150ce67fff8eb2947d20fbeb3acf71:"$f" 2>/dev/null; then git checkout 73fa3b3faf150ce67fff8eb2947d20fbeb3acf71 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 73fa3b3faf150ce67fff8eb2947d20fbeb3acf71 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/ctx_test.go b/ctx_test.go
index 9f5160d7ee0..d9ccbc0dbb9 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -23,6 +23,7 @@ import (
 	"net"
 	"net/http"
 	"net/http/httptest"
+	"net/url"
 	"os"
 	"path/filepath"
 	"runtime"
@@ -7717,6 +7718,185 @@ func Test_Ctx_SendFile_404(t *testing.T) {
 	require.Equal(t, "sendfile: file ctx12.go not found", string(body))
 }
 
+// Test_Ctx_SendFile_NameIsLiteral pins that SendFile opens exactly the name it
+// is given, the way os.Open would. The file server reads the request URI,
+// which fasthttp decodes and splits at "?" and "#", so the name is escaped on
+// its way in: a "%", "?" or "#" is part of the name, and "100%25.txt" is not
+// "100%.txt".
+func Test_Ctx_SendFile_NameIsLiteral(t *testing.T) {
+	t.Parallel()
+
+	dir := t.TempDir()
+	names := []string{"100%25.txt", "100%.txt", "hash_sign_#.txt", "sp ace.txt", "café.txt", "plus+sign.txt"}
+	if runtime.GOOS != windowsOS {
+		names = append(names, "question?.txt")
+	}
+	for _, name := range names {
+		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte("content of "+name), 0o600))
+	}
+
+	for _, name := range names {
+		app := New()
+		app.Get("/", func(c Ctx) error {
+			return c.SendFile(filepath.Join(dir, name))
+		})
+		resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+		require.NoError(t, err, name)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err, name)
+		require.Equal(t, StatusOK, resp.StatusCode, name)
+		require.Equal(t, "content of "+name, string(body), name)
+	}
+}
+
+// Test_Ctx_SendFile_EncodedSeparatorStaysInDirectory pins that a name built
+// from request input cannot leave the directory the handler joined it to. The
+// router keeps "%2F" encoded, so c.Params("*") of "/files/..%2Fsecret.txt" is
+// one segment that filepath.Join cannot clean; SendFile used to decode it
+// afterwards into "../secret.txt" and serve the file outside the directory.
+// An encoded "?" or "#" likewise stays part of the name.
+func Test_Ctx_SendFile_EncodedSeparatorStaysInDirectory(t *testing.T) {
+	t.Parallel()
+
+	root := t.TempDir()
+	pub := filepath.Join(root, "public")
+	require.NoError(t, os.Mkdir(pub, 0o750))
+	require.NoError(t, os.WriteFile(filepath.Join(pub, "ok.txt"), []byte("OK"), 0o600))
+	require.NoError(t, os.WriteFile(filepath.Join(root, "secret.txt"), []byte("SECRET"), 0o600))
+
+	for _, unescape := range []bool{false, true} {
+		app := New(Config{UnescapePath: unescape})
+		app.Get("/files/*", func(c Ctx) error {
+			return c.SendFile(filepath.Join(pub, c.Params("*")))
+		})
+
+		resp, err := app.Test(httptest.NewRequest(MethodGet, "/files/ok.txt", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, StatusOK, resp.StatusCode, "unescape=%v", unescape)
+
+		for _, target := range []string{
+			"/files/..%2Fsecret.txt",
+			"/files/%2e%2e%2Fsecret.txt",
+			"/files/..%252Fsecret.txt",
+			"/files/ok.txt%3Fx",
+			"/files/ok.txt%23x",
+		} {
+			resp, err := app.Test(httptest.NewRequest(MethodGet, target, http.NoBody))
+			require.NoError(t, err, target)
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err, target)
+			require.Equal(t, StatusNotFound, resp.StatusCode, "unescape=%v target=%s", unescape, target)
+			require.NotContains(t, string(body), "SECRET", "unescape=%v target=%s", unescape, target)
+		}
+	}
+}
+
+// Test_Ctx_SendFile_DirectoryIsNotFound pins that a directory named without a
+// trailing slash is not found rather than redirected: fasthttp's redirect
+// would carry the directory's filesystem path in Location.
+func Test_Ctx_SendFile_DirectoryIsNotFound(t *testing.T) {
+	t.Parallel()
+
+	dir := t.TempDir()
+	// fasthttp escapes the name in the redirect it answers with, so a name it
+	// has to escape (a space, a percent, UTF-8) must be caught all the same.
+	for _, name := range []string{"sub", "sub dir", "100%", "café"} {
+		require.NoError(t, os.Mkdir(filepath.Join(dir, name), 0o750))
+		require.NoError(t, os.WriteFile(filepath.Join(dir, name, "index.html"), []byte("INDEX"), 0o600))
+
+		app := New()
+		app.Get("/", func(c Ctx) error {
+			return c.SendFile(filepath.Join(dir, name))
+		})
+		resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, StatusNotFound, resp.StatusCode, name)
+		require.Empty(t, resp.Header.Get(HeaderLocation), name)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.NotContains(t, string(body), "INDEX", name)
+		// the error the default handler writes names neither the directory
+		// nor where it lives
+		require.NotContains(t, string(body), filepath.ToSlash(dir), name)
+		require.NotContains(t, string(body), name, name)
+	}
+}
+
+// Test_Ctx_SendFile_DecodedParamWithRoot pins the recipe the SendFile docs give
+// for a name taken from a route parameter under the default configuration,
+// where c.Params keeps the escapes the router keeps: decode the parameter and
+// serve it through the FS option from an os.Root, which refuses a name that
+// leaves the directory once decoded.
+func Test_Ctx_SendFile_DecodedParamWithRoot(t *testing.T) {
+	t.Parallel()
+
+	dir := t.TempDir()
+	files := filepath.Join(dir, "files")
+	require.NoError(t, os.Mkdir(files, 0o750))
+	for _, name := range []string{"my file.txt", "café.txt", "100%.txt"} {
+		require.NoError(t, os.WriteFile(filepath.Join(files, name), []byte("FILE "+name), 0o600))
+	}
+	require.NoError(t, os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("SECRET"), 0o600))
+	root, err := os.OpenRoot(files)
+	require.NoError(t, err)
+	t.Cleanup(func() { require.NoError(t, root.Close()) })
+
+	app := New()
+	app.Get("/files/:name", func(c Ctx) error {
+		name, err := url.PathUnescape(c.Params("name"))
+		if err != nil {
+			return ErrBadRequest
+		}
+		return c.SendFile(name, SendFile{FS: root.FS()})
+	})
+
+	for target, want := range map[string]string{
+		"/files/my%20file.txt":   "FILE my file.txt",
+		"/files/caf%C3%A9.txt":   "FILE café.txt",
+		"/files/100%25.txt":      "FILE 100%.txt",
+		"/files/..%2Fsecret.txt": "",
+	} {
+		resp, err := app.Test(httptest.NewRequest(MethodGet, target, http.NoBody))
+		require.NoError(t, err, target)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err, target)
+		if want == "" {
+			require.Equal(t, StatusNotFound, resp.StatusCode, target)
+			require.NotContains(t, string(body), "SECRET", target)
+			continue
+		}
+		require.Equal(t, StatusOK, resp.StatusCode, target)
+		require.Equal(t, want, string(body), target)
+	}
+}
+
+// Test_Ctx_SendFile_ControlByteIsNotFound pins that a name holding a control
+// byte is not found. fasthttp's URI parser used to reject it silently, which
+// left the root path, so the root's index.html was served instead.
+func Test_Ctx_SendFile_ControlByteIsNotFound(t *testing.T) {
+	t.Parallel()
+
+	dir := t.TempDir()
+	require.NoError(t, os.WriteFile(filepath.Join(dir, "index.html"), []byte("INDEX"), 0o600))
+
+	for _, cfg := range []SendFile{{}, {FS: os.DirFS(dir)}} {
+		app := New()
+		app.Get("/", func(c Ctx) error {
+			name := "nope\x00.txt"
+			if cfg.FS == nil {
+				name = filepath.Join(dir, name)
+			}
+			return c.SendFile(name, cfg)
+		})
+		resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, StatusNotFound, resp.StatusCode, "fs=%v", cfg.FS != nil)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.NotContains(t, string(body), "INDEX", "fs=%v", cfg.FS != nil)
+	}
+}
+
 func Test_Ctx_SendFile_Multiple(t *testing.T) {
 	t.Parallel()
 
@@ -12056,3 +12236,30 @@ func Test_Ctx_PathSlashCount(t *testing.T) {
 		}
 	}
 }
+
+// Test_PathNeedsNormalization pins the request gate: a path that kept its
+// parsed length has nothing to decode or resolve, except that a target
+// without a leading slash is normalized whatever its length, since the slash
+// fasthttp adds in front can be canceled by the one a doubled slash loses.
+func Test_PathNeedsNormalization(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		path string
+		norm string
+		want bool
+	}{
+		{path: "/a/b", norm: "/a/b", want: false},
+		{path: "/a%41", norm: "/aA", want: true},
+		{path: "/a//b", norm: "/a/b", want: true},
+		{path: "/a/.", norm: "/a/.", want: true},
+		{path: "/a%zzb", norm: "/a%zzb", want: false},
+		{path: "", norm: "/", want: true},
+		{path: "*", norm: "/*", want: true},
+		{path: "admin//secret", norm: "/admin/secret", want: true},
+		{path: "secret//", norm: "/secret/", want: true},
+		{path: "example.com:443", norm: "/example.com:443", want: true},
+	} {
+		require.Equal(t, tc.want, pathNeedsNormalization(len(tc.norm), tc.path), "%q", tc.path)
+	}
+}
diff --git a/path_test.go b/path_test.go
index 645e63c46cb..9111e4d9e24 100644
--- a/path_test.go
+++ b/path_test.go
@@ -822,6 +822,26 @@ func Test_RegexHandler_CustomCompilerUsesSegmentMatcher(t *testing.T) {
 }
 
 // Test_RoutePatternMatch_WithRegex verifies RoutePatternMatch works with regex constraints
+// Test_RoutePatternMatch_UnrootedPath pins the boundary of the path contract:
+// the empty string is read as "/", and any other string without a leading
+// slash matches no pattern, the root wildcard included, even though the router
+// roots such a request target before matching it.
+func Test_RoutePatternMatch_UnrootedPath(t *testing.T) {
+	t.Parallel()
+
+	require.True(t, RoutePatternMatch("", "/"))
+	require.True(t, RoutePatternMatch("", "/*"))
+	require.True(t, RoutePatternMatch("/", "/"))
+	require.True(t, RoutePatternMatch("/*", "/*"))
+
+	for _, path := range []string{"*", "user/john", "a/../b", "admin//secret"} {
+		for _, pattern := range []string{"/*", "/+", "/:name", "/user/:name", "*"} {
+			require.False(t, RoutePatternMatch(path, pattern), "path=%q pattern=%q", path, pattern)
+			require.False(t, RoutePatternMatch(path, pattern, Config{StrictRouting: true, CaseSensitive: true}), "path=%q pattern=%q", path, pattern)
+		}
+	}
+}
+
 func Test_RoutePatternMatch_WithRegex(t *testing.T) {
 	t.Parallel()
 
@@ -1468,21 +1488,94 @@ func Test_UnescapeSafePath(t *testing.T) {
 		{in: "/100%2525", out: "/100%2525"},
 		{in: "/a%5cb", out: "/a%5Cb"},
 		{in: "/%00%1f%7f", out: "/%00%1F%7F"},
-		// Malformed escapes are kept.
+		// A stray "%" that begins no escape is kept as sent, as it is in a
+		// path matched without normalization.
 		{in: "/a%zzb", out: "/a%zzb"},
 		{in: "/trailing%2", out: "/trailing%2"},
 		{in: "/%", out: "/%"},
+		{in: "/100%", out: "/100%"},
 		{in: "/%2g%41", out: "/%2gA"},
+		{in: "/%a%2Fb", out: "/%a%2Fb"},
 		// Decoding runs once: "%25" never becomes a new escape.
 		{in: "/%2570rivate", out: "/%2570rivate"},
 		{in: "/%2E%2E/%70", out: "/../p"},
+		// A stray "%" cannot line up with a decoded hex digit into a fresh
+		// escape that a later decode would read as "private" or ".git": when
+		// the two bytes written after it are hex digits, it is written as
+		// "%25", whether a decoded escape gives one of them or both.
+		{in: "/%%370rivate", out: "/%2570rivate"},
+		{in: "/%7%30rivate", out: "/%2570rivate"},
+		{in: "/%%32%65git", out: "/%252egit"},
+		{in: "/%%34A", out: "/%254A"},
+		{in: "/%%41%2Fb", out: "/%A%2Fb"},
+		// After a stray "%" a kept escape is still kept, with uppercase hex,
+		// and the "%" it starts with is no hex digit.
+		{in: "/%%20", out: "/%%20"},
+		{in: "/%zz%2fb", out: "/%zz%2Fb"},
+		{in: "/%%%%31%32", out: "/%%%2512"},
 	}
 
 	for _, tc := range tests {
-		require.Equal(t, tc.out, string(unescapeSafePath([]byte(tc.in))), "in=%q", tc.in)
+		got := string(unescapeSafePath([]byte(tc.in)))
+		require.Equal(t, tc.out, got, "in=%q", tc.in)
+		// the normalized path normalizes to itself
+		require.Equal(t, tc.out, string(unescapeSafePath([]byte(got))), "in=%q normalized twice", tc.in)
 	}
 }
 
+// Test_UnescapeSafePath_NoForgedEscape checks every short path over an
+// alphabet of escapes and stray percents: the result normalizes to itself, is
+// never longer than the input, and every "%" in it either begins an escape of
+// a reserved character with uppercase hex digits or is a stray "%" that two
+// hex digits do not follow.
+func Test_UnescapeSafePath_NoForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	alphabet := []string{"%", "a", "3", "7", "%37", "%41", "%2F", "%2f", "/"}
+	var walk func(prefix string, depth int)
+	walk = func(prefix string, depth int) {
+		got := string(unescapeSafePath([]byte(prefix)))
+		require.Equal(t, got, string(unescapeSafePath([]byte(got))), "in=%q normalized twice", prefix)
+		require.LessOrEqual(t, len(got), len(prefix), "in=%q out=%q grew", prefix, got)
+		for i := 0; i < len(got); i++ {
+			if got[i] != '%' || i+2 >= len(got) {
+				continue
+			}
+			hi, lo := unhex(got[i+1]), unhex(got[i+2])
+			if hi < 0 || lo < 0 {
+				continue
+			}
+			require.False(t, pathUnreserved[byte(hi<<4|lo)], "in=%q out=%q holds an escape of an unreserved character", prefix, got)
+			require.Equal(t, strings.ToUpper(got[i+1:i+3]), got[i+1:i+3], "in=%q out=%q holds lowercase hex", prefix, got)
+			i += 2
+		}
+		if depth == 0 {
+			return
+		}
+		for _, a := range alphabet {
+			walk(prefix+a, depth-1)
+		}
+	}
+	walk("/", 5)
+}
+
+// Test_UnescapeSafePath_OneCopy pins that a path full of stray percents, some
+// kept and some written as "%25", is copied once rather than regrown for each.
+//
+// It does not call t.Parallel: testing.AllocsPerRun panics in a parallel test.
+func Test_UnescapeSafePath_OneCopy(t *testing.T) { //nolint:paralleltest // AllocsPerRun cannot run in a parallel test
+	path := []byte("/" + strings.Repeat("%zz%%370", 4000))
+	buf := make([]byte, len(path))
+	allocs := testing.AllocsPerRun(10, func() {
+		copy(buf, path)
+		_ = unescapeSafePath(buf)
+	})
+	require.InDelta(t, 1, allocs, 0)
+	got := unescapeSafePath(append([]byte(nil), path...))
+	require.Equal(t, "/"+strings.Repeat("%zz%2570", 4000), string(got))
+	require.LessOrEqual(t, len(got), len(path))
+}
+
 func Test_CleanPathSegments(t *testing.T) {
 	t.Parallel()
 
@@ -1543,6 +1636,12 @@ func Test_NormalizeRequestPath(t *testing.T) {
 		{in: "/%2570rivate", out: "/%2570rivate"},
 		{in: "/%2570rivate", unescape: true, out: "/%70rivate"},
 		{in: "/%252e%252e/x", unescape: true, out: "/%2e%2e/x"},
+		// An unrooted path is rooted first: the empty path of an absolute-form
+		// target, the asterisk form, and a relative path with a dot segment.
+		{in: "", out: "/"},
+		{in: "*", out: "/*"},
+		{in: "a/../b", out: "/b"},
+		{in: "", unescape: true, out: "/"},
 	}
 
 	for _, tc := range tests {
@@ -1580,7 +1679,7 @@ func Test_NeedsPathNormalization_MatchesReference(t *testing.T) {
 	t.Parallel()
 
 	ref := func(s string) bool {
-		if s != "" && s[0] == '.' {
+		if s == "" || s[0] != '/' {
 			return true
 		}
 		return strings.Contains(s, "%") || strings.Contains(s, "/.")
@@ -1627,10 +1726,11 @@ func Benchmark_NeedsPathNormalization(b *testing.B) {
 func Test_NeedsPathNormalization(t *testing.T) {
 	t.Parallel()
 
-	for _, s := range []string{"/a/./b", "/a/../b", "/%41", "/%2F", "/.", "/..", "./x", "../x", "/.well-known/x"} {
+	// an unrooted path needs rooting, so it counts as needing normalization
+	for _, s := range []string{"/a/./b", "/a/../b", "/%41", "/%2F", "/.", "/..", "./x", "../x", "/.well-known/x", "", "*", "a/b"} {
 		require.True(t, needsPathNormalization(s), "path=%q", s)
 	}
-	for _, s := range []string{"", "/", "/a", "/a/b", "/a/b/", "/a//b", "//", "/a.b/c", "/a-b_c~d", "/a/b.", "/a..b", "/user/keys/1337"} {
+	for _, s := range []string{"/", "/a", "/a/b", "/a/b/", "/a//b", "//", "/a.b/c", "/a-b_c~d", "/a/b.", "/a..b", "/user/keys/1337"} {
 		require.False(t, needsPathNormalization(s), "path=%q", s)
 	}
 }
diff --git a/router_test.go b/router_test.go
index 70dc842f5d8..29c508694e8 100644
--- a/router_test.go
+++ b/router_test.go
@@ -5081,6 +5081,151 @@ func Test_Router_UnescapePath_PlusIsLiteral(t *testing.T) {
 	require.False(t, RoutePatternMatch("/u/john+doe", "/u/john doe", Config{UnescapePath: true}))
 }
 
+// Test_Router_StrayPercent pins what a "%" that begins no escape becomes in
+// c.Path(). fasthttp copies it as sent, so a path holding nothing else to
+// decode or resolve keeps its parsed length, passes pathNeedsNormalization and
+// is matched as sent. A path normalized for another reason keeps it as sent
+// too, unless an escape decoded after it would complete a new escape with it;
+// then it is written as "%25". Either way c.Path() never holds an escape of an
+// unreserved character, and the same name comes out alike whatever else the
+// path holds. httptest rejects these spellings, so the requests go through the
+// raw handler.
+func Test_Router_StrayPercent(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		path string
+		body string
+	}{
+		// nothing to decode or resolve: matched as sent
+		{path: "/a%zzb", body: "/a%zzb"},
+		{path: "/trailing%2", body: "/trailing%2"},
+		{path: "/%", body: "/%"},
+		// normalized for something else: the stray "%" is kept
+		{path: "/%2g%41", body: "/%2gA"},
+		{path: "/x%zz/%41", body: "/x%zz/A"},
+		{path: "/a%zzb/./c", body: "/a%zzb/c"},
+		{path: "/a//%zzb", body: "/a//%zzb"},
+		{path: "/files/a%2Fb/100%", body: "/files/a%2Fb/100%"},
+		// a decoded escape would complete an escape with it: "%25"
+		{path: "/%%370rivate", body: "/%2570rivate"},
+		{path: "/x/%%32%65git", body: "/x/%252egit"},
+	}
+	for _, caseSensitive := range []bool{false, true} {
+		app := New(Config{CaseSensitive: caseSensitive})
+		app.Use(func(c Ctx) error {
+			return c.SendString(c.Path())
+		})
+		handler := app.Handler()
+		for _, tc := range testCases {
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Request.Header.SetMethod(MethodGet)
+			fctx.Request.SetRequestURI(tc.path)
+			handler(fctx)
+			require.Equal(t, StatusOK, fctx.Response.StatusCode(), "CaseSensitive=%v GET %s", caseSensitive, tc.path)
+			require.Equal(t, tc.body, string(fctx.Response.Body()), "CaseSensitive=%v GET %s", caseSensitive, tc.path)
+		}
+	}
+}
+
+// Test_Router_StrayPercentParamIsStable pins that a route parameter holding a
+// stray "%" does not depend on the rest of the path: "/files/100%" is matched
+// as sent, "/files/./100%" and "/files/x/../100%" are normalized for their dot
+// segments, and under DisablePathNormalizing every "%" sends the path through
+// normalization. All of them give the parameter "100%".
+func Test_Router_StrayPercentParamIsStable(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Get("/files/:name", func(c Ctx) error {
+		return c.SendString(c.Params("name"))
+	})
+	handler := app.Handler()
+	for _, disable := range []bool{false, true} {
+		for _, target := range []string{"/files/100%", "/files/./100%", "/files/x/../100%", "/files/%2e/100%"} {
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Request.Header.SetMethod(MethodGet)
+			fctx.Request.SetRequestURI(target)
+			fctx.Request.URI().DisablePathNormalizing = disable
+			handler(fctx)
+			require.Equal(t, StatusOK, fctx.Response.StatusCode(), "DisablePathNormalizing=%v GET %s", disable, target)
+			require.Equal(t, "100%", string(fctx.Response.Body()), "DisablePathNormalizing=%v GET %s", disable, target)
+		}
+	}
+}
+
+// Test_Router_UnrootedTargetIsRooted pins that a request target without a
+// leading slash, the absolute form with an empty path or the asterisk form,
+// is routed as the rooted path fasthttp reports for it. Unrooted, it slipped
+// past every root-level Use middleware while a "/*" route still matched it.
+// httptest rejects these targets, so the requests go through the raw handler.
+func Test_Router_UnrootedTargetIsRooted(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		method, target, path string
+	}{
+		{MethodGet, "http://example.com?x=1", "/"},
+		{MethodPost, "http://example.com#f", "/"},
+		{MethodOptions, "*", "/*"},
+		{MethodGet, "http://example.com/a/b", "/a/b"},
+		// the authority form fasthttp admits for CONNECT; with one doubled
+		// slash the parsed copy keeps the original's length, since the slash
+		// fasthttp adds in front is the one it takes out of the pair, so the
+		// length gate alone would not notice the missing slash
+		{MethodConnect, "admin//secret", "/admin//secret"},
+		{MethodConnect, "secret//", "/secret//"},
+		{MethodConnect, "example.com:443", "/example.com:443"},
+	}
+	// with DisablePathNormalizing the scan, not fasthttp's parsed copy, has
+	// to notice the missing slash
+	for _, disable := range []bool{false, true} {
+		for _, tc := range testCases {
+			app := New()
+			guardRan, seen := false, ""
+			app.Use(func(c Ctx) error {
+				guardRan = true
+				return c.Next()
+			})
+			app.All("/*", func(c Ctx) error {
+				seen = c.Path()
+				return c.SendString("catch-all")
+			})
+
+			var req fasthttp.Request
+			req.Header.SetMethod(tc.method)
+			req.SetRequestURI(tc.target)
+			req.Header.SetHost("example.com")
+			var fctx fasthttp.RequestCtx
+			fctx.Init(&req, nil, nil)
+			if disable {
+				fctx.Request.URI().DisablePathNormalizing = true
+			}
+			app.Handler()(&fctx)
+
+			require.Equal(t, StatusOK, fctx.Response.StatusCode(), "disable=%v %s %s", disable, tc.method, tc.target)
+			require.True(t, guardRan, "disable=%v %s %s: root middleware skipped", disable, tc.method, tc.target)
+			require.Equal(t, tc.path, seen, "disable=%v %s %s", disable, tc.method, tc.target)
+		}
+	}
+
+	// an override is rooted the same way
+	app := New()
+	app.Use(func(c Ctx) error {
+		c.Path("rewritten")
+		return c.Next()
+	})
+	app.Get("/rewritten", func(c Ctx) error {
+		return c.SendString(c.Path())
+	})
+	resp, err := app.Test(httptest.NewRequest(MethodGet, "/original", http.NoBody))
+	require.NoError(t, err)
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, StatusOK, resp.StatusCode)
+	require.Equal(t, "/rewritten", string(body))
+}
+
 func Test_App_Add_MultipleMethods_Name(t *testing.T) {
 	t.Parallel()
 

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path ctx_test.go --path path_test.go --path router_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./')"
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
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
