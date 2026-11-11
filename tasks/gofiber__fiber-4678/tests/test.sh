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
for f in appconfig_test.go extractors/bench_test.go extractors/extractors_fuzz_test.go extractors/extractors_test.go internal/appconfig/appconfig_test.go internal/headerlookup/headerlookup_test.go middleware/keyauth/keyauth_test.go middleware/limiter/limiter_test.go middleware/session/session_test.go middleware/session/store_test.go; do if git cat-file -e ef013fa52a2435224f99b78fddc68f50bdfb71b5:"$f" 2>/dev/null; then git checkout ef013fa52a2435224f99b78fddc68f50bdfb71b5 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - ef013fa52a2435224f99b78fddc68f50bdfb71b5 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/appconfig_test.go b/appconfig_test.go
new file mode 100644
index 00000000000..834a31a08f3
--- /dev/null
+++ b/appconfig_test.go
@@ -0,0 +1,66 @@
+package fiber
+
+import (
+	"testing"
+
+	"github.com/gofiber/fiber/v3/internal/appconfig"
+	"github.com/stretchr/testify/require"
+)
+
+// Test_AppConfigReader covers the read the internal hot paths use instead of
+// Config(): what the app was configured with, nothing for what is not an app,
+// and no way to replace it.
+func Test_AppConfigReader(t *testing.T) {
+	t.Parallel()
+
+	t.Run("reports the configured bits", func(t *testing.T) {
+		t.Parallel()
+
+		app := New(Config{Immutable: true, DisableHeaderNormalizing: true, UnescapePath: true})
+		require.Equal(t, appconfig.Hot{Immutable: true, DisableHeaderNormalizing: true, UnescapePath: true}, appconfig.Of(app))
+	})
+
+	t.Run("reports the defaults", func(t *testing.T) {
+		t.Parallel()
+
+		require.Equal(t, appconfig.Hot{}, appconfig.Of(New()))
+	})
+
+	t.Run("agrees with Config", func(t *testing.T) {
+		t.Parallel()
+
+		app := New(Config{DisableHeaderNormalizing: true})
+		h := appconfig.Of(app)
+		cfg := app.Config()
+		require.Equal(t, cfg.Immutable, h.Immutable)
+		require.Equal(t, cfg.DisableHeaderNormalizing, h.DisableHeaderNormalizing)
+		require.Equal(t, cfg.UnescapePath, h.UnescapePath)
+	})
+
+	t.Run("answers nothing for what is not an app", func(t *testing.T) {
+		t.Parallel()
+
+		for _, arg := range []any{nil, "app", 0, App{}} {
+			require.Equal(t, appconfig.Hot{}, appconfig.Of(arg), "%T must not answer", arg)
+		}
+	})
+
+	t.Run("a nil app faults, as reading its Config would", func(t *testing.T) {
+		t.Parallel()
+
+		require.Panics(t, func() { appconfig.Of((*App)(nil)) })
+	})
+
+	t.Run("the reader cannot be replaced", func(t *testing.T) {
+		t.Parallel()
+
+		// init installed the reader, so no later caller can change what
+		// Immutable means for the rest of the process.
+		appconfig.SetReader(func(any) appconfig.Hot {
+			return appconfig.Hot{Immutable: true, DisableHeaderNormalizing: true, UnescapePath: true}
+		})
+		appconfig.SetReader(nil)
+
+		require.Equal(t, appconfig.Hot{}, appconfig.Of(New()))
+	})
+}
diff --git a/extractors/bench_test.go b/extractors/bench_test.go
new file mode 100644
index 00000000000..a31536009e7
--- /dev/null
+++ b/extractors/bench_test.go
@@ -0,0 +1,336 @@
+package extractors
+
+import (
+	"testing"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/valyala/fasthttp"
+)
+
+// A JWT-sized token68 credential.
+const benchToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9P"
+
+// benchSink keeps the results alive so nothing measured is optimized away.
+var benchSink struct {
+	err    error
+	value  string
+	source Source
+	ok     bool
+}
+
+func newBenchCtx(b *testing.B, cfg ...fiber.Config) fiber.Ctx {
+	b.Helper()
+	app := fiber.New(cfg...)
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	b.Cleanup(func() { app.ReleaseCtx(c) })
+	return c
+}
+
+func benchExtract(b *testing.B, e Extractor, c fiber.Ctx) {
+	b.Helper()
+	b.ReportAllocs()
+	for b.Loop() {
+		benchSink.value, benchSink.err = e.Extract(c)
+	}
+}
+
+func benchExtractWithSource(b *testing.B, e Extractor, c fiber.Ctx) {
+	b.Helper()
+	b.ReportAllocs()
+	for b.Loop() {
+		benchSink.value, benchSink.source, benchSink.err = ExtractWithSource(e, c)
+	}
+}
+
+// benchExtractFresh resets the request's user values after every extraction,
+// as fasthttp does between requests, so what an extractor keeps in Locals is
+// paid for per request rather than amortized over a reused context.
+func benchExtractFresh(b *testing.B, e Extractor, c fiber.Ctx) {
+	b.Helper()
+	b.ReportAllocs()
+	for b.Loop() {
+		benchSink.value, benchSink.err = e.Extract(c)
+		c.RequestCtx().ResetUserValues()
+	}
+}
+
+// benchExtractWithSourceFresh is benchExtractFresh for the source-aware entry
+// point.
+func benchExtractWithSourceFresh(b *testing.B, e Extractor, c fiber.Ctx) {
+	b.Helper()
+	b.ReportAllocs()
+	for b.Loop() {
+		benchSink.value, benchSink.source, benchSink.err = ExtractWithSource(e, c)
+		c.RequestCtx().ResetUserValues()
+	}
+}
+
+func benchChain3() Extractor {
+	return Chain(FromHeader("X-API-Key"), FromCookie("api_key"), FromQuery("api_key"))
+}
+
+// --- leaves -----------------------------------------------------------------
+
+func Benchmark_Extractor_FromHeader_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtract(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_FromHeader_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-Other", "x")
+	benchExtract(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_FromHeader_Hit_ManyHeaders(b *testing.B) {
+	c := newBenchCtx(b)
+	for _, h := range []string{
+		"Accept", "Accept-Encoding", "Accept-Language", "Cache-Control", "Referer",
+		"Sec-Fetch-Site", "Sec-Fetch-Mode", "Origin", "X-Request-Id", "X-Forwarded-For",
+	} {
+		c.Request().Header.Set(h, "value")
+	}
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtract(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_FromHeader_Hit_NoNormalize(b *testing.B) {
+	c := newBenchCtx(b, fiber.Config{DisableHeaderNormalizing: true})
+	c.Request().Header.DisableNormalizing()
+	c.Request().Header.Set("x-api-key", benchToken)
+	benchExtract(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_FromHeader_Hit_Immutable(b *testing.B) {
+	c := newBenchCtx(b, fiber.Config{Immutable: true})
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtract(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_FromAuthHeader_Bearer_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set(fiber.HeaderAuthorization, "Bearer "+benchToken)
+	benchExtract(b, FromAuthHeader("Bearer"), c)
+}
+
+func Benchmark_Extractor_FromAuthHeader_Basic_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set(fiber.HeaderAuthorization, "Basic dXNlcjpwYXNzd29yZA==")
+	benchExtract(b, FromAuthHeader("Basic"), c)
+}
+
+func Benchmark_Extractor_FromAuthHeader_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	benchExtract(b, FromAuthHeader("Bearer"), c)
+}
+
+func Benchmark_Extractor_FromAuthHeader_WrongScheme(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set(fiber.HeaderAuthorization, "Basic dXNlcjpwYXNzd29yZA==")
+	benchExtract(b, FromAuthHeader("Bearer"), c)
+}
+
+func Benchmark_Extractor_FromAuthHeader_NoScheme(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set(fiber.HeaderAuthorization, "Bearer "+benchToken)
+	benchExtract(b, FromAuthHeader(""), c)
+}
+
+func Benchmark_Extractor_FromCookie_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.SetCookie("session_id", "abc123")
+	c.Request().Header.SetCookie("other", "x")
+	benchExtract(b, FromCookie("session_id"), c)
+}
+
+func Benchmark_Extractor_FromCookie_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.SetCookie("other", "x")
+	benchExtract(b, FromCookie("session_id"), c)
+}
+
+func Benchmark_Extractor_FromQuery_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?format=json&token=abc123")
+	benchExtract(b, FromQuery("token"), c)
+}
+
+func Benchmark_Extractor_FromQuery_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?format=json")
+	benchExtract(b, FromQuery("token"), c)
+}
+
+func Benchmark_Extractor_FromForm_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.SetMethod(fiber.MethodPost)
+	c.Request().Header.SetContentType(fiber.MIMEApplicationForm)
+	c.Request().SetBodyString("username=john&token=abc123")
+	benchExtract(b, FromForm("token"), c)
+}
+
+func Benchmark_Extractor_FromForm_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.SetMethod(fiber.MethodPost)
+	c.Request().Header.SetContentType(fiber.MIMEApplicationForm)
+	c.Request().SetBodyString("username=john")
+	benchExtract(b, FromForm("token"), c)
+}
+
+// benchParam runs the loop inside a matched route, where route parameters are
+// the only place they exist.
+func benchParam(b *testing.B, uri string) {
+	b.Helper()
+	app := fiber.New()
+	ext := FromParam("id")
+	ran := false
+	app.Get("/users/:id", func(c fiber.Ctx) error {
+		ran = true
+		b.ReportAllocs()
+		for b.Loop() {
+			benchSink.value, benchSink.err = ext.Extract(c)
+		}
+		return nil
+	})
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	fctx.Request.SetRequestURI(uri)
+	app.Handler()(fctx)
+	if !ran {
+		b.Fatal("route did not match")
+	}
+}
+
+func Benchmark_Extractor_FromParam_Hit(b *testing.B) {
+	benchParam(b, "/users/abc123")
+}
+
+func Benchmark_Extractor_FromParam_Hit_Escaped(b *testing.B) {
+	benchParam(b, "/users/abc%20123")
+}
+
+func Benchmark_Extractor_FromCustom_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	benchExtract(b, FromCustom("k", func(fiber.Ctx) (string, error) { return "v", nil }), c)
+}
+
+// --- chains -----------------------------------------------------------------
+
+func Benchmark_Extractor_Chain1_Hit(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtract(b, Chain(FromHeader("X-API-Key")), c)
+}
+
+func Benchmark_Extractor_Chain3_HitFirst(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtract(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_Chain3_HitLast(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	benchExtract(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_Chain3_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	benchExtract(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_ChainNested_HitInner(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	outer := Chain(FromHeader("X-API-Key"), Chain(FromCookie("api_key"), FromQuery("api_key")))
+	benchExtract(b, outer, c)
+}
+
+// The locals a real request accumulates before the extractor runs; every
+// request-local lookup scans past them.
+func Benchmark_Extractor_Chain3_HitFirst_WithLocals(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	for i := range 5 {
+		c.Locals(i, "value")
+	}
+	benchExtract(b, benchChain3(), c)
+}
+
+// --- source-aware -------------------------------------------------------------
+
+func Benchmark_Extractor_ExtractWithSource_Leaf(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtractWithSource(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_Chain3_HitFirst(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtractWithSource(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_Chain3_HitLast(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	benchExtractWithSource(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_Chain3_Miss(b *testing.B) {
+	c := newBenchCtx(b)
+	benchExtractWithSource(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_Nested_HitInner(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	outer := Chain(FromHeader("X-API-Key"), Chain(FromCookie("api_key"), FromQuery("api_key")))
+	benchExtractWithSource(b, outer, c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_BareChain_HitLast(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	bare := Extractor{
+		Chain:  []Extractor{FromHeader("X-API-Key"), FromCookie("api_key"), FromQuery("api_key")},
+		Source: SourceHeader,
+	}
+	benchExtractWithSource(b, bare, c)
+}
+
+// --- fresh request -----------------------------------------------------------
+
+func Benchmark_Extractor_FromHeader_Hit_FreshRequest(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtractFresh(b, FromHeader("X-API-Key"), c)
+}
+
+func Benchmark_Extractor_Chain1_Hit_FreshRequest(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtractFresh(b, Chain(FromHeader("X-API-Key")), c)
+}
+
+func Benchmark_Extractor_Chain3_HitLast_FreshRequest(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().SetRequestURI("/api?api_key=abc123")
+	benchExtractFresh(b, benchChain3(), c)
+}
+
+func Benchmark_Extractor_ExtractWithSource_Chain3_HitFirst_FreshRequest(b *testing.B) {
+	c := newBenchCtx(b)
+	c.Request().Header.Set("X-API-Key", benchToken)
+	benchExtractWithSourceFresh(b, benchChain3(), c)
+}
+
+// --- token68 ------------------------------------------------------------------
+
+func Benchmark_Extractor_Token68_JWT(b *testing.B) {
+	b.ReportAllocs()
+	for b.Loop() {
+		benchSink.ok = isValidToken68(benchToken)
+	}
+}
diff --git a/extractors/extractors_fuzz_test.go b/extractors/extractors_fuzz_test.go
new file mode 100644
index 00000000000..6aeb8dfc9e4
--- /dev/null
+++ b/extractors/extractors_fuzz_test.go
@@ -0,0 +1,20 @@
+package extractors
+
+import (
+	"testing"
+)
+
+// FuzzIsValidToken68 holds the table scan to the range-compare scan it
+// replaced, on whatever the fuzzer can think of.
+//
+// go test -v -run=^$ -fuzz=FuzzIsValidToken68
+func FuzzIsValidToken68(f *testing.F) {
+	for _, seed := range token68Samples {
+		f.Add(seed)
+	}
+	f.Fuzz(func(t *testing.T, token string) {
+		if isValidToken68(token) != isValidToken68Reference(token) {
+			t.Fatalf("table and reference disagree on %q", token)
+		}
+	})
+}
diff --git a/extractors/extractors_test.go b/extractors/extractors_test.go
index 4415eaa9c52..2b37b4d9613 100644
--- a/extractors/extractors_test.go
+++ b/extractors/extractors_test.go
@@ -5,11 +5,15 @@ import (
 	"context"
 	"errors"
 	"fmt"
+	"io"
 	"net/http"
 	"strings"
+	"sync"
+	"sync/atomic"
 	"testing"
 
 	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
 )
@@ -1208,7 +1212,7 @@ func Test_isValidToken68(t *testing.T) {
 // go test -v -run=^$ -bench=Benchmark_isValidToken68 -benchmem -count=4
 func Benchmark_isValidToken68(b *testing.B) {
 	inputs := []string{
-		"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9P", // JWT-like
+		benchToken,             // JWT-sized credential
 		"dXNlcjpwYXNzd29yZA==", // short base64 credential
 		"token@invalid",        // early reject
 	}
@@ -1898,9 +1902,7 @@ func Test_ExtractWithSource_BareChain(t *testing.T) {
 
 		// The guard set for the walk must be cleared afterwards, or the next
 		// walk on this ctx would be mistaken for a cycle.
-		guard, ok := chainGuardFor(bare.Chain)
-		require.True(t, ok)
-		require.Equal(t, false, ctx.Locals(guard))
+		require.NotContains(t, chainStateFor(ctx).active, chainGuard(bare.Chain))
 
 		v, src, err = ExtractWithSource(bare, ctx)
 		require.NoError(t, err)
@@ -1921,8 +1923,491 @@ func Test_ExtractWithSource_BareChain(t *testing.T) {
 		_, _, err := ExtractWithSource(bare, ctx)
 		require.ErrorIs(t, err, ErrChainCycle)
 
-		guard, ok := chainGuardFor(bare.Chain)
-		require.True(t, ok)
-		require.Equal(t, false, ctx.Locals(guard), "the guard is released even after a refused walk")
+		require.NotContains(t, chainStateFor(ctx).active, chainGuard(bare.Chain), "the guard is released even after a refused walk")
 	})
 }
+
+// The state is reclaimed by the request store calling Close on it.
+var _ io.Closer = (*chainState)(nil)
+
+// closeRecorder reports whether the request store closed it. The contract is
+// pinned here rather than through the chain state, whose pointer is back in
+// the pool by the time a test could look at it.
+type closeRecorder struct {
+	closed *atomic.Bool
+}
+
+// Close records the call fasthttp makes when it resets the request.
+func (r closeRecorder) Close() error {
+	r.closed.Store(true)
+	return nil
+}
+
+// Test_Chain_StateIsRecycledOnRequestReset pins the recycling: fasthttp closes
+// request-local io.Closers on reset, the state is stored where that happens,
+// and one handed out afterwards is clean.
+func Test_Chain_StateIsRecycledOnRequestReset(t *testing.T) {
+	t.Parallel()
+
+	t.Run("request store closes values on reset", func(t *testing.T) {
+		t.Parallel()
+
+		var closed atomic.Bool
+		fctx := &fasthttp.RequestCtx{}
+		fctx.SetUserValue("recorder", closeRecorder{closed: &closed})
+		require.False(t, closed.Load())
+
+		fctx.Request.Reset()
+		require.True(t, closed.Load(), "fasthttp must close request-local values that implement io.Closer")
+	})
+
+	t.Run("chain state lives in the request store and is dropped on reset", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		chain := Chain(FromHeader("X-Token"), FromQuery("token"))
+		app.Get("/t", func(c fiber.Ctx) error {
+			v, err := chain.Extract(c)
+			require.NoError(t, err)
+			require.Equal(t, "tok", v)
+			// Dirty it, so a stale state would show up in the next holder.
+			st := chainStateFor(c)
+			st.win = SourceQuery
+			st.hasWin = true
+			return c.SendStatus(fiber.StatusNoContent)
+		})
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Request.Header.SetMethod(fiber.MethodGet)
+		fctx.Request.SetRequestURI("/t")
+		fctx.Request.Header.Set("X-Token", "tok")
+		app.Handler()(fctx)
+		require.Equal(t, fiber.StatusNoContent, fctx.Response.StatusCode())
+
+		_, ok := fctx.UserValue(chainStateKey{}).(*chainState)
+		require.True(t, ok, "the state must be stored in the request, which is what gets closed")
+
+		fctx.Request.Reset()
+		require.Nil(t, fctx.UserValue(chainStateKey{}), "the reset must drop the state")
+	})
+
+	t.Run("a state handed out is clean", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+		t.Cleanup(func() { app.ReleaseCtx(ctx) })
+
+		// Whether this state is new or recycled, it must carry nothing from
+		// the request that used it before.
+		st := chainStateFor(ctx)
+		require.Empty(t, st.active)
+		require.Zero(t, st.depth)
+		require.False(t, st.hasWin)
+		require.Same(t, st, chainStateFor(ctx), "one state per request")
+	})
+}
+
+// Test_Chain_NoAllocations guards the pooled state: the source-aware path
+// allocated a []Source per winning child before it existed.
+//
+// Not parallel: AllocsPerRun counts allocations process-wide, and Go pauses
+// parallel tests while a sequential one runs.
+func Test_Chain_NoAllocations(t *testing.T) {
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(ctx) })
+	ctx.Request().Header.Set("X-Token", "from-header")
+	ctx.Request().SetRequestURI("/?token=from-query")
+
+	flat := Chain(FromCookie("token"), FromQuery("token"))
+	nested := Chain(FromHeader("X-Missing"), Chain(FromCookie("token"), FromQuery("token")))
+
+	cases := []struct {
+		run  func()
+		name string
+	}{
+		{name: "Extract", run: func() {
+			if _, err := flat.Extract(ctx); err != nil {
+				t.Error(err)
+			}
+		}},
+		{name: "ExtractWithSource", run: func() {
+			if _, _, err := ExtractWithSource(flat, ctx); err != nil {
+				t.Error(err)
+			}
+		}},
+		{name: "ExtractWithSource_nested", run: func() {
+			if _, _, err := ExtractWithSource(nested, ctx); err != nil {
+				t.Error(err)
+			}
+		}},
+		{name: "ExtractWithSource_bare_chain", run: func() {
+			bare := Extractor{Chain: flat.Chain}
+			if _, _, err := ExtractWithSource(bare, ctx); err != nil {
+				t.Error(err)
+			}
+		}},
+	}
+
+	for _, tc := range cases {
+		tc.run() // warm the state into the request store
+		require.Zero(t, testing.AllocsPerRun(100, tc.run), "%s must not allocate", tc.name)
+	}
+}
+
+// countingCtx makes the Locals override observable.
+type countingCtx struct {
+	fiber.DefaultCtx
+	calls atomic.Int64
+}
+
+// Locals counts each call before forwarding it.
+func (c *countingCtx) Locals(key any, value ...any) any {
+	c.calls.Add(1)
+	return c.DefaultCtx.Locals(key, value...)
+}
+
+// Test_Chain_CustomCtx keeps the chain state reachable through a context that
+// overrides Locals. Such a store may never close the state, which costs an
+// allocation but must not change any answer.
+func Test_Chain_CustomCtx(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.NewWithCustomCtx(func(app *fiber.App) fiber.CustomCtx {
+		return &countingCtx{DefaultCtx: *fiber.NewDefaultCtx(app)}
+	})
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(ctx) })
+	ctx.Request().SetRequestURI("/?token=from-query")
+
+	custom, ok := ctx.(*countingCtx)
+	require.True(t, ok, "the app must hand out the custom context")
+
+	chain := Chain(FromHeader("X-Token"), FromQuery("token"))
+
+	v, err := chain.Extract(ctx)
+	require.NoError(t, err)
+	require.Equal(t, "from-query", v)
+
+	// Sequential reuse: the guard is released, so the second walk is not a cycle.
+	sv, src, serr := ExtractWithSource(chain, ctx)
+	require.NoError(t, serr)
+	require.Equal(t, "from-query", sv)
+	require.Equal(t, SourceQuery, src)
+
+	var cyclic Extractor
+	cyclic = Chain(FromCustom("cycle", func(c fiber.Ctx) (string, error) {
+		return cyclic.Extract(c)
+	}))
+	_, err = cyclic.Extract(ctx)
+	require.ErrorIs(t, err, ErrChainCycle)
+
+	require.Positive(t, custom.calls.Load(), "the overridden Locals must be the one that ran")
+}
+
+// Test_Chain_Concurrent runs chains on many requests at once, so the race
+// detector sees the pooled state cross goroutines.
+func Test_Chain_Concurrent(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	chain := Chain(FromHeader("X-Token"), FromQuery("token"))
+
+	var cyclic Extractor
+	cyclic = Chain(FromCustom("cycle", func(c fiber.Ctx) (string, error) {
+		return cyclic.Extract(c)
+	}))
+
+	const workers = 64
+	var wg sync.WaitGroup
+	wg.Add(workers)
+	for range workers {
+		go func() {
+			defer wg.Done()
+			for range 50 {
+				fctx := &fasthttp.RequestCtx{}
+				fctx.Request.SetRequestURI("/?token=from-query")
+				c := app.AcquireCtx(fctx)
+
+				v, src, err := ExtractWithSource(chain, c)
+				assert.NoError(t, err)
+				assert.Equal(t, "from-query", v)
+				assert.Equal(t, SourceQuery, src)
+
+				_, err = cyclic.Extract(c)
+				assert.ErrorIs(t, err, ErrChainCycle)
+
+				app.ReleaseCtx(c)
+				// What the server does between requests.
+				fctx.Request.Reset()
+			}
+		}()
+	}
+	wg.Wait()
+}
+
+// token68Samples are the shapes the table and the scan it replaced could most
+// easily disagree about. The fuzz target seeds its corpus with them.
+var token68Samples = []string{
+	"", "=", "==", "===", "=a", "a", "a=", "a==", "a===", "a=b", "a==b",
+	"dXNlcjpwYXNzd29yZA==", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0",
+	benchToken, "-._~+/", "a b", "a\tb", "a\nb", "token@invalid",
+}
+
+// isValidToken68Reference is the range-compare scan the table replaced, kept
+// as the definition it is checked against.
+func isValidToken68Reference(token string) bool {
+	if token == "" {
+		return false
+	}
+	paddingStarted := false
+	for i := 0; i < len(token); i++ {
+		c := token[i]
+		switch {
+		case (c >= 'A' && c <= 'Z') ||
+			(c >= 'a' && c <= 'z') ||
+			(c >= '0' && c <= '9') ||
+			c == '-' || c == '.' || c == '_' || c == '~' || c == '+' || c == '/':
+			if paddingStarted {
+				return false // No characters allowed after padding starts
+			}
+		case c == '=':
+			if i == 0 {
+				return false // Cannot start with padding
+			}
+			paddingStarted = true
+		default:
+			return false // Invalid character
+		}
+	}
+	return true
+}
+
+// Test_isValidToken68_MatchesReference checks the table against the scan it
+// replaced, on every byte in every position that could distinguish them.
+func Test_isValidToken68_MatchesReference(t *testing.T) {
+	t.Parallel()
+
+	t.Run("every byte in every position", func(t *testing.T) {
+		t.Parallel()
+
+		for c := range 256 {
+			// From the byte, not rune(c): the high half must be one invalid
+			// byte, not two UTF-8 ones.
+			b := string([]byte{byte(c)})
+			for _, in := range []string{
+				b,             // alone
+				b + "aA",      // at the start
+				"a" + b + "A", // in the middle
+				"aA" + b,      // at the end
+				"aA" + b + "==",
+				"aA==" + b,
+			} {
+				require.Equal(t, isValidToken68Reference(in), isValidToken68(in), "input %q", in)
+			}
+		}
+	})
+
+	t.Run("padding shapes", func(t *testing.T) {
+		t.Parallel()
+
+		for _, in := range token68Samples {
+			require.Equal(t, isValidToken68Reference(in), isValidToken68(in), "input %q", in)
+		}
+	})
+}
+
+// Test_ExtractWithSource_EmptyValue covers an Extract that succeeds and hands
+// back nothing, which is a miss rather than a value.
+func Test_ExtractWithSource_EmptyValue(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(ctx) })
+
+	v, src, err := ExtractWithSource(Extractor{
+		Extract: func(fiber.Ctx) (string, error) { return "", nil },
+		Source:  SourceForm,
+		Key:     "empty",
+	}, ctx)
+	require.Empty(t, v)
+	require.Equal(t, SourceForm, src, "a miss reports the declared source")
+	require.ErrorIs(t, err, ErrNotFound)
+}
+
+// Test_ExtractWithSource_BareChain_EmptyChildren covers a walked chain whose
+// children have nothing to run: each is stepped over, and a chain that ran
+// nothing reports ErrNotFound rather than a child's error.
+func Test_ExtractWithSource_BareChain_EmptyChildren(t *testing.T) {
+	t.Parallel()
+
+	// A context each: a walk writes the chain state into the one it is given.
+	newCtx := func(t *testing.T) fiber.Ctx {
+		t.Helper()
+
+		app := fiber.New()
+		ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+		t.Cleanup(func() { app.ReleaseCtx(ctx) })
+		ctx.Request().Header.Set("X-Token", "from-header")
+		return ctx
+	}
+
+	t.Run("every child is skipped", func(t *testing.T) {
+		t.Parallel()
+
+		v, src, err := ExtractWithSource(Extractor{
+			Chain:  []Extractor{{}, {Key: "no extract, no chain"}},
+			Source: SourceCookie,
+		}, newCtx(t))
+		require.Empty(t, v)
+		require.Equal(t, SourceCookie, src)
+		require.ErrorIs(t, err, ErrNotFound)
+	})
+
+	t.Run("a skipped child does not stop the walk", func(t *testing.T) {
+		t.Parallel()
+
+		v, src, err := ExtractWithSource(Extractor{
+			Chain:  []Extractor{{}, FromHeader("X-Token")},
+			Source: SourceCookie,
+		}, newCtx(t))
+		require.NoError(t, err)
+		require.Equal(t, "from-header", v)
+		require.Equal(t, SourceHeader, src)
+	})
+}
+
+// Test_Extractor_FromAuthHeader_SchemeWithoutCredential covers a header that is
+// the scheme and its separating space and nothing else, which is a scheme
+// naming no credential rather than a credential that happens to be empty.
+func Test_Extractor_FromAuthHeader_SchemeWithoutCredential(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(ctx) })
+	// Set rather than read from the wire: parsing strips the trailing space,
+	// so only a field written in process carries one. Middleware rewriting
+	// Authorization writes this shape.
+	ctx.Request().Header.Set(fiber.HeaderAuthorization, "Bearer ")
+	require.Equal(t, "Bearer ", string(ctx.Request().Header.Peek(fiber.HeaderAuthorization)))
+
+	value, err := FromAuthHeader("Bearer").Extract(ctx)
+	require.Empty(t, value)
+	require.ErrorIs(t, err, ErrNotFound)
+}
+
+// Test_FromParam_RefusesUndecodableValue covers a parameter the router left
+// raw and that percent-decoding cannot make sense of.
+func Test_FromParam_RefusesUndecodableValue(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	extractor := FromParam("id")
+	ran := false
+	app.Get("/users/:id", func(c fiber.Ctx) error {
+		ran = true
+		value, err := extractor.Extract(c)
+		require.Empty(t, value)
+		require.ErrorIs(t, err, ErrNotFound)
+		return c.SendStatus(fiber.StatusNoContent)
+	})
+
+	// Driven through the handler rather than app.Test, whose URL parsing
+	// refuses the escape before the router ever sees it.
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	fctx.Request.SetRequestURI("/users/%zz")
+	app.Handler()(fctx)
+
+	require.Equal(t, fiber.StatusNoContent, fctx.Response.StatusCode())
+	require.True(t, ran, "the route must have matched")
+}
+
+// Test_ChainState_PoolHoldsSomethingElse covers the guard on what the pool
+// hands back. sync.Pool is typed as any, so a state is rebuilt rather than
+// trusted; this drives that branch by putting sentinels in front of it.
+//
+// Not parallel: it borrows the shared pool, and it takes back out everything
+// it puts in.
+func Test_ChainState_PoolHoldsSomethingElse(t *testing.T) {
+	app := fiber.New()
+
+	const sentinels = 8
+	for range sentinels {
+		// Pointer-like, so parking it in the pool does not allocate.
+		chainStatePool.Put(new(struct{}))
+	}
+
+	for range sentinels {
+		ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+		st := chainStateFor(ctx)
+		require.NotNil(t, st, "a usable state whatever the pool held")
+		require.Empty(t, st.active)
+		require.Zero(t, st.depth)
+		require.False(t, st.hasWin)
+		app.ReleaseCtx(ctx)
+	}
+}
+
+// Test_ExtractWithSource_NestedCapturePreservesWinner covers a decorated chain
+// that calls its base and then makes another source-aware call before
+// returning the base's value. The nested frame must not consume the winner the
+// base recorded, or the value is reported against the decorator's declared
+// source instead of the child that supplied it.
+func Test_ExtractWithSource_NestedCapturePreservesWinner(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(ctx) })
+	ctx.Request().SetRequestURI("/?token=from-query")
+	ctx.Request().Header.SetCookie("other", "cookie-value")
+
+	chain := Chain(FromHeader("X-Missing"), FromQuery("token"))
+	base := chain.Extract
+	chain.Extract = func(c fiber.Ctx) (string, error) {
+		v, err := base(c)
+		if err != nil {
+			return "", err
+		}
+		// An unrelated source-aware lookup, after the winner was recorded.
+		if _, _, err := ExtractWithSource(FromCookie("other"), c); err != nil {
+			return "", err
+		}
+		return v, nil
+	}
+
+	v, src, err := ExtractWithSource(chain, ctx)
+	require.NoError(t, err)
+	require.Equal(t, "from-query", v)
+	require.Equal(t, SourceQuery, src, "the query child supplied the value")
+}
+
+// Test_ChainState_CloseClearsGuards covers the guards a finished request leaves
+// in the buffer past its length: a retained one keeps a chain's Extractor array
+// alive for as long as the pool holds the state.
+func Test_ChainState_CloseClearsGuards(t *testing.T) {
+	t.Parallel()
+
+	st := &chainState{active: make([]*byte, 0, 4)}
+	first := Chain(FromHeader("X-One")).Chain
+	second := Chain(FromHeader("X-Two")).Chain
+	require.True(t, st.enter(chainGuard(first)))
+	require.True(t, st.enter(chainGuard(second)))
+	st.leave()
+	st.leave()
+	require.Empty(t, st.active, "both are released")
+
+	buffer := st.active[:cap(st.active)]
+	require.NotNil(t, buffer[0], "released guards are still in the buffer")
+
+	// reset rather than Close: Close hands the state to the pool, where another
+	// request may take it and write the very buffer this reads.
+	st.reset()
+	for i, guard := range buffer {
+		require.Nil(t, guard, "guard %d must not outlive the request", i)
+	}
+}
diff --git a/internal/appconfig/appconfig_test.go b/internal/appconfig/appconfig_test.go
new file mode 100644
index 00000000000..eb73ead0fad
--- /dev/null
+++ b/internal/appconfig/appconfig_test.go
@@ -0,0 +1,42 @@
+package appconfig
+
+import (
+	"testing"
+
+	"github.com/stretchr/testify/require"
+)
+
+// uninstalled is what Of answers before anything installs a reader. Captured
+// here rather than inside the test because package initialization runs once
+// however many times the tests are run, and the first installation below is
+// permanent. Package fiber is not linked into this binary, so this is the only
+// place that answer is observable at all.
+var uninstalled = Of("no reader installed yet")
+
+// Test_Reader covers the reader's contract in the order it depends on: what Of
+// answers before an installation, the one that wins, and every call after it.
+//
+// One function, because SetReader is once-only and the assertions mean nothing
+// out of order.
+func Test_Reader(t *testing.T) {
+	t.Parallel()
+
+	require.Equal(t, Hot{}, uninstalled)
+
+	// A nil reader must not spend the single installation, which the real one
+	// taking effect below is what proves.
+	SetReader(nil)
+
+	installed := Hot{Immutable: true, UnescapePath: true}
+	SetReader(func(app any) Hot {
+		if app == nil {
+			return Hot{}
+		}
+		return installed
+	})
+	require.Equal(t, installed, Of("an app"))
+	require.Equal(t, Hot{}, Of(nil), "the installed reader decides what it answers for")
+
+	SetReader(func(any) Hot { return Hot{DisableHeaderNormalizing: true} })
+	require.Equal(t, installed, Of("an app"), "the first reader keeps answering")
+}
diff --git a/internal/headerlookup/headerlookup_test.go b/internal/headerlookup/headerlookup_test.go
new file mode 100644
index 00000000000..36d552558fb
--- /dev/null
+++ b/internal/headerlookup/headerlookup_test.go
@@ -0,0 +1,207 @@
+package headerlookup
+
+import (
+	"bufio"
+	"strings"
+	"testing"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// newCtx returns a context on an app configured with cfg, released when the
+// test ends.
+func newCtx(t *testing.T, cfg ...fiber.Config) fiber.Ctx {
+	t.Helper()
+
+	app := fiber.New(cfg...)
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+	if len(cfg) > 0 && cfg[0].DisableHeaderNormalizing {
+		c.Request().Header.DisableNormalizing()
+	}
+	return c
+}
+
+// readRequest parses raw into c's request, the only way to build a message
+// carrying a field the way a peer would rather than the way Set does.
+func readRequest(t *testing.T, c fiber.Ctx, raw string) {
+	t.Helper()
+
+	require.NoError(t, c.Request().Header.Read(bufio.NewReader(strings.NewReader(raw))))
+}
+
+func Test_Canonical(t *testing.T) {
+	t.Parallel()
+
+	require.True(t, Canonical(newCtx(t)))
+	require.False(t, Canonical(newCtx(t, fiber.Config{DisableHeaderNormalizing: true})))
+}
+
+func Test_Value(t *testing.T) {
+	t.Parallel()
+
+	t.Run("single line", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t)
+		c.Request().Header.Set(fiber.HeaderAuthorization, "Bearer abc")
+		v, ok := Value(c, fiber.HeaderAuthorization)
+		require.True(t, ok)
+		require.Equal(t, "Bearer abc", v)
+	})
+
+	t.Run("absent is present-and-empty, not a refusal", func(t *testing.T) {
+		t.Parallel()
+
+		v, ok := Value(newCtx(t), fiber.HeaderAuthorization)
+		require.True(t, ok, "absent must not read as malformed")
+		require.Empty(t, v)
+	})
+
+	t.Run("a line that is present and empty", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t)
+		c.Request().Header.Set("X-Token", "")
+		v, ok := Value(c, "X-Token")
+		require.True(t, ok)
+		require.Empty(t, v)
+	})
+
+	t.Run("repeated lines are refused", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t)
+		readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n")
+		v, ok := Value(c, fiber.HeaderAuthorization)
+		require.False(t, ok, "an ambiguous credential has no answer")
+		require.Empty(t, v, "the value is empty whenever ok is false, so a caller fails closed")
+	})
+
+	t.Run("matches the name case-insensitively", func(t *testing.T) {
+		t.Parallel()
+
+		// The spelling HTTP/2 and 3 put on the wire, kept as sent.
+		c := newCtx(t, fiber.Config{DisableHeaderNormalizing: true})
+		readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nauthorization: Bearer abc\r\n\r\n")
+		v, ok := Value(c, fiber.HeaderAuthorization)
+		require.True(t, ok)
+		require.Equal(t, "Bearer abc", v)
+	})
+
+	t.Run("repeated lines are refused whatever they are spelled like", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t, fiber.Config{DisableHeaderNormalizing: true})
+		readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nAuthorization: Bearer a\r\nauthorization: Bearer b\r\n\r\n")
+		_, ok := Value(c, fiber.HeaderAuthorization)
+		require.False(t, ok)
+	})
+
+	t.Run("Immutable hands back a copy", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t, fiber.Config{Immutable: true})
+		c.Request().Header.Set("X-Token", "abc")
+		v, ok := Value(c, "X-Token")
+		require.True(t, ok)
+		require.Equal(t, "abc", v)
+
+		// Same length, so fasthttp may write over the bytes just read.
+		c.Request().Header.Set("X-Token", "xyz")
+		require.Equal(t, "abc", v, "Immutable promises a value that outlives the request's buffer")
+	})
+}
+
+func Test_Combined(t *testing.T) {
+	t.Parallel()
+
+	t.Run("single line is unchanged", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t)
+		c.Request().Header.Set("X-API-Key", "abc123")
+		require.Equal(t, "abc123", Combined(c, "X-API-Key"))
+	})
+
+	t.Run("absent and empty both read as nothing", func(t *testing.T) {
+		t.Parallel()
+
+		for _, normalize := range []bool{true, false} {
+			c := newCtx(t, fiber.Config{DisableHeaderNormalizing: !normalize})
+			require.Empty(t, Combined(c, "X-API-Key"), "normalize=%v", normalize)
+			c.Request().Header.Set("X-API-Key", "")
+			require.Empty(t, Combined(c, "X-API-Key"), "normalize=%v", normalize)
+		}
+	})
+
+	t.Run("repeated lines are one value", func(t *testing.T) {
+		t.Parallel()
+
+		for _, normalize := range []bool{true, false} {
+			c := newCtx(t, fiber.Config{DisableHeaderNormalizing: !normalize})
+			readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nAccept: text/html\r\naccept: application/json\r\n\r\n")
+			require.Equal(t, "text/html, application/json", Combined(c, "Accept"), "normalize=%v", normalize)
+		}
+	})
+
+	t.Run("an empty line among repeated ones keeps its place", func(t *testing.T) {
+		t.Parallel()
+
+		// Both halves join every line they were sent, so a present-and-empty
+		// line is a value of nothing, not an absent line.
+		for _, normalize := range []bool{true, false} {
+			c := newCtx(t, fiber.Config{DisableHeaderNormalizing: !normalize})
+			readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nAccept:\r\naccept: application/json\r\n\r\n")
+			require.Equal(t, ", application/json", Combined(c, "Accept"), "normalize=%v", normalize)
+		}
+	})
+
+	t.Run("Cookie keeps its own separator", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t)
+		readRequest(t, c, "GET / HTTP/1.1\r\nHost: e.com\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n")
+		require.Equal(t, "a=1; b=2", Combined(c, fiber.HeaderCookie))
+	})
+
+	t.Run("Immutable hands back a copy", func(t *testing.T) {
+		t.Parallel()
+
+		c := newCtx(t, fiber.Config{Immutable: true})
+		c.Request().Header.Set("X-Token", "abc")
+		v := Combined(c, "X-Token")
+		c.Request().Header.Set("X-Token", "xyz")
+		require.Equal(t, "abc", v)
+	})
+}
+
+// Test_Combined_DoesNotAllocate pins the fold path, which allocated three
+// times per header read before it walked the store itself.
+//
+// Not parallel, and top level: AllocsPerRun counts allocations process-wide
+// and refuses to run under a parallel parent.
+func Test_Combined_DoesNotAllocate(t *testing.T) {
+	for _, mode := range []struct {
+		name string
+		cfg  fiber.Config
+		raw  string
+	}{
+		{name: "normalized", cfg: fiber.Config{}, raw: "GET / HTTP/1.1\r\nHost: e.com\r\nX-API-Key: abc123\r\n\r\n"},
+		{name: "as sent", cfg: fiber.Config{DisableHeaderNormalizing: true}, raw: "GET / HTTP/1.1\r\nHost: e.com\r\nx-api-key: abc123\r\n\r\n"},
+	} {
+		c := newCtx(t, mode.cfg)
+		readRequest(t, c, mode.raw)
+
+		read := func() {
+			if v := Combined(c, "X-API-Key"); v != "abc123" {
+				t.Errorf("%s: got %q", mode.name, v)
+			}
+		}
+		read() // warm anything the header store collects once
+
+		require.Zero(t, testing.AllocsPerRun(100, read), "%s", mode.name)
+	}
+}
diff --git a/middleware/keyauth/keyauth_test.go b/middleware/keyauth/keyauth_test.go
index 020c1cd8a91..e98112a34e3 100644
--- a/middleware/keyauth/keyauth_test.go
+++ b/middleware/keyauth/keyauth_test.go
@@ -3,6 +3,7 @@ package keyauth
 import (
 	"bytes"
 	"context"
+	"crypto/subtle"
 	"errors"
 	"io"
 	"net/http"
@@ -13,6 +14,7 @@ import (
 
 	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
 
 	"github.com/gofiber/fiber/v3"
 	"github.com/gofiber/fiber/v3/extractors"
@@ -1269,3 +1271,73 @@ func Test_New_ErrorURIAbsolute(t *testing.T) {
 		})
 	})
 }
+
+// benchKey is a JWT-sized token68 credential, the shape a Bearer token has in
+// practice.
+const benchKey = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9P"
+
+// benchValidator compares in constant time, as a real deployment must, but
+// without hashing, so the numbers are the middleware and not a digest.
+func benchValidator(_ fiber.Ctx, key string) (bool, error) {
+	return subtle.ConstantTimeCompare([]byte(key), []byte(benchKey)) == 1, nil
+}
+
+// benchApp registers the middleware with cfg on a route that answers 418. cfg
+// is a pointer because Config is 200 bytes and gocritic refuses the copy.
+func benchApp(cfg *Config) fasthttp.RequestHandler {
+	app := fiber.New()
+	app.Use(New(*cfg))
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusTeapot)
+	})
+	return app.Handler()
+}
+
+// go test -v -run=^$ -bench=Benchmark_KeyAuth_Bearer -benchmem -count=4
+func Benchmark_KeyAuth_Bearer(b *testing.B) {
+	h := benchApp(&Config{Validator: benchValidator})
+
+	ctx := &fasthttp.RequestCtx{}
+	ctx.Request.Header.SetMethod(fiber.MethodGet)
+	ctx.Request.SetRequestURI("/")
+	ctx.Request.Header.Set(fiber.HeaderAuthorization, "Bearer "+benchKey)
+
+	b.ReportAllocs()
+
+	for b.Loop() {
+		// What fasthttp does between requests. Without it the extractor's
+		// request-local state is installed once and reused, and the per-request
+		// cost of installing and recycling it is not in the number.
+		ctx.ResetUserValues()
+		h(ctx)
+	}
+
+	require.Equal(b, fiber.StatusTeapot, ctx.Response.Header.StatusCode())
+}
+
+// The credential is in the last source, so the walk pays for both misses.
+//
+// go test -v -run=^$ -bench=Benchmark_KeyAuth_Chain -benchmem -count=4
+func Benchmark_KeyAuth_Chain(b *testing.B) {
+	h := benchApp(&Config{
+		Validator: benchValidator,
+		Extractor: extractors.Chain(
+			extractors.FromAuthHeader("Bearer"),
+			extractors.FromHeader("X-API-Key"),
+			extractors.FromQuery("api_key"),
+		),
+	})
+
+	ctx := &fasthttp.RequestCtx{}
+	ctx.Request.Header.SetMethod(fiber.MethodGet)
+	ctx.Request.SetRequestURI("/?api_key=" + benchKey)
+
+	b.ReportAllocs()
+
+	for b.Loop() {
+		ctx.ResetUserValues()
+		h(ctx)
+	}
+
+	require.Equal(b, fiber.StatusTeapot, ctx.Response.Header.StatusCode())
+}
diff --git a/middleware/limiter/limiter_test.go b/middleware/limiter/limiter_test.go
index 6662ac4653b..f599527f071 100644
--- a/middleware/limiter/limiter_test.go
+++ b/middleware/limiter/limiter_test.go
@@ -1973,9 +1973,15 @@ func assertSubSecondWindowIsFloored(t *testing.T, strategy Handler) {
 	clock := newTestClock(time.Now().Truncate(time.Second))
 	app := fiber.New()
 	app.Use(New(Config{
-		Max:               5,
-		ExpirationFunc:    func(fiber.Ctx) time.Duration { return 500 * time.Millisecond },
-		clock:             clock.Now,
+		Max:            5,
+		ExpirationFunc: func(fiber.Ctx) time.Duration { return 500 * time.Millisecond },
+		clock:          clock.Now,
+		// clock freezes the limiter's own window, but the default store expires
+		// entries on real time, so a slow runner could drop the counter between
+		// requests and let the 6th open a fresh window. This storage keeps what
+		// it is given (it only fails when errs says so), leaving the flooring
+		// itself as the only thing under test.
+		Storage:           newFailingLimiterStorage(),
 		LimiterMiddleware: strategy,
 	}))
 	app.Get("/", func(c fiber.Ctx) error { return c.SendString("Hello tester!") })
diff --git a/middleware/session/session_test.go b/middleware/session/session_test.go
index 0b123554342..ba94eadf799 100644
--- a/middleware/session/session_test.go
+++ b/middleware/session/session_test.go
@@ -1516,6 +1516,38 @@ func Benchmark_Session(b *testing.B) {
 	})
 }
 
+// Benchmark_Session_ChainExtractor measures the lookup a chain-configured store
+// does per request. The user values are reset every iteration because a reused
+// context answers from the cached session-ID local and never reaches the
+// extractor.
+//
+// go test -v -run=^$ -bench=Benchmark_Session_ChainExtractor -benchmem -count=4
+func Benchmark_Session_ChainExtractor(b *testing.B) {
+	app := fiber.New()
+	store := NewStore(Config{
+		Extractor: extractors.Chain(
+			extractors.FromHeader("X-Session"),
+			extractors.FromCookie("session_id"),
+		),
+	})
+
+	fctx := &fasthttp.RequestCtx{}
+	c := app.AcquireCtx(fctx)
+	defer app.ReleaseCtx(c)
+	c.Request().Header.SetCookie("session_id", "12356789")
+
+	b.ReportAllocs()
+	for b.Loop() {
+		fctx.ResetUserValues()
+
+		sess, _ := store.Get(c) //nolint:errcheck // We're inside a benchmark
+		sess.Set("john", "doe")
+		_ = sess.Save() //nolint:errcheck // We're inside a benchmark
+
+		sess.Release()
+	}
+}
+
 // go test -v -run=^$ -bench=Benchmark_Session_Parallel -benchmem -count=4
 func Benchmark_Session_Parallel(b *testing.B) {
 	b.Run("default", func(b *testing.B) {
diff --git a/middleware/session/store_test.go b/middleware/session/store_test.go
index 24428d56510..4433af58f16 100644
--- a/middleware/session/store_test.go
+++ b/middleware/session/store_test.go
@@ -225,3 +225,36 @@ func Test_Store_GetByID(t *testing.T) {
 		})
 	})
 }
+
+// Test_Store_getSessionID_SkipsChildrenWithoutExtract covers a chain carrying a
+// zero-value child, which Chain skips but the store used to call straight
+// through, panicking on the nil function.
+func Test_Store_getSessionID_SkipsChildrenWithoutExtract(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	store := NewStore(Config{
+		Extractor: extractors.Chain(extractors.Extractor{}, extractors.FromCookie("session_id")),
+	})
+
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(ctx)
+	ctx.Request().Header.SetCookie("session_id", "abc123")
+
+	require.Equal(t, "abc123", store.getSessionID(ctx))
+}
+
+// Test_Store_getSessionID_WithoutExtractor covers a Store built directly rather
+// than through NewStore, which would have replaced the zero-value extractor
+// with the default. There is nothing to run, so there is no session ID.
+func Test_Store_getSessionID_WithoutExtractor(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(ctx)
+	ctx.Request().Header.SetCookie("session_id", "abc123")
+
+	store := &Store{}
+	require.Empty(t, store.getSessionID(ctx))
+}

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path appconfig_test.go --path extractors/bench_test.go --path extractors/extractors_fuzz_test.go --path extractors/extractors_test.go --path internal/appconfig/appconfig_test.go --path internal/headerlookup/headerlookup_test.go --path middleware/keyauth/keyauth_test.go --path middleware/limiter/limiter_test.go --path middleware/session/session_test.go --path middleware/session/store_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./extractors ./internal/appconfig ./internal/headerlookup ./middleware/keyauth ./middleware/limiter ./middleware/session')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./extractors ./internal/appconfig ./internal/headerlookup ./middleware/keyauth ./middleware/limiter ./middleware/session' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
