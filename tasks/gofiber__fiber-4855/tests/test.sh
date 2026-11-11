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
for f in middleware/cache/cache_security_test.go middleware/cache/cache_test.go middleware/cache/keygen_test.go middleware/proxy/response_test.go middleware/session/equal_test.go; do if git cat-file -e 95d7398102ac5a6efa2113bfa15f6f11976bd81a:"$f" 2>/dev/null; then git checkout 95d7398102ac5a6efa2113bfa15f6f11976bd81a -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 95d7398102ac5a6efa2113bfa15f6f11976bd81a "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/middleware/cache/cache_security_test.go b/middleware/cache/cache_security_test.go
index f7f74936927..dec1868d9e8 100644
--- a/middleware/cache/cache_security_test.go
+++ b/middleware/cache/cache_security_test.go
@@ -1625,6 +1625,50 @@ func Test_Cache_ProxiedResponseCasingIsRead(t *testing.T) {
 	}
 }
 
+// Test_Cache_EntryStoredUnderTheEarlierVaryRuleIsNotRead covers the entries the key version before the stricter Vary
+// rule wrote. A response that varied on a header an inner middleware overwrote was stored under the value the client
+// sent, and a hit never looks at what the handler saw, so on a store that survived the upgrade every client sending
+// that value would still be served the page. The key namespace moves with the rule, so such an entry is never read.
+func Test_Cache_EntryStoredUnderTheEarlierVaryRuleIsNotRead(t *testing.T) {
+	t.Parallel()
+	const earlier = "v6" // the key version that stored them
+	storage := memory.New()
+	config := Config{Storage: storage, Expiration: time.Minute}
+
+	// What the earlier version left in the store: a page stored under the placeholder "0", moved to that version's keys.
+	seed := fiber.New()
+	seed.Use(New(config))
+	seed.Get("/", func(c fiber.Ctx) error {
+		c.Set(fiber.HeaderVary, "X-User-Id")
+		return c.SendString("alice's page")
+	})
+	cacheTestCRequireReply(t, cacheTestCGet(t, seed, "/", "X-User-Id", "0"), cacheMiss, "alice's page")
+	cacheTestCRequireReply(t, cacheTestCGet(t, seed, "/", "X-User-Id", "0"), cacheHit, "alice's page")
+	keys, err := storage.Keys()
+	require.NoError(t, err)
+	require.NotEmpty(t, keys)
+	for _, key := range keys {
+		raw, err := storage.Get(string(key))
+		require.NoError(t, err)
+		moved := strings.ReplaceAll(string(key), cacheKeyVersion+"|", earlier+"|")
+		require.NoError(t, storage.Set(moved, raw, time.Minute))
+		if moved != string(key) {
+			require.NoError(t, storage.Delete(string(key)))
+		}
+	}
+
+	// The upgraded app: the header is overwritten with the session's, which is what made the page the client's.
+	app := fiber.New()
+	app.Use(New(config))
+	app.Use(func(c fiber.Ctx) error { c.Request().Header.Set("X-User-Id", c.Cookies("session")); return c.Next() })
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Set(fiber.HeaderVary, "X-User-Id")
+		return c.SendString("bob's page")
+	})
+	got := cacheTestCGet(t, app, "/", "X-User-Id", "0", fiber.HeaderCookie, "session=bob")
+	cacheTestCRequireReply(t, got, cacheUnreachable, "bob's page", "an entry of the earlier version must not be served")
+}
+
 // Test_Cache_LegacyAnonymousEntryIsNotRead covers an entry a previous version
 // stored. It detected Authorization byte-exactly, so under DisableHeaderNormalizing
 // a request bearing a lower-case "authorization" was taken for anonymous and its
@@ -2108,17 +2152,20 @@ func Test_Cache_Security_RefusedRequestIsNotStored(t *testing.T) {
 	}
 }
 
-// Test_Cache_VaryOnHeaderAddedBehindTheCache checks that a response varying on a request header an inner
-// middleware added is not stored: its key, built from the header as the lookup saw it, would serve the first
-// client's page to every other client. A header rewritten in place or removed keeps the lookup's key and stays
-// cacheable, as the response is then the one for what the client sent.
-func Test_Cache_VaryOnHeaderAddedBehindTheCache(t *testing.T) {
+// Test_Cache_VaryOnHeaderChangedBehindTheCache checks that a response varying on a request header an inner
+// middleware added, overwrote, rewrote or removed is not stored: its key, built from the header as the lookup saw it,
+// would serve the first client's page to every other client sending the same value, a placeholder included. A
+// response is stored when the headers it varies on reach the handler as they came, whatever else the middleware does.
+func Test_Cache_VaryOnHeaderChangedBehindTheCache(t *testing.T) {
 	t.Parallel()
 	type step struct {
 		body, cache string
 		headers     []string // name and value pairs the request sends
 	}
+	alice := []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}
+	bob := []string{fiber.HeaderCookie, "session=bob", "X-User-Id", "0"}
 	fromSession := func(c fiber.Ctx) { c.Request().Header.Set("X-User-Id", c.Cookies("session")) }
+	upperTenant := func(c fiber.Ctx) { c.Request().Header.Set("X-Tenant", strings.ToUpper(c.Get("X-Tenant"))) }
 	for name, tc := range map[string]struct {
 		rewrite func(c fiber.Ctx)
 		vary    string // the response's Vary
@@ -2133,9 +2180,7 @@ func Test_Cache_VaryOnHeaderAddedBehindTheCache(t *testing.T) {
 				{headers: []string{fiber.HeaderCookie, "session=bob"}, body: "X-User-Id=bob", cache: cacheUnreachable},
 			},
 		},
-		// The client's value stays in the key, as a rewrite's does: the response has to vary on
-		// the input it was derived from as well (the next case), as cache.md says.
-		// The cookies make one field line, so an added cookie is told by its name.
+		// The cookies make one field line, so an added cookie is told by what the line holds.
 		"cookie added": {
 			rewrite: func(c fiber.Ctx) { c.Request().Header.SetCookie("session", c.Get("X-Login")) },
 			vary:    fiber.HeaderCookie,
@@ -2153,40 +2198,88 @@ func Test_Cache_VaryOnHeaderAddedBehindTheCache(t *testing.T) {
 				{headers: []string{fiber.HeaderCookie, "user=0", "X-Login", "bob"}, body: "Cookie=user=0; user=bob", cache: cacheUnreachable},
 			},
 		},
+		// The client's value stays in the key, which any client sending the placeholder would reach.
 		"overwritten": {
 			rewrite: fromSession,
 			vary:    "X-User-Id",
 			steps: []step{
-				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheMiss},
-				{headers: []string{fiber.HeaderCookie, "session=bob", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheHit},
+				{headers: alice, body: "X-User-Id=alice", cache: cacheUnreachable},
+				{headers: bob, body: "X-User-Id=bob", cache: cacheUnreachable},
 			},
 		},
+		// Naming the input too does not make the derived value part of what a later lookup can select by.
 		"overwritten, varying on its input too": {
 			rewrite: fromSession,
 			vary:    "Cookie, X-User-Id",
 			echo:    "X-User-Id",
 			steps: []step{
-				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheMiss},
-				{headers: []string{fiber.HeaderCookie, "session=bob", "X-User-Id", "0"}, body: "X-User-Id=bob", cache: cacheMiss},
-				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheHit},
+				{headers: alice, body: "X-User-Id=alice", cache: cacheUnreachable},
+				{headers: bob, body: "X-User-Id=bob", cache: cacheUnreachable},
+				{headers: alice, body: "X-User-Id=alice", cache: cacheUnreachable},
+			},
+		},
+		// The input the value is derived from reaches the handler as it came, and is what the page varies on.
+		"overwritten, varying on its input only": {
+			rewrite: fromSession,
+			vary:    fiber.HeaderCookie,
+			echo:    "X-User-Id",
+			steps: []step{
+				{headers: alice, body: "X-User-Id=alice", cache: cacheMiss},
+				{headers: bob, body: "X-User-Id=bob", cache: cacheMiss},
+				{headers: alice, body: "X-User-Id=alice", cache: cacheHit},
 			},
 		},
 		"removed": {
 			rewrite: func(c fiber.Ctx) { c.Request().Header.Del("X-Debug") },
 			vary:    "X-Debug",
 			steps: []step{
-				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheMiss},
-				{headers: []string{"X-Debug", "2"}, body: "X-Debug=", cache: cacheMiss},
-				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheHit},
+				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheUnreachable},
+				{headers: []string{"X-Debug", "2"}, body: "X-Debug=", cache: cacheUnreachable},
+				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheUnreachable},
 			},
 		},
 		"rewritten in place": {
-			rewrite: func(c fiber.Ctx) { c.Request().Header.Set("X-Tenant", strings.ToUpper(c.Get("X-Tenant"))) },
+			rewrite: upperTenant,
+			vary:    "X-Tenant",
+			steps: []step{
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheUnreachable},
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheUnreachable},
+				{headers: []string{"X-Tenant", "other"}, body: "X-Tenant=OTHER", cache: cacheUnreachable},
+			},
+		},
+		"cookie rewritten in place": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.SetCookie("user", strings.ToUpper(c.Cookies("user"))) },
+			vary:    fiber.HeaderCookie,
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "user=bob; theme=dark"}, body: "Cookie=user=BOB; theme=dark", cache: cacheUnreachable},
+				{headers: []string{fiber.HeaderCookie, "user=bob; theme=dark"}, body: "Cookie=user=BOB; theme=dark", cache: cacheUnreachable},
+			},
+		},
+		"cookie removed": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.DelCookie("user") },
+			vary:    fiber.HeaderCookie,
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "user=bob; theme=dark"}, body: "Cookie=theme=dark", cache: cacheUnreachable},
+				{headers: []string{fiber.HeaderCookie, "user=bob; theme=dark"}, body: "Cookie=theme=dark", cache: cacheUnreachable},
+			},
+		},
+		// What the middleware does to a header the response does not vary on is no concern of the key.
+		"rewritten outside the Vary list": {
+			rewrite: upperTenant,
+			vary:    fiber.HeaderAcceptLanguage,
+			steps: []step{
+				{headers: []string{"X-Tenant", "acme", fiber.HeaderAcceptLanguage, "en"}, body: "Accept-Language=en", cache: cacheMiss},
+				{headers: []string{"X-Tenant", "acme", fiber.HeaderAcceptLanguage, "en"}, body: "Accept-Language=en", cache: cacheHit},
+				{headers: []string{"X-Tenant", "acme", fiber.HeaderAcceptLanguage, "de"}, body: "Accept-Language=de", cache: cacheMiss},
+			},
+		},
+		"written back unchanged": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.Set("X-Tenant", c.Get("X-Tenant")) },
 			vary:    "X-Tenant",
 			steps: []step{
-				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheMiss},
-				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheHit},
-				{headers: []string{"X-Tenant", "other"}, body: "X-Tenant=OTHER", cache: cacheMiss},
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=acme", cache: cacheMiss},
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=acme", cache: cacheHit},
+				{headers: []string{"X-Tenant", "other"}, body: "X-Tenant=other", cache: cacheMiss},
 			},
 		},
 	} {
diff --git a/middleware/cache/cache_test.go b/middleware/cache/cache_test.go
index df8a80d31b0..3d9706bac96 100644
--- a/middleware/cache/cache_test.go
+++ b/middleware/cache/cache_test.go
@@ -4660,38 +4660,60 @@ func Test_Cache_VaryReplayedWithCompress(t *testing.T) {
 	}
 }
 
-// Test_Cache_VaryKeyedByTheHeadersTheLookupSaw stores a response that varies on a header an inner
-// middleware rewrites under the value the lookup hashed. encryptcookie decrypts the cookie in place, and
-// keyed by the decrypted value the page went to anyone sending that value as a plain cookie.
-func Test_Cache_VaryKeyedByTheHeadersTheLookupSaw(t *testing.T) {
+// Test_Cache_VaryOnCookieEncryptcookieDecrypts stores a response that varies on a cookie encryptcookie
+// decrypts. Registered outside it, the cache keys the page by the sealed cookie the client sent while the
+// handler builds it from the decrypted one, which the cache cannot tell from a placeholder replaced with another
+// client's value, so nothing is stored. Registered behind it, the cache sees the cookie the handler does: the
+// page is keyed by the decrypted value, which a plain cookie cannot spell, as encryptcookie drops one it cannot
+// decrypt before the lookup.
+func Test_Cache_VaryOnCookieEncryptcookieDecrypts(t *testing.T) {
 	t.Parallel()
 	secret := encryptcookie.GenerateKey(32)
 	sealed, err := encryptcookie.EncryptCookie("user", "alice", secret)
 	require.NoError(t, err)
 
-	app := fiber.New()
-	app.Use(New(Config{MaxBytes: 1024}))
-	app.Use(encryptcookie.New(encryptcookie.Config{Key: secret}))
-	app.Get("/account", func(c fiber.Ctx) error {
-		c.Set(fiber.HeaderCacheControl, "max-age=30")
-		c.Vary(fiber.HeaderCookie)
-		if c.Cookies("user") == "alice" {
-			return c.SendString("alice's recovery codes")
-		}
-		return c.SendString("please sign in")
-	})
-	app.Get("/other", func(c fiber.Ctx) error { return c.SendString(strings.Repeat("x", 300)) })
+	for _, tc := range []struct {
+		name        string
+		sealed      string // X-Cache for the sealed cookie
+		plain       string // X-Cache for the same value as a plain cookie
+		sealedAgain string // X-Cache for the sealed cookie, sent a second time
+		// cacheOutside registers the cache before encryptcookie, which then decrypts behind it.
+		cacheOutside bool
+	}{
+		{name: "cache outside", cacheOutside: true, sealed: cacheUnreachable, plain: cacheUnreachable, sealedAgain: cacheUnreachable},
+		{name: "cache behind", sealed: cacheMiss, plain: cacheMiss, sealedAgain: cacheHit},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			store, decrypt := New(Config{MaxBytes: 1024}), encryptcookie.New(encryptcookie.Config{Key: secret})
+			if tc.cacheOutside {
+				app.Use(store, decrypt)
+			} else {
+				app.Use(decrypt, store)
+			}
+			app.Get("/account", func(c fiber.Ctx) error {
+				c.Set(fiber.HeaderCacheControl, "max-age=30")
+				c.Vary(fiber.HeaderCookie)
+				if c.Cookies("user") == "alice" {
+					return c.SendString("alice's recovery codes")
+				}
+				return c.SendString("please sign in")
+			})
+			app.Get("/other", func(c fiber.Ctx) error { return c.SendString(strings.Repeat("x", 300)) })
 
-	get := func(path, cookie string) reply { return cacheTestCGet(t, app, path, fiber.HeaderCookie, cookie) }
+			get := func(path, cookie string) reply { return cacheTestCGet(t, app, path, fiber.HeaderCookie, cookie) }
 
-	// The second round starts after the URL's entries, and with them its Vary manifest, were evicted.
-	for _, round := range []string{"first store", "after eviction"} {
-		cacheTestCRequireReply(t, get("/account", "user="+sealed), cacheMiss, "alice's recovery codes", round)
-		cacheTestCRequireReply(t, get("/account", "user=alice"), cacheMiss, "please sign in", round)
-		cacheTestCRequireReply(t, get("/account", "user="+sealed), cacheHit, "alice's recovery codes", round)
-		for i := range 8 {
-			get("/other?q="+strconv.Itoa(i), "")
-		}
+			// The second round starts after the URL's entries, and with them its Vary manifest, were evicted.
+			for _, round := range []string{"first store", "after eviction"} {
+				cacheTestCRequireReply(t, get("/account", "user="+sealed), tc.sealed, "alice's recovery codes", round)
+				cacheTestCRequireReply(t, get("/account", "user=alice"), tc.plain, "please sign in", round)
+				cacheTestCRequireReply(t, get("/account", "user="+sealed), tc.sealedAgain, "alice's recovery codes", round)
+				for i := range 8 {
+					get("/other?q="+strconv.Itoa(i), "")
+				}
+			}
+		})
 	}
 }
 
diff --git a/middleware/cache/keygen_test.go b/middleware/cache/keygen_test.go
index 5084cf5500f..824e7efb758 100644
--- a/middleware/cache/keygen_test.go
+++ b/middleware/cache/keygen_test.go
@@ -195,13 +195,13 @@ func Test_Cache_KeyFormatIsStable(t *testing.T) {
 		want        []string
 		disableVary bool
 	}{
-		{name: "anonymous", want: []string{"v6|manifest|v6|GET|/demo", "v6|GET|/demo"}},
+		{name: "anonymous", want: []string{"v7|manifest|v7|GET|/demo", "v7|GET|/demo"}},
 		{
 			name: "authenticated",
 			auth: "Bearer token",
-			want: []string{"v6|manifest|v6|GET|/demo|auth=" + authHash, "v6|GET|/demo|auth=" + authHash},
+			want: []string{"v7|manifest|v7|GET|/demo|auth=" + authHash, "v7|GET|/demo|auth=" + authHash},
 		},
-		{name: "vary disabled", disableVary: true, want: []string{"v6|GET|/demo"}},
+		{name: "vary disabled", disableVary: true, want: []string{"v7|GET|/demo"}},
 	}
 
 	for _, tc := range tests {
diff --git a/middleware/proxy/response_test.go b/middleware/proxy/response_test.go
new file mode 100644
index 00000000000..1cf44ce56b9
--- /dev/null
+++ b/middleware/proxy/response_test.go
@@ -0,0 +1,329 @@
+package proxy
+
+import (
+	"bufio"
+	"errors"
+	"fmt"
+	"io"
+	"math"
+	"net/http"
+	"net/http/httptest"
+	"net/url"
+	"strconv"
+	"strings"
+	"testing"
+	"testing/iotest"
+	"time"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+
+	"github.com/gofiber/fiber/v3/internal/apptest"
+)
+
+// Test_Proxy_UpstreamBodyLimit checks that a streamed body delivers what its limit allows and fails with
+// fasthttp.ErrBodyTooLarge in place of the byte past it, however the reads cut the body up, and keeps failing.
+func Test_Proxy_UpstreamBodyLimit(t *testing.T) {
+	t.Parallel()
+	const limit = 10
+	for _, tc := range []struct {
+		name  string
+		limit int64
+		size  int
+		over  bool
+	}{
+		{name: "under the limit", limit: limit, size: limit - 1},
+		{name: "at the limit", limit: limit, size: limit},
+		{name: "one past the limit", limit: limit, size: limit + 1, over: true},
+		{name: "far past the limit", limit: limit, size: 10 * limit, over: true},
+		{name: "empty", limit: limit},
+		{name: "no limit", size: 10 * limit},
+		{name: "negative limit", limit: -1, size: 10 * limit},
+		{name: "the largest limit", limit: math.MaxInt64, size: 10 * limit},
+	} {
+		for reads, wrap := range map[string]func(io.Reader) io.Reader{
+			"whole":         func(r io.Reader) io.Reader { return r },
+			"byte by byte":  iotest.OneByteReader,
+			"data with EOF": iotest.DataErrReader,
+		} {
+			t.Run(tc.name+", "+reads, func(t *testing.T) {
+				t.Parallel()
+				body := &upstreamBody{Reader: wrap(strings.NewReader(strings.Repeat("x", tc.size))), limit: tc.limit}
+
+				got, err := io.ReadAll(body)
+				if !tc.over {
+					require.NoError(t, err)
+					require.Len(t, got, tc.size)
+					return
+				}
+				require.ErrorIs(t, err, fasthttp.ErrBodyTooLarge)
+				require.Len(t, got, int(tc.limit), "what the limit allows, and no byte more")
+				n, again := body.Read(make([]byte, 8))
+				require.Zero(t, n)
+				require.ErrorIs(t, again, fasthttp.ErrBodyTooLarge, "the failure is kept")
+			})
+		}
+	}
+}
+
+// Test_Proxy_StreamedBodyLimit pins the size a body that Balancer streams is held to.
+func Test_Proxy_StreamedBodyLimit(t *testing.T) {
+	t.Parallel()
+	custom := &fasthttp.LBClient{}
+	for name, tc := range map[string]struct {
+		config Config
+		want   int
+	}{
+		"servers, size left out":           {config: Config{Servers: []string{"http://upstream.example"}}, want: defaultMaxResponseBodySize},
+		"servers, size set":                {config: Config{Servers: []string{"http://upstream.example"}, MaxResponseBodySize: 4096}, want: 4096},
+		"servers, no bound":                {config: Config{Servers: []string{"http://upstream.example"}, MaxResponseBodySize: -1}},
+		"client of the caller's, left out": {config: Config{Client: custom}},
+		"client of the caller's, set":      {config: Config{Client: custom, MaxResponseBodySize: 4096}, want: 4096},
+		"client of the caller's, no bound": {config: Config{Client: custom, MaxResponseBodySize: -1}},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			cfg := configDefault(tc.config)
+			require.Equal(t, tc.want, streamedBodyLimit(&cfg, tc.config.MaxResponseBodySize))
+		})
+	}
+}
+
+// proxyTestSizedUpstream serves a body of the size the request names in X-Size, declaring its length unless it
+// sends X-Chunked, and returns its address.
+func proxyTestSizedUpstream(t *testing.T) string {
+	t.Helper()
+
+	upstream := fiber.New()
+	upstream.Get("/", func(c fiber.Ctx) error {
+		size, err := strconv.Atoi(c.Get("X-Size"))
+		if err != nil {
+			return fiber.NewError(fiber.StatusBadRequest, "X-Size: "+err.Error())
+		}
+		if c.Get("X-Chunked") == "" {
+			return c.SendStream(strings.NewReader(strings.Repeat("x", size)), size)
+		}
+		return c.SendStreamWriter(func(w *bufio.Writer) {
+			for left := size; left > 0; {
+				n := min(left, 1024)
+				if _, err := w.WriteString(strings.Repeat("x", n)); err != nil || w.Flush() != nil {
+					return
+				}
+				left -= n
+			}
+		})
+	})
+	return listenUpstream(t, upstream)
+}
+
+// proxyTestStreamedHandlers returns every way a response reaches the proxy as a stream, each holding it to bound
+// bytes, none when that is zero: Balancer with a response set to stream, Balancer with a client of the caller's
+// that streams, Do with a client that streams or a response set to stream, and Forward with a client that streams.
+func proxyTestStreamedHandlers(addr string, bound int) map[string]fiber.Handler {
+	policy := proxyTestAllowPrivatePolicy()
+	configured := bound // Config's way to say none
+	if bound == 0 {
+		configured = -1
+	}
+	send := func(cli *fasthttp.Client, req *fasthttp.Request, res *fasthttp.Response, _ *url.URL) error {
+		return cli.Do(req, res)
+	}
+	do := func(streamed bool, cli *fasthttp.Client) fiber.Handler {
+		return func(c fiber.Ctx) error {
+			c.Response().StreamBody = streamed
+			return doActionWithPolicy(c, "http://"+addr, normalizePolicy(policy), nil, send, cli)
+		}
+	}
+	return map[string]fiber.Handler{
+		"Balancer, response streamed": Balancer(Config{
+			Servers: []string{addr}, SecurityPolicy: &policy, MaxResponseBodySize: configured,
+			ModifyRequest: func(c fiber.Ctx) error { c.Response().StreamBody = true; return nil },
+		}),
+		"Balancer, streaming client": Balancer(Config{
+			Client:         &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{&fasthttp.HostClient{Addr: addr, StreamResponseBody: true}}},
+			SecurityPolicy: &policy, MaxResponseBodySize: configured,
+		}),
+		"Do, streaming client":  do(false, &fasthttp.Client{StreamResponseBody: true, MaxResponseBodySize: bound}),
+		"Do, response streamed": do(true, &fasthttp.Client{MaxResponseBodySize: bound}),
+		"Forward, streaming client": func(c fiber.Ctx) error {
+			return forwardWithRealIP(c, "http://"+addr, normalizePolicy(policy), &fasthttp.Client{StreamResponseBody: true, MaxResponseBodySize: bound})
+		},
+	}
+}
+
+// Test_Proxy_StreamedBodyBound checks that a body the proxy streams is held to the bound its client was given,
+// which fasthttp ignores for a body it hands over as a stream: one whose declared length is past it is refused
+// before any of it is sent, as a body read into memory would be, one that goes past it without declaring its
+// length is aborted, and a body within the bound, or any body when there is none, arrives whole.
+func Test_Proxy_StreamedBodyBound(t *testing.T) {
+	t.Parallel()
+	const bound = 4096
+	addr := proxyTestSizedUpstream(t)
+
+	const (
+		delivered = iota
+		refused
+		aborted
+	)
+	for _, tc := range []struct {
+		name    string
+		bound   int
+		size    int
+		want    int
+		chunked bool
+	}{
+		{name: "declared, at the bound", bound: bound, size: bound, want: delivered},
+		{name: "declared, past the bound", bound: bound, size: bound + 1, want: refused},
+		{name: "chunked, at the bound", bound: bound, size: bound, chunked: true, want: delivered},
+		{name: "chunked, past the bound", bound: bound, size: bound + 1, chunked: true, want: aborted},
+		{name: "declared, no bound", size: 4 * bound, want: delivered},
+		{name: "chunked, no bound", size: 4 * bound, chunked: true, want: delivered},
+	} {
+		for name, handler := range proxyTestStreamedHandlers(addr, tc.bound) {
+			t.Run(tc.name+", "+name, func(t *testing.T) {
+				t.Parallel()
+				var handled error
+				app := fiber.New(fiber.Config{ErrorHandler: func(c fiber.Ctx, err error) error {
+					handled = err
+					return c.SendStatus(fiber.StatusBadGateway)
+				}})
+				app.Get("/", handler)
+				chunked := ""
+				if tc.chunked {
+					chunked = "1"
+				}
+				req := apptest.Req(fiber.MethodGet, "/", apptest.WithHeader("X-Size", strconv.Itoa(tc.size)), apptest.WithHeaderIf("X-Chunked", chunked))
+
+				switch tc.want {
+				case delivered:
+					apptest.ExpectBody(t, app, req, fiber.StatusOK, strings.Repeat("x", tc.size))
+					require.NoError(t, handled)
+				case refused:
+					require.NotContains(t, apptest.Body(t, apptest.Expect(t, app, req, fiber.StatusBadGateway)), "x", "none of the body was sent")
+					require.ErrorIs(t, handled, fasthttp.ErrBodyTooLarge)
+				case aborted:
+					_, err := app.Test(req)
+					require.ErrorIs(t, err, fasthttp.ErrBodyTooLarge)
+					require.NoError(t, handled, "the response had started")
+				}
+			})
+		}
+	}
+}
+
+// Test_Proxy_StreamedBodyBound_ModifyResponse checks that a hook that reads the body of a streamed response,
+// as ModifyResponse may, never takes in more than the bound, and that a read that goes past it fails the request
+// unless the hook sets a response of its own after it: the stream left as it is would end the response early,
+// and fasthttp's Body puts the error's text in the body in place of one it could not read, which would go out as
+// the upstream's response.
+func Test_Proxy_StreamedBodyBound_ModifyResponse(t *testing.T) {
+	t.Parallel()
+	const bound = 4096
+	addr := proxyTestSizedUpstream(t)
+	policy := proxyTestAllowPrivatePolicy()
+	failure := fasthttp.ErrBodyTooLarge.Error()
+
+	// read takes the body in through Body, which leaves the error's text in its place when the read fails.
+	read := func(c fiber.Ctx) (int, error) { return len(c.Response().Body()), nil }
+	// answering reads the stream itself, as a hook does that tells the failure from a body, and ends the hook
+	// with answer when the read went past the bound.
+	answering := func(answer func(c fiber.Ctx) error) func(c fiber.Ctx) (int, error) {
+		return func(c fiber.Ctx) (int, error) {
+			got, err := io.ReadAll(c.Response().BodyStream())
+			if !errors.Is(err, fasthttp.ErrBodyTooLarge) {
+				return len(got), err
+			}
+			return len(got), answer(c)
+		}
+	}
+	for _, tc := range []struct {
+		hook   func(c fiber.Ctx) (int, error) // how much of the body it took in, and what it returns
+		name   string
+		body   string
+		size   int
+		status int
+	}{
+		{name: "within the bound", size: bound, hook: read, status: fiber.StatusOK, body: strings.Repeat("x", bound)},
+		{name: "Body read", size: 8 * bound, hook: read, status: fiber.StatusInternalServerError, body: failure},
+		{
+			name: "stream read, failure not answered", size: 8 * bound, status: fiber.StatusInternalServerError, body: failure,
+			hook: answering(func(fiber.Ctx) error { return nil }),
+		},
+		{
+			name: "stream read, error returned", size: 8 * bound, status: fiber.StatusRequestEntityTooLarge, body: "Request Entity Too Large",
+			hook: answering(func(fiber.Ctx) error { return fiber.ErrRequestEntityTooLarge }),
+		},
+		{
+			// Not told from the failure Body leaves, so the request fails; a status of the hook's own takes an error.
+			name: "stream read, the error's text set", size: 8 * bound, status: fiber.StatusInternalServerError, body: failure,
+			hook: answering(func(c fiber.Ctx) error { return c.Status(fiber.StatusRequestEntityTooLarge).SendString(failure) }),
+		},
+		{
+			name: "stream read, status and body set", size: 8 * bound, status: fiber.StatusRequestEntityTooLarge, body: "too large",
+			hook: answering(func(c fiber.Ctx) error { return c.Status(fiber.StatusRequestEntityTooLarge).SendString("too large") }),
+		},
+		{
+			name: "stream read, stream set", size: 8 * bound, status: fiber.StatusOK, body: "replaced",
+			hook: answering(func(c fiber.Ctx) error { c.Response().SetBodyStream(strings.NewReader("replaced"), -1); return nil }),
+		},
+		{
+			name: "Body read, body set", size: 8 * bound, status: fiber.StatusOK, body: "replaced",
+			hook: func(c fiber.Ctx) (int, error) {
+				n := len(c.Response().Body())
+				c.Response().SetBodyString("replaced")
+				return n, nil
+			},
+		},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			taken := make(chan int, 1)
+			app := fiber.New()
+			app.Get("/", Balancer(Config{
+				Servers: []string{addr}, SecurityPolicy: &policy, MaxResponseBodySize: bound,
+				ModifyRequest: func(c fiber.Ctx) error { c.Response().StreamBody = true; return nil },
+				ModifyResponse: func(c fiber.Ctx) error {
+					n, err := tc.hook(c)
+					taken <- n
+					return err
+				},
+			}))
+
+			req := apptest.Req(fiber.MethodGet, "/", apptest.WithHeader("X-Size", strconv.Itoa(tc.size)), apptest.WithHeader("X-Chunked", "1"))
+			apptest.ExpectBody(t, app, req, tc.status, tc.body)
+			require.LessOrEqual(t, apptest.Recv(t, taken, time.Second), bound)
+		})
+	}
+}
+
+// Test_Proxy_Do_StreamedResponseDefaultBound checks that the default client holds a response set to stream to its
+// 100 MiB bound as well: one that declares more is refused as soon as its header is read, without waiting for a
+// body that never comes.
+func Test_Proxy_Do_StreamedResponseDefaultBound(t *testing.T) {
+	t.Parallel()
+	release := make(chan struct{})
+	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
+		w.Header().Set(fiber.HeaderContentLength, strconv.Itoa(2*defaultMaxResponseBodySize))
+		w.WriteHeader(http.StatusOK)
+		fmt.Fprint(w, "start")
+		if http.NewResponseController(w).Flush() == nil {
+			<-release
+		}
+	}))
+	t.Cleanup(upstream.Close)
+	t.Cleanup(func() { close(release) })
+
+	var handled error
+	app := fiber.New(fiber.Config{ErrorHandler: func(c fiber.Ctx, err error) error {
+		handled = err
+		return c.SendStatus(fiber.StatusBadGateway)
+	}})
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Response().StreamBody = true
+		return Do(c, upstream.URL)
+	})
+
+	apptest.Expect(t, app, "/", fiber.StatusBadGateway)
+	require.ErrorIs(t, handled, fasthttp.ErrBodyTooLarge)
+}
diff --git a/middleware/session/equal_test.go b/middleware/session/equal_test.go
new file mode 100644
index 00000000000..608e23c9c89
--- /dev/null
+++ b/middleware/session/equal_test.go
@@ -0,0 +1,307 @@
+package session
+
+import (
+	"fmt"
+	"math"
+	"reflect"
+	"testing"
+	"time"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/gofiber/fiber/v3/internal/storage/memory"
+	"github.com/stretchr/testify/require"
+)
+
+// Test_Session_UnchangedRequestKeepsConcurrentChange_NaN checks that a session holding a NaN is told from an
+// edited one like any other. NaN differs from itself, so the snapshot decoded again from the same bytes read as
+// changed once a value Get returned could be edited in place, and a request that only read the session
+// overwrote the change another request stored, a role taken away for one.
+func Test_Session_UnchangedRequestKeepsConcurrentChange_NaN(t *testing.T) {
+	t.Parallel()
+	nan := math.NaN()
+	// It asserts nothing: a failed assertion through the t of this test would end it from the goroutine of a
+	// subtest. Were the seeded value of another type, the edit would not happen and the subtest's own checks fail.
+	samples := func(s *Session) []float64 {
+		if v, ok := s.Get("samples").([]float64); ok {
+			return v
+		}
+		return make([]float64, 2)
+	}
+	for name, tc := range map[string]struct {
+		touch   func(*Session)
+		want    string // the role the storage ends up with
+		samples string // the samples it ends up with, as fmt prints them: NaN is not equal to itself
+	}{
+		"scalar NaN beside a slice read": {touch: func(s *Session) { _ = s.Get("tags") }, want: "user", samples: "[1 NaN]"},
+		"NaN inside the slice read":      {touch: func(s *Session) { _ = samples(s) }, want: "user", samples: "[1 NaN]"},
+		"NaN inside the map read":        {touch: func(s *Session) { _ = s.Get("scores") }, want: "user", samples: "[1 NaN]"},
+		"a value changed beside the NaN": {touch: func(s *Session) { samples(s)[0] = 2 }, want: "admin", samples: "[2 NaN]"},
+		"the NaN replaced in place":      {touch: func(s *Session) { samples(s)[1] = 3 }, want: "admin", samples: "[1 3]"},
+		"a value replaced by a NaN":      {touch: func(s *Session) { samples(s)[0] = nan }, want: "admin", samples: "[NaN NaN]"},
+		"a map entry changed in place": {touch: func(s *Session) {
+			if scores, ok := s.Get("scores").(map[string]float64); ok {
+				scores["b"] = 3
+			}
+		}, want: "admin", samples: "[1 NaN]"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			store := NewStore(Config{Storage: memory.New()})
+			store.RegisterType([]string{})
+			store.RegisterType([]float64{})
+			store.RegisterType(map[string]float64{})
+			id := seedSession(t, app, store, func(s *Session) {
+				s.Set("role", "admin")
+				s.Set("ratio", nan)
+				s.Set("tags", []string{"x"})
+				s.Set("samples", []float64{1, nan})
+				s.Set("scores", map[string]float64{"a": nan, "b": 2})
+			})
+
+			inFlight := loadSession(t, app, store, id)
+			tc.touch(inFlight)
+			other := loadSession(t, app, store, id)
+			other.Set("role", "user")
+			require.NoError(t, other.Save())
+			require.NoError(t, inFlight.Save())
+
+			stored := sessionTestStored(t, store, id)
+			require.Equal(t, tc.want, stored.Get("role"))
+			require.Equal(t, tc.samples, fmt.Sprint(stored.Get("samples")))
+		})
+	}
+}
+
+// sameTestNode is session data with a field that is not exported, and a way to refer to itself.
+type sameTestNode struct {
+	next  *sameTestNode
+	Name  string
+	Tags  []string
+	Score float64
+	value float64
+}
+
+// sameTestDataOf wraps v the way a session holds it.
+func sameTestDataOf(v any) map[any]any { return map[any]any{"key": v} }
+
+// Test_SameData_AgreesWithDeepEqual checks that without a NaN sameData tells what reflect.DeepEqual does
+// for every pair of values of a corpus of the kinds a session holds: it only adds that a NaN is the same as a NaN.
+func Test_SameData_AgreesWithDeepEqual(t *testing.T) {
+	t.Parallel()
+	zone := time.FixedZone("", 3600)
+	var nilNode *sameTestNode
+	values := []any{
+		nil, 0, 1, int64(1), uint8(1), "", "a", "b", true, false, 1.5, float32(1.5), complex(1, 2), complex(1, 3),
+		[]byte(nil),
+		[]byte{},
+		[]byte("a"), []int(nil),
+		[]int{},
+		[]int{1},
+		[]int{1, 2},
+		[]int{1, 3},
+		[2]int{1, 2},
+		[2]int{1, 3},
+		[2]string{"a", "b"},
+		map[string]int(nil),
+		map[string]int{},
+		map[string]int{"a": 1},
+		map[string]int{"a": 2},
+		map[string]int{"b": 1},
+		map[string]int{"a": 1, "b": 2},
+		map[string]any{"a": []int{1}},
+		map[string]any{"a": []int{2}},
+		map[string]any{"a": 1},
+		[]any{1, "a"},
+		[]any{1, "b"},
+		[]any{nil},
+		[]any{},
+		new(1), new(1), new(2), (*int)(nil),
+		sameTestNode{Name: "a"},
+		sameTestNode{Name: "a"},
+		sameTestNode{Name: "b"},
+		sameTestNode{Name: "a", value: 1},
+		sameTestNode{Tags: []string{"x"}},
+		sameTestNode{Tags: []string{"y"}},
+		sameTestNode{Tags: []string{}},
+		sameTestNode{Tags: nil},
+		&sameTestNode{Name: "a"}, &sameTestNode{Name: "a"}, &sameTestNode{Name: "a", next: &sameTestNode{}}, nilNode,
+		time.Unix(100, 0).UTC(), time.Unix(100, 0).In(zone), time.Unix(101, 0).UTC(),
+		struct{ A int }{1},
+		struct{ B int }{1},
+		(func())(nil), func() {}, // a func is the same as another only when both are nil
+	}
+	for i, a := range values {
+		for j, b := range values {
+			want := reflect.DeepEqual(sameTestDataOf(a), sameTestDataOf(b))
+			require.Equal(t, want, sameValue(reflect.ValueOf(sameTestDataOf(a)), reflect.ValueOf(sameTestDataOf(b)), make(map[visit]struct{})), "%d (%#v) and %d (%#v)", i, a, j, b)
+			require.Equal(t, want, sameData(sameTestDataOf(a), sameTestDataOf(b)), "%d (%#v) and %d (%#v)", i, a, j, b)
+		}
+	}
+}
+
+// Test_SameData_NaN pins where a NaN is the same as a NaN, and that nothing else is made the same by it.
+func Test_SameData_NaN(t *testing.T) {
+	t.Parallel()
+	nan := math.NaN()
+	type nested = map[string][]map[string]float64
+	for name, tc := range map[string]struct {
+		a, b any
+		want bool
+	}{
+		"NaN and NaN":                    {a: nan, b: nan, want: true},
+		"NaN and a number":               {a: nan, b: 1.0},
+		"a number and NaN":               {a: 1.0, b: nan},
+		"infinity and NaN":               {a: math.Inf(1), b: nan},
+		"float32 NaN and NaN":            {a: float32(nan), b: float32(nan), want: true},
+		"float32 NaN and float64 NaN":    {a: float32(nan), b: nan},
+		"complex with a NaN part":        {a: complex(nan, 1), b: complex(nan, 1), want: true},
+		"complex with another real part": {a: complex(nan, 1), b: complex(2, 1)},
+		"complex with another imaginary": {a: complex(1, nan), b: complex(1, 2)},
+		"slice":                          {a: []float64{1, nan}, b: []float64{1, nan}, want: true},
+		"slice with another number":      {a: []float64{2, nan}, b: []float64{1, nan}},
+		"slice with a shorter one":       {a: []float64{1, nan}, b: []float64{1}},
+		"slice with nil":                 {a: []float64{nan}, b: []float64(nil)},
+		"array":                          {a: [2]float64{nan, 1}, b: [2]float64{nan, 1}, want: true},
+		"array with another number":      {a: [2]float64{nan, 1}, b: [2]float64{nan, 2}},
+		"map value":                      {a: map[string]float64{"a": nan}, b: map[string]float64{"a": nan}, want: true},
+		"map value of another key":       {a: map[string]float64{"a": nan}, b: map[string]float64{"b": nan}},
+		"map with another entry":         {a: map[string]float64{"a": nan, "b": 1}, b: map[string]float64{"a": nan, "b": 2}},
+		"map with an entry more":         {a: map[string]float64{"a": nan}, b: map[string]float64{"a": nan, "b": 1}},
+		"map keyed by a NaN":             {a: map[float64]int{nan: 1}, b: map[float64]int{nan: 1}}, // as with DeepEqual: never found
+		"struct":                         {a: sameTestNode{Score: nan}, b: sameTestNode{Score: nan}, want: true},
+		"struct field that is not exported": {
+			a: sameTestNode{value: nan}, b: sameTestNode{value: nan}, want: true,
+		},
+		"struct with another name":  {a: sameTestNode{Name: "a", Score: nan}, b: sameTestNode{Name: "b", Score: nan}},
+		"pointer":                   {a: new(nan), b: new(nan), want: true},
+		"pointer and nil":           {a: new(nan), b: (*float64)(nil)},
+		"interfaces":                {a: []any{nan, "x"}, b: []any{nan, "x"}, want: true},
+		"interfaces and a nil":      {a: []any{nan}, b: []any{nil}},
+		"nested":                    {a: nested{"a": {{"b": nan}}}, b: nested{"a": {{"b": nan}}}, want: true},
+		"nested with another value": {a: nested{"a": {{"b": nan, "c": 1}}}, b: nested{"a": {{"b": nan, "c": 2}}}},
+		"nested with a slice less":  {a: nested{"a": {{"b": nan}}}, b: nested{"a": {}}},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, sameData(sameTestDataOf(tc.a), sameTestDataOf(tc.b)))
+			require.Equal(t, tc.want, sameData(sameTestDataOf(tc.b), sameTestDataOf(tc.a)), "the other way round")
+		})
+	}
+}
+
+// Test_SameData_SelfReference checks that the walk ends where the data was made to refer to itself, as the
+// data of a request can be after an edit in place, by following the snapshot, which cannot.
+func Test_SameData_SelfReference(t *testing.T) {
+	t.Parallel()
+	nan := math.NaN()
+	loop := &sameTestNode{Score: nan}
+	loop.next = loop
+	snapshot := sameTestDataOf(&sameTestNode{Score: nan, next: &sameTestNode{Score: nan}})
+	require.False(t, sameData(snapshot, sameTestDataOf(loop)))
+	require.False(t, sameData(sameTestDataOf(loop), snapshot))
+}
+
+// Test_SameData_Cycles checks that the walk ends on data that refers to itself, however it does so, and still
+// tells a NaN from a difference. A cycle can be in the snapshot too: a type's decoder may rebuild one.
+func Test_SameData_Cycles(t *testing.T) {
+	t.Parallel()
+	nan := math.NaN()
+	// The cycle comes first in a node, before the fields that differ: the walk follows it before it finds one.
+	ring := func(name string, score float64) *sameTestNode {
+		n := &sameTestNode{Name: name, Score: score}
+		n.next = n
+		return n
+	}
+	pair := func(first, second string, score float64) *sameTestNode {
+		a, b := &sameTestNode{Name: first, Score: score}, &sameTestNode{Name: second, Score: score}
+		a.next, b.next = b, a
+		return a
+	}
+	mapRing := func(v float64) map[string]any {
+		m := map[string]any{"v": v}
+		m["self"] = m
+		return m
+	}
+	sliceRing := func(v float64) []any {
+		s := make([]any, 2)
+		s[0], s[1] = s, v
+		return s
+	}
+	for name, tc := range map[string]struct {
+		a, b any
+		want bool
+	}{
+		"node that refers to itself, with a NaN":       {a: ring("a", nan), b: ring("a", nan), want: true},
+		"node that refers to itself, another name":     {a: ring("a", nan), b: ring("b", nan)},
+		"node that refers to itself, another number":   {a: ring("a", 1), b: ring("a", 2)},
+		"two nodes that refer to each other, a NaN":    {a: pair("a", "b", nan), b: pair("a", "b", nan), want: true},
+		"two nodes that refer to each other, another":  {a: pair("a", "b", nan), b: pair("a", "c", nan)},
+		"map that holds itself, with a NaN":            {a: mapRing(nan), b: mapRing(nan), want: true},
+		"map that holds itself, another number":        {a: mapRing(1), b: mapRing(2)},
+		"slice that holds itself, with a NaN":          {a: sliceRing(nan), b: sliceRing(nan), want: true},
+		"slice that holds itself, another number":      {a: sliceRing(1), b: sliceRing(2)},
+		"node that refers to itself and a plain node":  {a: ring("a", nan), b: &sameTestNode{Name: "a", Score: nan}},
+		"node that refers to itself and the other way": {a: &sameTestNode{Name: "a", Score: nan}, b: ring("a", nan)},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, sameData(sameTestDataOf(tc.a), sameTestDataOf(tc.b)))
+			require.Equal(t, tc.want, sameData(sameTestDataOf(tc.b), sameTestDataOf(tc.a)), "the other way round")
+		})
+	}
+}
+
+// sameTestRing is a value whose decoder links it to itself, as a type that rebuilds a cyclic structure from its
+// encoding does. The link comes first, before the label an edit changes.
+type sameTestRing struct {
+	Next  *sameTestRing
+	Label string
+}
+
+func (r *sameTestRing) GobEncode() ([]byte, error) { return []byte(r.Label), nil }
+
+func (r *sameTestRing) GobDecode(data []byte) error {
+	r.Label, r.Next = string(data), r
+	return nil
+}
+
+// Test_Session_InPlaceEditOfSelfReferencingValue checks that a request that edited such a value in place keeps its
+// own change over the one another request stored meanwhile. Telling the edit from a read walks the value in step
+// with the snapshot, whose decoder rebuilt the cycle, so the walk has to end on it.
+func Test_Session_InPlaceEditOfSelfReferencingValue(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	store := NewStore(Config{Storage: memory.New()})
+	store.RegisterType(&sameTestRing{})
+	id := seedSession(t, app, store, func(s *Session) {
+		s.Set("role", "admin")
+		s.Set("ring", &sameTestRing{Label: "before"})
+	})
+
+	inFlight := loadSession(t, app, store, id)
+	ring, ok := inFlight.Get("ring").(*sameTestRing)
+	require.True(t, ok)
+	require.Same(t, ring, ring.Next, "the decoder linked the value to itself")
+	ring.Label = "after"
+	other := loadSession(t, app, store, id)
+	other.Set("role", "user")
+	require.NoError(t, other.Save())
+	require.NoError(t, inFlight.Save())
+
+	stored := sessionTestStored(t, store, id)
+	require.Equal(t, "admin", stored.Get("role"), "an edit in place is the request's own change, as a Set is")
+	got, ok := stored.Get("ring").(*sameTestRing)
+	require.True(t, ok)
+	require.Equal(t, "after", got.Label)
+}
+
+// Test_SameValue_InvalidValues pins the guard for values that hold nothing, which the walk never meets in a
+// session's data: two are the same, and one is not the same as a value that holds something.
+func Test_SameValue_InvalidValues(t *testing.T) {
+	t.Parallel()
+	seen := make(map[visit]struct{})
+	require.True(t, sameValue(reflect.Value{}, reflect.Value{}, seen))
+	require.False(t, sameValue(reflect.ValueOf(1), reflect.Value{}, seen))
+	require.False(t, sameValue(reflect.Value{}, reflect.ValueOf(1), seen))
+}

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path middleware/cache/cache_security_test.go --path middleware/cache/cache_test.go --path middleware/cache/keygen_test.go --path middleware/proxy/response_test.go --path middleware/session/equal_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache ./middleware/proxy ./middleware/session')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache ./middleware/proxy ./middleware/session' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
