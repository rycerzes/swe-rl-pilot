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
for f in app_test.go ctx_test.go helpers_test.go internal/byterange/byterange_test.go listen_test.go middleware/static/static_test.go middleware/timeout/timeout_test.go prefork_test.go; do if git cat-file -e 014cfa68cbbff281b2b53fad9138b7267f0f7a7e:"$f" 2>/dev/null; then git checkout 014cfa68cbbff281b2b53fad9138b7267f0f7a7e -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 014cfa68cbbff281b2b53fad9138b7267f0f7a7e "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/app_test.go b/app_test.go
index 8b97ba727c8..173a6eafdde 100644
--- a/app_test.go
+++ b/app_test.go
@@ -1164,6 +1164,42 @@ func Test_App_GETOnly_ErrorHandler_WithoutStatus(t *testing.T) {
 	require.Equal(t, "Method Not Allowed", string(body), "Body")
 }
 
+// RFC 9110 §15.5.6: a 405 lists the allowed methods, even when a custom
+// ErrorHandler rewrites the response.
+// go test -run Test_App_GETOnly_Allow
+func Test_App_GETOnly_Allow(t *testing.T) {
+	t.Parallel()
+
+	for name, config := range map[string]Config{
+		"default error handler": {GETOnly: true},
+		"custom error handler": {
+			GETOnly:      true,
+			ErrorHandler: func(c Ctx, err error) error { return c.SendString(err.Error()) },
+		},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New(config)
+			app.All("/", func(c Ctx) error { return c.SendString("ok") })
+
+			for _, method := range []string{MethodPost, MethodPut, MethodPatch, MethodDelete, MethodOptions} {
+				resp, err := app.Test(httptest.NewRequest(method, "/", http.NoBody))
+				require.NoError(t, err, method)
+				require.Equal(t, StatusMethodNotAllowed, resp.StatusCode, method)
+				require.Equal(t, "GET, HEAD", resp.Header.Get(HeaderAllow), method)
+			}
+
+			for _, method := range []string{MethodGet, MethodHead} {
+				resp, err := app.Test(httptest.NewRequest(method, "/", http.NoBody))
+				require.NoError(t, err, method)
+				require.Equal(t, StatusOK, resp.StatusCode, method)
+				require.Empty(t, resp.Header.Get(HeaderAllow), method)
+			}
+		})
+	}
+}
+
 func Test_App_Use_Params_Group(t *testing.T) {
 	t.Parallel()
 	app := New()
@@ -4178,3 +4214,503 @@ func Test_Domain_Use_MultiplePrefixes_MountsEachPrefix(t *testing.T) {
 		require.Equal(t, StatusOK, resp.StatusCode, "%s was not mounted", prefix)
 	}
 }
+
+// rawResponse is a response read off a test connection.
+type rawResponse struct {
+	header        http.Header
+	body          string
+	contentLength int64 // -1 when not declared
+	status        int
+	closes        bool // announced Connection: close
+	chunked       bool
+}
+
+// What a connection did once the expected responses were read.
+const (
+	connClosed = "closed" // the server closed it
+	connOpen   = "open"   // it stayed open and silent
+	connData   = "data"   // it sent more than expected
+)
+
+// startRawServer serves app on an in-memory listener until the test ends.
+func startRawServer(t *testing.T, app *App) *fasthttputil.InmemoryListener {
+	t.Helper()
+
+	return startRawServerWith(t, app, nil)
+}
+
+// startRawServerWith is startRawServer with a ListenConfig.BeforeServeFunc.
+func startRawServerWith(t *testing.T, app *App, beforeServe func(*App) error) *fasthttputil.InmemoryListener {
+	t.Helper()
+
+	ln := fasthttputil.NewInmemoryListener()
+	errCh := make(chan error, 1)
+	go func() {
+		errCh <- app.Listener(ln, ListenConfig{DisableStartupMessage: true, BeforeServeFunc: beforeServe})
+	}()
+
+	t.Cleanup(func() {
+		require.NoError(t, app.Shutdown())
+		if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
+			require.NoError(t, err)
+		}
+	})
+
+	require.Eventually(t, func() bool {
+		conn, err := ln.Dial()
+		if err != nil {
+			return false
+		}
+		return conn.Close() == nil
+	}, time.Second, 5*time.Millisecond)
+
+	return ln
+}
+
+// dialer opens connections to the server under test.
+type dialer interface {
+	Dial() (net.Conn, error)
+}
+
+// tcpDialer dials a TCP address.
+type tcpDialer string
+
+func (d tcpDialer) Dial() (net.Conn, error) {
+	conn, err := net.Dial(NetworkTCP4, string(d))
+	if err != nil {
+		return nil, fmt.Errorf("dial %s: %w", string(d), err)
+	}
+	return conn, nil
+}
+
+// rawExchange writes raw to a new connection, reads want responses and reports
+// what the connection did next.
+func rawExchange(t *testing.T, server dialer, raw string, want int) (responses []rawResponse, after string) { //nolint:nonamedreturns // gocritic's unnamedResult asks for names
+	t.Helper()
+
+	conn, err := server.Dial()
+	require.NoError(t, err)
+	t.Cleanup(func() { _ = conn.Close() }) //nolint:errcheck // usually closed by the server already
+
+	require.NoError(t, conn.SetDeadline(time.Now().Add(10*time.Second)))
+	_, err = conn.Write([]byte(raw))
+	require.NoError(t, err)
+
+	// A response to HEAD has no body, so the parser needs the method.
+	method, _, _ := strings.Cut(raw, " ")
+	request := &http.Request{Method: method}
+
+	reader := bufio.NewReader(conn)
+	for range want {
+		resp, readErr := http.ReadResponse(reader, request)
+		require.NoError(t, readErr, "reading response %d of %d", len(responses)+1, want)
+		body, readErr := io.ReadAll(resp.Body)
+		require.NoError(t, readErr)
+		require.NoError(t, resp.Body.Close())
+		responses = append(responses, rawResponse{
+			status:        resp.StatusCode,
+			header:        resp.Header,
+			body:          string(body),
+			closes:        resp.Close,
+			contentLength: resp.ContentLength,
+			chunked:       len(resp.TransferEncoding) > 0 && resp.TransferEncoding[0] == "chunked",
+		})
+	}
+
+	// A closed connection answers at once; an open one stays silent until the deadline.
+	require.NoError(t, conn.SetReadDeadline(time.Now().Add(250*time.Millisecond)))
+	if _, peekErr := reader.Peek(1); peekErr != nil {
+		switch {
+		case errors.Is(peekErr, io.EOF):
+			after = connClosed
+		case errors.Is(peekErr, fasthttputil.ErrTimeout), errors.Is(peekErr, os.ErrDeadlineExceeded):
+			after = connOpen
+		default:
+			require.NoError(t, peekErr)
+		}
+	} else {
+		after = connData
+	}
+
+	return responses, after
+}
+
+// An Accept-Encoding with no value reaches AcceptsEncodings as present but empty,
+// which wants no content coding, and is not read as an absent one, which accepts any.
+func Test_App_AcceptsEncodings_EmptyField_Request(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Get("/", func(c Ctx) error {
+		return c.SendString(c.AcceptsEncodings("br", "gzip", "identity"))
+	})
+	ln := startRawServer(t, app)
+
+	for name, tc := range map[string]struct{ field, answer string }{
+		"absent": {field: "", answer: "br"},
+		"empty":  {field: "Accept-Encoding:\r\n", answer: "identity"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			raw := "GET / HTTP/1.1\r\nHost: example.com\r\n" + tc.field + "Connection: close\r\n\r\n"
+			responses, _ := rawExchange(t, ln, raw, 1)
+			require.Equal(t, StatusOK, responses[0].status)
+			require.Equal(t, tc.answer, responses[0].body)
+		})
+	}
+}
+
+// RFC 9112 §6.1: a transfer coding the server does not understand gets a 501.
+func Test_App_TransferEncoding_Request(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Post("/", func(c Ctx) error { return c.SendString("posted") })
+	ln := startRawServer(t, app)
+
+	tests := []struct {
+		name   string
+		raw    string
+		status int
+	}{
+		{
+			name:   "unknown coding",
+			raw:    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: foo\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
+			status: StatusNotImplemented,
+		},
+		{
+			name:   "unknown coding before chunked",
+			raw:    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
+			status: StatusNotImplemented,
+		},
+		{
+			name:   "unknown coding after chunked",
+			raw:    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n",
+			status: StatusNotImplemented,
+		},
+		{
+			// HTTP/1.0 has no transfer codings.
+			name:   "HTTP/1.0 message with the field",
+			raw:    "POST / HTTP/1.0\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
+			status: StatusBadRequest,
+		},
+		{
+			name:   "repeated field",
+			raw:    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
+			status: StatusBadRequest,
+		},
+		{
+			name:   "chunked is served",
+			raw:    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
+			status: StatusOK,
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			responses, after := rawExchange(t, ln, tc.raw, 1)
+			require.Equal(t, tc.status, responses[0].status)
+			if tc.status == StatusNotImplemented {
+				// The body names the status, not the request bytes fasthttp quotes.
+				require.Equal(t, "Not Implemented", responses[0].body)
+			}
+			if tc.status != StatusOK {
+				// An unusable message leaves the connection in an unknown state.
+				require.True(t, responses[0].closes, "Connection: close expected")
+				require.Equal(t, connClosed, after)
+			}
+		})
+	}
+}
+
+// With SecureErrorLogMessage fasthttp reports every transfer-encoding fault with
+// the same error, which hides the coding: those requests stay 400.
+func Test_App_TransferEncoding_SecureErrorLogMessage(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Server().SecureErrorLogMessage = true
+	app.Post("/", func(c Ctx) error { return c.SendString("posted") })
+	ln := startRawServer(t, app)
+
+	responses, _ := rawExchange(t, ln, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: foo\r\n\r\n0\r\n\r\n", 1)
+	require.Equal(t, StatusBadRequest, responses[0].status)
+
+	responses, _ = rawExchange(t, ln, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n", 1)
+	require.Equal(t, StatusOK, responses[0].status)
+}
+
+// RFC 9112 §6.1: a request with both Content-Length and Transfer-Encoding is
+// framed by Transfer-Encoding, and the connection must close after the response.
+func Test_App_ContentLengthWithTransferEncoding_ClosesConnection(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Post("/", func(c Ctx) error { return c.SendString("first") })
+	app.Get("/second", func(c Ctx) error { return c.SendString("second") })
+	ln := startRawServer(t, app)
+
+	const (
+		second  = "GET /second HTTP/1.1\r\nHost: example.com\r\n\r\n"
+		chunked = "\r\n0\r\n\r\n"
+	)
+
+	t.Run("served by Transfer-Encoding then closed", func(t *testing.T) {
+		t.Parallel()
+
+		for name, headers := range map[string]string{
+			"Content-Length first":    "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n",
+			"Transfer-Encoding first": "Transfer-Encoding: chunked\r\nContent-Length: 4\r\n",
+			"lower-case names":        "content-length: 4\r\ntransfer-encoding: chunked\r\n",
+		} {
+			t.Run(name, func(t *testing.T) {
+				t.Parallel()
+
+				raw := "POST / HTTP/1.1\r\nHost: example.com\r\n" + headers + chunked + second
+				responses, after := rawExchange(t, ln, raw, 1)
+
+				require.Equal(t, StatusOK, responses[0].status)
+				require.Equal(t, "first", responses[0].body)
+				require.True(t, responses[0].closes, "Connection: close expected")
+				require.Equal(t, connClosed, after, "the pipelined request must not be answered")
+			})
+		}
+	})
+
+	// fasthttp ignores "identity" and frames the request by its Content-Length, so
+	// the request is served as one without the field, but it still has both.
+	t.Run("identity is ignored and still closes", func(t *testing.T) {
+		t.Parallel()
+
+		for name, headers := range map[string]string{
+			"Content-Length first":    "Content-Length: 4\r\nTransfer-Encoding: identity\r\n\r\nabcd",
+			"Transfer-Encoding first": "Transfer-Encoding: identity\r\nContent-Length: 4\r\n\r\nabcd",
+			"lower-case names":        "content-length: 4\r\ntransfer-encoding: identity\r\n\r\nabcd",
+			"empty body":              "Content-Length: 0\r\nTransfer-Encoding: identity\r\n\r\n",
+		} {
+			t.Run(name, func(t *testing.T) {
+				t.Parallel()
+
+				raw := "POST / HTTP/1.1\r\nHost: example.com\r\n" + headers + second
+				responses, after := rawExchange(t, ln, raw, 1)
+
+				require.Equal(t, StatusOK, responses[0].status)
+				require.Equal(t, "first", responses[0].body)
+				require.True(t, responses[0].closes, "Connection: close expected")
+				require.Equal(t, connClosed, after, "the pipelined request must not be answered")
+			})
+		}
+	})
+
+	// Each header alone is ordinary traffic and keeps the connection alive.
+	t.Run("one header alone keeps the connection", func(t *testing.T) {
+		t.Parallel()
+
+		for name, raw := range map[string]string{
+			"Transfer-Encoding only": "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n" + chunked + second,
+			"Content-Length only":    "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n" + second,
+		} {
+			t.Run(name, func(t *testing.T) {
+				t.Parallel()
+
+				responses, after := rawExchange(t, ln, raw, 2)
+
+				require.Equal(t, "first", responses[0].body)
+				require.Equal(t, "second", responses[1].body)
+				require.False(t, responses[1].closes, "Connection: close not expected")
+				require.Equal(t, connOpen, after)
+			})
+		}
+	})
+}
+
+// The close hook must keep the application's HeaderReceived callback and its limits,
+// whether it is set before the app starts or in ListenConfig.BeforeServeFunc, and
+// whether or not an earlier Test has already installed the hook.
+func Test_App_ContentLengthWithTransferEncoding_KeepsUserHeaderReceived(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name          string
+		inBeforeServe bool
+		testFirst     bool
+	}{
+		{name: "set before start"},
+		{name: "set in BeforeServeFunc", inBeforeServe: true},
+		{name: "set in BeforeServeFunc after Test", inBeforeServe: true, testFirst: true},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			app.Post("/", func(c Ctx) error { return c.SendString(strconv.Itoa(len(c.Body()))) })
+
+			var calls atomic.Int32
+			var chunkedSeen atomic.Bool
+			callback := func(header *fasthttp.RequestHeader) fasthttp.RequestConfig {
+				calls.Add(1)
+				if header.ContentLength() == -1 {
+					chunkedSeen.Store(true)
+				}
+				return fasthttp.RequestConfig{MaxRequestBodySize: 8}
+			}
+
+			if tc.testFirst {
+				resp, err := app.Test(httptest.NewRequest(MethodPost, "/", http.NoBody))
+				require.NoError(t, err)
+				require.NoError(t, resp.Body.Close())
+			}
+
+			var beforeServe func(*App) error
+			if tc.inBeforeServe {
+				beforeServe = func(app *App) error {
+					app.Server().HeaderReceived = callback
+					return nil
+				}
+			} else {
+				app.Server().HeaderReceived = callback
+			}
+			ln := startRawServerWith(t, app, beforeServe)
+
+			// Within the limit: served, then closed.
+			responses, after := rawExchange(t, ln,
+				"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", 1)
+			require.Equal(t, StatusOK, responses[0].status)
+			require.Equal(t, "5", responses[0].body)
+			require.True(t, responses[0].closes)
+			require.Equal(t, connClosed, after)
+
+			// Over the callback's limit: refused.
+			responses, _ = rawExchange(t, ln,
+				"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 20\r\nConnection: close\r\n\r\n01234567890123456789", 1)
+			require.Equal(t, StatusRequestEntityTooLarge, responses[0].status)
+
+			require.Equal(t, int32(2), calls.Load(), "the application's callback runs for every request")
+			require.True(t, chunkedSeen.Load(), "the callback still sees the chunked framing")
+		})
+	}
+}
+
+// The hook is installed once and a replaced callback is wrapped again.
+func Test_App_HeaderReceivedHook_Reinstalled(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.hookHeaderReceived()
+	installed := app.Server().HeaderReceived
+	require.NotNil(t, installed)
+
+	app.hookHeaderReceived()
+	require.True(t, sameFunc(app.Server().HeaderReceived, installed), "the hook is not wrapped again")
+
+	replaced := func(*fasthttp.RequestHeader) fasthttp.RequestConfig { return fasthttp.RequestConfig{} }
+	app.Server().HeaderReceived = replaced
+	app.hookHeaderReceived()
+	require.False(t, sameFunc(app.Server().HeaderReceived, replaced), "a replaced callback is wrapped")
+	require.False(t, sameFunc(app.Server().HeaderReceived, installed))
+}
+
+// Test and a listener run on one server at the same time, and the connections they
+// serve read the callback, so installing the hook must not write it again. Meant
+// for -race.
+func Test_App_HeaderReceivedHook_RaceFreeWithTest(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Get("/", func(c Ctx) error { return c.SendString("ok") })
+
+	stop := make(chan struct{})
+	var wg sync.WaitGroup
+	wg.Go(func() {
+		for {
+			select {
+			case <-stop:
+				return
+			default:
+				app.hookHeaderReceived()
+				runtime.Gosched()
+			}
+		}
+	})
+
+	for range 50 {
+		resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+		if assert.NoError(t, err) {
+			assert.NoError(t, resp.Body.Close())
+		}
+	}
+	close(stop)
+	wg.Wait()
+}
+
+// Test serves the connection itself, so it installs the close hook too.
+func Test_App_Test_ClosesAfterContentLengthWithTransferEncoding(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Post("/", func(c Ctx) error { return c.SendString(strconv.Itoa(len(c.Body()))) })
+
+	// The dump of a chunked request keeps the Content-Length header it is given.
+	req := httptest.NewRequest(MethodPost, "/", strings.NewReader("hello"))
+	req.TransferEncoding = []string{"chunked"}
+	req.Header.Set(HeaderContentLength, "4")
+
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.NoError(t, resp.Body.Close())
+	require.Equal(t, StatusOK, resp.StatusCode)
+	require.True(t, resp.Close, "Connection: close expected")
+}
+
+// A client older than HTTP/1.1 that leaves must free the writer. The response is
+// written as it is produced, so the writer's Flush fails once the client is gone;
+// buffering it instead would hold the handler, and its connection slot, until the
+// writer ended on its own.
+func Test_App_SendStreamWriter_HTTP10_ClientLeaves(t *testing.T) {
+	t.Parallel()
+
+	stop := make(chan struct{})
+	ended := make(chan struct{})
+	app := New()
+	app.Get("/", func(c Ctx) error {
+		return c.SendStreamWriter(func(w *bufio.Writer) {
+			defer close(ended)
+			for {
+				select {
+				case <-stop:
+					return
+				default:
+				}
+				if _, err := w.WriteString(":\n\n"); err != nil {
+					return
+				}
+				if err := w.Flush(); err != nil {
+					return
+				}
+				time.Sleep(time.Millisecond)
+			}
+		})
+	})
+	ln := startRawServer(t, app)
+	t.Cleanup(func() { close(stop) })
+
+	conn, err := ln.Dial()
+	require.NoError(t, err)
+	_, err = conn.Write([]byte("GET / HTTP/1.0\r\n\r\n"))
+	require.NoError(t, err)
+
+	// The first bytes arrive while the writer is still running.
+	require.NoError(t, conn.SetReadDeadline(time.Now().Add(5*time.Second)))
+	_, err = bufio.NewReader(conn).ReadString('\n')
+	require.NoError(t, err)
+	require.NoError(t, conn.Close())
+
+	select {
+	case <-ended:
+	case <-time.After(5 * time.Second):
+		t.Fatal("the writer kept running after the client left")
+	}
+}
diff --git a/ctx_test.go b/ctx_test.go
index 6c78f2ee7be..960f98016e2 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -44,6 +44,7 @@ import (
 	"github.com/valyala/fasthttp"
 
 	"github.com/gofiber/fiber/v3/internal/storage/memory"
+	"github.com/gofiber/fiber/v3/log"
 )
 
 const epsilon = 0.001
@@ -756,6 +757,93 @@ func Test_Ctx_AcceptsEncodings_MultiHeader(t *testing.T) {
 	require.Equal(t, "gzip", c.AcceptsEncodings("deflate", "gzip"))
 }
 
+// RFC 9110 §12.5.3: "identity" is acceptable unless the field excludes it.
+// go test -run Test_Ctx_AcceptsEncodings_Identity
+func Test_Ctx_AcceptsEncodings_Identity(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name   string
+		header string
+		want   string
+		offers []string
+	}{
+		// Listed codings keep winning on their weights.
+		{name: "listed coding", header: "gzip", offers: []string{"gzip", "br"}, want: "gzip"},
+		{name: "listed beats unlisted", header: "br;q=0.1", offers: []string{"identity", "br"}, want: "br"},
+		{name: "unlisted coding", header: "gzip", offers: []string{"br"}, want: ""},
+		{name: "refused coding", header: "gzip;q=0", offers: []string{"gzip"}, want: ""},
+
+		// Unmentioned identity is acceptable.
+		{name: "identity unlisted", header: "gzip", offers: []string{"identity"}, want: "identity"},
+		{name: "identity unlisted among offers", header: "gzip", offers: []string{"br", "identity"}, want: "identity"},
+		{name: "identity after a refused coding", header: "gzip;q=0", offers: []string{"gzip", "identity"}, want: "identity"},
+		{name: "identity ranks below a listed coding", header: "gzip;q=0.1", offers: []string{"identity", "gzip"}, want: "gzip"},
+		{name: "identity keeps the caller's spelling", header: "gzip", offers: []string{"Identity"}, want: "Identity"},
+
+		// ... unless the field excludes it.
+		{name: "identity refused", header: "identity;q=0", offers: []string{"identity"}, want: ""},
+		{name: "identity refused, other coding unlisted", header: "identity;q=0", offers: []string{"gzip", "identity"}, want: ""},
+		{name: "identity refused, other coding listed", header: "identity;q=0, gzip", offers: []string{"identity", "gzip"}, want: "gzip"},
+		{name: "identity refused in any case", header: "IDENTITY;q=0", offers: []string{"identity"}, want: ""},
+		{name: "everything refused", header: "*;q=0", offers: []string{"gzip", "identity"}, want: ""},
+		{name: "everything but identity refused", header: "*;q=0, identity", offers: []string{"gzip", "identity"}, want: "identity"},
+		{name: "everything but gzip refused", header: "*;q=0, gzip", offers: []string{"identity", "gzip"}, want: "gzip"},
+
+		// An entry for identity is more specific than the wildcard.
+		{name: "wildcard accepts identity", header: "*", offers: []string{"identity"}, want: "identity"},
+		{name: "identity refused despite the wildcard", header: "*;q=0.5, identity;q=0", offers: []string{"identity"}, want: ""},
+		{name: "wildcard still serves another coding", header: "*;q=0.5, identity;q=0", offers: []string{"identity", "gzip"}, want: "gzip"},
+		{name: "identity weighed on its own entry", header: "gzip;q=0.5, identity", offers: []string{"gzip", "identity"}, want: "identity"},
+		{name: "coding outweighs identity", header: "gzip, identity;q=0.5", offers: []string{"identity", "gzip"}, want: "gzip"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			c.Request().Header.Set(HeaderAcceptEncoding, tc.header)
+			require.Equal(t, tc.want, c.AcceptsEncodings(tc.offers...))
+		})
+	}
+}
+
+// An absent field accepts any coding; an empty one only identity.
+// go test -run Test_Ctx_AcceptsEncodings_AbsentAndEmpty
+func Test_Ctx_AcceptsEncodings_AbsentAndEmpty(t *testing.T) {
+	t.Parallel()
+
+	for _, config := range []Config{{}, {DisableHeaderNormalizing: true}} {
+		t.Run(fmt.Sprintf("DisableHeaderNormalizing=%t", config.DisableHeaderNormalizing), func(t *testing.T) {
+			t.Parallel()
+
+			app := New(config)
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			// Absent: the first offer, whatever it is.
+			require.Equal(t, "gzip", c.AcceptsEncodings("gzip", "identity"))
+			require.Equal(t, "br", c.AcceptsEncodings("br"))
+			require.Empty(t, c.AcceptsEncodings())
+
+			// Present and empty: only identity.
+			c.Request().Header.Set(HeaderAcceptEncoding, "")
+			require.Equal(t, "identity", c.AcceptsEncodings("gzip", "identity"))
+			require.Equal(t, "Identity", c.AcceptsEncodings("gzip", "Identity"))
+			require.Empty(t, c.AcceptsEncodings("gzip", "br"))
+			require.Empty(t, c.AcceptsEncodings())
+
+			// An empty line beside a coding is an empty list element (§5.6.1.2).
+			c.Request().Header.Add(HeaderAcceptEncoding, "gzip")
+			require.Equal(t, "gzip", c.AcceptsEncodings("identity", "gzip"))
+		})
+	}
+}
+
 // go test -v -run=^$ -bench=Benchmark_Ctx_AcceptsEncodings -benchmem -count=4
 func Benchmark_Ctx_AcceptsEncodings(b *testing.B) {
 	app := New()
@@ -1820,6 +1908,113 @@ func Test_Ctx_Cookie_Invalid(t *testing.T) {
 	}
 }
 
+// A value with a space or comma is written in quotes, as net/http does (RFC 6265
+// §4.1.1 allows neither even in quotes), and the quotes are not part of the value read back.
+// go test -run Test_Ctx_Cookie_ValueQuoting
+func Test_Ctx_Cookie_ValueQuoting(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name  string
+		value string
+		line  string // the Set-Cookie line
+		read  string // the value read back from it
+	}{
+		{name: "plain", value: "abc123", line: "n=abc123; path=/; SameSite=Lax", read: "abc123"},
+		{name: "empty", value: "", line: "n=; path=/; SameSite=Lax", read: ""},
+		{name: "space", value: "hello world", line: `n="hello world"; path=/; SameSite=Lax`, read: "hello world"},
+		{name: "comma", value: "x,y", line: `n="x,y"; path=/; SameSite=Lax`, read: "x,y"},
+		{name: "space and comma", value: "a b, c", line: `n="a b, c"; path=/; SameSite=Lax`, read: "a b, c"},
+		{name: "edge spaces", value: " a ", line: `n=" a "; path=/; SameSite=Lax`, read: " a "},
+		{name: "already quoted", value: `"abc"`, line: `n="abc"; path=/; SameSite=Lax`, read: "abc"},
+		{name: "already quoted with a space", value: `"a b"`, line: `n="a b"; path=/; SameSite=Lax`, read: "a b"},
+		{name: "empty and quoted", value: `""`, line: `n=""; path=/; SameSite=Lax`, read: ""},
+		{name: "visible ASCII", value: "!#$%&'()*+-./:<=>?@[]^_`{|}~", line: "n=!#$%&'()*+-./:<=>?@[]^_`{|}~; path=/; SameSite=Lax", read: "!#$%&'()*+-./:<=>?@[]^_`{|}~"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			c.Res().Cookie(&Cookie{Name: "n", Value: tc.value})
+			require.Equal(t, tc.line, c.Res().Get(HeaderSetCookie))
+
+			got, ok := c.Res().GetCookie("n")
+			require.True(t, ok)
+			require.Equal(t, tc.read, got.Value)
+
+			// The client sends the pair back as it received it.
+			pair, _, _ := strings.Cut(c.Res().Get(HeaderSetCookie), ";")
+			c.Request().Header.Set(HeaderCookie, pair)
+			require.Equal(t, tc.read, c.Cookies("n"))
+		})
+	}
+}
+
+// Values the grammar cannot carry, even in quotes, are refused, not altered.
+// go test -run Test_Ctx_Cookie_ValueRejected
+func Test_Ctx_Cookie_ValueRejected(t *testing.T) {
+	t.Parallel()
+
+	for name, value := range map[string]string{
+		"semicolon":                 "a;b",
+		"semicolon in quotes":       `"a;b"`,
+		"double quote":              `a"b`,
+		"double quote inside quote": `"a"b"`,
+		"lone double quote":         `"`,
+		"opening quote only":        `"abc`,
+		"closing quote only":        `abc"`,
+		"backslash":                 `a\b`,
+		"backslash in quotes":       `"a\b"`,
+		"tab":                       "a\tb",
+		"line feed":                 "a\nb",
+		"non-ASCII":                 "café",
+		"DEL":                       "a\x7fb",
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			c.Res().Cookie(&Cookie{Name: "n", Value: value})
+			require.Empty(t, c.Res().Get(HeaderSetCookie))
+		})
+	}
+}
+
+// net/http reads back the values that were set.
+// go test -run Test_Ctx_Cookie_ValueQuoting_NetHTTP
+func Test_Ctx_Cookie_ValueQuoting_NetHTTP(t *testing.T) {
+	t.Parallel()
+
+	values := []string{"plain", "hello world", "x,y", "a b, c", `"abc"`, `"a b"`}
+
+	app := New()
+	app.Get("/", func(c Ctx) error {
+		for i, value := range values {
+			c.Cookie(&Cookie{Name: "c" + strconv.Itoa(i), Value: value})
+		}
+		return nil
+	})
+
+	resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	t.Cleanup(func() { require.NoError(t, resp.Body.Close()) })
+
+	cookies := resp.Cookies()
+	require.Len(t, cookies, len(values))
+	for i, cookie := range cookies {
+		require.Equal(t, "c"+strconv.Itoa(i), cookie.Name)
+		require.Equal(t, strings.Trim(values[i], `"`), cookie.Value)
+	}
+}
+
 // go test -run Test_Ctx_Cookie_DefaultPath
 func Test_Ctx_Cookie_DefaultPath(t *testing.T) {
 	t.Parallel()
@@ -8386,6 +8581,120 @@ func Test_SendFile_ByteRange(t *testing.T) {
 	})
 }
 
+const (
+	byteRangeContent      = "0123456789abcdefghij"
+	byteRangeLastModified = "Thu, 02 Jan 2020 03:04:05 GMT"
+	byteRangeStale        = "Wed, 01 Jan 2020 03:04:05 GMT"
+)
+
+// byteRangeFixture writes the 20-byte file of the byte-range tests, dated to
+// byteRangeLastModified, and returns its path.
+func byteRangeFixture(t *testing.T) string {
+	t.Helper()
+
+	fixture := filepath.Join(t.TempDir(), "fixture.txt")
+	require.NoError(t, os.WriteFile(fixture, []byte(byteRangeContent), 0o600))
+	require.NoError(t, os.Chtimes(fixture, time.Time{}, time.Date(2020, time.January, 2, 3, 4, 5, 0, time.UTC)))
+	return fixture
+}
+
+// SendFile wires the Range and If-Range rules (RFC 9110 §13.1.5, §14.2) into the
+// file server; internal/byterange tests them in full.
+func Test_SendFile_ByteRange_RFC9110(t *testing.T) {
+	t.Parallel()
+
+	if runtime.GOOS == windowsOS {
+		t.Skip("SendFile byte-range tests are flaky on Windows")
+	}
+
+	fixture := byteRangeFixture(t)
+	app := New()
+	app.Get("/file", func(c Ctx) error {
+		c.Set("X-Request", "kept")
+		return c.SendFile(fixture, SendFile{ByteRange: true})
+	})
+
+	tests := []struct {
+		fields     map[string]string
+		name       string
+		wantRange  string
+		wantBody   string
+		wantStatus int
+		wantWhole  bool // the whole file, with its validators
+	}{
+		{name: "a range", fields: map[string]string{HeaderRange: "bytes=0-4"}, wantStatus: StatusPartialContent, wantBody: "01234", wantRange: "bytes 0-4/20"},
+		{name: "several ranges", fields: map[string]string{HeaderRange: "bytes=0-1,3-4"}, wantStatus: StatusOK, wantBody: byteRangeContent, wantWhole: true},
+		{name: "If-Range matches", fields: map[string]string{HeaderRange: "bytes=0-4", HeaderIfRange: byteRangeLastModified}, wantStatus: StatusPartialContent, wantBody: "01234", wantRange: "bytes 0-4/20"},
+		{name: "If-Range is stale", fields: map[string]string{HeaderRange: "bytes=0-4", HeaderIfRange: byteRangeStale}, wantStatus: StatusOK, wantBody: byteRangeContent, wantWhole: true},
+		{name: "unsatisfiable", fields: map[string]string{HeaderRange: "bytes=100-200"}, wantStatus: StatusRequestedRangeNotSatisfiable, wantRange: "bytes */20", wantBody: "Range Not Satisfiable"},
+		{name: "unsatisfiable, If-Range is stale", fields: map[string]string{HeaderRange: "bytes=100-200", HeaderIfRange: byteRangeStale}, wantStatus: StatusOK, wantBody: byteRangeContent, wantWhole: true},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			req := httptest.NewRequest(MethodGet, "/file", http.NoBody)
+			for k, v := range tc.fields {
+				req.Header.Set(k, v)
+			}
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			t.Cleanup(func() { require.NoError(t, resp.Body.Close()) })
+
+			require.Equal(t, tc.wantStatus, resp.StatusCode)
+			require.Equal(t, tc.wantRange, resp.Header.Get(HeaderContentRange))
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.Equal(t, tc.wantBody, string(body))
+
+			if tc.wantWhole {
+				require.Equal(t, "20", resp.Header.Get(HeaderContentLength))
+				require.Equal(t, byteRangeLastModified, resp.Header.Get(HeaderLastModified))
+			}
+			// Headers set before SendFile survive unless the response is discarded.
+			if tc.wantStatus != StatusRequestedRangeNotSatisfiable {
+				require.Equal(t, "kept", resp.Header.Get("X-Request"))
+			}
+		})
+	}
+}
+
+// An entity-tag in If-Range matches an ETag the handler set before SendFile,
+// which sends none of its own.
+func Test_SendFile_ByteRange_IfRangeETag(t *testing.T) {
+	t.Parallel()
+
+	if runtime.GOOS == windowsOS {
+		t.Skip("SendFile byte-range tests are flaky on Windows")
+	}
+
+	fixture := byteRangeFixture(t)
+	app := New()
+	app.Get("/file", func(c Ctx) error {
+		c.Set(HeaderETag, `"v1"`)
+		return c.SendFile(fixture, SendFile{ByteRange: true})
+	})
+
+	for ifRange, wantStatus := range map[string]int{
+		`"v1"`:   StatusPartialContent,
+		`"v2"`:   StatusOK,
+		`W/"v1"`: StatusOK, // a weak tag never matches
+	} {
+		t.Run(ifRange, func(t *testing.T) {
+			t.Parallel()
+
+			req := httptest.NewRequest(MethodGet, "/file", http.NoBody)
+			req.Header.Set(HeaderRange, "bytes=0-4")
+			req.Header.Set(HeaderIfRange, ifRange)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.NoError(t, resp.Body.Close())
+			require.Equal(t, wantStatus, resp.StatusCode)
+		})
+	}
+}
+
 func Benchmark_Ctx_SendFile(b *testing.B) {
 	app := New()
 	c := app.AcquireCtx(&fasthttp.RequestCtx{})
@@ -10090,6 +10399,100 @@ func Test_Ctx_Status(t *testing.T) {
 	require.Equal(t, "Hello, World", string(c.Response().Body()))
 }
 
+// Three-digit codes go out as given, 600..999 included (RFC 9112 §4).
+// go test -run Test_Ctx_Status_ThreeDigits
+func Test_Ctx_Status_ThreeDigits(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	for _, code := range []int{100, 101, 200, 204, 304, 404, 499, 500, 599, 600, 601, 799, 999} {
+		t.Run(strconv.Itoa(code), func(t *testing.T) {
+			t.Parallel()
+
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			c.Status(code)
+			require.Equal(t, code, c.Response().StatusCode())
+			c.Res().Status(code)
+			require.Equal(t, code, c.Response().StatusCode())
+		})
+	}
+}
+
+// Codes that do not fit a status line are logged and sent as 500.
+// go test -run Test_Ctx_Status_Invalid
+func Test_Ctx_Status_Invalid(t *testing.T) {
+	// Not parallel: redirects the process-wide logger output.
+	var logged bytes.Buffer
+	log.SetOutput(&logged)
+	t.Cleanup(func() { log.SetOutput(os.Stderr) })
+
+	invalid := []int{0, -1, -5, 1, 99, 1000, 12345, math.MaxInt, math.MinInt}
+
+	app := New()
+	for _, code := range invalid {
+		app.Get("/status/"+strconv.Itoa(code), func(c Ctx) error {
+			return c.Status(code).SendString("body")
+		})
+		app.Get("/send/"+strconv.Itoa(code), func(c Ctx) error {
+			return c.SendStatus(code)
+		})
+		app.Get("/error/"+strconv.Itoa(code), func(_ Ctx) error {
+			return NewError(code, "failed")
+		})
+		app.Get("/redirect/"+strconv.Itoa(code), func(c Ctx) error {
+			return c.Redirect().Status(code).To("/elsewhere")
+		})
+	}
+
+	for _, code := range invalid {
+		for _, kind := range []string{"status", "send", "error", "redirect"} {
+			t.Run(kind+"/"+strconv.Itoa(code), func(t *testing.T) {
+				logged.Reset()
+
+				// app.Test reads the response with net/http, which refuses malformed status lines.
+				resp, err := app.Test(httptest.NewRequest(MethodGet, "/"+kind+"/"+strconv.Itoa(code), http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, StatusInternalServerError, resp.StatusCode)
+				require.NoError(t, resp.Body.Close())
+
+				require.Contains(t, logged.String(), fmt.Sprintf("status code %d is not a three-digit HTTP status, sending 500 instead", code))
+			})
+		}
+	}
+
+	t.Run("SendStatus answers with the status that is sent", func(t *testing.T) {
+		c := app.AcquireCtx(&fasthttp.RequestCtx{})
+		t.Cleanup(func() { app.ReleaseCtx(c) })
+
+		require.NoError(t, c.SendStatus(0))
+		require.Equal(t, StatusInternalServerError, c.Response().StatusCode())
+		require.Equal(t, "Internal Server Error", string(c.Response().Body()))
+	})
+
+	t.Run("a valid status is not logged", func(t *testing.T) {
+		logged.Reset()
+
+		c := app.AcquireCtx(&fasthttp.RequestCtx{})
+		t.Cleanup(func() { app.ReleaseCtx(c) })
+		c.Status(StatusTeapot)
+		require.NoError(t, c.SendStatus(StatusNoContent))
+		require.Empty(t, logged.String())
+	})
+}
+
+func Benchmark_Ctx_Status(b *testing.B) {
+	app := New()
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+	b.ReportAllocs()
+	for b.Loop() {
+		c.Status(StatusTeapot)
+	}
+	require.Equal(b, StatusTeapot, c.Response().StatusCode())
+}
+
 // go test -run Test_Ctx_Type
 func Test_Ctx_Type(t *testing.T) {
 	t.Parallel()
diff --git a/helpers_test.go b/helpers_test.go
index cb7f5b672d6..c530c7dbfd7 100644
--- a/helpers_test.go
+++ b/helpers_test.go
@@ -5,6 +5,7 @@
 package fiber
 
 import (
+	"bufio"
 	"bytes"
 	"context"
 	"crypto/tls"
@@ -1909,3 +1910,130 @@ func Benchmark_bindMediaType(b *testing.B) {
 		})
 	}
 }
+
+func Test_sameFunc(t *testing.T) {
+	t.Parallel()
+
+	newCallback := func(limit int) func(*fasthttp.RequestHeader) fasthttp.RequestConfig {
+		return func(*fasthttp.RequestHeader) fasthttp.RequestConfig {
+			return fasthttp.RequestConfig{MaxRequestBodySize: limit}
+		}
+	}
+	a, b := newCallback(1), newCallback(1)
+
+	require.True(t, sameFunc(a, a))
+	require.False(t, sameFunc(a, b), "closures of one literal are different values")
+	require.False(t, sameFunc(a, nil))
+	require.False(t, sameFunc(nil, a))
+	require.False(t, sameFunc(nil, nil))
+}
+
+func Test_hasHeaderField(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name  string
+		raw   string
+		field string // HeaderContentLength when empty
+		want  bool
+	}{
+		{name: "empty", raw: "", want: false},
+		{name: "no fields", raw: "\r\n", want: false},
+		{name: "only field", raw: "Content-Length: 4\r\n\r\n", want: true},
+		{name: "among others", raw: "Host: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n", want: true},
+		{name: "last field", raw: "Host: x\r\nContent-Length: 4", want: true},
+		{name: "lower case", raw: "Host: x\r\ncontent-length: 4\r\n\r\n", want: true},
+		{name: "upper case", raw: "Host: x\r\nCONTENT-LENGTH: 4\r\n\r\n", want: true},
+		{name: "bare LF line ends", raw: "Host: x\nContent-Length: 4\n\n", want: true},
+		{name: "no space after the colon", raw: "Host: x\r\nContent-Length:4\r\n\r\n", want: true},
+		{name: "empty value", raw: "Host: x\r\nContent-Length:\r\n\r\n", want: true},
+		{name: "longer name", raw: "Host: x\r\nContent-Length-Extra: 4\r\n\r\n", want: false},
+		{name: "longer name ending in it", raw: "Host: x\r\nX-Content-Length: 4\r\n\r\n", want: false},
+		{name: "shorter name", raw: "Host: x\r\nContent-Len: 4\r\n\r\n", want: false},
+		{name: "name inside a value", raw: "Host: x\r\nX-Note: Content-Length: 4\r\n\r\n", want: false},
+		{name: "folded continuation line", raw: "Host: x\r\nX-Note: a\r\n Content-Length: 4\r\n\r\n", want: false},
+		{name: "name without a colon", raw: "Host: x\r\nContent-Length\r\n\r\n", want: false},
+		{name: "name only", raw: "Content-Length", want: false},
+		{name: "Transfer-Encoding", raw: "Host: x\r\nTransfer-Encoding: identity\r\n\r\n", field: HeaderTransferEncoding, want: true},
+		{name: "Transfer-Encoding lower case", raw: "Host: x\r\ntransfer-encoding: identity\r\n\r\n", field: HeaderTransferEncoding, want: true},
+		{name: "Transfer-Encoding absent", raw: "Host: x\r\nContent-Length: 4\r\n\r\n", field: HeaderTransferEncoding, want: false},
+		{name: "Transfer-Encoding longer name", raw: "Host: x\r\nX-Transfer-Encoding: chunked\r\n\r\n", field: HeaderTransferEncoding, want: false},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			field := tc.field
+			if field == "" {
+				field = HeaderContentLength
+			}
+			require.Equal(t, tc.want, hasHeaderField([]byte(tc.raw), field))
+		})
+	}
+}
+
+// fasthttp reports -1 for a chunked request, the Content-Length value for one it
+// frames by Content-Length ("identity" included) and -2 for neither; the field
+// that is not reflected in that is looked up in the header block.
+func Test_bothFramingFields(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name string
+		raw  string
+		want bool
+	}{
+		{name: "neither", raw: "GET / HTTP/1.1\r\nHost: x\r\n\r\n", want: false},
+		{name: "Content-Length only", raw: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nabcd", want: false},
+		{name: "chunked only", raw: "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", want: false},
+		{name: "identity only", raw: "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\n\r\n", want: false},
+		{name: "chunked after Content-Length", raw: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", want: true},
+		{name: "chunked before Content-Length", raw: "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\n", want: true},
+		{name: "identity after Content-Length", raw: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: identity\r\n\r\nabcd", want: true},
+		{name: "identity before Content-Length", raw: "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\nContent-Length: 4\r\n\r\nabcd", want: true},
+		{name: "identity with an empty body", raw: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nTransfer-Encoding: identity\r\n\r\n", want: true},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var h fasthttp.RequestHeader
+			require.NoError(t, h.Read(bufio.NewReader(strings.NewReader(tc.raw))))
+			require.Equal(t, tc.want, bothFramingFields(&h))
+		})
+	}
+}
+
+func Benchmark_hasHeaderField(b *testing.B) {
+	raw := []byte("Host: example.com\r\nUser-Agent: Go-http-client/1.1\r\nAccept: */*\r\nAccept-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n")
+
+	b.ReportAllocs()
+	for b.Loop() {
+		if !hasHeaderField(raw, HeaderContentLength) {
+			b.Fatal("Content-Length field not found")
+		}
+	}
+}
+
+func Benchmark_bothFramingFields(b *testing.B) {
+	const fields = "Host: example.com\r\nUser-Agent: Go-http-client/1.1\r\nAccept: */*\r\nAccept-Encoding: gzip\r\n"
+	for _, tc := range []struct{ name, raw string }{
+		{"no body length", "GET / HTTP/1.1\r\n" + fields + "\r\n"},
+		{"Content-Length", "POST / HTTP/1.1\r\n" + fields + "Content-Length: 4\r\n\r\nabcd"},
+		{"chunked", "POST / HTTP/1.1\r\n" + fields + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"},
+	} {
+		b.Run(tc.name, func(b *testing.B) {
+			var h fasthttp.RequestHeader
+			require.NoError(b, h.Read(bufio.NewReader(strings.NewReader(tc.raw))))
+
+			b.ReportAllocs()
+			for b.Loop() {
+				if bothFramingFields(&h) {
+					b.Fatal("a single framing field was taken for both")
+				}
+			}
+		})
+	}
+}
diff --git a/internal/byterange/byterange_test.go b/internal/byterange/byterange_test.go
new file mode 100644
index 00000000000..651b376df2b
--- /dev/null
+++ b/internal/byterange/byterange_test.go
@@ -0,0 +1,442 @@
+package byterange
+
+import (
+	"os"
+	"path/filepath"
+	"testing"
+	"time"
+
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+func Test_classify(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name      string
+		field     string
+		canonical string
+		verdict   verdict
+	}{
+		// Handed on as they are.
+		{name: "single range", field: "bytes=0-4", verdict: pass},
+		{name: "open ended", field: "bytes=5-", verdict: pass},
+		{name: "suffix", field: "bytes=-5", verdict: pass},
+
+		// Spelled the way the file server parses them.
+		{name: "unit in upper case", field: "BYTES=0-4", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "unit in mixed case", field: "Bytes=0-4", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "space after the equals sign", field: "bytes= 0-4", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "space before the equals sign", field: "bytes =0-4", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "trailing comma", field: "bytes=0-4,", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "leading comma", field: "bytes=,0-4", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "empty elements around", field: "bytes=, ,0-4, ,", canonical: "bytes=0-4", verdict: rewrite},
+		{name: "space around the spec", field: "bytes=  0-4  ", canonical: "bytes=0-4", verdict: rewrite},
+
+		// Unknown units are ignored.
+		{name: "unknown unit", field: "items=0-4", verdict: ignore},
+		{name: "unknown unit with several ranges", field: "items=0-4,6-9", verdict: ignore},
+		{name: "unit that only starts like bytes", field: "bytes2=0-4", verdict: ignore},
+
+		// Several ranges are ignored, not refused.
+		{name: "two ranges", field: "bytes=0-1,3-4", verdict: ignore},
+		{name: "two ranges with empty elements between", field: "bytes=0-1,,3-4", verdict: ignore},
+		{name: "three ranges", field: "bytes=0-1,3-4,6-", verdict: ignore},
+		{name: "overlapping ranges", field: "bytes=0-5,3-8", verdict: ignore},
+
+		// Not a ranges-specifier: left for the file server to refuse.
+		{name: "no equals sign", field: "bytes", verdict: pass},
+		{name: "no unit", field: "=0-4", verdict: pass},
+		{name: "no range set", field: "bytes=", verdict: pass},
+		{name: "only empty elements", field: "bytes=,,", verdict: pass},
+		{name: "garbage", field: "garbage", verdict: pass},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var buf [64]byte
+			got := classify(buf[:0], []byte(tc.field))
+			require.Equal(t, tc.verdict, got.verdict)
+			if tc.verdict == rewrite {
+				require.Equal(t, tc.canonical, string(got.canonical))
+			} else {
+				require.Nil(t, got.canonical)
+			}
+		})
+	}
+}
+
+func Test_ifRangeMatches(t *testing.T) {
+	t.Parallel()
+
+	const modified = "Thu, 02 Jan 2020 03:04:05 GMT"
+	modifiedAt := time.Date(2020, time.January, 2, 3, 4, 5, 0, time.UTC)
+
+	tests := []struct {
+		name         string
+		ifRange      string
+		lastModified string
+		etag         string
+		want         bool
+	}{
+		{name: "exact date", ifRange: modified, lastModified: modified, want: true},
+		{name: "exact date with spaces around", ifRange: "  " + modified + " ", lastModified: modified, want: true},
+		{name: "other date", ifRange: "Fri, 03 Jan 2020 03:04:05 GMT", lastModified: modified, want: false},
+		{name: "same instant, another spelling", ifRange: "Thursday, 02-Jan-20 03:04:05 GMT", lastModified: modified, want: false},
+		{name: "date, no Last-Modified", ifRange: modified, want: false},
+		{name: "not a date", ifRange: "yesterday", lastModified: modified, want: false},
+		{name: "empty", ifRange: "", lastModified: modified, want: false},
+		{name: "strong tag", ifRange: `"v1"`, etag: `"v1"`, want: true},
+		{name: "other strong tag", ifRange: `"v1"`, etag: `"v2"`, want: false},
+		{name: "strong tag, no ETag", ifRange: `"v1"`, want: false},
+		{name: "strong tag against a weak ETag", ifRange: `"v1"`, etag: `W/"v1"`, want: false},
+		{name: "weak tag is never strong", ifRange: `W/"v1"`, etag: `W/"v1"`, want: false},
+		{name: "weak tag against a strong ETag", ifRange: `W/"v1"`, etag: `"v1"`, want: false},
+		{name: "tag is not compared with the date", ifRange: `"v1"`, lastModified: modified, want: false},
+		{name: "date is not compared with the ETag", ifRange: modified, etag: modified, want: false},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var resp fasthttp.Response
+			if tc.lastModified != "" {
+				resp.Header.Set(fasthttp.HeaderLastModified, tc.lastModified)
+			}
+			if tc.etag != "" {
+				resp.Header.Set(fasthttp.HeaderETag, tc.etag)
+			}
+			require.Equal(t, tc.want, ifRangeMatches([]byte(tc.ifRange), &resp, modifiedAt.Add(time.Hour)))
+		})
+	}
+
+	// A date is a strong validator only when it is old enough (§8.8.2.2).
+	t.Run("a date is strong once strongAfter old", func(t *testing.T) {
+		t.Parallel()
+
+		var resp fasthttp.Response
+		resp.Header.Set(fasthttp.HeaderLastModified, modified)
+		for age, want := range map[time.Duration]bool{
+			-time.Hour:                    false, // a date in the future cannot be strong
+			0:                             false,
+			time.Second:                   false,
+			strongAfter - time.Nanosecond: false,
+			strongAfter:                   true,
+			time.Hour:                     true,
+		} {
+			require.Equal(t, want, ifRangeMatches([]byte(modified), &resp, modifiedAt.Add(age)), age.String())
+		}
+	})
+}
+
+const (
+	fileContent  = "0123456789abcdefghij"
+	fileModified = "Thu, 02 Jan 2020 03:04:05 GMT"
+)
+
+// newFileServer serves a 20-byte file, old enough for a strong Last-Modified,
+// through fasthttp's file server with ranges enabled.
+func newFileServer(t *testing.T) fasthttp.RequestHandler {
+	t.Helper()
+
+	dir := t.TempDir()
+	name := filepath.Join(dir, "file.txt")
+	require.NoError(t, os.WriteFile(name, []byte(fileContent), 0o600))
+	require.NoError(t, os.Chtimes(name, time.Time{}, time.Date(2020, time.January, 2, 3, 4, 5, 0, time.UTC)))
+
+	server := &fasthttp.FS{
+		Root:            dir,
+		AcceptByteRange: true,
+		SkipCache:       true,
+	}
+	return server.NewRequestHandler()
+}
+
+// discardLogger is the logger of the contexts the tests build.
+type discardLogger struct{}
+
+func (discardLogger) Printf(string, ...any) {}
+
+// reply is a response read back out of a RequestCtx.
+type reply struct {
+	ctx  *fasthttp.RequestCtx
+	body string
+}
+
+func (r reply) status() int            { return r.ctx.Response.StatusCode() }
+func (r reply) header(k string) string { return string(r.ctx.Response.Header.Peek(k)) }
+
+// request runs Serve for a request to the file with the given method and fields.
+func request(t *testing.T, handler fasthttp.RequestHandler, method string, fields map[string]string, prepare ...func(*fasthttp.RequestCtx)) reply {
+	t.Helper()
+
+	return requestAt(t, time.Now, handler, method, fields, prepare...)
+}
+
+// requestAt is request with the clock that ages Last-Modified given.
+func requestAt(t *testing.T, now func() time.Time, handler fasthttp.RequestHandler, method string, fields map[string]string, prepare ...func(*fasthttp.RequestCtx)) reply {
+	t.Helper()
+
+	var req fasthttp.Request
+	req.Header.SetMethod(method)
+	req.SetRequestURI("/file.txt")
+	for k, v := range fields {
+		req.Header.Set(k, v)
+	}
+
+	// The file server logs the ranges it refuses, which needs a logger.
+	ctx := &fasthttp.RequestCtx{}
+	ctx.Init(&req, nil, discardLogger{})
+	for _, p := range prepare {
+		p(ctx)
+	}
+
+	serveAt(ctx, handler, now)
+
+	// Reading the body of a stream drains and closes it.
+	return reply{ctx: ctx, body: string(ctx.Response.Body())}
+}
+
+func Test_Wrap_RangeRules(t *testing.T) {
+	t.Parallel()
+
+	handler := newFileServer(t)
+
+	tests := []struct {
+		name         string
+		method       string
+		rangeField   string
+		wantRange    string // Content-Range of the response
+		wantBody     string
+		wantLength   string
+		wantStatus   int
+		wantAccepted bool // Accept-Ranges is advertised
+	}{
+		{name: "no Range", method: fasthttp.MethodGet, wantStatus: 200, wantBody: fileContent, wantLength: "20", wantAccepted: true},
+		{name: "a range", method: fasthttp.MethodGet, rangeField: "bytes=0-4", wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20", wantLength: "5", wantAccepted: true},
+		{name: "suffix range", method: fasthttp.MethodGet, rangeField: "bytes=-5", wantStatus: 206, wantBody: "fghij", wantRange: "bytes 15-19/20", wantLength: "5", wantAccepted: true},
+		{name: "open ended range", method: fasthttp.MethodGet, rangeField: "bytes=15-", wantStatus: 206, wantBody: "fghij", wantRange: "bytes 15-19/20", wantLength: "5", wantAccepted: true},
+
+		// Units are case-insensitive (§14.1).
+		{name: "unit in upper case", method: fasthttp.MethodGet, rangeField: "BYTES=0-4", wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20", wantLength: "5", wantAccepted: true},
+		{name: "unit in mixed case", method: fasthttp.MethodGet, rangeField: "Bytes=-5", wantStatus: 206, wantBody: "fghij", wantRange: "bytes 15-19/20", wantLength: "5", wantAccepted: true},
+		{name: "space after the equals sign", method: fasthttp.MethodGet, rangeField: "bytes= 0-4", wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20", wantLength: "5", wantAccepted: true},
+		{name: "empty list elements", method: fasthttp.MethodGet, rangeField: "bytes=,0-4,", wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20", wantLength: "5", wantAccepted: true},
+
+		// The whole representation: Range is ignored.
+		{name: "several ranges", method: fasthttp.MethodGet, rangeField: "bytes=0-1,3-4", wantStatus: 200, wantBody: fileContent, wantLength: "20", wantAccepted: true},
+		{name: "several ranges, one of them unsatisfiable", method: fasthttp.MethodGet, rangeField: "bytes=0-1,100-200", wantStatus: 200, wantBody: fileContent, wantLength: "20", wantAccepted: true},
+		{name: "unknown unit", method: fasthttp.MethodGet, rangeField: "items=0-4", wantStatus: 200, wantBody: fileContent, wantLength: "20", wantAccepted: true},
+		{name: "only GET has ranges: HEAD", method: fasthttp.MethodHead, rangeField: "bytes=0-4", wantStatus: 200, wantLength: "20", wantAccepted: true},
+
+		// Refused by the file server, as before.
+		{name: "start past the end", method: fasthttp.MethodGet, rangeField: "bytes=100-200", wantStatus: 416, wantBody: "Range Not Satisfiable"},
+		{name: "reversed range", method: fasthttp.MethodGet, rangeField: "bytes=5-1", wantStatus: 416, wantBody: "Range Not Satisfiable"},
+		{name: "no range set", method: fasthttp.MethodGet, rangeField: "bytes=", wantStatus: 416, wantBody: "Range Not Satisfiable"},
+		{name: "garbage", method: fasthttp.MethodGet, rangeField: "garbage", wantStatus: 416, wantBody: "Range Not Satisfiable"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			fields := map[string]string{}
+			if tc.rangeField != "" {
+				fields[fasthttp.HeaderRange] = tc.rangeField
+			}
+			got := request(t, handler, tc.method, fields)
+
+			require.Equal(t, tc.wantStatus, got.status())
+			require.Equal(t, tc.wantBody, got.body)
+			require.Equal(t, tc.wantRange, got.header(fasthttp.HeaderContentRange))
+			if tc.wantLength != "" {
+				require.Equal(t, tc.wantLength, got.header("Content-Length"))
+			}
+			if tc.wantAccepted {
+				require.Equal(t, "bytes", got.header("Accept-Ranges"))
+			}
+
+			// The rest of the chain sees the request as it came.
+			require.Equal(t, tc.rangeField, string(got.ctx.Request.Header.Peek(fasthttp.HeaderRange)))
+		})
+	}
+}
+
+func Test_Wrap_IfRange(t *testing.T) {
+	t.Parallel()
+
+	handler := newFileServer(t)
+
+	const stale = "Wed, 01 Jan 2020 03:04:05 GMT"
+
+	tests := []struct {
+		name       string
+		rangeField string
+		ifRange    string
+		wantRange  string
+		wantBody   string
+		wantStatus int
+	}{
+		// The validator matches: the range is served.
+		{name: "matching date", rangeField: "bytes=0-4", ifRange: fileModified, wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20"},
+		{name: "matching date, unit in upper case", rangeField: "BYTES=0-4", ifRange: fileModified, wantStatus: 206, wantBody: "01234", wantRange: "bytes 0-4/20"},
+		{name: "matching date, unsatisfiable range", rangeField: "bytes=100-200", ifRange: fileModified, wantStatus: 416, wantBody: "Range Not Satisfiable"},
+
+		// It does not: the whole file is sent (§13.1.5).
+		{name: "stale date", rangeField: "bytes=0-4", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+		{name: "stale date, suffix range", rangeField: "bytes=-5", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+		{name: "stale date, unsatisfiable range", rangeField: "bytes=100-200", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+		{name: "entity-tag the file server never sent", rangeField: "bytes=0-4", ifRange: `"deadbeef"`, wantStatus: 200, wantBody: fileContent},
+		{name: "weak entity-tag", rangeField: "bytes=0-4", ifRange: `W/"deadbeef"`, wantStatus: 200, wantBody: fileContent},
+		{name: "not a validator", rangeField: "bytes=0-4", ifRange: "later", wantStatus: 200, wantBody: fileContent},
+
+		// Ranges that were ignored anyway.
+		{name: "matching date, several ranges", rangeField: "bytes=0-1,3-4", ifRange: fileModified, wantStatus: 200, wantBody: fileContent},
+		{name: "stale date, several ranges", rangeField: "bytes=0-1,3-4", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+		{name: "stale date, unknown unit", rangeField: "items=0-4", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+
+		// If-Range means nothing without Range.
+		{name: "no Range", ifRange: stale, wantStatus: 200, wantBody: fileContent},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			fields := map[string]string{fasthttp.HeaderIfRange: tc.ifRange}
+			if tc.rangeField != "" {
+				fields[fasthttp.HeaderRange] = tc.rangeField
+			}
+			got := request(t, handler, fasthttp.MethodGet, fields)
+
+			require.Equal(t, tc.wantStatus, got.status())
+			require.Equal(t, tc.wantBody, got.body)
+			require.Equal(t, tc.wantRange, got.header(fasthttp.HeaderContentRange))
+			if tc.wantStatus == 200 {
+				// A whole representation, framed as one.
+				require.Equal(t, "20", got.header("Content-Length"))
+				require.Equal(t, fileModified, got.header(fasthttp.HeaderLastModified))
+				require.Equal(t, "bytes", got.header("Accept-Ranges"))
+			}
+			require.Equal(t, tc.rangeField, string(got.ctx.Request.Header.Peek(fasthttp.HeaderRange)))
+			require.Equal(t, tc.ifRange, string(got.ctx.Request.Header.Peek(fasthttp.HeaderIfRange)))
+		})
+	}
+}
+
+// A file modified less than strongAfter ago has no strong validator, so no
+// If-Range date matches it (§8.8.2.2).
+func Test_Wrap_IfRange_Strength(t *testing.T) {
+	t.Parallel()
+
+	handler := newFileServer(t)
+	modifiedAt := time.Date(2020, time.January, 2, 3, 4, 5, 0, time.UTC)
+
+	for age, wantStatus := range map[time.Duration]int{
+		0:                             200,
+		time.Second:                   200,
+		strongAfter - time.Nanosecond: 200,
+		strongAfter:                   206,
+		time.Hour:                     206,
+	} {
+		t.Run(age.String(), func(t *testing.T) {
+			t.Parallel()
+
+			now := func() time.Time { return modifiedAt.Add(age) }
+			fields := map[string]string{fasthttp.HeaderRange: "bytes=0-4", fasthttp.HeaderIfRange: fileModified}
+			require.Equal(t, wantStatus, requestAt(t, now, handler, fasthttp.MethodGet, fields).status())
+		})
+	}
+}
+
+// Headers set before the file server ran survive every outcome; those of a
+// partial response do not.
+func Test_Wrap_KeepsCallerHeaders(t *testing.T) {
+	t.Parallel()
+
+	handler := newFileServer(t)
+	prepare := func(ctx *fasthttp.RequestCtx) {
+		ctx.Response.Header.Set("X-Request", "kept")
+	}
+
+	for name, fields := range map[string]map[string]string{
+		"range served":               {fasthttp.HeaderRange: "bytes=0-4"},
+		"range ignored":              {fasthttp.HeaderRange: "bytes=0-1,3-4"},
+		"range dropped for If-Range": {fasthttp.HeaderRange: "bytes=0-4", fasthttp.HeaderIfRange: "Wed, 01 Jan 2020 03:04:05 GMT"},
+		// The refusal wipes the response; the caller's headers are put back.
+		"unsatisfiable range dropped for If-Range": {fasthttp.HeaderRange: "bytes=100-200", fasthttp.HeaderIfRange: "Wed, 01 Jan 2020 03:04:05 GMT"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			got := request(t, handler, fasthttp.MethodGet, fields, prepare)
+			require.Equal(t, "kept", got.header("X-Request"))
+			if got.status() == 200 {
+				require.Empty(t, got.header(fasthttp.HeaderContentRange))
+				require.Equal(t, "20", got.header("Content-Length"))
+			}
+		})
+	}
+}
+
+func Benchmark_Wrap_NoRange(b *testing.B) {
+	dir := b.TempDir()
+	require.NoError(b, os.WriteFile(filepath.Join(dir, "file.txt"), []byte(fileContent), 0o600))
+	server := &fasthttp.FS{Root: dir, AcceptByteRange: true}
+	handler := Wrap(server.NewRequestHandler())
+
+	ctx := &fasthttp.RequestCtx{}
+	ctx.Request.SetRequestURI("/file.txt")
+
+	b.ReportAllocs()
+	for b.Loop() {
+		handler(ctx)
+		ctx.Response.Reset()
+	}
+}
+
+func Benchmark_Wrap_SingleRange(b *testing.B) {
+	dir := b.TempDir()
+	require.NoError(b, os.WriteFile(filepath.Join(dir, "file.txt"), []byte(fileContent), 0o600))
+	server := &fasthttp.FS{Root: dir, AcceptByteRange: true}
+	handler := Wrap(server.NewRequestHandler())
+
+	ctx := &fasthttp.RequestCtx{}
+	ctx.Request.SetRequestURI("/file.txt")
+	ctx.Request.Header.Set(fasthttp.HeaderRange, "bytes=0-4")
+
+	b.ReportAllocs()
+	for b.Loop() {
+		handler(ctx)
+		ctx.Response.Reset()
+	}
+}
+
+// The Range field is put back even when the handler panics.
+func Test_Wrap_RestoresRangeAfterPanic(t *testing.T) {
+	t.Parallel()
+
+	handler := Wrap(func(*fasthttp.RequestCtx) { panic("handler broke") })
+
+	for _, tc := range []struct{ method, field string }{
+		{method: fasthttp.MethodGet, field: "bytes=0-4"},
+		{method: fasthttp.MethodGet, field: "Bytes=0-4"},
+		{method: fasthttp.MethodGet, field: "bytes=0-1,3-4"},
+		{method: fasthttp.MethodGet, field: "items=0-4"},
+		{method: fasthttp.MethodHead, field: "bytes=0-4"},
+	} {
+		var req fasthttp.Request
+		req.Header.SetMethod(tc.method)
+		req.SetRequestURI("/file.txt")
+		req.Header.Set(fasthttp.HeaderRange, tc.field)
+		ctx := &fasthttp.RequestCtx{}
+		ctx.Init(&req, nil, discardLogger{})
+
+		require.Panics(t, func() { handler(ctx) })
+		require.Equal(t, tc.field, string(ctx.Request.Header.Peek(fasthttp.HeaderRange)), tc.method+" "+tc.field)
+	}
+}
diff --git a/listen_test.go b/listen_test.go
index 94a579ad711..d3dac8a3bfa 100644
--- a/listen_test.go
+++ b/listen_test.go
@@ -829,6 +829,40 @@ func Test_Listen_BeforeServeFunc(t *testing.T) {
 	require.Zero(t, handlers)
 }
 
+// Listen serves with the close hook installed.
+func Test_Listen_ClosesAfterContentLengthWithTransferEncoding(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Post("/", func(c Ctx) error { return c.SendString("ok") })
+
+	addrCh := make(chan string, 1)
+	errCh := make(chan error, 1)
+	go func() {
+		errCh <- app.Listen("127.0.0.1:0", ListenConfig{
+			DisableStartupMessage: true,
+			ListenerNetwork:       NetworkTCP4,
+			ListenerAddrFunc:      func(addr net.Addr) { addrCh <- addr.String() },
+		})
+	}()
+	t.Cleanup(func() {
+		require.NoError(t, app.Shutdown())
+		require.NoError(t, <-errCh)
+	})
+
+	var addr string
+	select {
+	case addr = <-addrCh:
+	case <-time.After(5 * time.Second):
+		t.Fatal("the server did not start")
+	}
+
+	responses, _ := rawExchange(t, tcpDialer(addr),
+		"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", 1)
+	require.Equal(t, StatusOK, responses[0].status)
+	require.True(t, responses[0].closes, "Connection: close expected")
+}
+
 // skipIfNoIPv6 skips the test on hosts without IPv6 support (e.g. some CI containers).
 func skipIfNoIPv6(t *testing.T) {
 	t.Helper()
diff --git a/middleware/static/static_test.go b/middleware/static/static_test.go
index 51721f696a4..2929778c429 100644
--- a/middleware/static/static_test.go
+++ b/middleware/static/static_test.go
@@ -1872,6 +1872,75 @@ func Test_Static_MaxAge_NotOnErrorResponses(t *testing.T) {
 	require.Equal(t, "public, max-age=3600", resp.Header.Get(fiber.HeaderCacheControl))
 }
 
+// With ByteRange on, the Range and If-Range rules (RFC 9110 §13.1.5, §14.2) are
+// applied around the file server's single range; internal/byterange tests them
+// in full.
+func Test_Static_ByteRange_RFC9110(t *testing.T) {
+	t.Parallel()
+
+	const (
+		content      = "0123456789abcdefghij"
+		lastModified = "Thu, 02 Jan 2020 03:04:05 GMT"
+		staleDate    = "Wed, 01 Jan 2020 03:04:05 GMT"
+	)
+	dir := t.TempDir()
+	name := filepath.Join(dir, "file.txt")
+	require.NoError(t, os.WriteFile(name, []byte(content), 0o600))
+	require.NoError(t, os.Chtimes(name, time.Time{}, time.Date(2020, time.January, 2, 3, 4, 5, 0, time.UTC)))
+
+	app := fiber.New()
+	app.Get("/ranges/*", New(dir, Config{ByteRange: true}))
+	app.Get("/plain/*", New(dir))
+
+	tests := []struct {
+		fields      map[string]string
+		name        string
+		path        string
+		wantRange   string
+		wantBody    string
+		wantStatus  int
+		wantWhole   bool // the whole file, with its validators
+		wantAdvised bool // Accept-Ranges is advertised
+	}{
+		{name: "a range", path: "/ranges/file.txt", fields: map[string]string{fiber.HeaderRange: "bytes=0-4"}, wantStatus: fiber.StatusPartialContent, wantBody: "01234", wantRange: "bytes 0-4/20", wantAdvised: true},
+		{name: "several ranges", path: "/ranges/file.txt", fields: map[string]string{fiber.HeaderRange: "bytes=0-1,3-4"}, wantStatus: fiber.StatusOK, wantBody: content, wantWhole: true, wantAdvised: true},
+		{name: "If-Range is stale", path: "/ranges/file.txt", fields: map[string]string{fiber.HeaderRange: "bytes=0-4", fiber.HeaderIfRange: staleDate}, wantStatus: fiber.StatusOK, wantBody: content, wantWhole: true, wantAdvised: true},
+		{name: "unsatisfiable", path: "/ranges/file.txt", fields: map[string]string{fiber.HeaderRange: "bytes=100-200"}, wantStatus: fiber.StatusRequestedRangeNotSatisfiable, wantBody: "Range Not Satisfiable"},
+		// ByteRange off: no ranges are offered and Range is not looked at.
+		{name: "ByteRange off", path: "/plain/file.txt", fields: map[string]string{fiber.HeaderRange: "bytes=0-4"}, wantStatus: fiber.StatusOK, wantBody: content, wantWhole: true},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			req := httptest.NewRequest(fiber.MethodGet, tc.path, http.NoBody)
+			for k, v := range tc.fields {
+				req.Header.Set(k, v)
+			}
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			t.Cleanup(func() { require.NoError(t, resp.Body.Close()) })
+
+			require.Equal(t, tc.wantStatus, resp.StatusCode)
+			require.Equal(t, tc.wantRange, resp.Header.Get(fiber.HeaderContentRange))
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.Equal(t, tc.wantBody, string(body))
+
+			if tc.wantAdvised {
+				require.Equal(t, "bytes", resp.Header.Get(fiber.HeaderAcceptRanges))
+			} else {
+				require.Empty(t, resp.Header.Get(fiber.HeaderAcceptRanges))
+			}
+			if tc.wantWhole {
+				require.Equal(t, "20", resp.Header.Get(fiber.HeaderContentLength))
+				require.Equal(t, lastModified, resp.Header.Get(fiber.HeaderLastModified))
+			}
+		})
+	}
+}
+
 func Test_Static_NonGetMethod_PassesThrough(t *testing.T) {
 	t.Parallel()
 
diff --git a/middleware/timeout/timeout_test.go b/middleware/timeout/timeout_test.go
index 7cc257cf1ec..46942668e7a 100644
--- a/middleware/timeout/timeout_test.go
+++ b/middleware/timeout/timeout_test.go
@@ -81,11 +81,71 @@ func TestTimeout_Exceeded(t *testing.T) {
 	resp, err := app.Test(req)
 	elapsed := time.Since(start)
 	require.NoError(t, err, "app.Test(req) should not fail")
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode, "Expected 408 Request Timeout")
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode, "Expected 503 Service Unavailable")
 	// Handler should return on cancelation, well before its own sleep elapses.
 	require.Less(t, elapsed, handlerSleep/2, "handler should return early on context cancelation")
 }
 
+// TestTimeout_DefaultStatus pins the default 503 (RFC 9110 §15.6.4): 408 would
+// invite a retry while the timed-out handler may still be running.
+func TestTimeout_DefaultStatus(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+
+	var sideEffects atomic.Int32
+	app.Post("/charge", New(func(c fiber.Ctx) error {
+		// Work that ignores the context, so it finishes after the response went out.
+		time.Sleep(150 * time.Millisecond)
+		sideEffects.Add(1)
+		return c.SendString("charged")
+	}, Config{Timeout: 20 * time.Millisecond}))
+
+	req := httptest.NewRequest(fiber.MethodPost, "/charge", http.NoBody)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
+	require.NotEqual(t, fiber.StatusRequestTimeout, resp.StatusCode)
+
+	body, readErr := io.ReadAll(resp.Body)
+	require.NoError(t, readErr)
+	require.Equal(t, fiber.ErrServiceUnavailable.Message, string(body))
+
+	// The premise: the timed-out handler runs to completion after the response.
+	require.Zero(t, sideEffects.Load())
+	require.Eventually(t, func() bool { return sideEffects.Load() == 1 }, 5*time.Second, 10*time.Millisecond)
+}
+
+// TestTimeout_OnTimeoutChoosesStatus shows how to keep or choose another
+// status: return the error from OnTimeout.
+func TestTimeout_OnTimeoutChoosesStatus(t *testing.T) {
+	t.Parallel()
+
+	for name, want := range map[string]*fiber.Error{
+		"request timeout": fiber.ErrRequestTimeout,
+		"gateway timeout": fiber.ErrGatewayTimeout,
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+
+			release := make(chan struct{})
+			t.Cleanup(func() { close(release) })
+			app.Get("/slow", New(func(c fiber.Ctx) error {
+				<-c.Context().Done()
+				<-release
+				return nil
+			}, Config{
+				Timeout:   20 * time.Millisecond,
+				OnTimeout: func(_ fiber.Ctx) error { return want },
+			}))
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/slow", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, want.Code, resp.StatusCode)
+		})
+	}
+}
+
 // TestTimeout_ContextPropagation verifies that the timeout context is properly
 // passed to the handler so it can detect cancelation (Issue #3671).
 func TestTimeout_ContextPropagation(t *testing.T) {
@@ -113,7 +173,7 @@ func TestTimeout_ContextPropagation(t *testing.T) {
 	resp, err := app.Test(req)
 
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	safety := time.NewTimer(1 * time.Second)
 	defer safety.Stop()
@@ -152,7 +212,7 @@ func TestTimeout_HandlerReturnsEarlyOnCancel(t *testing.T) {
 	elapsed := time.Since(start)
 
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 	// Should complete much faster than 500ms because handler checks context
 	require.Less(t, elapsed, 100*time.Millisecond)
 }
@@ -173,11 +233,11 @@ func TestTimeout_DefaultResponseClearsBufferedBody(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/partial", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	body, readErr := io.ReadAll(resp.Body)
 	require.NoError(t, readErr)
-	require.Equal(t, fiber.ErrRequestTimeout.Message, string(body))
+	require.Equal(t, fiber.ErrServiceUnavailable.Message, string(body))
 }
 
 // TestTimeout_CustomError tests that returning a user-defined error is also treated as a timeout.
@@ -198,7 +258,7 @@ func TestTimeout_CustomError(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/custom", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err, "app.Test(req) should not fail")
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode, "Expected 408 for custom timeout error")
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode, "Expected 503 for custom timeout error")
 }
 
 // TestTimeout_UnmatchedError checks that if the handler returns an error
@@ -319,7 +379,7 @@ func TestTimeout_OnTimeoutWritesResponse(t *testing.T) {
 
 // TestTimeout_OnTimeoutEmptyResponse exercises the timeout path with an
 // OnTimeout handler that leaves the response untouched (still default 200/empty),
-// so the middleware falls back to writing the default 408 timeout response.
+// so the middleware falls back to writing the default 503 timeout response.
 func TestTimeout_OnTimeoutEmptyResponse(t *testing.T) {
 	t.Parallel()
 	app := fiber.New()
@@ -341,17 +401,17 @@ func TestTimeout_OnTimeoutEmptyResponse(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/on-timeout-empty", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 	require.Equal(t, int32(1), called.Load())
 
 	body, readErr := io.ReadAll(resp.Body)
 	require.NoError(t, readErr)
-	require.Equal(t, fiber.ErrRequestTimeout.Message, string(body))
+	require.Equal(t, fiber.ErrServiceUnavailable.Message, string(body))
 }
 
 // TestTimeout_DeadlineErrorDefaultResponse verifies that when the handler returns
 // a timeout error and no OnTimeout is configured, invokeOnTimeout falls back to
-// fiber.ErrRequestTimeout. The handler returns immediately so the result is
+// fiber.ErrServiceUnavailable. The handler returns immediately so the result is
 // processed via the handler-returned branch deterministically.
 func TestTimeout_DeadlineErrorDefaultResponse(t *testing.T) {
 	t.Parallel()
@@ -364,7 +424,7 @@ func TestTimeout_DeadlineErrorDefaultResponse(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/deadline-default", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 }
 
 // TestTimeout_PanicInHandler verifies that panics in the handler return 500.
@@ -451,7 +511,7 @@ func TestTimeout_ImmediateReturn(t *testing.T) {
 	elapsed := time.Since(start)
 
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 	// Middleware should return immediately after timeout, not wait 500ms
 	require.Less(t, elapsed, 100*time.Millisecond, "middleware should return immediately on timeout")
 
@@ -481,8 +541,8 @@ func TestTimeout_PanicAfterTimeout(t *testing.T) {
 	resp, err := app.Test(req)
 
 	require.NoError(t, err)
-	// With immediate return, we get 408 (not 500) because panic happens after middleware returned
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	// With immediate return, we get 503 (not 500) because panic happens after middleware returned
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	// Wait for panic to occur and be handled by cleanup goroutine
 	select {
@@ -532,7 +592,7 @@ func TestTimeout_ContextCleanup(t *testing.T) {
 	resp, err := app.Test(req)
 
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	// Wait for handler to finish - cleanup goroutine should release context
 	select {
@@ -589,7 +649,7 @@ func TestTimeout_AbandonedCtxReclaimed(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/reclaim", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	var c fiber.Ctx
 	select {
@@ -627,7 +687,7 @@ func TestTimeout_PanicAfterTimeoutReclaimed(t *testing.T) {
 	req := httptest.NewRequest(fiber.MethodGet, "/panic-reclaim", http.NoBody)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	var c fiber.Ctx
 	select {
@@ -721,15 +781,15 @@ func Test_Timeout_OnTimeout_ResetsBodyStream(t *testing.T) {
 	// What handleTimeout does once the check passes. ResetBody closes the stream
 	// instead of draining it, so this returns rather than blocking on the reader.
 	resp.ResetBody()
-	resp.SetStatusCode(fiber.StatusRequestTimeout)
-	resp.SetBodyString(fiber.ErrRequestTimeout.Message)
+	resp.SetStatusCode(fiber.StatusServiceUnavailable)
+	resp.SetBodyString(fiber.ErrServiceUnavailable.Message)
 
 	require.False(t, resp.IsBodyStream())
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode())
-	require.Equal(t, fiber.ErrRequestTimeout.Message, string(resp.Body()))
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode())
+	require.Equal(t, fiber.ErrServiceUnavailable.Message, string(resp.Body()))
 }
 
-func Test_Timeout_DefaultReturnsErrRequestTimeout(t *testing.T) {
+func Test_Timeout_DefaultReturnsErrServiceUnavailable(t *testing.T) {
 	t.Parallel()
 	app := fiber.New()
 
@@ -751,11 +811,11 @@ func Test_Timeout_DefaultReturnsErrRequestTimeout(t *testing.T) {
 	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/slow", http.NoBody))
 	close(release)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 
 	select {
 	case err := <-seen:
-		require.ErrorIs(t, err, fiber.ErrRequestTimeout)
+		require.ErrorIs(t, err, fiber.ErrServiceUnavailable)
 	case <-time.After(time.Second):
 		t.Fatal("outer middleware never observed the result")
 	}
@@ -816,14 +876,14 @@ func Test_Timeout_ErrorHandlerSkippedAfterTimeout(t *testing.T) {
 	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/partial", http.NoBody))
 	close(release)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode)
+	require.Equal(t, fiber.StatusServiceUnavailable, resp.StatusCode)
 	body, err := io.ReadAll(resp.Body)
 	require.NoError(t, err)
-	require.Equal(t, fiber.ErrRequestTimeout.Message, string(body))
+	require.Equal(t, fiber.ErrServiceUnavailable.Message, string(body))
 
 	select {
 	case err := <-seen:
-		require.ErrorIs(t, err, fiber.ErrRequestTimeout)
+		require.ErrorIs(t, err, fiber.ErrServiceUnavailable)
 	case <-time.After(time.Second):
 		t.Fatal("outer middleware never observed the result")
 	}
diff --git a/prefork_test.go b/prefork_test.go
index c403e54b359..e73108b9b84 100644
--- a/prefork_test.go
+++ b/prefork_test.go
@@ -51,6 +51,9 @@ func Test_App_Prefork_Child_Process(t *testing.T) {
 
 	cfg = listenConfigDefault()
 	require.NoError(t, app.prefork("127.0.0.1:", config, &cfg))
+
+	// The child installs the Content-Length/Transfer-Encoding close hook before it serves.
+	require.NotNil(t, app.Server().HeaderReceived)
 }
 
 func Test_App_Prefork_Master_Process(t *testing.T) {

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path app_test.go --path ctx_test.go --path helpers_test.go --path internal/byterange/byterange_test.go --path listen_test.go --path middleware/static/static_test.go --path middleware/timeout/timeout_test.go --path prefork_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/byterange ./middleware/static ./middleware/timeout')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/byterange ./middleware/static ./middleware/timeout' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
