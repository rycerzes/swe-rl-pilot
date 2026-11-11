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
for f in middleware/cache/cache_security_test.go middleware/cache/cache_test.go middleware/cache/keygen_test.go; do if git cat-file -e 78b8ee93c988865603e3e1e83f95958b259eba92:"$f" 2>/dev/null; then git checkout 78b8ee93c988865603e3e1e83f95958b259eba92 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 78b8ee93c988865603e3e1e83f95958b259eba92 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
index de8cbaeafb2..69bc9d17c27 100644
--- a/middleware/cache/cache_security_test.go
+++ b/middleware/cache/cache_security_test.go
@@ -2210,3 +2210,236 @@ func Test_Cache_LegacyAnonymousEntryIsNotRead(t *testing.T) {
 	require.Equal(t, "handler ran", string(body), "the legacy anonymous entry must not be served")
 	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
 }
+
+const (
+	tenantAHost = "tenant-a.example"
+	tenantBHost = "tenant-b.example"
+)
+
+// authorityReply is what one request through an app under test came back with.
+type authorityReply struct {
+	body        string
+	location    string
+	cacheStatus string
+	status      int
+}
+
+// getFromHost sends a GET for target under the given Host through app.
+func getFromHost(t *testing.T, app *fiber.App, host, target string) authorityReply {
+	t.Helper()
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "http://"+host+target, http.NoBody))
+	require.NoError(t, err)
+	raw, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.NoError(t, resp.Body.Close())
+	return authorityReply{
+		body:        string(raw),
+		location:    resp.Header.Get(fiber.HeaderLocation),
+		cacheStatus: resp.Header.Get("X-Cache"),
+		status:      resp.StatusCode,
+	}
+}
+
+// Test_Cache_Security_KeyIncludesAuthority asserts that the default key is
+// partitioned by the request scheme and host. A cache key is composed of the
+// request method and the target URI at a minimum (RFC 9111 §2), and the target
+// URI carries the authority: two requests that differ only in Host must never
+// share an entry. Keyed on the path alone, a page routed with app.Domain
+// answered the other host, and a redirect built from c.BaseURL for one host
+// was served for the other.
+func Test_Cache_Security_KeyIncludesAuthority(t *testing.T) {
+	t.Parallel()
+
+	t.Run("domain routed pages stay with their host", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Domain(tenantAHost).Get("/dash", func(c fiber.Ctx) error { return c.SendString("tenant-a") })
+		app.Domain(tenantBHost).Get("/dash", func(c fiber.Ctx) error { return c.SendString("tenant-b") })
+
+		reply := getFromHost(t, app, tenantAHost, "/dash")
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "tenant-a", reply.body)
+
+		reply = getFromHost(t, app, tenantBHost, "/dash")
+		require.Equal(t, cacheMiss, reply.cacheStatus, "tenant B must not hit tenant A's entry")
+		require.Equal(t, "tenant-b", reply.body)
+
+		// Each host still caches on a key of its own.
+		reply = getFromHost(t, app, tenantAHost, "/dash")
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, "tenant-a", reply.body)
+		reply = getFromHost(t, app, tenantBHost, "/dash")
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, "tenant-b", reply.body)
+	})
+
+	t.Run("a redirect built from the authority is not served for another host", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/canonical", func(c fiber.Ctx) error {
+			return c.Redirect().Status(fiber.StatusMovedPermanently).To(c.BaseURL() + "/landing")
+		})
+
+		reply := getFromHost(t, app, tenantAHost, "/canonical")
+		require.Equal(t, fiber.StatusMovedPermanently, reply.status)
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "http://"+tenantAHost+"/landing", reply.location)
+
+		reply = getFromHost(t, app, tenantBHost, "/canonical")
+		require.Equal(t, fiber.StatusMovedPermanently, reply.status)
+		require.Equal(t, cacheMiss, reply.cacheStatus, "the second host must not be served the first host's redirect")
+		require.Equal(t, "http://"+tenantBHost+"/landing", reply.location)
+	})
+
+	t.Run("the port is part of the authority", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/", func(c fiber.Ctx) error { return c.SendString(c.Host()) })
+
+		reply := getFromHost(t, app, "example.com:8080", "/")
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "example.com:8080", reply.body)
+
+		reply = getFromHost(t, app, "example.com:9090", "/")
+		require.Equal(t, cacheMiss, reply.cacheStatus, "a different port is a different authority")
+		require.Equal(t, "example.com:9090", reply.body)
+	})
+
+	t.Run("vary manifests are partitioned by host as well", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/", func(c fiber.Ctx) error {
+			c.Set(fiber.HeaderVary, "X-Tenant")
+			return c.SendString(c.Host())
+		})
+
+		// The same X-Tenant on both hosts: only the authority keeps them apart,
+		// in the manifest key and in the variant key beneath it.
+		do := func(host string) authorityReply {
+			req := httptest.NewRequest(fiber.MethodGet, "http://"+host+"/", http.NoBody)
+			req.Header.Set("X-Tenant", "acme")
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			raw, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.NoError(t, resp.Body.Close())
+			return authorityReply{body: string(raw), cacheStatus: resp.Header.Get("X-Cache"), status: resp.StatusCode}
+		}
+
+		reply := do(tenantAHost)
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, tenantAHost, reply.body)
+
+		reply = do(tenantBHost)
+		require.Equal(t, cacheMiss, reply.cacheStatus, "the variant stored for tenant A must not answer tenant B")
+		require.Equal(t, tenantBHost, reply.body)
+
+		reply = do(tenantAHost)
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, tenantAHost, reply.body)
+		reply = do(tenantBHost)
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, tenantBHost, reply.body)
+	})
+
+	t.Run("one cache per domain over a shared store stays isolated", func(t *testing.T) {
+		t.Parallel()
+
+		// Separate middleware instances do not help on their own: over a shared
+		// store, such as one Redis, their keys land in the same namespace, so
+		// the key itself has to carry the host.
+		store := memory.New()
+		app := fiber.New()
+		app.Domain(tenantAHost).Use(New(Config{Storage: store, Expiration: time.Hour}))
+		app.Domain(tenantBHost).Use(New(Config{Storage: store, Expiration: time.Hour}))
+		app.Domain(tenantAHost).Get("/dash", func(c fiber.Ctx) error { return c.SendString("tenant-a") })
+		app.Domain(tenantBHost).Get("/dash", func(c fiber.Ctx) error { return c.SendString("tenant-b") })
+
+		reply := getFromHost(t, app, tenantAHost, "/dash")
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "tenant-a", reply.body)
+
+		reply = getFromHost(t, app, tenantBHost, "/dash")
+		require.Equal(t, cacheMiss, reply.cacheStatus, "tenant B's instance must not find tenant A's entry in the shared store")
+		require.Equal(t, "tenant-b", reply.body)
+	})
+}
+
+// Test_Cache_Security_KeyAuthorityFollowsTrustedProxy pins the field source of
+// the authority segment: c.Scheme and c.Host, which read X-Forwarded-Proto and
+// X-Forwarded-Host from a trusted proxy. That is the authority app.Domain routes
+// on and c.BaseURL builds from, so the key has to follow it — behind such a
+// proxy every tenant may arrive under the backend's own Host. From an untrusted
+// peer the handlers ignore the same fields, so they do not partition the cache
+// either.
+func Test_Cache_Security_KeyAuthorityFollowsTrustedProxy(t *testing.T) {
+	t.Parallel()
+
+	do := func(t *testing.T, app *fiber.App, forwardedHost, forwardedProto string) authorityReply {
+		t.Helper()
+		req := httptest.NewRequest(fiber.MethodGet, "http://backend.internal/", http.NoBody)
+		req.Header.Set(fiber.HeaderXForwardedHost, forwardedHost)
+		req.Header.Set(fiber.HeaderXForwardedProto, forwardedProto)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		raw, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.NoError(t, resp.Body.Close())
+		return authorityReply{body: string(raw), cacheStatus: resp.Header.Get("X-Cache"), status: resp.StatusCode}
+	}
+	baseURL := func(c fiber.Ctx) error { return c.SendString(c.BaseURL()) }
+
+	t.Run("trusted proxy", func(t *testing.T) {
+		t.Parallel()
+
+		// app.Test connects from 0.0.0.0, so that is the trusted proxy.
+		app := fiber.New(fiber.Config{
+			TrustProxy:       true,
+			TrustProxyConfig: fiber.TrustProxyConfig{Proxies: []string{"0.0.0.0"}},
+		})
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/", baseURL)
+
+		reply := do(t, app, tenantAHost, "https")
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "https://"+tenantAHost, reply.body)
+
+		reply = do(t, app, tenantBHost, "https")
+		require.Equal(t, cacheMiss, reply.cacheStatus, "a different forwarded host must not hit the first entry")
+		require.Equal(t, "https://"+tenantBHost, reply.body)
+
+		reply = do(t, app, tenantAHost, "http")
+		require.Equal(t, cacheMiss, reply.cacheStatus, "a different forwarded scheme must not hit the https entry")
+		require.Equal(t, "http://"+tenantAHost, reply.body)
+
+		reply = do(t, app, tenantAHost, "https")
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, "https://"+tenantAHost, reply.body)
+	})
+
+	t.Run("untrusted peer", func(t *testing.T) {
+		t.Parallel()
+
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/", baseURL)
+
+		reply := do(t, app, tenantAHost, "https")
+		require.Equal(t, cacheMiss, reply.cacheStatus)
+		require.Equal(t, "http://backend.internal", reply.body)
+
+		// Not the authority here, so not a partition either: the same entry
+		// answers whatever the untrusted peer claims to forward.
+		reply = do(t, app, tenantBHost, "http")
+		require.Equal(t, cacheHit, reply.cacheStatus)
+		require.Equal(t, "http://backend.internal", reply.body)
+	})
+}
diff --git a/middleware/cache/cache_test.go b/middleware/cache/cache_test.go
index 9f106458727..4dc91665420 100644
--- a/middleware/cache/cache_test.go
+++ b/middleware/cache/cache_test.go
@@ -268,7 +268,7 @@ func TestCacheStorageGetError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["get|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
+	storage.errs["get|"+cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -294,7 +294,7 @@ func TestCacheStorageSetError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["set|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body"] = errors.New("boom")
+	storage.errs["set|"+cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -320,14 +320,14 @@ func TestCacheStorageDeleteError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["del|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
+	storage.errs["del|"+cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	// Use an obviously expired timestamp without relying on time-based conversions
 	expired := &item{exp: 1}
 	raw, err := expired.MarshalMsg(nil)
 	require.NoError(t, err)
 
-	storage.data[cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = raw
+	storage.data[cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = raw
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -409,8 +409,8 @@ func TestCacheEvictionPropagatesRequestContextToDelete(t *testing.T) {
 	}
 
 	require.ElementsMatch(t, []string{
-		cacheKeyVersion + "|GET|/first|q=|h=accept:0|accept-encoding:0|accept-language:0",
-		cacheKeyVersion + "|GET|/first|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
+		cacheKeyVersion + "|GET|scheme=http|host=example.com|/first|q=|h=accept:0|accept-encoding:0|accept-language:0",
+		cacheKeyVersion + "|GET|scheme=http|host=example.com|/first|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
 	}, keys)
 }
 
@@ -418,7 +418,7 @@ func TestCacheCleanupPropagatesRequestContextToDelete(t *testing.T) {
 	t.Parallel()
 
 	storage := newContextRecorderStorage()
-	storage.errs["set|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
+	storage.errs["set|"+cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -447,7 +447,7 @@ func TestCacheCleanupPropagatesRequestContextToDelete(t *testing.T) {
 
 	records := storage.recordedDeletes()
 	require.Len(t, records, 1)
-	require.Equal(t, cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body", records[0].key)
+	require.Equal(t, cacheKeyVersion+"|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body", records[0].key)
 	require.Equal(t, "cleanup", records[0].value)
 	require.True(t, records[0].canceled)
 }
@@ -499,8 +499,8 @@ func TestCacheStorageOperationsObserveRequestContext(t *testing.T) {
 	require.Len(t, setRecords, 2)
 	for _, rec := range setRecords {
 		require.Contains(t, []string{
-			cacheKeyVersion + "|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0",
-			cacheKeyVersion + "|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
+			cacheKeyVersion + "|GET|scheme=http|host=example.com|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0",
+			cacheKeyVersion + "|GET|scheme=http|host=example.com|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
 		}, rec.key)
 		require.Equal(t, "store", rec.value)
 		require.True(t, rec.canceled)
@@ -515,11 +515,11 @@ func TestCacheStorageOperationsObserveRequestContext(t *testing.T) {
 			continue
 		}
 
-		if rec.key == cacheKeyVersion+"|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0" {
+		if rec.key == cacheKeyVersion+"|GET|scheme=http|host=example.com|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0" {
 			require.True(t, rec.canceled)
 			fetchEntry = true
 		}
-		if rec.key == cacheKeyVersion+"|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body" {
+		if rec.key == cacheKeyVersion+"|GET|scheme=http|host=example.com|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body" {
 			require.True(t, rec.canceled)
 			fetchBody = true
 		}
@@ -1383,7 +1383,7 @@ func Test_Cache_DefaultKeyDimensions(t *testing.T) {
 		expectedBoundedPath := "sha256:" + hex.EncodeToString(hash[:])
 		require.Len(t, expectedBoundedPath, len("sha256:")+sha256.Size*2)
 
-		expectedPrefix := cacheKeyVersion + "|" + fiber.MethodGet + "|" + expectedBoundedPath
+		expectedPrefix := cacheKeyVersion + "|" + fiber.MethodGet + "|scheme=http|host=example.com|" + expectedBoundedPath
 		foundBoundedKey := false
 		for key := range storage.data {
 			require.NotContains(t, key, oversizedPath)
@@ -2282,7 +2282,7 @@ func Test_Cache_NoCacheRefresh_KeepsAccounting(t *testing.T) {
 func Test_Cache_FailedRefreshKeepsOldEntryTracked(t *testing.T) {
 	t.Parallel()
 
-	const bodyKey = "set|" + cacheKeyVersion + "|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body"
+	const bodyKey = "set|" + cacheKeyVersion + "|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body"
 
 	storage := newFailingCacheStorage()
 	probe := &accountingProbe{}
@@ -2324,7 +2324,7 @@ func Test_Cache_FailedRefreshKeepsOldEntryTracked(t *testing.T) {
 func Test_Cache_FailedRefreshAfterBodyWriteDropsOldEntry(t *testing.T) {
 	t.Parallel()
 
-	const metaKey = "set|" + cacheKeyVersion + "|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"
+	const metaKey = "set|" + cacheKeyVersion + "|GET|scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"
 
 	storage := newFailingCacheStorage()
 	probe := &accountingProbe{}
@@ -6682,7 +6682,7 @@ func Test_Cache_VaryManifestStoreFailureUnreservesSpace(t *testing.T) {
 		return c.SendString(body)
 	})
 
-	manifestKey := cacheKeyVersion + "|GET|/a|q=|h=accept:0|accept-encoding:0|accept-language:0|vary"
+	manifestKey := cacheKeyVersion + "|GET|scheme=http|host=example.com|/a|q=|h=accept:0|accept-encoding:0|accept-language:0|vary"
 	storage.mu.Lock()
 	storage.errs["set|"+manifestKey] = errors.New("boom")
 	storage.mu.Unlock()
diff --git a/middleware/cache/keygen_test.go b/middleware/cache/keygen_test.go
index fad2dcbd9e0..8458deae032 100644
--- a/middleware/cache/keygen_test.go
+++ b/middleware/cache/keygen_test.go
@@ -22,6 +22,7 @@ type keygenCase struct {
 	headers  map[string]string
 	name     string
 	uri      string
+	host     string
 	method   string
 	body     string
 	cookie   string
@@ -32,23 +33,29 @@ type keygenCase struct {
 
 func keygenCorpus() []keygenCase {
 	return []keygenCase{
-		{name: "noquery", uri: "/demo", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "single", uri: "/demo?foo=bar", want: "/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "multi_dup", uri: "/demo?b=2&a=1&a=3", want: "/|q=a=1&a=3&b=2|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "path_delims", uri: "/a|b:c\\d?x=1", want: "/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "query_escape", uri: "/p?k=a b&z=%2F&k=z", want: "/|q=k=a+b&k=z&z=%2F|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "with_headers", uri: "/p?foo=bar", headers: map[string]string{"Accept": "text/html", "Accept-Encoding": "gzip"}, want: "/|q=foo=bar|h=accept:1|text/html|accept-encoding:1|gzip|accept-language:0"},
-		{name: "with_cookie", uri: "/p?foo=bar", cookie: "sid=abc123", keyCooks: []string{"sid"}, want: "/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0|c=sid:abc123"},
-		{name: "long_query", uri: "/p?q=" + strings.Repeat("x", 300), want: "/|q=sha256:4d86f7dbfc8b3bfe229da7e27f4ac8f6cf8114e24e5cb6b5af1d09cb4cc3d982|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "long_path", uri: "/" + strings.Repeat("p", 300) + "?a=1", want: "/|q=a=1|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "disable_query", uri: "/p?foo=bar", noQuery: true, want: "/|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "header_val_delims", uri: "/p", headers: map[string]string{"Accept": "a|b:c"}, want: "/|q=|h=accept:1|a\\pb\\cc|accept-encoding:0|accept-language:0"},
-		{name: "empty_query", uri: "/p?", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "many_params", uri: "/p?" + strings.Repeat("k=v&", 200) + "z=1", want: "/|q=sha256:f8f7166c8aec35092b4c6f66a895ec9f302746c6310aa0dbfde45cbd30aa1829|h=accept:0|accept-encoding:0|accept-language:0"},
-		{name: "query_empty_body", uri: "/q", method: fiber.MethodQuery, want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b="},
-		{name: "query_body", uri: "/q", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
-		{name: "query_body_delims", uri: "/q", method: fiber.MethodQuery, body: "a|b:c", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=a\\pb\\cc"},
-		{name: "query_with_querystring", uri: "/q?x=1", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
+		{name: "noquery", uri: "/demo", want: "scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "single", uri: "/demo?foo=bar", want: "scheme=http|host=example.com|/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "multi_dup", uri: "/demo?b=2&a=1&a=3", want: "scheme=http|host=example.com|/|q=a=1&a=3&b=2|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "path_delims", uri: "/a|b:c\\d?x=1", want: "scheme=http|host=example.com|/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "query_escape", uri: "/p?k=a b&z=%2F&k=z", want: "scheme=http|host=example.com|/|q=k=a+b&k=z&z=%2F|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "with_headers", uri: "/p?foo=bar", headers: map[string]string{"Accept": "text/html", "Accept-Encoding": "gzip"}, want: "scheme=http|host=example.com|/|q=foo=bar|h=accept:1|text/html|accept-encoding:1|gzip|accept-language:0"},
+		{name: "with_cookie", uri: "/p?foo=bar", cookie: "sid=abc123", keyCooks: []string{"sid"}, want: "scheme=http|host=example.com|/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0|c=sid:abc123"},
+		{name: "long_query", uri: "/p?q=" + strings.Repeat("x", 300), want: "scheme=http|host=example.com|/|q=sha256:4d86f7dbfc8b3bfe229da7e27f4ac8f6cf8114e24e5cb6b5af1d09cb4cc3d982|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "long_path", uri: "/" + strings.Repeat("p", 300) + "?a=1", want: "scheme=http|host=example.com|/|q=a=1|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "disable_query", uri: "/p?foo=bar", noQuery: true, want: "scheme=http|host=example.com|/|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "header_val_delims", uri: "/p", headers: map[string]string{"Accept": "a|b:c"}, want: "scheme=http|host=example.com|/|q=|h=accept:1|a\\pb\\cc|accept-encoding:0|accept-language:0"},
+		{name: "empty_query", uri: "/p?", want: "scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "many_params", uri: "/p?" + strings.Repeat("k=v&", 200) + "z=1", want: "scheme=http|host=example.com|/|q=sha256:f8f7166c8aec35092b4c6f66a895ec9f302746c6310aa0dbfde45cbd30aa1829|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "query_empty_body", uri: "/q", method: fiber.MethodQuery, want: "scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0|b="},
+		{name: "query_body", uri: "/q", method: fiber.MethodQuery, body: "foo=bar", want: "scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
+		{name: "query_body_delims", uri: "/q", method: fiber.MethodQuery, body: "a|b:c", want: "scheme=http|host=example.com|/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=a\\pb\\cc"},
+		{name: "query_with_querystring", uri: "/q?x=1", method: fiber.MethodQuery, body: "foo=bar", want: "scheme=http|host=example.com|/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
+		// The authority: the port is part of it, its delimiters are escaped like
+		// every other segment's, and past the bound it is hashed rather than
+		// allowed to grow the key.
+		{name: "host_port", uri: "/p", host: "example.com:8443", want: "scheme=http|host=example.com\\c8443|/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "host_delims", uri: "/p", host: "a|b:c\\d", want: "scheme=http|host=a\\pb\\cc\\\\d|/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "long_host", uri: "/p", host: strings.Repeat("h", 300), want: "scheme=http|host=" + boundKeySegment(strings.Repeat("h", 300)) + "|/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
 	}
 }
 
@@ -64,6 +71,13 @@ func buildKeygenCtx(tc *keygenCase) (fiber.Ctx, *Config) {
 	fctx.Request.Header.SetMethod(method)
 	c := app.AcquireCtx(fctx)
 	c.Request().SetRequestURI(tc.uri)
+	// The authority is read live as well; a request without one is not what
+	// the key is built for, so the fixtures carry the host httptest would set.
+	host := tc.host
+	if host == "" {
+		host = "example.com"
+	}
+	c.Request().SetHost(host)
 	if tc.body != "" {
 		c.Request().SetBody([]byte(tc.body))
 	}
@@ -185,17 +199,17 @@ func Test_Cache_KeyFormatIsStable(t *testing.T) {
 	}{
 		{
 			name: "anonymous",
-			want: []string{"v2|GET|/demo|vary", "v2|GET|/demo"},
+			want: []string{"v3|GET|/demo|vary", "v3|GET|/demo"},
 		},
 		{
 			name: "authenticated",
 			auth: "Bearer token",
-			want: []string{"v2|GET|/demo|auth=" + authHash + "|vary", "v2|GET|/demo|auth=" + authHash},
+			want: []string{"v3|GET|/demo|auth=" + authHash + "|vary", "v3|GET|/demo|auth=" + authHash},
 		},
 		{
 			name:        "vary disabled",
 			disableVary: true,
-			want:        []string{"v2|GET|/demo"},
+			want:        []string{"v3|GET|/demo"},
 		},
 	}
 

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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path middleware/cache/cache_security_test.go --path middleware/cache/cache_test.go --path middleware/cache/keygen_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache')"
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path middleware/cache/cache_security_test.go --path middleware/cache/cache_test.go --path middleware/cache/keygen_test.go --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache')"
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
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/cache' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
