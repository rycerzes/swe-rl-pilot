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
for f in bind_test.go client/cookiejar_test.go ctx_test.go helpers_test.go internal/logtemplate/sanitize_test.go middleware/basicauth/basicauth_test.go middleware/expvar/expvar_test.go middleware/logger/logger_test.go middleware/pprof/pprof_test.go path_test.go redirect_test.go router_test.go; do if git cat-file -e d8ae9aaaaea0e03df5d2e12839d5a47450011c14:"$f" 2>/dev/null; then git checkout d8ae9aaaaea0e03df5d2e12839d5a47450011c14 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - d8ae9aaaaea0e03df5d2e12839d5a47450011c14 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/bind_test.go b/bind_test.go
index e3f545b81a0..a2a3489de0e 100644
--- a/bind_test.go
+++ b/bind_test.go
@@ -3139,3 +3139,173 @@ func BenchmarkBind_All_CustomPrecedence(b *testing.B) {
 		}
 	}
 }
+
+// Test_Bind_Body_ContentTypeNormalization pins both halves of the
+// Content-Type contract. The media type must be folded in place, because
+// fasthttp and binder.FormBinding locate the form body with case-sensitive
+// prefix checks — so a legal "Multipart/Form-Data" has to still bind. The
+// parameters must NOT be folded, because a multipart boundary is
+// case-sensitive and anything replaying the request (a proxy, an adaptor)
+// would no longer parse the body it forwarded.
+func Test_Bind_Body_ContentTypeNormalization(t *testing.T) {
+	t.Parallel()
+
+	// Both the media type and the parameter names are case-insensitive
+	// (RFC 9110 Sections 8.3.1 and 5.6.6); only the boundary value is not.
+	for _, ctype := range []string{
+		"multipart/form-data; boundary=AbCdEfMixed12345",
+		"Multipart/Form-Data; boundary=AbCdEfMixed12345",
+		"multipart/form-data; BOUNDARY=AbCdEfMixed12345",
+		"multipart/form-data; Boundary=AbCdEfMixed12345",
+		"Multipart/Form-Data; BOUNDARY=AbCdEfMixed12345",
+		`multipart/form-data; CHARSET="a;b"; BOUNDARY=AbCdEfMixed12345`,
+	} {
+		t.Run("case-insensitive "+ctype, func(t *testing.T) {
+			t.Parallel()
+
+			var body bytes.Buffer
+			w := multipart.NewWriter(&body)
+			require.NoError(t, w.SetBoundary("AbCdEfMixed12345"))
+			require.NoError(t, w.WriteField("name", "john"))
+			require.NoError(t, w.Close())
+
+			app := New()
+			app.Post("/", func(c Ctx) error {
+				var out struct {
+					Name string `form:"name"`
+				}
+				require.NoError(t, c.Bind().Body(&out))
+				require.Equal(t, "john", out.Name)
+				// The boundary value keeps its case so the request can be replayed.
+				require.Contains(t, c.Get(HeaderContentType), "AbCdEfMixed12345")
+				return nil
+			})
+
+			req := httptest.NewRequest(MethodPost, "/", bytes.NewReader(body.Bytes()))
+			req.Header.Set(HeaderContentType, ctype)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, StatusOK, resp.StatusCode)
+		})
+	}
+
+	t.Run("mixed-case urlencoded still binds", func(t *testing.T) {
+		t.Parallel()
+
+		app := New()
+		app.Post("/", func(c Ctx) error {
+			var out struct {
+				Name string `form:"name"`
+			}
+			require.NoError(t, c.Bind().Body(&out))
+			require.Equal(t, "john", out.Name)
+			return nil
+		})
+
+		req := httptest.NewRequest(MethodPost, "/", strings.NewReader("name=john"))
+		req.Header.Set(HeaderContentType, "APPLICATION/X-WWW-FORM-URLENCODED")
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, StatusOK, resp.StatusCode)
+	})
+
+	t.Run("boundary case is preserved", testBindBodyPreservesBoundary)
+}
+
+func testBindBodyPreservesBoundary(t *testing.T) {
+	t.Parallel()
+
+	var body bytes.Buffer
+	w := multipart.NewWriter(&body)
+	require.NoError(t, w.SetBoundary("AbCdEfMixedCase12345"))
+	require.NoError(t, w.WriteField("name", "john"))
+	require.NoError(t, w.Close())
+	raw := body.Bytes()
+
+	const wantCType = "multipart/form-data; boundary=AbCdEfMixedCase12345"
+
+	app := New()
+	app.Post("/", func(c Ctx) error {
+		var out struct {
+			Name string `form:"name"`
+		}
+		require.NoError(t, c.Bind().Body(&out))
+		require.Equal(t, "john", out.Name)
+
+		require.Equal(t, wantCType, c.Get(HeaderContentType))
+
+		// Replaying the request from its header and body — what forwarding it
+		// upstream amounts to — must still parse.
+		fwd := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(fwd)
+		fwd.Header.SetMethod(MethodPost)
+		fwd.SetRequestURI("/")
+		fwd.Header.SetContentType(c.Get(HeaderContentType))
+		fwd.SetBody(raw)
+
+		form, err := fwd.MultipartForm()
+		require.NoError(t, err)
+		require.Equal(t, []string{"john"}, form.Value["name"])
+		return nil
+	})
+
+	req := httptest.NewRequest(MethodPost, "/", bytes.NewReader(raw))
+	req.Header.Set(HeaderContentType, wantCType)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, StatusOK, resp.StatusCode)
+}
+
+// Test_Bind_Form_ContentTypeNormalization covers the Form entry point
+// directly. Bind().Body() normalizes the Content-Type before dispatching, but
+// Bind().Form() reaches the binder without going through it — so a legal
+// mixed-case media type bound nothing here and reported no error.
+func Test_Bind_Form_ContentTypeNormalization(t *testing.T) {
+	t.Parallel()
+
+	t.Run("multipart", func(t *testing.T) {
+		t.Parallel()
+
+		var body bytes.Buffer
+		w := multipart.NewWriter(&body)
+		require.NoError(t, w.SetBoundary("AbCdEfMixed12345"))
+		require.NoError(t, w.WriteField("name", "john"))
+		require.NoError(t, w.Close())
+
+		app := New()
+		app.Post("/", func(c Ctx) error {
+			var out struct {
+				Name string `form:"name"`
+			}
+			require.NoError(t, c.Bind().Form(&out))
+			require.Equal(t, "john", out.Name)
+			return nil
+		})
+
+		req := httptest.NewRequest(MethodPost, "/", bytes.NewReader(body.Bytes()))
+		req.Header.Set(HeaderContentType, "Multipart/Form-Data; BOUNDARY=AbCdEfMixed12345")
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, StatusOK, resp.StatusCode)
+	})
+
+	t.Run("urlencoded", func(t *testing.T) {
+		t.Parallel()
+
+		app := New()
+		app.Post("/", func(c Ctx) error {
+			var out struct {
+				Name string `form:"name"`
+			}
+			require.NoError(t, c.Bind().Form(&out))
+			require.Equal(t, "john", out.Name)
+			return nil
+		})
+
+		req := httptest.NewRequest(MethodPost, "/", strings.NewReader("name=john"))
+		req.Header.Set(HeaderContentType, "APPLICATION/X-WWW-FORM-URLENCODED")
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, StatusOK, resp.StatusCode)
+	})
+}
diff --git a/client/cookiejar_test.go b/client/cookiejar_test.go
index d1456623602..e970aca8377 100644
--- a/client/cookiejar_test.go
+++ b/client/cookiejar_test.go
@@ -3,11 +3,16 @@ package client
 import (
 	"bytes"
 	"fmt"
+	"net/http"
+	"net/http/cookiejar"
+	neturl "net/url"
+	"sort"
 	"testing"
 	"time"
 
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
+	"golang.org/x/net/publicsuffix"
 )
 
 func checkKeyValue(t *testing.T, cj *CookieJar, cookie *fasthttp.Cookie, uri *fasthttp.URI, n int) {
@@ -827,6 +832,75 @@ func Test_CookieJar_PathMatch(t *testing.T) {
 	require.Empty(t, jar.Get(uriNoMatch))
 }
 
+// Test_CookieJar_SamePathAndPathMatchEdges exercises samePath and pathMatch
+// directly. Both treat an empty path as the default "/" (RFC 6265 §5.1.4), and
+// pathMatch's prefix rule only extends across a '/' boundary — reachable only
+// with inputs the higher-level tests do not produce.
+func Test_CookieJar_SamePathAndPathMatchEdges(t *testing.T) {
+	t.Parallel()
+
+	t.Run("samePath", func(t *testing.T) {
+		t.Parallel()
+
+		testCases := []struct {
+			a, b string
+			want bool
+		}{
+			{"/a", "/a", true},
+			{"", "/", true}, // empty defaults to "/"
+			{"/", "", true}, // and in the other direction
+			{"", "", true},  // both empty
+			{"/a", "/b", false},
+			{"/a", "/a/b", false}, // exact, not prefix
+			{"", "/a", false},
+		}
+		for _, tc := range testCases {
+			require.Equal(t, tc.want, samePath([]byte(tc.a), []byte(tc.b)),
+				"samePath(%q, %q)", tc.a, tc.b)
+		}
+	})
+
+	t.Run("pathMatch", func(t *testing.T) {
+		t.Parallel()
+
+		testCases := []struct {
+			reqPath, cookiePath string
+			want                bool
+		}{
+			{"/a", "/a", true},
+			{"", "/", true},       // empty request path defaults to "/"
+			{"/a", "", true},      // empty cookie path defaults to "/"
+			{"/a/b", "/a", true},  // prefix across a '/' boundary
+			{"/a/b", "/a/", true}, // cookie path already ends in '/'
+			{"/ab", "/a", false},  // prefix but not on a boundary
+			{"/b", "/a", false},   // no prefix at all
+			{"/a", "/a/b", false}, // request shorter than the cookie path
+		}
+		for _, tc := range testCases {
+			require.Equal(t, tc.want, pathMatch([]byte(tc.reqPath), []byte(tc.cookiePath)),
+				"pathMatch(%q, %q)", tc.reqPath, tc.cookiePath)
+		}
+	})
+}
+
+// Test_CookieJar_NilURI pins the nil guards on the exported URI-taking methods:
+// they must be no-ops rather than panicking.
+func Test_CookieJar_NilURI(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	require.Nil(t, jar.Get(nil))
+
+	c := fasthttp.AcquireCookie()
+	defer fasthttp.ReleaseCookie(c)
+	c.SetKey("k")
+	c.SetValue("v")
+	require.NotPanics(t, func() { jar.Set(nil, c) })
+	require.Empty(t, jar.hostCookies, "a nil URI must store nothing")
+}
+
 // Test_CookieJar_DomainMatchBoundary pins the RFC 6265 §5.1.3 label-boundary
 // semantics of domainMatch: a bare string suffix without a '.' separator must
 // never match, and the comparison is ASCII case-insensitive.
@@ -855,3 +929,682 @@ func Test_CookieJar_DomainMatchBoundary(t *testing.T) {
 		require.Equal(t, tc.want, domainMatch(tc.host, tc.domain), "domainMatch(%q, %q)", tc.host, tc.domain)
 	}
 }
+
+// Test_CookieJar_DistinctPathsCoexist covers RFC 6265 Section 5.3 step 11:
+// a stored cookie is only replaced when name, domain and path all match. A
+// cookie set for a deeper path must not evict the same-named cookie stored
+// for a shallower one.
+func Test_CookieJar_DistinctPathsCoexist(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	root := fasthttp.AcquireCookie()
+	defer fasthttp.ReleaseCookie(root)
+	root.SetKey("a")
+	root.SetValue("root")
+	root.SetPath("/")
+
+	admin := fasthttp.AcquireCookie()
+	defer fasthttp.ReleaseCookie(admin)
+	admin.SetKey("a")
+	admin.SetValue("admin")
+	admin.SetPath("/admin")
+
+	jar.SetByHost([]byte("example.com"), root)
+	jar.SetByHost([]byte("example.com"), admin)
+
+	collect := func(path string) map[string]string {
+		got := jar.getByHostAndPath([]byte("example.com"), []byte(path), false)
+		out := make(map[string]string, len(got))
+		for _, c := range got {
+			out[string(c.Path())] = string(c.Value())
+			fasthttp.ReleaseCookie(c)
+		}
+		return out
+	}
+
+	require.Equal(t, map[string]string{"/": "root"}, collect("/"))
+	require.Equal(t, map[string]string{"/": "root", "/admin": "admin"}, collect("/admin"))
+	require.Equal(t, map[string]string{"/": "root"}, collect("/other"))
+
+	// Re-setting the same (name, path) replaces in place rather than appending.
+	updated := fasthttp.AcquireCookie()
+	defer fasthttp.ReleaseCookie(updated)
+	updated.SetKey("a")
+	updated.SetValue("root2")
+	updated.SetPath("/")
+	jar.SetByHost([]byte("example.com"), updated)
+
+	require.Equal(t, map[string]string{"/": "root2"}, collect("/"))
+	require.Equal(t, map[string]string{"/": "root2", "/admin": "admin"}, collect("/admin"))
+}
+
+// Test_CookieJar_SetByHost_DoesNotMutateArgument checks the jar's documented
+// contract that it only stores copies: normalizing the Domain attribute used
+// to case-fold the caller's cookie in place.
+func Test_CookieJar_SetByHost_DoesNotMutateArgument(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	c := fasthttp.AcquireCookie()
+	defer fasthttp.ReleaseCookie(c)
+	c.SetKey("a")
+	c.SetValue("1")
+	c.SetDomain("Example.COM")
+
+	jar.SetByHost([]byte("sub.example.com"), c)
+
+	require.Equal(t, "Example.COM", string(c.Domain()))
+
+	// The stored copy is still normalized, so lookups keep working.
+	got := jar.getByHostAndPath([]byte("sub.example.com"), []byte("/"), false)
+	require.Len(t, got, 1)
+	require.Equal(t, "1", string(got[0].Value()))
+	fasthttp.ReleaseCookie(got[0])
+}
+
+// Test_CookieJar_SetByHost_ReplacesOnNormalizedPath pins SetByHost's documented
+// replace semantics against fasthttp's path normalization. SetPathBytes runs the
+// value through normalizePath, so a cookie built by ParseBytes can carry a path
+// that differs from the one the entry ends up storing. Searching on the raw form
+// missed the entry a previous identical call had created and appended a
+// duplicate, quietly consuming per-host slots until eviction dropped a
+// legitimate cookie.
+func Test_CookieJar_SetByHost_ReplacesOnNormalizedPath(t *testing.T) {
+	t.Parallel()
+
+	// Each raw path is one fasthttp's normalizePath rewrites: collapsed slashes,
+	// a percent escape, a dot segment, and a ';' that gets stripped.
+	for _, raw := range []string{"/x//y", "/x/%41", "/x/./y", "/x;y"} {
+		t.Run(raw, func(t *testing.T) {
+			t.Parallel()
+
+			jar := AcquireCookieJar()
+			defer ReleaseCookieJar(jar)
+
+			const host = "example.com"
+			for i := range 3 {
+				c := fasthttp.AcquireCookie()
+				require.NoError(t, c.ParseBytes(
+					fmt.Appendf(nil, "a=v%d; path=%s", i, raw)))
+				jar.SetByHost([]byte(host), c)
+				fasthttp.ReleaseCookie(c)
+			}
+
+			// Three writes of the same name and path must leave one entry.
+			require.Len(t, jar.hostCookies[host], 1,
+				"repeated SetByHost calls must replace, not accumulate")
+
+			// And it must be the last value written.
+			require.Equal(t, "v2", string(jar.hostCookies[host][0].cookie.Value()))
+		})
+	}
+}
+
+// Test_CookieJar_SetUsesURIDefaultPath pins that Set derives the RFC 6265
+// Section 5.1.4 default-path from the URI it is given, the same rule
+// parseCookiesFromResp applies to a Set-Cookie received for that URI. A cookie
+// with no Path set against "/a/b" is scoped to "/a", not host-wide.
+//
+// SetByHost has no URI to derive a path from and keeps scoping such cookies to
+// "/", so the two entry points stay distinguishable.
+func Test_CookieJar_SetUsesURIDefaultPath(t *testing.T) {
+	t.Parallel()
+
+	t.Run("Set scopes to the URI default-path", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+
+		setURI := fasthttp.AcquireURI()
+		defer fasthttp.ReleaseURI(setURI)
+		require.NoError(t, setURI.Parse(nil, []byte("http://example.com/a/b")))
+
+		c := fasthttp.AcquireCookie()
+		defer fasthttp.ReleaseCookie(c)
+		c.SetKey("k")
+		c.SetValue("v")
+
+		jar.Set(setURI, c)
+
+		require.Len(t, jar.hostCookies["example.com"], 1)
+		require.Equal(t, "/a", string(jar.hostCookies["example.com"][0].cookie.Path()),
+			"a path-less cookie must take the URI's default-path")
+
+		// Sent to a sibling under the same directory...
+		sibling := fasthttp.AcquireURI()
+		defer fasthttp.ReleaseURI(sibling)
+		require.NoError(t, sibling.Parse(nil, []byte("http://example.com/a/other")))
+		got := jar.Get(sibling)
+		require.Len(t, got, 1)
+		for _, gc := range got {
+			fasthttp.ReleaseCookie(gc)
+		}
+
+		// ...but not host-wide.
+		root := fasthttp.AcquireURI()
+		defer fasthttp.ReleaseURI(root)
+		require.NoError(t, root.Parse(nil, []byte("http://example.com/")))
+		require.Empty(t, jar.Get(root), "the cookie must not escape its default-path")
+	})
+
+	t.Run("an explicit Path still wins", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+
+		setURI := fasthttp.AcquireURI()
+		defer fasthttp.ReleaseURI(setURI)
+		require.NoError(t, setURI.Parse(nil, []byte("http://example.com/a/b")))
+
+		c := fasthttp.AcquireCookie()
+		defer fasthttp.ReleaseCookie(c)
+		c.SetKey("k")
+		c.SetValue("v")
+		c.SetPath("/")
+
+		jar.Set(setURI, c)
+
+		require.Equal(t, "/", string(jar.hostCookies["example.com"][0].cookie.Path()))
+	})
+
+	t.Run("SetByHost still scopes to root", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+
+		c := fasthttp.AcquireCookie()
+		defer fasthttp.ReleaseCookie(c)
+		c.SetKey("k")
+		c.SetValue("v")
+
+		jar.SetByHost([]byte("example.com"), c)
+
+		require.Equal(t, "/", string(jar.hostCookies["example.com"][0].cookie.Path()),
+			"SetByHost has no request path, so the scope stays at the root")
+	})
+}
+
+// Test_CookieJar_MatchesStdlibJar cross-checks storage and retrieval against
+// net/http/cookiejar, which implements RFC 6265 with the same public-suffix
+// list. It caught path-less cookies being stored at "/" instead of the
+// request's default-path.
+func Test_CookieJar_MatchesStdlibJar(t *testing.T) {
+	t.Parallel()
+
+	type setStep struct {
+		url    string
+		cookie string
+	}
+	tests := []struct {
+		name string
+		sets []setStep
+		gets []string
+	}{
+		{
+			name: "host only",
+			sets: []setStep{{"http://example.com/", "a=1"}},
+			gets: []string{"http://example.com/", "http://sub.example.com/", "http://other.com/"},
+		},
+		{
+			name: "domain attribute",
+			sets: []setStep{{"http://example.com/", "a=1; Domain=example.com"}},
+			gets: []string{"http://example.com/", "http://sub.example.com/"},
+		},
+		{
+			name: "leading dot domain",
+			sets: []setStep{{"http://example.com/", "a=1; Domain=.example.com"}},
+			gets: []string{"http://example.com/", "http://sub.example.com/"},
+		},
+		{
+			name: "subdomain sets parent",
+			sets: []setStep{{"http://sub.example.com/", "a=1; Domain=example.com"}},
+			gets: []string{"http://example.com/", "http://sub.example.com/", "http://x.example.com/"},
+		},
+		{
+			name: "public suffix rejected",
+			sets: []setStep{{"http://example.com/", "a=1; Domain=com"}},
+			gets: []string{"http://example.com/", "http://other.com/"},
+		},
+		{
+			name: "unrelated domain rejected",
+			sets: []setStep{{"http://example.com/", "a=1; Domain=evil.com"}},
+			gets: []string{"http://example.com/", "http://evil.com/"},
+		},
+		{
+			name: "explicit paths",
+			sets: []setStep{{"http://example.com/", "a=1; Path=/"}, {"http://example.com/admin", "b=2; Path=/admin"}},
+			gets: []string{"http://example.com/", "http://example.com/admin", "http://example.com/admin/x", "http://example.com/adminx"},
+		},
+		{
+			name: "secure",
+			sets: []setStep{{"https://example.com/", "a=1; Secure"}},
+			gets: []string{"https://example.com/", "http://example.com/"},
+		},
+		{
+			name: "overwrite",
+			sets: []setStep{{"http://example.com/", "a=1"}, {"http://example.com/", "a=2"}},
+			gets: []string{"http://example.com/"},
+		},
+		{
+			name: "ip host",
+			sets: []setStep{{"http://127.0.0.1/", "a=1"}},
+			gets: []string{"http://127.0.0.1/"},
+		},
+		{
+			name: "ip domain",
+			sets: []setStep{{"http://127.0.0.1/", "a=1; Domain=127.0.0.1"}},
+			gets: []string{"http://127.0.0.1/"},
+		},
+		{
+			name: "default path",
+			sets: []setStep{{"http://example.com/a/b", "a=1"}},
+			gets: []string{"http://example.com/a/b", "http://example.com/a/", "http://example.com/a", "http://example.com/"},
+		},
+		{
+			name: "default path at root",
+			sets: []setStep{{"http://example.com/b", "a=1"}},
+			gets: []string{"http://example.com/b", "http://example.com/"},
+		},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			t.Parallel()
+
+			std, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
+			require.NoError(t, err)
+			jar := AcquireCookieJar()
+			defer ReleaseCookieJar(jar)
+
+			for _, s := range tt.sets {
+				u, err := neturl.Parse(s.url)
+				require.NoError(t, err)
+
+				header := http.Header{}
+				header.Add("Set-Cookie", s.cookie)
+				std.SetCookies(u, (&http.Response{Header: header}).Cookies())
+
+				resp := fasthttp.AcquireResponse()
+				resp.Header.Add("Set-Cookie", s.cookie)
+				jar.parseCookiesFromResp([]byte(u.Host), []byte(u.Path), resp)
+				fasthttp.ReleaseResponse(resp)
+			}
+
+			for _, g := range tt.gets {
+				u, err := neturl.Parse(g)
+				require.NoError(t, err)
+
+				want := make([]string, 0, 2)
+				for _, c := range std.Cookies(u) {
+					want = append(want, c.Name+"="+c.Value)
+				}
+				sort.Strings(want)
+
+				fURI := fasthttp.AcquireURI()
+				require.NoError(t, fURI.Parse(nil, []byte(g)))
+				got := make([]string, 0, 2)
+				for _, c := range jar.Get(fURI) {
+					got = append(got, string(c.Key())+"="+string(c.Value()))
+					fasthttp.ReleaseCookie(c)
+				}
+				fasthttp.ReleaseURI(fURI)
+				sort.Strings(got)
+
+				require.Equal(t, want, got, "request %s", g)
+			}
+		})
+	}
+}
+
+// Test_CookieJar_SendsMostSpecificCookie pins RFC 6265 Section 5.4 ordering:
+// longer path first, ties broken by write order.
+func Test_CookieJar_SendsMostSpecificCookie(t *testing.T) {
+	t.Parallel()
+
+	t.Run("longer path wins", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+
+		adminResp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(adminResp)
+		adminResp.Header.Add("Set-Cookie", "sess=ADMINVAL")
+		jar.parseCookiesFromResp([]byte("example.com"), []byte("/admin/login"), adminResp)
+
+		rootResp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(rootResp)
+		rootResp.Header.Add("Set-Cookie", "sess=ROOTVAL; Path=/")
+		jar.parseCookiesFromResp([]byte("example.com"), []byte("/"), rootResp)
+
+		require.Equal(t, "sess=ADMINVAL", cookieHeaderFor(jar, "http://example.com/admin/dashboard"))
+		require.Equal(t, "sess=ROOTVAL", cookieHeaderFor(jar, "http://example.com/other"))
+	})
+
+	// Equal-length paths stored under *different* keys is the shape where map
+	// iteration order decides the winner, so it is the one that needs the
+	// explicit tiebreak. Repeat it: Go randomizes map order per run.
+	t.Run("equal paths across storage keys are deterministic", func(t *testing.T) {
+		t.Parallel()
+
+		for range 50 {
+			jar := AcquireCookieJar()
+
+			hostOnly := fasthttp.AcquireResponse()
+			hostOnly.Header.Add("Set-Cookie", "sess=HOSTONLY; Path=/ab")
+			jar.parseCookiesFromResp([]byte("sub.example.com"), []byte("/ab"), hostOnly)
+			fasthttp.ReleaseResponse(hostOnly)
+
+			domainWide := fasthttp.AcquireResponse()
+			domainWide.Header.Add("Set-Cookie", "sess=DOMAINWIDE; Path=/ab; Domain=example.com")
+			jar.parseCookiesFromResp([]byte("sub.example.com"), []byte("/ab"), domainWide)
+			fasthttp.ReleaseResponse(domainWide)
+
+			// Same path length, so the write-order tiebreak decides: the
+			// host-only cookie was stored first and wins every run.
+			require.Equal(t, "sess=HOSTONLY", cookieHeaderFor(jar, "http://sub.example.com/ab/c"))
+
+			ReleaseCookieJar(jar)
+		}
+	})
+}
+
+// cookieHeaderFor renders the Cookie header the jar would put on a request.
+func cookieHeaderFor(jar *CookieJar, rawURL string) string {
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.SetRequestURI(rawURL)
+	jar.dumpCookiesToReq(req)
+	return string(req.Header.Peek("Cookie"))
+}
+
+// Test_CookieJar_DefaultPathStaysReachable guards the default-path against
+// fasthttp's Cookie.SetPathBytes, which percent-decodes the value it is given.
+// The path already came out of URI.Path() decoded once, so a naive set decoded
+// it twice and stored a scope the setting URL itself could never match.
+//
+// The invariant is reachability, not exact scope: a path containing ';' cannot
+// round-trip at all (SetPathBytes rewrites it unconditionally), so those fall
+// back to "/" — the same scope every path-less cookie had before default-path
+// scoping existed. Broader than the RFC prescribes, but never silently lost.
+func Test_CookieJar_DefaultPathStaysReachable(t *testing.T) {
+	t.Parallel()
+
+	for _, rawURL := range []string{
+		"http://example.com/a%2541b/c",
+		"http://example.com/plain/c",
+		"http://example.com/matrix;v=1/c",
+	} {
+		t.Run(rawURL, func(t *testing.T) {
+			t.Parallel()
+
+			jar := AcquireCookieJar()
+			defer ReleaseCookieJar(jar)
+
+			uri := fasthttp.AcquireURI()
+			defer fasthttp.ReleaseURI(uri)
+			require.NoError(t, uri.Parse(nil, []byte(rawURL)))
+
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseResponse(resp)
+			resp.Header.Add("Set-Cookie", "k=v")
+			jar.parseCookiesFromResp(uri.Host(), uri.Path(), resp)
+
+			got := jar.Get(uri)
+			require.Len(t, got, 1, "cookie must still be sent to the URL that set it")
+			require.Equal(t, "v", string(got[0].Value()))
+			fasthttp.ReleaseCookie(got[0])
+		})
+	}
+}
+
+// Test_CookieJar_BoundsCookiesPerHost checks the per-host ceiling. Scoping
+// path-less cookies to their default-path lets one origin mint an entry per
+// directory it serves, so the host cap alone no longer bounds the jar.
+func Test_CookieJar_BoundsCookiesPerHost(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	for i := range 500 {
+		resp := fasthttp.AcquireResponse()
+		resp.Header.Add("Set-Cookie", "a=1")
+		jar.parseCookiesFromResp([]byte("example.com"), fmt.Appendf(nil, "/u/%d/x", i), resp)
+		fasthttp.ReleaseResponse(resp)
+	}
+
+	require.LessOrEqual(t, len(jar.hostCookies["example.com"]), maxCookiesPerHost)
+}
+
+// Test_CookieJar_PerHostEvictionPrefersExpired pins the first half of
+// enforceHostCookieLimitLocked: when a host is over its ceiling, expired entries
+// are dropped before any live one is considered, and the remaining eviction is
+// least-recently-written rather than oldest-created. A cookie the server keeps
+// re-sending must therefore survive a flood of one-off cookies, which is exactly
+// the pressure default-path scoping creates.
+func Test_CookieJar_PerHostEvictionPrefersExpired(t *testing.T) {
+	t.Parallel()
+
+	const host = "example.com"
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+	jar.hostCookies = make(map[string][]storedCookie)
+
+	now := time.Now()
+
+	// One live cookie written first, so it is the least-recently-written of the
+	// live entries and would be the eviction victim if expiry were not checked.
+	oldest := fasthttp.AcquireCookie()
+	oldest.SetKey("oldest")
+	oldest.SetValue("v")
+	oldest.SetExpire(fasthttp.CookieExpireUnlimited)
+	jar.hostCookies[host] = append(jar.hostCookies[host],
+		storedCookie{cookie: oldest, seq: jar.nextSeqLocked(), isHostOnly: true})
+
+	// Fill past the ceiling with already-expired cookies.
+	for i := range maxCookiesPerHost {
+		c := fasthttp.AcquireCookie()
+		c.SetKey(fmt.Sprintf("dead%d", i))
+		c.SetValue("v")
+		c.SetExpire(now.Add(-time.Hour))
+		jar.hostCookies[host] = append(jar.hostCookies[host],
+			storedCookie{cookie: c, seq: jar.nextSeqLocked(), isHostOnly: true})
+	}
+	require.Greater(t, len(jar.hostCookies[host]), maxCookiesPerHost)
+
+	jar.enforceHostCookieLimitLocked(host)
+
+	// Every expired entry is gone and the single live one survived, even though
+	// it was written first.
+	require.Len(t, jar.hostCookies[host], 1)
+	require.Equal(t, "oldest", string(jar.hostCookies[host][0].cookie.Key()))
+}
+
+// Test_CookieJar_PerHostEvictionDropsEmptyKey covers the case where dropping
+// expired entries leaves nothing behind: the storage key must be deleted rather
+// than left mapped to an empty slice, which would keep an entry in hostCookies
+// forever and count against the jar's host ceiling.
+func Test_CookieJar_PerHostEvictionDropsEmptyKey(t *testing.T) {
+	t.Parallel()
+
+	const host = "example.com"
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+	jar.hostCookies = make(map[string][]storedCookie)
+
+	past := time.Now().Add(-time.Hour)
+	for i := range maxCookiesPerHost + 1 {
+		c := fasthttp.AcquireCookie()
+		c.SetKey(fmt.Sprintf("dead%d", i))
+		c.SetValue("v")
+		c.SetExpire(past)
+		jar.hostCookies[host] = append(jar.hostCookies[host],
+			storedCookie{cookie: c, seq: jar.nextSeqLocked(), isHostOnly: true})
+	}
+
+	jar.enforceHostCookieLimitLocked(host)
+
+	_, ok := jar.hostCookies[host]
+	require.False(t, ok, "a host left with no live cookies must be removed from the map")
+}
+
+// Test_CookieJar_PerHostEvictionDropsLeastRecentlyWritten covers the other half:
+// with nothing expired, the entries evicted are the ones written longest ago,
+// and re-writing a cookie refreshes its recency.
+func Test_CookieJar_PerHostEvictionDropsLeastRecentlyWritten(t *testing.T) {
+	t.Parallel()
+
+	const host = "example.com"
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	// Fill the host to exactly its ceiling, each cookie on its own path so they
+	// are distinct entries rather than replacements.
+	for i := range maxCookiesPerHost {
+		c := fasthttp.AcquireCookie()
+		require.NoError(t, c.ParseBytes(fmt.Appendf(nil, "k%d=v; path=/p%d", i, i)))
+		jar.SetByHost([]byte(host), c)
+		fasthttp.ReleaseCookie(c)
+	}
+	require.Len(t, jar.hostCookies[host], maxCookiesPerHost)
+
+	// Re-write the very first cookie so it becomes the most recently written.
+	refreshed := fasthttp.AcquireCookie()
+	require.NoError(t, refreshed.ParseBytes([]byte("k0=v2; path=/p0")))
+	jar.SetByHost([]byte(host), refreshed)
+	fasthttp.ReleaseCookie(refreshed)
+	require.Len(t, jar.hostCookies[host], maxCookiesPerHost, "a re-write must replace, not grow")
+
+	// Now push one more distinct cookie in, forcing a single eviction.
+	extra := fasthttp.AcquireCookie()
+	require.NoError(t, extra.ParseBytes([]byte("extra=v; path=/extra")))
+	jar.SetByHost([]byte(host), extra)
+	fasthttp.ReleaseCookie(extra)
+
+	require.Len(t, jar.hostCookies[host], maxCookiesPerHost)
+
+	names := make(map[string]string, maxCookiesPerHost)
+	for _, sc := range jar.hostCookies[host] {
+		names[string(sc.cookie.Key())] = string(sc.cookie.Value())
+	}
+	require.Contains(t, names, "extra", "the newest cookie must be kept")
+	require.Contains(t, names, "k0", "the refreshed cookie must survive on recency")
+	require.Equal(t, "v2", names["k0"], "and it must hold the re-written value")
+	require.NotContains(t, names, "k1", "the least recently written cookie is the victim")
+}
+
+// Test_CookieJar_RelativePathUsesDefaultPath covers RFC 6265 Section 5.2.4:
+// a Path attribute that does not begin with "/" is unusable and must fall back
+// to the default-path. fasthttp's ParseBytes stores such a value verbatim, so
+// without the fallback the cookie could never match any request path while
+// still occupying one of the per-host slots.
+func Test_CookieJar_RelativePathUsesDefaultPath(t *testing.T) {
+	t.Parallel()
+
+	for _, attr := range []string{"admin", "./admin", "../admin"} {
+		t.Run(attr, func(t *testing.T) {
+			t.Parallel()
+
+			jar := AcquireCookieJar()
+			defer ReleaseCookieJar(jar)
+
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseResponse(resp)
+			resp.Header.Add("Set-Cookie", "a=1; Path="+attr)
+			jar.parseCookiesFromResp([]byte("example.com"), []byte("/dir/page"), resp)
+
+			require.Equal(t, "a=1", cookieHeaderFor(jar, "http://example.com/dir/x"))
+			require.Empty(t, cookieHeaderFor(jar, "http://example.com/other"))
+		})
+	}
+}
+
+// Test_CookieJar_EvictsLeastRecentlyWritten checks that a cookie the server
+// keeps refreshing survives eviction pressure from one-off cookies, which is
+// exactly the pressure default-path scoping creates.
+func Test_CookieJar_EvictsLeastRecentlyWritten(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	setCookie := func(path, header string) {
+		resp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(resp)
+		resp.Header.Add("Set-Cookie", header)
+		jar.parseCookiesFromResp([]byte("example.com"), []byte(path), resp)
+	}
+
+	setCookie("/login", "session=SECRET; Path=/")
+	for i := range maxCookiesPerHost * 2 {
+		// Each directory mints its own entry for the same cookie name.
+		setCookie(fmt.Sprintf("/page/%d/x", i), "pref=1")
+		// The server re-sends the session cookie on every response.
+		setCookie("/login", "session=SECRET; Path=/")
+	}
+
+	require.LessOrEqual(t, len(jar.hostCookies["example.com"]), maxCookiesPerHost)
+	require.Equal(t, "session=SECRET", cookieHeaderFor(jar, "http://example.com/account"))
+}
+
+// Test_CookieJar_BoundsCookiesPerRequest checks the ceiling on what one
+// request carries. The per-key cap alone does not bound it: a host-only cookie
+// plus one Domain= cookie per parent label live under different keys and all
+// domain-match the same request, so a host deep in a DNS tree could otherwise
+// multiply its allowance by its label count.
+func Test_CookieJar_BoundsCookiesPerRequest(t *testing.T) {
+	t.Parallel()
+
+	jar := AcquireCookieJar()
+	defer ReleaseCookieJar(jar)
+
+	const host = "a.b.c.d.example.com"
+	for _, domain := range []string{"", "b.c.d.example.com", "c.d.example.com", "d.example.com", "example.com"} {
+		for i := range maxCookiesPerHost * 2 {
+			resp := fasthttp.AcquireResponse()
+			attr := fmt.Sprintf("c%d_%d=v; Path=/", len(domain), i)
+			if domain != "" {
+				attr += "; Domain=" + domain
+			}
+			resp.Header.Add("Set-Cookie", attr)
+			jar.parseCookiesFromResp([]byte(host), []byte("/"), resp)
+			fasthttp.ReleaseResponse(resp)
+		}
+	}
+
+	// The cap belongs to the wire, so it is the request that must be bounded.
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.SetRequestURI("http://" + host + "/")
+	jar.dumpCookiesToReq(req)
+
+	written := 0
+	for range req.Header.Cookies() {
+		written++
+	}
+	require.LessOrEqual(t, written, maxCookiesPerRequest)
+	require.NotZero(t, written, "the request should still carry cookies")
+
+	// Get is a storage query, not a wire operation: it must report every stored
+	// cookie matching the URI, well past maxCookiesPerRequest. Capping it there
+	// silently hid cookies that remain in the jar.
+	uri := fasthttp.AcquireURI()
+	defer fasthttp.ReleaseURI(uri)
+	require.NoError(t, uri.Parse(nil, []byte("http://"+host+"/")))
+
+	got := jar.Get(uri)
+	require.Greater(t, len(got), maxCookiesPerRequest,
+		"Get must not apply the per-request wire cap")
+	for _, c := range got {
+		fasthttp.ReleaseCookie(c)
+	}
+}
diff --git a/ctx_test.go b/ctx_test.go
index 8624bb71742..6f28f2167e2 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -10556,3 +10556,51 @@ func Benchmark_Ctx_OverrideParam(b *testing.B) {
 		c.OverrideParam("name", "changed")
 	}
 }
+
+// Test_Ctx_Cookie_DoesNotMutateArgument verifies that Cookie treats its
+// argument as read-only, so a caller can reuse the same *Cookie template
+// across requests without the normalization leaking back into it.
+//
+// Note the deliberate absence of Partitioned: fasthttp's SetPartitioned also
+// forces path=/ and secure, so a partitioned cookie would satisfy the emitted
+// header assertions below even if the normalization were removed entirely.
+func Test_Ctx_Cookie_DoesNotMutateArgument(t *testing.T) {
+	t.Parallel()
+	app := New()
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+	tmpl := &Cookie{
+		Name:        "session",
+		Value:       "v",
+		SameSite:    CookieSameSiteNoneMode,
+		SessionOnly: true,
+		MaxAge:      60,
+		Expires:     time.Now().Add(time.Hour),
+	}
+	before := *tmpl
+
+	c.Cookie(tmpl)
+
+	require.Equal(t, before, *tmpl, "Cookie must not mutate the caller's struct")
+	require.Empty(t, tmpl.Path)
+	require.False(t, tmpl.Secure)
+	require.Equal(t, 60, tmpl.MaxAge)
+
+	// The emitted cookie still carries the normalized attributes. These are
+	// regression guards, not proof of the normalization: fasthttp defaults an
+	// empty path to "/" and forces Secure for SameSite=None on its own, so
+	// they would hold even without it. The require.Equal above is the
+	// assertion that actually pins this method's contract.
+	header := string(c.Response().Header.Peek(HeaderSetCookie))
+	require.Contains(t, header, "path=/")
+	require.Contains(t, header, "secure")
+	require.Contains(t, header, "SameSite=None")
+	require.NotContains(t, header, "max-age=")
+
+	// Partitioned is normalized on the copy too; assert on the struct rather
+	// than the header, since fasthttp sets Secure and Path for it anyway.
+	part := &Cookie{Name: "p", Value: "v", Path: "/scoped", Partitioned: true}
+	c.Cookie(part)
+	require.False(t, part.Secure, "Partitioned must not write Secure back to the caller")
+	require.Equal(t, "/scoped", part.Path)
+}
diff --git a/helpers_test.go b/helpers_test.go
index 19bec65f6bc..78cda93e1bf 100644
--- a/helpers_test.go
+++ b/helpers_test.go
@@ -1929,3 +1929,85 @@ func Test_appendLowerASCII(t *testing.T) {
 		})
 	}
 }
+
+// Test_normalizeContentTypeMediaType pins the RFC 9110 case rules the
+// Content-Type normalizer implements: the media type (Section 8.3.1) and each
+// parameter name (Section 5.6.6) are case-insensitive and get folded, while
+// parameter values are left byte-for-byte alone. Folding a value would corrupt
+// a multipart boundary, which is case-sensitive.
+func Test_normalizeContentTypeMediaType(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		name string
+		in   string
+		want string
+	}{
+		{name: "no parameters", in: "Application/JSON", want: "application/json"},
+		{name: "already lower", in: "application/json", want: "application/json"},
+		{name: "empty", in: "", want: ""},
+		{
+			name: "parameter name folded, value preserved",
+			in:   "Multipart/Form-Data; BOUNDARY=AbC123",
+			want: "multipart/form-data; boundary=AbC123",
+		},
+		{
+			name: "whitespace after the semicolon",
+			in:   "Text/Plain;\t CHARSET=UTF-8",
+			want: "text/plain;\t charset=UTF-8",
+		},
+		{
+			name: "several parameters",
+			in:   "Text/Plain; CHARSET=UTF-8; Format=Flowed",
+			want: "text/plain; charset=UTF-8; format=Flowed",
+		},
+		{
+			// A quoted-string may itself contain ';', so it must be consumed as
+			// a unit or the next parameter name would be mislocated.
+			name: "semicolon inside a quoted value",
+			in:   `Text/Plain; NAME="a;B"; Charset=UTF-8`,
+			want: `text/plain; name="a;B"; charset=UTF-8`,
+		},
+		{
+			name: "escaped quote inside a quoted value",
+			in:   `Text/Plain; NAME="a\"; B"; Charset=UTF-8`,
+			want: `text/plain; name="a\"; B"; charset=UTF-8`,
+		},
+		{
+			name: "unterminated quoted value",
+			in:   `Text/Plain; NAME="abc`,
+			want: `text/plain; name="abc`,
+		},
+		{
+			// A bare parameter with no '=' must not swallow what follows it.
+			name: "valueless parameter",
+			in:   "Text/Plain; FLAG; CHARSET=UTF-8",
+			want: "text/plain; flag; charset=UTF-8",
+		},
+		{
+			name: "trailing semicolon",
+			in:   "Text/Plain;",
+			want: "text/plain;",
+		},
+		{
+			name: "empty parameter between semicolons",
+			in:   "Text/Plain;; CHARSET=UTF-8",
+			want: "text/plain;; charset=UTF-8",
+		},
+	}
+
+	for _, tc := range testCases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			h := &fasthttp.RequestHeader{}
+			h.SetContentType(tc.in)
+
+			require.Equal(t, tc.want, string(normalizeContentTypeMediaType(h)))
+			// The fold is in place, so the header itself must now read back
+			// normalized — that is what makes fasthttp's case-sensitive
+			// multipart lookups work.
+			require.Equal(t, tc.want, string(h.ContentType()))
+		})
+	}
+}
diff --git a/internal/logtemplate/sanitize_test.go b/internal/logtemplate/sanitize_test.go
new file mode 100644
index 00000000000..d79078c7635
--- /dev/null
+++ b/internal/logtemplate/sanitize_test.go
@@ -0,0 +1,200 @@
+package logtemplate
+
+import (
+	"bytes"
+	"math/rand"
+	"strings"
+	"testing"
+
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/bytebufferpool"
+)
+
+// referenceIndexControlByte is the obvious scalar implementation the SWAR scan
+// must agree with.
+func referenceIndexControlByte(s string) int {
+	for i := 0; i < len(s); i++ {
+		if s[i] == '\t' {
+			continue
+		}
+		if s[i] < 0x20 || s[i] == 0x7f {
+			return i
+		}
+	}
+	return -1
+}
+
+func Test_IsControlByte(t *testing.T) {
+	t.Parallel()
+
+	for b := range 256 {
+		want := (b < 0x20 || b == 0x7f) && b != '\t'
+		require.Equal(t, want, IsControlByte(byte(b)), "byte 0x%02x", b)
+	}
+}
+
+// Test_IndexControlByte_MatchesReference walks every length across the SWAR
+// boundaries (the 8-byte main loop, the overlapping tail word, and the
+// byte-wise path for short inputs) with the control byte at every position.
+func Test_IndexControlByte_MatchesReference(t *testing.T) {
+	t.Parallel()
+
+	const clean = "abcdefghijklmnopqrstuvwxyz0123456789"
+	for n := range 25 {
+		base := clean[:n]
+		require.Equal(t, referenceIndexControlByte(base), IndexControlByte(base), "clean n=%d", n)
+
+		for pos := range n {
+			for _, bad := range []byte{0x00, '\n', '\r', 0x1f, 0x7f} {
+				b := []byte(base)
+				b[pos] = bad
+				s := string(b)
+				require.Equal(t, referenceIndexControlByte(s), IndexControlByte(s),
+					"n=%d pos=%d byte=0x%02x", n, pos, bad)
+				require.Equal(t, referenceIndexControlByte(s), IndexControlByte([]byte(s)),
+					"[]byte n=%d pos=%d byte=0x%02x", n, pos, bad)
+			}
+		}
+	}
+}
+
+// Test_IndexControlByte_HighBytesAreNotControls guards the SWAR range mask
+// against matching bytes >= 0x80, which would corrupt UTF-8 in log lines: the
+// C1 range 0x80-0x9f looks like a control range to a naive comparison.
+func Test_IndexControlByte_HighBytesAreNotControls(t *testing.T) {
+	t.Parallel()
+
+	for n := 1; n <= 20; n++ {
+		for pos := range n {
+			for _, high := range []byte{0x80, 0x9f, 0xc3, 0xff} {
+				b := bytes.Repeat([]byte("x"), n)
+				b[pos] = high
+				require.Equal(t, -1, IndexControlByte(string(b)),
+					"n=%d pos=%d byte=0x%02x must not be treated as a control", n, pos, high)
+			}
+		}
+	}
+
+	require.Equal(t, -1, IndexControlByte("héllo wörld — ünïcode"))
+}
+
+func Test_IndexControlByte_Randomized(t *testing.T) {
+	t.Parallel()
+
+	rng := rand.New(rand.NewSource(1))
+	for range 20000 {
+		b := make([]byte, rng.Intn(40))
+		for i := range b {
+			b[i] = byte(rng.Intn(256))
+		}
+		s := string(b)
+		require.Equal(t, referenceIndexControlByte(s), IndexControlByte(s), "input %q", s)
+	}
+}
+
+func Test_ScrubControls(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name string
+		in   string
+		want string
+	}{
+		{name: "crlf", in: "a\r\nb", want: "a  b"},
+		{name: "nul", in: "a\x00b", want: "a b"},
+		{name: "del", in: "a\x7fb", want: "a b"},
+		{name: "tab preserved", in: "a\tb", want: "a\tb"},
+		{name: "esc", in: "a\x1b[31mb", want: "a [31mb"},
+		{name: "leading", in: "\nabc", want: " abc"},
+		{name: "trailing", in: "abc\n", want: "abc "},
+		{name: "utf8 untouched", in: "héllo\nwörld", want: "héllo wörld"},
+		{name: "long multiword", in: strings.Repeat("abcdefgh", 3) + "\n" + strings.Repeat("x", 9), want: strings.Repeat("abcdefgh", 3) + " " + strings.Repeat("x", 9)},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			t.Parallel()
+
+			idx := IndexControlByte(tt.in)
+			require.Equal(t, referenceIndexControlByte(tt.in), idx)
+			if idx == -1 {
+				require.Equal(t, tt.want, tt.in)
+				return
+			}
+			require.Equal(t, tt.want, string(ScrubControls(tt.in, idx)))
+			require.Equal(t, tt.want, string(ScrubControls([]byte(tt.in), idx)))
+		})
+	}
+}
+
+// Test_ScrubControls_LeavesNoControlByte is the property that actually matters
+// for log injection: whatever comes out must contain no control byte at all.
+func Test_ScrubControls_LeavesNoControlByte(t *testing.T) {
+	t.Parallel()
+
+	rng := rand.New(rand.NewSource(2))
+	for range 20000 {
+		b := make([]byte, rng.Intn(40))
+		for i := range b {
+			b[i] = byte(rng.Intn(256))
+		}
+		s := string(b)
+		idx := IndexControlByte(s)
+		if idx == -1 {
+			continue
+		}
+		out := ScrubControls(s, idx)
+		require.Len(t, out, len(s), "scrub must preserve length")
+		require.Equal(t, -1, IndexControlByte(out), "control byte survived in %q", out)
+	}
+}
+
+func Test_WriteSanitized(t *testing.T) {
+	t.Parallel()
+
+	buf := bytebufferpool.Get()
+	defer bytebufferpool.Put(buf)
+
+	n, err := WriteSanitizedString(buf, "clean")
+	require.NoError(t, err)
+	require.Equal(t, 5, n)
+
+	buf.Reset()
+	n, err = WriteSanitizedString(buf, "a\r\nb")
+	require.NoError(t, err)
+	require.Equal(t, 4, n)
+	require.Equal(t, "a  b", buf.String())
+
+	buf.Reset()
+	n, err = WriteSanitized(buf, []byte("a\nb"))
+	require.NoError(t, err)
+	require.Equal(t, 3, n)
+	require.Equal(t, "a b", buf.String())
+
+	// The []byte variant's clean fast path forwards straight to Write without
+	// copying, so it needs its own case: the dirty case above exercises a
+	// different branch entirely.
+	buf.Reset()
+	n, err = WriteSanitized(buf, []byte("clean\tbytes"))
+	require.NoError(t, err)
+	require.Equal(t, 11, n)
+	require.Equal(t, "clean\tbytes", buf.String(), "tab must survive and nothing else may change")
+
+	// Empty input takes the same fast path and must not panic.
+	buf.Reset()
+	n, err = WriteSanitized(buf, nil)
+	require.NoError(t, err)
+	require.Zero(t, n)
+}
+
+// Test_ScrubControls_NegativeIndex covers the clamp documented on ScrubControls:
+// callers may pass IndexControlByte's -1 straight through, so a negative index
+// must scan from the start rather than panicking.
+func Test_ScrubControls_NegativeIndex(t *testing.T) {
+	t.Parallel()
+
+	require.Equal(t, "a b", string(ScrubControls("a\nb", -1)),
+		"a negative index must be clamped to 0, not panic")
+	require.Equal(t, "clean", string(ScrubControls("clean", IndexControlByte("clean"))),
+		"ScrubControls(s, IndexControlByte(s)) must be safe on clean input")
+}
diff --git a/middleware/basicauth/basicauth_test.go b/middleware/basicauth/basicauth_test.go
index d82704b0a74..d9306bb707d 100644
--- a/middleware/basicauth/basicauth_test.go
+++ b/middleware/basicauth/basicauth_test.go
@@ -800,3 +800,58 @@ func Benchmark_containsCTL(b *testing.B) {
 	}
 	_ = got
 }
+
+// Test_BasicAuth_RejectsWrongDigestLength ensures a prefixed hash whose
+// decoded digest has the wrong size is rejected at construction time instead
+// of being accepted as a verifier that can never match.
+func Test_BasicAuth_RejectsWrongDigestLength(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		wantErr error
+		name    string
+		hash    string
+	}{
+		{
+			name:    "sha256 too short",
+			hash:    "{SHA256}" + base64.StdEncoding.EncodeToString([]byte("short")),
+			wantErr: ErrInvalidSHA256PasswordLength,
+		},
+		{
+			name:    "sha512 too short",
+			hash:    "{SHA512}" + base64.StdEncoding.EncodeToString([]byte("short")),
+			wantErr: ErrInvalidSHA512PasswordLength,
+		},
+		{
+			name:    "sha512 holds a sha256 digest",
+			hash:    "{SHA512}" + base64.StdEncoding.EncodeToString(sha256Sum("hello")),
+			wantErr: ErrInvalidSHA512PasswordLength,
+		},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			t.Parallel()
+			_, _, err := buildVerifiers(map[string]string{"john": tt.hash})
+			require.ErrorIs(t, err, tt.wantErr)
+		})
+	}
+
+	// A correctly sized digest still builds and verifies.
+	verifiers, _, err := buildVerifiers(map[string]string{
+		"john": "{SHA512}" + base64.StdEncoding.EncodeToString(sha512Sum("doe")),
+	})
+	require.NoError(t, err)
+	require.True(t, verifiers["john"]("doe"))
+	require.False(t, verifiers["john"]("nope"))
+}
+
+func sha256Sum(s string) []byte {
+	sum := sha256.Sum256([]byte(s))
+	return sum[:]
+}
+
+func sha512Sum(s string) []byte {
+	sum := sha512.Sum512([]byte(s))
+	return sum[:]
+}
diff --git a/middleware/expvar/expvar_test.go b/middleware/expvar/expvar_test.go
index ddc01fdd8cd..34c05f7a855 100644
--- a/middleware/expvar/expvar_test.go
+++ b/middleware/expvar/expvar_test.go
@@ -102,3 +102,24 @@ func Test_Expvar_Next(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, 404, resp.StatusCode)
 }
+
+// Test_Expvar_Sibling_Prefix_Path ensures a route that merely starts with the
+// same characters as /debug/vars is not swallowed by the middleware.
+func Test_Expvar_Sibling_Prefix_Path(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+
+	app.Use(New())
+
+	app.Get("/debug/varsdump", func(c fiber.Ctx) error {
+		return c.SendString("app route")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/debug/varsdump", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "app route", string(body))
+}
diff --git a/middleware/logger/logger_test.go b/middleware/logger/logger_test.go
index 13f98b26972..37ac00c2bf3 100644
--- a/middleware/logger/logger_test.go
+++ b/middleware/logger/logger_test.go
@@ -14,6 +14,7 @@ import (
 	"regexp"
 	"runtime"
 	"strconv"
+	"strings"
 	"sync"
 	"sync/atomic"
 	"testing"
@@ -1741,3 +1742,289 @@ func Benchmark_Logger_Parallel(b *testing.B) {
 		benchmarkSetupParallel(bb, app, "/")
 	})
 }
+
+// failingBuffer is a Buffer whose WriteString starts failing after failAfter
+// successful calls, so the error paths of writeSanitizedColored can be reached
+// without a real failing sink.
+type failingBuffer struct {
+	*bytebufferpool.ByteBuffer
+	failAfter int
+	calls     int
+}
+
+var errWriteFailed = errors.New("write failed")
+
+func (b *failingBuffer) WriteString(s string) (int, error) {
+	if b.calls >= b.failAfter {
+		return 0, errWriteFailed
+	}
+	b.calls++
+	n, err := b.ByteBuffer.WriteString(s)
+	if err != nil {
+		return n, fmt.Errorf("failingBuffer write string: %w", err)
+	}
+	return n, nil
+}
+
+func (b *failingBuffer) Write(p []byte) (int, error) {
+	if b.calls >= b.failAfter {
+		return 0, errWriteFailed
+	}
+	b.calls++
+	n, err := b.ByteBuffer.Write(p)
+	if err != nil {
+		return n, fmt.Errorf("failingBuffer write: %w", err)
+	}
+	return n, nil
+}
+
+// Test_writeSanitizedColored_PropagatesWriteErrors pins the short-circuits in
+// writeSanitizedColored. A sink that fails partway must stop the sequence and
+// surface the error rather than writing a reset escape with no matching color
+// (or silently dropping the failure), and the byte count returned must reflect
+// only what actually reached the sink.
+func Test_writeSanitizedColored_PropagatesWriteErrors(t *testing.T) {
+	t.Parallel()
+
+	const color, value, reset = "<c>", "va\nlue", "<r>"
+
+	t.Run("color write fails", func(t *testing.T) {
+		t.Parallel()
+
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 0}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := writeSanitizedColored(buf, color, value, reset)
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Zero(t, n)
+		require.Empty(t, buf.String(), "nothing may reach the sink once the color fails")
+	})
+
+	t.Run("value write fails", func(t *testing.T) {
+		t.Parallel()
+
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 1}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := writeSanitizedColored(buf, color, value, reset)
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Equal(t, len(color), n, "only the color made it out")
+		require.Equal(t, color, buf.String(), "the reset must not be written after a failure")
+	})
+
+	t.Run("reset write fails", func(t *testing.T) {
+		t.Parallel()
+
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 2}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := writeSanitizedColored(buf, color, value, reset)
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Equal(t, len(color)+len(value), n, "the color and value made it out, the reset did not")
+		require.Equal(t, "<c>va lue", buf.String())
+	})
+
+	t.Run("all writes succeed", func(t *testing.T) {
+		t.Parallel()
+
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 99}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := writeSanitizedColored(buf, color, value, reset)
+		require.NoError(t, err)
+		require.Equal(t, len(color)+len(value)+len(reset), n)
+		require.Equal(t, "<c>va lue<r>", buf.String(),
+			"the value is scrubbed but the color escapes pass through verbatim")
+	})
+}
+
+// Test_Logger_SanitizesLocalsByType covers each arm of ${locals:}'s type
+// switch. The []byte arm has its own scrubbing call, so a []byte local carrying
+// CR/LF must be scrubbed just like the string one — otherwise a handler
+// stashing raw request bytes in Locals would reopen the injection this scrubs.
+func Test_Logger_SanitizesLocalsByType(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		value    any
+		name     string
+		expected string
+	}{
+		{name: "bytes", value: []byte("a\r\nb"), expected: "a  b"},
+		{name: "string", value: "a\r\nb", expected: "a  b"},
+		{name: "nil", value: nil, expected: ""},
+		{name: "other", value: struct{ V string }{"a\r\nb"}, expected: "{a  b}"},
+	}
+
+	for _, tc := range testCases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			buf := bytebufferpool.Get()
+			defer bytebufferpool.Put(buf)
+
+			app := fiber.New()
+			app.Use(New(Config{Format: "${locals:demo}", Stream: buf}))
+			app.Get("/", func(c fiber.Ctx) error {
+				if tc.value != nil {
+					c.Locals("demo", tc.value)
+				}
+				return c.SendStatus(fiber.StatusOK)
+			})
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+			require.Equal(t, tc.expected, buf.String())
+		})
+	}
+}
+
+// Test_Logger_SanitizesControlBytes ensures user-controlled values cannot
+// inject CR/LF (or other C0/DEL bytes) into a log line and forge log entries.
+// See https://github.com/gofiber/fiber/issues/4341.
+func Test_Logger_SanitizesControlBytes(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name     string
+		format   string
+		build    func() *http.Request
+		expected string
+	}{
+		{
+			name:   "query",
+			format: "${query:q}",
+			build: func() *http.Request {
+				return httptest.NewRequest(fiber.MethodGet, "/?q=a%0d%0a200+GET+/legit", http.NoBody)
+			},
+			expected: "a  200 GET /legit",
+		},
+		{
+			name:   "body",
+			format: "${body}",
+			build: func() *http.Request {
+				req := httptest.NewRequest(fiber.MethodPost, "/", strings.NewReader("a\r\nb\x00c"))
+				req.Header.Set(fiber.HeaderContentType, fiber.MIMETextPlain)
+				return req
+			},
+			expected: "a  b c",
+		},
+		{
+			name:   "tab is preserved",
+			format: "${query:q}",
+			build: func() *http.Request {
+				return httptest.NewRequest(fiber.MethodGet, "/?q=a%09b", http.NoBody)
+			},
+			expected: "a\tb",
+		},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			t.Parallel()
+
+			buf := bytebufferpool.Get()
+			defer bytebufferpool.Put(buf)
+
+			app := fiber.New()
+			app.Use(New(Config{Format: tt.format, Stream: buf}))
+			app.Add([]string{fiber.MethodGet, fiber.MethodPost}, "/", func(c fiber.Ctx) error {
+				return c.SendString("ok")
+			})
+
+			_, err := app.Test(tt.build())
+			require.NoError(t, err)
+			require.Equal(t, tt.expected, buf.String())
+		})
+	}
+}
+
+// Test_Logger_SanitizesPath covers the decoded-path case: with UnescapePath
+// enabled c.Path() carries the percent-decoded bytes, so ${path} would
+// otherwise emit raw CRLF.
+func Test_Logger_SanitizesPath(t *testing.T) {
+	t.Parallel()
+
+	buf := bytebufferpool.Get()
+	defer bytebufferpool.Put(buf)
+
+	app := fiber.New(fiber.Config{UnescapePath: true})
+	app.Use(New(Config{Format: "${path}", Stream: buf}))
+
+	_, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/admin%0d%0a200", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, "/admin  200", buf.String())
+}
+
+// Test_Logger_DefaultFormat_SanitizesControlBytes covers the default logger
+// configuration, which takes defaultLoggerInstance's hand-written fast path
+// instead of the tag map. Without scrubbing there, plain logger.New() — by far
+// the most common setup — still lets a request forge extra log lines (#4341).
+func Test_Logger_DefaultFormat_SanitizesControlBytes(t *testing.T) {
+	t.Parallel()
+
+	for _, colors := range []bool{false, true} {
+		t.Run(fmt.Sprintf("colors=%v", colors), func(t *testing.T) {
+			t.Parallel()
+
+			buf := bytebufferpool.Get()
+			defer bytebufferpool.Put(buf)
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			cfg := Config{Stream: buf}
+			if colors {
+				cfg.ForceColors = true
+			} else {
+				cfg.DisableColors = true
+			}
+			app.Use(New(cfg))
+			app.Get("/*", func(_ fiber.Ctx) error {
+				return errors.New("boom\r\nFORGED-ERROR-LINE")
+			})
+
+			_, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/admin%0d%0aFORGED-PATH-LINE", http.NoBody))
+			require.NoError(t, err)
+
+			out := buf.String()
+			require.NotContains(t, out, "\r")
+			require.Equal(t, 1, strings.Count(out, "\n"), "log entry must stay on one line: %q", out)
+			require.Contains(t, out, "FORGED-PATH-LINE")
+			require.Contains(t, out, "FORGED-ERROR-LINE")
+		})
+	}
+}
+
+// Test_SanitizeValue covers the exported helper the docs point custom tags,
+// context tags and LoggerFunc implementations at. It has to apply exactly what
+// the built-in tags apply, or the guidance is wrong.
+func Test_SanitizeValue(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		name string
+		in   string
+		want string
+	}{
+		{name: "clean passes through", in: "plain-value", want: "plain-value"},
+		{name: "empty", in: "", want: ""},
+		{name: "CRLF is neutralized", in: "a\r\nb", want: "a  b"},
+		{name: "tab is preserved", in: "a\tb", want: "a\tb"},
+		{name: "NUL and DEL", in: "a\x00b\x7fc", want: "a b c"},
+		{name: "escape sequence", in: "a\x1b[31mb", want: "a [31mb"},
+		// Documented limitation: only ASCII controls are replaced, so C1
+		// controls (including NEL U+0085) survive.
+		{name: "C1 NEL passes through", in: "a\u0085b", want: "a\u0085b"},
+		{name: "multibyte is untouched", in: "h\u00e9llo", want: "h\u00e9llo"},
+	}
+
+	for _, tc := range testCases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, SanitizeValue(tc.in))
+			// The exported helper must not diverge from the internal one the
+			// built-in tags use.
+			require.Equal(t, sanitizeLogValue(tc.in), SanitizeValue(tc.in))
+		})
+	}
+}
diff --git a/middleware/pprof/pprof_test.go b/middleware/pprof/pprof_test.go
index b8149e07068..9640d816e04 100644
--- a/middleware/pprof/pprof_test.go
+++ b/middleware/pprof/pprof_test.go
@@ -225,3 +225,24 @@ func Test_Pprof_Next_WithPrefix(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, 404, resp.StatusCode)
 }
+
+// Test_Pprof_Sibling_Prefix_Path ensures a route that merely starts with the
+// same characters as /debug/pprof is not swallowed by the middleware.
+func Test_Pprof_Sibling_Prefix_Path(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+
+	app.Use(New())
+
+	app.Get("/debug/pprofiler", func(c fiber.Ctx) error {
+		return c.SendString("app route")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/debug/pprofiler", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "app route", string(body))
+}
diff --git a/path_test.go b/path_test.go
index 62c5fc2004d..92790642118 100644
--- a/path_test.go
+++ b/path_test.go
@@ -917,6 +917,36 @@ func Test_RegexHandler_NilReturnPanics(t *testing.T) {
 }
 
 // Test_RoutePatternMatch_InvalidRegexHandlerPanics verifies RoutePatternMatch also validates RegexHandler configuration.
+// Test_RoutePatternMatch_NormalizesInputs covers the guards that run before any
+// parsing: an empty path and an empty or slash-less pattern are all coerced to
+// the forms the router itself registers, so callers do not have to pre-normalize.
+func Test_RoutePatternMatch_NormalizesInputs(t *testing.T) {
+	t.Parallel()
+
+	testCases := []struct {
+		name    string
+		path    string
+		pattern string
+		want    bool
+	}{
+		{name: "empty pattern becomes root", path: "/", pattern: "", want: true},
+		{name: "empty pattern does not match a child", path: "/a", pattern: "", want: false},
+		{name: "empty path becomes root", path: "", pattern: "/", want: true},
+		{name: "both empty", path: "", pattern: "", want: true},
+		{name: "pattern gains a leading slash", path: "/a", pattern: "a", want: true},
+		{name: "slash-less pattern with a param", path: "/1", pattern: ":id", want: true},
+		{name: "slash-less pattern that should not match", path: "/b", pattern: "a", want: false},
+	}
+
+	for _, tc := range testCases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, RoutePatternMatch(tc.path, tc.pattern),
+				"path=%q pattern=%q", tc.path, tc.pattern)
+		})
+	}
+}
+
 func Test_RoutePatternMatch_InvalidRegexHandlerPanics(t *testing.T) {
 	t.Parallel()
 
@@ -1041,3 +1071,64 @@ func Test_RouteParser_ConstParamFixture(t *testing.T) {
 	}
 	require.NotZero(t, checked, "fixture exercised no specialized routes")
 }
+
+// Test_RoutePatternMatch_MatchesRouter is a differential test: RoutePatternMatch
+// documents itself as "see logic in (*Route).match and (*App).register", so for
+// every pattern/path/config combination it must agree with what the router
+// actually does. It caught RoutePatternMatch trimming trailing slashes from the
+// pattern but not from the path.
+func Test_RoutePatternMatch_MatchesRouter(t *testing.T) {
+	t.Parallel()
+
+	patterns := []string{
+		"/", "/a", "/a/b", "/:id", "/a/:id", "/a/:id?", "/a/*", "/*", "/+",
+		"/a/+", "/:a/:b", "/a-:b", "/a.:b", "/:a?/b", "/api/v1/:id/x",
+		"/a/*/b", "/:id<int>", "/:id<minLen(3)>", "/a/:b?/c", "/ab/*",
+		// Case-sensitive constraints: these are evaluated against the value
+		// getMatch slices out of the untouched path, not the detection path.
+		"/:id<regex(^[a-z]+$)>", "/:id<regex(^[A-Z]+$)>", "/:id<regex(^[^a-z]+$)>",
+		"/user/:n<regex(^[A-Z][a-z]+$)>",
+		// Escaped specials: register strips the escapes before deriving the
+		// root/star flags, so the helper has to as well.
+		`/\*`, `/\:id`, `/a\-b`,
+	}
+	paths := []string{
+		"/", "/a", "/a/", "/a/b", "/a/b/", "/1", "/a/1", "/a/b/c",
+		"/a-b", "/a.b", "/b", "/api/v1/9/x", "/a/x/b", "/abc", "/ab",
+		"/a/b/c/d", "//", "/a//b", "/ab/", "/A", "/A/",
+		"/ABC", "/Abc", "/user/John", "/a%2Fb", "/a%20b", "/a%41b",
+	}
+	configs := []Config{
+		{},
+		{StrictRouting: true},
+		{CaseSensitive: true},
+		{StrictRouting: true, CaseSensitive: true},
+		{UnescapePath: true},
+		{UnescapePath: true, CaseSensitive: true},
+		{UnescapePath: true, StrictRouting: true},
+	}
+
+	for _, cfg := range configs {
+		name := fmt.Sprintf("strict=%v/casesensitive=%v/unescape=%v",
+			cfg.StrictRouting, cfg.CaseSensitive, cfg.UnescapePath)
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			for _, pattern := range patterns {
+				for _, path := range paths {
+					app := New(cfg)
+					matched := false
+					app.Get(pattern, func(_ Ctx) error {
+						matched = true
+						return nil
+					})
+
+					_, err := app.Test(httptest.NewRequest(MethodGet, path, http.NoBody))
+					require.NoError(t, err)
+
+					require.Equal(t, matched, RoutePatternMatch(path, pattern, cfg),
+						"pattern=%q path=%q", pattern, path)
+				}
+			}
+		})
+	}
+}
diff --git a/redirect_test.go b/redirect_test.go
index 9dfe08c7874..b48466f2ddd 100644
--- a/redirect_test.go
+++ b/redirect_test.go
@@ -208,7 +208,7 @@ func Test_Redirect_Back(t *testing.T) {
 
 	err = c.Redirect().Back()
 	require.Equal(t, 500, c.Response().StatusCode())
-	require.ErrorAs(t, err, &ErrRedirectBackNoFallback)
+	require.ErrorIs(t, err, ErrRedirectBackNoFallback)
 }
 
 // go test -run Test_Redirect_Back_WithFlashMessages
diff --git a/router_test.go b/router_test.go
index eef04f44aaf..ac9ded7b205 100644
--- a/router_test.go
+++ b/router_test.go
@@ -4349,3 +4349,39 @@ func Test_Route_PrefixFilter_UnconstrainedShapes(t *testing.T) {
 		require.False(t, routeFilterRejects(empty, path), "path %q", path)
 	}
 }
+
+// Test_Route_OptionalSlash_SingleCharSegment guards the tree-bucket key against
+// the optional trailing slash. A leading constant of exactly maxDetectionPaths
+// bytes ("/a/") can match a detection path one byte shorter ("/a"), and that
+// shorter path always hashes to bucket 0 — so bucketing the route under the
+// hash of the full constant made it unreachable, while the otherwise identical
+// "/ab/..." routes matched.
+func Test_Route_OptionalSlash_SingleCharSegment(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		pattern string
+		path    string
+	}{
+		{"/a/:id?", "/a"},
+		{"/a/:id?", "/a/"},
+		{"/a/:id?", "/a/1"},
+		{"/a/*", "/a"},
+		{"/a/*", "/a/"},
+		{"/a/*", "/a/b"},
+		{"/ab/:id?", "/ab"},
+		{"/ab/*", "/ab"},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.pattern+" "+tt.path, func(t *testing.T) {
+			t.Parallel()
+			app := New()
+			app.Get(tt.pattern, func(c Ctx) error { return c.SendString("ok") })
+
+			resp, err := app.Test(httptest.NewRequest(MethodGet, tt.path, http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, StatusOK, resp.StatusCode)
+		})
+	}
+}

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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path bind_test.go --path client/cookiejar_test.go --path ctx_test.go --path helpers_test.go --path internal/logtemplate/sanitize_test.go --path middleware/basicauth/basicauth_test.go --path middleware/expvar/expvar_test.go --path middleware/logger/logger_test.go --path middleware/pprof/pprof_test.go --path path_test.go --path redirect_test.go --path router_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/logtemplate ./middleware/basicauth ./middleware/expvar ./middleware/logger ./middleware/pprof')"
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path bind_test.go --path client/cookiejar_test.go --path ctx_test.go --path helpers_test.go --path internal/logtemplate/sanitize_test.go --path middleware/basicauth/basicauth_test.go --path middleware/expvar/expvar_test.go --path middleware/logger/logger_test.go --path middleware/pprof/pprof_test.go --path path_test.go --path redirect_test.go --path router_test.go --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/logtemplate ./middleware/basicauth ./middleware/expvar ./middleware/logger ./middleware/pprof')"
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
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/logtemplate ./middleware/basicauth ./middleware/expvar ./middleware/logger ./middleware/pprof' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/logtemplate ./middleware/basicauth ./middleware/expvar ./middleware/logger ./middleware/pprof' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
