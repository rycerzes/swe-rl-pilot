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
for f in addon/retry/exponential_backoff_test.go client/client_test.go client/hooks_pathparam_test.go client/hooks_test.go client/transport_test.go ctx_test.go middleware/basicauth/basicauth_test.go middleware/cache/cache_test.go middleware/limiter/limiter_test.go middleware/session/middleware_test.go; do if git cat-file -e e090d85da6bcdde7c267a65e0b1b366c0ad93835:"$f" 2>/dev/null; then git checkout e090d85da6bcdde7c267a65e0b1b366c0ad93835 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - e090d85da6bcdde7c267a65e0b1b366c0ad93835 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/addon/retry/exponential_backoff_test.go b/addon/retry/exponential_backoff_test.go
index 7b14fd5c3fa..2569aff336f 100644
--- a/addon/retry/exponential_backoff_test.go
+++ b/addon/retry/exponential_backoff_test.go
@@ -61,6 +61,141 @@ func Test_ExponentialBackoff_Retry(t *testing.T) {
 	}
 }
 
+// Test_ExponentialBackoff_Retry_ZeroValue covers an ExponentialBackoff that was
+// not built by NewExponentialBackoff. MaxRetryCount is the number of attempts, so
+// a zero one made Retry return nil without calling f: success reported for work
+// that never ran. Every field left at zero takes the default instead.
+func Test_ExponentialBackoff_Retry_ZeroValue(t *testing.T) {
+	t.Parallel()
+
+	t.Run("the zero value calls f", func(t *testing.T) {
+		t.Parallel()
+
+		var backoff ExponentialBackoff
+		calls := 0
+		require.NoError(t, backoff.Retry(func() error {
+			calls++
+			return nil
+		}))
+		require.Equal(t, 1, calls)
+		require.Equal(t, ExponentialBackoff{}, backoff, "Retry must leave a shared value alone")
+	})
+
+	t.Run("the zero value reports a failure instead of success", func(t *testing.T) {
+		t.Parallel()
+
+		// Fast intervals so the default ten attempts do not wait out the default
+		// one to thirty-two seconds; MaxRetryCount stays unset.
+		backoff := &ExponentialBackoff{InitialInterval: time.Microsecond, MaxBackoffTime: time.Millisecond}
+		boom := errors.New("boom")
+		calls := 0
+		require.ErrorIs(t, backoff.Retry(func() error {
+			calls++
+			return boom
+		}), boom)
+		require.Equal(t, DefaultConfig.MaxRetryCount, calls)
+	})
+
+	t.Run("a negative attempt count is unset too", func(t *testing.T) {
+		t.Parallel()
+
+		backoff := &ExponentialBackoff{
+			InitialInterval: time.Microsecond,
+			MaxBackoffTime:  time.Millisecond,
+			Multiplier:      2,
+			MaxRetryCount:   -3,
+		}
+		calls := 0
+		require.Error(t, backoff.Retry(func() error {
+			calls++
+			return errors.New("again")
+		}))
+		require.Equal(t, DefaultConfig.MaxRetryCount, calls)
+	})
+
+	t.Run("a zero max backoff does not turn the retries into a busy loop", func(t *testing.T) {
+		t.Parallel()
+
+		backoff := &ExponentialBackoff{InitialInterval: 10 * time.Millisecond, MaxRetryCount: 3}
+		start := time.Now()
+		calls := 0
+		require.Error(t, backoff.Retry(func() error {
+			calls++
+			return errors.New("again")
+		}))
+		require.Equal(t, 3, calls)
+		// Two waits of at least the initial interval, which a zero cap used to
+		// shrink to nothing.
+		require.GreaterOrEqual(t, time.Since(start), 20*time.Millisecond)
+	})
+}
+
+func Test_ExponentialBackoff_withDefaults(t *testing.T) {
+	t.Parallel()
+
+	defaults := ExponentialBackoff{
+		InitialInterval: DefaultConfig.InitialInterval,
+		MaxBackoffTime:  DefaultConfig.MaxBackoffTime,
+		Multiplier:      DefaultConfig.Multiplier,
+		MaxRetryCount:   DefaultConfig.MaxRetryCount,
+	}
+
+	tests := []struct {
+		name string
+		in   ExponentialBackoff
+		want ExponentialBackoff
+	}{
+		{name: "zero value", want: defaults},
+		{
+			name: "negative numbers count as unset",
+			in:   ExponentialBackoff{InitialInterval: -1, MaxBackoffTime: -1, Multiplier: -1, MaxRetryCount: -1},
+			want: ExponentialBackoff{
+				InitialInterval: defaults.InitialInterval,
+				MaxBackoffTime:  defaults.MaxBackoffTime,
+				Multiplier:      defaults.Multiplier,
+				MaxRetryCount:   defaults.MaxRetryCount,
+			},
+		},
+		{
+			name: "values that are set are kept",
+			in:   ExponentialBackoff{InitialInterval: time.Second * 3, MaxBackoffTime: time.Minute, Multiplier: 1.5, MaxRetryCount: 4},
+			want: ExponentialBackoff{InitialInterval: time.Second * 3, MaxBackoffTime: time.Minute, Multiplier: 1.5, MaxRetryCount: 4},
+		},
+		{
+			name: "an unset initial interval starts from the current one",
+			in:   ExponentialBackoff{currentInterval: 7 * time.Second},
+			want: ExponentialBackoff{
+				InitialInterval: 7 * time.Second,
+				MaxBackoffTime:  defaults.MaxBackoffTime,
+				Multiplier:      defaults.Multiplier,
+				MaxRetryCount:   defaults.MaxRetryCount,
+				currentInterval: 7 * time.Second,
+			},
+		},
+		{
+			name: "one built by NewExponentialBackoff is unchanged",
+			in:   *NewExponentialBackoff(Config{InitialInterval: 2 * time.Second, MaxRetryCount: 6}),
+			want: ExponentialBackoff{
+				InitialInterval: 2 * time.Second,
+				MaxBackoffTime:  defaults.MaxBackoffTime,
+				Multiplier:      defaults.Multiplier,
+				MaxRetryCount:   6,
+				currentInterval: 2 * time.Second,
+			},
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			in := tc.in
+			require.Equal(t, tc.want, in.withDefaults())
+			require.Equal(t, tc.in, in, "the receiver must not change")
+		})
+	}
+}
+
 func Test_ExponentialBackoff_Retry_NoSleepAfterLastAttempt(t *testing.T) {
 	t.Parallel()
 
diff --git a/client/client_test.go b/client/client_test.go
index c76af450e87..ec12e637937 100644
--- a/client/client_test.go
+++ b/client/client_test.go
@@ -6,11 +6,14 @@ import (
 	"crypto/tls"
 	"encoding/hex"
 	"errors"
+	"fmt"
 	"io"
+	stdlog "log" //nolint:depguard // log.DefaultLogger is keyed by the standard library logger type the default logger exposes.
 	"net"
 	"os"
 	"path/filepath"
 	"reflect"
+	"runtime"
 	"strconv"
 	"strings"
 	"sync"
@@ -218,6 +221,94 @@ func TestClientLoggerAccessors(t *testing.T) {
 	require.Equal(t, contextual, client.Logger())
 }
 
+// Test_Client_DefaultLogger covers the logger a client starts with. It used to
+// ask for the default logger with Fiber's Logger interface as the type
+// argument instead of the standard library's *log.Logger, which no logger
+// implements, so every client began without one: Debug printed nothing and the
+// error paths of SetRootCertificate dereferenced it.
+func Test_Client_DefaultLogger(t *testing.T) {
+	t.Parallel()
+
+	clients := map[string]*Client{
+		"New":               New(),
+		"NewWithClient":     NewWithClient(&fasthttp.Client{}),
+		"NewWithHostClient": NewWithHostClient(&fasthttp.HostClient{}),
+		"NewWithLBClient":   NewWithLBClient(&fasthttp.LBClient{}),
+	}
+	for name, c := range clients {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			require.NotNil(t, c.Logger())
+			require.Equal(t, log.DefaultLogger[*stdlog.Logger](), c.Logger())
+		})
+	}
+}
+
+// recoverValue runs fn and returns what it panicked with, nil when it did not.
+func recoverValue(fn func()) any {
+	var recovered any
+	func() {
+		defer func() { recovered = recover() }()
+		fn()
+	}()
+	return recovered
+}
+
+// Test_Client_SetRootCertificate_InvalidInput pins the documented panic for a
+// certificate that cannot be loaded. The panic has to say why: a client with no
+// logger turned it into a nil pointer dereference that named nothing.
+func Test_Client_SetRootCertificate_InvalidInput(t *testing.T) {
+	t.Parallel()
+
+	noCertificate := filepath.Join(t.TempDir(), "invalid.pem")
+	require.NoError(t, os.WriteFile(noCertificate, []byte("not a pem"), 0o600))
+	missing := filepath.Join(t.TempDir(), "missing.pem")
+
+	tests := []struct {
+		call func(c *Client)
+		name string
+		want string
+	}{
+		{name: "string without a certificate", want: ErrFailedToAppendCert.Error(), call: func(c *Client) {
+			c.SetRootCertificateFromString("not a pem")
+		}},
+		{name: "empty string", want: ErrFailedToAppendCert.Error(), call: func(c *Client) {
+			c.SetRootCertificateFromString("")
+		}},
+		{name: "file without a certificate", want: ErrFailedToAppendCert.Error(), call: func(c *Client) {
+			c.SetRootCertificate(noCertificate)
+		}},
+		{name: "missing file", want: "client: open " + missing, call: func(c *Client) {
+			c.SetRootCertificate(missing)
+		}},
+	}
+
+	for _, tc := range tests {
+		for loggerName, setup := range map[string]func(*Client){
+			"default logger": func(*Client) {},
+			"no logger":      func(c *Client) { c.SetLogger(nil) },
+		} {
+			t.Run(tc.name+"/"+loggerName, func(t *testing.T) {
+				t.Parallel()
+
+				c := New()
+				setup(c)
+
+				recovered := recoverValue(func() { tc.call(c) })
+				require.NotNil(t, recovered, "an unusable certificate must not be ignored")
+
+				var runtimeErr runtime.Error
+				if err, ok := recovered.(error); ok {
+					require.NotErrorAs(t, err, &runtimeErr, "got a runtime panic")
+				}
+				require.Contains(t, fmt.Sprint(recovered), "client: ")
+				require.Contains(t, fmt.Sprint(recovered), tc.want)
+			})
+		}
+	}
+}
+
 func TestClientResetClearsState(t *testing.T) {
 	t.Parallel()
 
@@ -2781,6 +2872,122 @@ func Test_CookieJar_MaxAgePrecedence(t *testing.T) {
 	}
 }
 
+// Test_CookieJar_UnparsableAttributeKeepsTheOthers covers a Set-Cookie header
+// with one attribute fasthttp cannot parse. RFC 6265 Section 5.2 has such an
+// attribute ignored, but fasthttp stops at the first one, so everything after
+// it was lost: "Max-Age=abc; Secure; Path=/" stored a cookie that was neither
+// Secure nor on "/", which the jar then sent over plain HTTP, and only to the
+// directory that set it.
+func Test_CookieJar_UnparsableAttributeKeepsTheOthers(t *testing.T) {
+	t.Parallel()
+
+	const (
+		receivedPath = "/dir/x" // the request that received the cookie: default path "/dir"
+		otherPath    = "/other" // outside the default path
+	)
+
+	tests := []struct {
+		check     func(t *testing.T, jar *CookieJar)
+		name      string
+		setCookie string
+	}{
+		{
+			name:      "Secure and Path after a non-integer Max-Age",
+			setCookie: "s=1; Max-Age=abc; Secure; Path=/",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				require.Empty(t, jarGet(t, jar, "http://example.com"+otherPath), "a Secure cookie must not go over plain HTTP")
+				got := jarGet(t, jar, "https://example.com"+otherPath)
+				require.Len(t, got, 1, "Path=/ must be kept")
+				require.True(t, got[0].Secure())
+				require.Equal(t, "/", string(got[0].Path()))
+			},
+		},
+		{
+			name:      "Path after a fractional Max-Age",
+			setCookie: "s=1; Max-Age=1.5; Path=/",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				require.Len(t, jarGet(t, jar, "http://example.com"+otherPath), 1)
+			},
+		},
+		{
+			name:      "attributes after an empty Max-Age",
+			setCookie: "s=1; Max-Age=; HttpOnly; Path=/; SameSite=Lax",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				got := jarGet(t, jar, "http://example.com"+otherPath)
+				require.Len(t, got, 1)
+				require.True(t, got[0].HTTPOnly())
+				require.Equal(t, fasthttp.CookieSameSiteLaxMode, got[0].SameSite())
+			},
+		},
+		{
+			name:      "attributes after an unparsable Expires",
+			setCookie: "s=1; Expires=bogus; Secure; Path=/",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				require.Empty(t, jarGet(t, jar, "http://example.com"+otherPath))
+				require.Len(t, jarGet(t, jar, "https://example.com"+otherPath), 1)
+			},
+		},
+		{
+			name:      "Domain after a non-integer Max-Age",
+			setCookie: "s=1; Max-Age=abc; Domain=example.com; Path=/",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				require.Len(t, jarGet(t, jar, "http://sub.example.com"+otherPath), 1, "a Domain cookie reaches the subdomains")
+			},
+		},
+		{
+			name:      "the last integer Max-Age counts and the attributes survive",
+			setCookie: "s=1; Max-Age=3600; Max-Age=abc; Secure; Path=/",
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				got := jarGet(t, jar, "https://example.com"+otherPath)
+				require.Len(t, got, 1)
+				require.WithinDuration(t, time.Now().Add(time.Hour), got[0].Expire(), time.Minute)
+			},
+		},
+		{
+			name:      "an unusable name and value pair is dropped with its attributes",
+			setCookie: `s=a"b; Path=/`,
+			check: func(t *testing.T, jar *CookieJar) {
+				t.Helper()
+				require.Empty(t, jar.hostCookies, "nothing may be stored, not even an empty cookie")
+			},
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			jar := AcquireCookieJar()
+			t.Cleanup(jar.Release)
+
+			resp := fasthttp.AcquireResponse()
+			t.Cleanup(func() { fasthttp.ReleaseResponse(resp) })
+			resp.Header.Add("Set-Cookie", tc.setCookie)
+
+			jar.parseCookiesFromResp([]byte("example.com"), []byte(receivedPath), resp)
+
+			tc.check(t, jar)
+		})
+	}
+}
+
+// jarGet returns the cookies jar would send to rawURL.
+func jarGet(t *testing.T, jar *CookieJar, rawURL string) []*fasthttp.Cookie {
+	t.Helper()
+
+	uri := fasthttp.AcquireURI()
+	t.Cleanup(func() { fasthttp.ReleaseURI(uri) })
+	require.NoError(t, uri.Parse(nil, []byte(rawURL)))
+
+	return jar.Get(uri)
+}
+
 func Test_Request_CancelledContext_NoRace(t *testing.T) {
 	t.Parallel()
 
diff --git a/client/hooks_pathparam_test.go b/client/hooks_pathparam_test.go
index d1c9a9aca5c..8006ed053f5 100644
--- a/client/hooks_pathparam_test.go
+++ b/client/hooks_pathparam_test.go
@@ -5,6 +5,7 @@ import (
 	"net"
 	"net/url"
 	"strings"
+	"sync"
 	"sync/atomic"
 	"testing"
 	"time"
@@ -13,6 +14,7 @@ import (
 	utilsstrings "github.com/gofiber/utils/v2/strings"
 	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
 	"github.com/valyala/fasthttp/fasthttputil"
 )
 
@@ -210,6 +212,29 @@ func Test_SubstitutePathParams(t *testing.T) {
 			want:    "http://example.com/api/v1/..%2F..%2Fadmin/end",
 			keepEsc: true,
 		},
+		{
+			// An escape cannot hide a dot segment: sent as written, "/files/pub/../meta"
+			// is resolved by the server or a proxy to "/files/meta".
+			name:    "a dot-dot value is rejected when normalizing is off",
+			uri:     "http://example.com/files/pub/:name/meta",
+			params:  PathParam{"name": ".."},
+			wantErr: ErrPathParamInPath,
+			keepEsc: true,
+		},
+		{
+			name:    "a dot value is rejected when normalizing is off",
+			uri:     "http://example.com/files/pub/:name/meta",
+			params:  PathParam{"name": "."},
+			wantErr: ErrPathParamInPath,
+			keepEsc: true,
+		},
+		{
+			name:    "a value of three dots is an ordinary segment when normalizing is off",
+			uri:     "http://example.com/files/pub/:name/meta",
+			params:  PathParam{"name": "..."},
+			want:    "http://example.com/files/pub/.../meta",
+			keepEsc: true,
+		},
 		{
 			// A "%2F" the caller typed is escaped to "%252F" and decodes to a
 			// literal "%2F", so it never becomes a separator.
@@ -245,10 +270,12 @@ func Test_SubstitutePathParams(t *testing.T) {
 			wantErr: ErrPathParamInPath,
 		},
 		{
-			name:    "an empty value collapses the placeholder when normalizing is off",
+			// Sent as written, "/api//x" is read as "/api/x" by a server that
+			// merges slashes, so the segment is gone there too.
+			name:    "an empty value is rejected when normalizing is off",
 			uri:     "http://example.com/api/:id/x",
 			params:  PathParam{"id": ""},
-			want:    "http://example.com/api//x",
+			wantErr: ErrPathParamInPath,
 			keepEsc: true,
 		},
 		{
@@ -483,6 +510,446 @@ func Test_PathParam_Traversal_NeverDials(t *testing.T) {
 	require.False(t, dialed.Load(), "the request was sent")
 }
 
+// pathRecorder is a server that records the request target exactly as it
+// arrived. It is the only reliable view of what the client wrote: the URI the
+// client holds is rewritten once more by fasthttp just before the request goes
+// out, so what Fiber built and what is sent can differ.
+type pathRecorder struct {
+	dial   fasthttp.DialFunc
+	target chan string
+}
+
+func startPathRecorder(t *testing.T) *pathRecorder {
+	t.Helper()
+
+	mem := fasthttputil.NewInmemoryListener()
+	ln := &acceptSignalListener{Listener: mem, accepting: make(chan struct{})}
+	rec := &pathRecorder{
+		target: make(chan string, 16),
+		dial:   func(string) (net.Conn, error) { return mem.Dial() },
+	}
+	server := &fasthttp.Server{Handler: func(ctx *fasthttp.RequestCtx) {
+		rec.target <- string(ctx.RequestURI())
+		ctx.SetStatusCode(fasthttp.StatusOK)
+	}}
+
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		assert.NoError(t, server.Serve(ln))
+	}()
+	// A test that expects the request to fail never reaches the server, so
+	// without this Shutdown can run before Serve has registered its listener,
+	// find nothing to close, and leave Serve blocked in Accept for good.
+	<-ln.accepting
+	t.Cleanup(func() {
+		require.NoError(t, server.Shutdown())
+		<-done
+	})
+
+	return rec
+}
+
+// acceptSignalListener closes accepting the first time it is asked to accept,
+// which is when the server has registered the listener.
+type acceptSignalListener struct {
+	net.Listener
+	accepting chan struct{}
+	once      sync.Once
+}
+
+func (l *acceptSignalListener) Accept() (net.Conn, error) {
+	l.once.Do(func() { close(l.accepting) })
+	return l.Listener.Accept() //nolint:wrapcheck // a transparent wrapper
+}
+
+// next returns the next request target the server saw.
+func (r *pathRecorder) next(t *testing.T) string {
+	t.Helper()
+
+	select {
+	case got := <-r.target:
+		return got
+	case <-time.After(5 * time.Second):
+		t.Fatal("the server saw no request")
+		return ""
+	}
+}
+
+// pathClientKinds lists every way of wrapping a fasthttp client. wrapped is the
+// DisablePathNormalizing the fasthttp client itself is created with, the only
+// way to have it before the Fiber client's own setting is applied. setterLifts
+// says whether SetDisablePathNormalizing alone lifts the path parameter check
+// for a client of that kind: NewWithClient cannot tell whether the fasthttp
+// client it is given has served a host already, so it needs wrapped as well.
+var pathClientKinds = []struct {
+	build       func(dial fasthttp.DialFunc, wrapped bool) *Client
+	name        string
+	setterLifts bool
+}{
+	{name: "New", setterLifts: true, build: func(dial fasthttp.DialFunc, wrapped bool) *Client {
+		c := New().SetDial(dial)
+		c.FasthttpClient().DisablePathNormalizing = wrapped
+		return c
+	}},
+	{name: "NewWithClient", build: func(dial fasthttp.DialFunc, wrapped bool) *Client {
+		return NewWithClient(&fasthttp.Client{Dial: dial, DisablePathNormalizing: wrapped})
+	}},
+	{name: "NewWithHostClient", setterLifts: true, build: func(dial fasthttp.DialFunc, wrapped bool) *Client {
+		return NewWithHostClient(&fasthttp.HostClient{Addr: "example.com:80", Dial: dial, DisablePathNormalizing: wrapped})
+	}},
+	{name: "NewWithLBClient", setterLifts: true, build: func(dial fasthttp.DialFunc, wrapped bool) *Client {
+		return NewWithLBClient(&fasthttp.LBClient{
+			Timeout: 5 * time.Second,
+			Clients: []fasthttp.BalancingClient{
+				&fasthttp.HostClient{Addr: "example.com:80", Dial: dial, DisablePathNormalizing: wrapped},
+			},
+		})
+	}},
+}
+
+// Test_Client_DisablePathNormalizing_Wire checks the path a server receives.
+// The Fiber setting used to be written to the request's URI only, and fasthttp
+// overwrites that field with its own client's just before it writes the
+// request, so "/a//b/./c%2Fd" went out as "/a/b/c/d" however it was set.
+func Test_Client_DisablePathNormalizing_Wire(t *testing.T) {
+	t.Parallel()
+
+	const (
+		target     = "http://example.com/a//b/./c%2Fd"
+		asWritten  = "/a//b/./c%2Fd"
+		normalized = "/a/b/c/d"
+	)
+
+	cases := []struct {
+		setup func(c *Client) *Client
+		name  string
+		want  string
+		cfg   Config
+		// wrapped is DisablePathNormalizing on the fasthttp client itself.
+		wrapped bool
+	}{
+		{name: "normalized by default", want: normalized},
+		{
+			name:  "the client setting sends the path as written",
+			setup: func(c *Client) *Client { return c.SetDisablePathNormalizing(true) },
+			want:  asWritten,
+		},
+		{
+			name:  "turning the client setting off again normalizes",
+			setup: func(c *Client) *Client { return c.SetDisablePathNormalizing(true).SetDisablePathNormalizing(false) },
+			want:  normalized,
+		},
+		{name: "a fasthttp client created not to normalize sends the path as written", wrapped: true, want: asWritten},
+		// A request cannot change a client that other requests share, so on its
+		// own the request setting does not reach the wire.
+		{name: "the request setting alone leaves the wire normalized", cfg: Config{DisablePathNormalizing: true}, want: normalized},
+	}
+
+	for _, kind := range pathClientKinds {
+		t.Run(kind.name, func(t *testing.T) {
+			t.Parallel()
+
+			for _, tc := range cases {
+				t.Run(tc.name, func(t *testing.T) {
+					t.Parallel()
+
+					rec := startPathRecorder(t)
+					c := kind.build(rec.dial, tc.wrapped)
+					if tc.setup != nil {
+						c = tc.setup(c)
+					}
+
+					resp, err := c.Get(target, tc.cfg)
+					require.NoError(t, err)
+					resp.Close()
+					require.Equal(t, tc.want, rec.next(t))
+				})
+			}
+		})
+	}
+}
+
+// Test_Client_DisablePathNormalizing_PathParamGuard is the property the setting
+// must never break: a path parameter value cannot change the path the template
+// names. The check that holds a value inside its segment was lifted by the
+// Fiber setting alone, which fasthttp ignored, so "x/../../admin" in
+// "/api/users/:id" reached the server as "/api/admin".
+func Test_Client_DisablePathNormalizing_PathParamGuard(t *testing.T) {
+	t.Parallel()
+
+	const (
+		target    = "http://example.com/api/users/:id"
+		traversal = "x/../../admin"
+		oneSeg    = "/api/users/x%2F..%2F..%2Fadmin"
+	)
+
+	cases := []struct {
+		setup func(c *Client) *Client
+		name  string
+		// want is the request target the server must see; empty means the
+		// request has to fail with ErrPathParamInPath before anything is sent.
+		want string
+		cfg  Config
+		// wrapped is DisablePathNormalizing on the fasthttp client itself.
+		wrapped bool
+		// bySetter marks a want that holds only for a client whose Fiber setting
+		// alone lifts the check; any other kind has to reject the value.
+		bySetter bool
+	}{
+		{name: "rejected by default"},
+		{
+			name: "rejected when only the request asks, because the path is still normalized",
+			cfg:  Config{DisablePathNormalizing: true},
+		},
+		{
+			name:     "kept in one segment when the client sends paths as written",
+			setup:    func(c *Client) *Client { return c.SetDisablePathNormalizing(true) },
+			want:     oneSeg,
+			bySetter: true,
+		},
+		{
+			name:  "rejected again once the client setting is turned off",
+			setup: func(c *Client) *Client { return c.SetDisablePathNormalizing(true).SetDisablePathNormalizing(false) },
+		},
+		{
+			name:    "kept in one segment when the request asks of a client that does not normalize",
+			cfg:     Config{DisablePathNormalizing: true},
+			wrapped: true,
+			want:    oneSeg,
+		},
+		{name: "rejected when nobody asked, even if the client does not normalize", wrapped: true},
+	}
+
+	for _, kind := range pathClientKinds {
+		t.Run(kind.name, func(t *testing.T) {
+			t.Parallel()
+
+			for _, tc := range cases {
+				t.Run(tc.name, func(t *testing.T) {
+					t.Parallel()
+
+					rec := startPathRecorder(t)
+					c := kind.build(rec.dial, tc.wrapped)
+					if tc.setup != nil {
+						c = tc.setup(c)
+					}
+
+					want := tc.want
+					if tc.bySetter && !kind.setterLifts {
+						want = ""
+					}
+
+					cfg := tc.cfg
+					cfg.PathParam = map[string]string{"id": traversal}
+					resp, err := c.Get(target, cfg)
+					if want == "" {
+						require.ErrorIs(t, err, ErrPathParamInPath)
+						require.Empty(t, rec.target, "the request was sent")
+						return
+					}
+
+					require.NoError(t, err)
+					resp.Close()
+					require.Equal(t, want, rec.next(t))
+				})
+			}
+		})
+	}
+}
+
+// Test_Client_DisablePathNormalizing_ValuesNoSettingLetsThrough covers the
+// values that cannot stay a segment however the path is sent. With the check
+// lifted a "/" in a value travels as "%2F", but ".." is a dot segment that the
+// server resolves, so "/files/pub/:name/meta" with ".." went out as
+// "/files/pub/../meta" and reached "/files/meta". An empty value gave
+// "/files/pub//meta", which a server that merges slashes reads as
+// "/files/pub/meta".
+func Test_Client_DisablePathNormalizing_ValuesNoSettingLetsThrough(t *testing.T) {
+	t.Parallel()
+
+	const target = "http://example.com/files/pub/:name/meta"
+
+	cases := []struct {
+		name string
+		val  string
+		// want is the request target the server must see; empty means the
+		// request has to fail with ErrPathParamInPath before anything is sent.
+		want string
+	}{
+		{name: "dot", val: "."},
+		{name: "dot-dot", val: ".."},
+		{name: "empty", val: ""},
+		// The two below show the check is lifted for these clients: only the
+		// values above are held back.
+		{name: "separator", val: "a/b", want: "/files/pub/a%2Fb/meta"},
+		{name: "three dots", val: "...", want: "/files/pub/.../meta"},
+	}
+
+	for _, kind := range pathClientKinds {
+		t.Run(kind.name, func(t *testing.T) {
+			t.Parallel()
+
+			for _, tc := range cases {
+				t.Run(tc.name, func(t *testing.T) {
+					t.Parallel()
+
+					rec := startPathRecorder(t)
+					// The fasthttp client is created not to normalize, which
+					// lifts the check for every kind.
+					c := kind.build(rec.dial, true).SetDisablePathNormalizing(true)
+					require.True(t, c.writesPathAsBuilt())
+
+					resp, err := c.Get(target, Config{PathParam: map[string]string{"name": tc.val}})
+					if tc.want == "" {
+						require.ErrorIs(t, err, ErrPathParamInPath)
+						require.Empty(t, rec.target, "the request was sent")
+						return
+					}
+
+					require.NoError(t, err)
+					resp.Close()
+					require.Equal(t, tc.want, rec.next(t))
+				})
+			}
+		})
+	}
+}
+
+// Test_Client_DisablePathNormalizing_ClientHandedOver covers a fasthttp.Client
+// that someone else may have used. It gives each host the setting it had when it
+// first served that host, so a wrapper made later cannot tell, from the field
+// alone, whether turning normalizing off reaches the host. Before the wrapper
+// kept the check on for such a client, "x/../../admin" in "/files/pub/:name"
+// reached the server as "/files/admin" through a client that had served the
+// host already.
+func Test_Client_DisablePathNormalizing_ClientHandedOver(t *testing.T) {
+	t.Parallel()
+
+	const target = "http://example.com/files/pub/:name"
+
+	get := func(c *Client, name string) (*Response, error) {
+		return c.Get(target, Config{PathParam: map[string]string{"name": name}})
+	}
+
+	t.Run("a client that served the host already keeps the check on", func(t *testing.T) {
+		t.Parallel()
+
+		rec := startPathRecorder(t)
+		fh := &fasthttp.Client{Dial: rec.dial}
+
+		warm, err := NewWithClient(fh).Get("http://example.com/warm")
+		require.NoError(t, err)
+		warm.Close()
+		require.Equal(t, "/warm", rec.next(t))
+
+		c := NewWithClient(fh).SetDisablePathNormalizing(true)
+		require.True(t, fh.DisablePathNormalizing, "the field is set for hosts not served yet")
+		require.False(t, c.writesPathAsBuilt(), "nothing says the host client keeps up")
+
+		_, err = get(c, "x/../../admin")
+		require.ErrorIs(t, err, ErrPathParamInPath)
+		require.Empty(t, rec.target, "the request was sent")
+	})
+
+	t.Run("a client not used yet cannot be told from one that was", func(t *testing.T) {
+		t.Parallel()
+
+		rec := startPathRecorder(t)
+		c := NewWithClient(&fasthttp.Client{Dial: rec.dial}).SetDisablePathNormalizing(true)
+		require.False(t, c.writesPathAsBuilt())
+
+		// The path itself goes out as written, because the host is new.
+		resp, err := c.Get("http://example.com/a//b/./c%2Fd")
+		require.NoError(t, err)
+		resp.Close()
+		require.Equal(t, "/a//b/./c%2Fd", rec.next(t))
+
+		_, err = get(c, "a/b")
+		require.ErrorIs(t, err, ErrPathParamInPath)
+	})
+
+	t.Run("a client created with the setting on lifts the check, used or not", func(t *testing.T) {
+		t.Parallel()
+
+		rec := startPathRecorder(t)
+		fh := &fasthttp.Client{Dial: rec.dial, DisablePathNormalizing: true}
+
+		warm, err := NewWithClient(fh).Get("http://example.com/warm")
+		require.NoError(t, err)
+		warm.Close()
+		require.Equal(t, "/warm", rec.next(t))
+
+		c := NewWithClient(fh).SetDisablePathNormalizing(true)
+		require.True(t, c.writesPathAsBuilt())
+
+		resp, err := get(c, "a/b")
+		require.NoError(t, err)
+		resp.Close()
+		require.Equal(t, "/files/pub/a%2Fb", rec.next(t))
+	})
+
+	t.Run("turning the setting off and on again keeps the check on", func(t *testing.T) {
+		t.Parallel()
+
+		rec := startPathRecorder(t)
+		c := NewWithClient(&fasthttp.Client{Dial: rec.dial, DisablePathNormalizing: true})
+		require.True(t, c.writesPathAsBuilt())
+
+		c.SetDisablePathNormalizing(false)
+		resp, err := c.Get("http://example.com/first")
+		require.NoError(t, err)
+		resp.Close()
+		require.Equal(t, "/first", rec.next(t))
+
+		c.SetDisablePathNormalizing(true)
+		require.False(t, c.writesPathAsBuilt(), "the host client made for /first normalizes")
+	})
+
+	t.Run("a client from New is its own", func(t *testing.T) {
+		t.Parallel()
+
+		rec := startPathRecorder(t)
+		c := New().SetDial(rec.dial).SetDisablePathNormalizing(true)
+		require.True(t, c.writesPathAsBuilt())
+
+		resp, err := get(c, "a/b")
+		require.NoError(t, err)
+		resp.Close()
+		require.Equal(t, "/files/pub/a%2Fb", rec.next(t))
+	})
+}
+
+// Test_Client_DisablePathNormalizing_AfterFirstRequest covers a client that has
+// already sent a request while normalizing. fasthttp.Client hands each host the
+// setting it has when it first creates that host's client and never updates it,
+// so turning normalizing off afterwards does not reach the host already served.
+// The check that keeps a path parameter in its segment has to stay, or "x/../../admin"
+// would change the path for that host.
+func Test_Client_DisablePathNormalizing_AfterFirstRequest(t *testing.T) {
+	t.Parallel()
+
+	rec := startPathRecorder(t)
+	c := New().SetDial(rec.dial)
+
+	resp, err := c.Get("http://example.com/first")
+	require.NoError(t, err)
+	resp.Close()
+	require.Equal(t, "/first", rec.next(t))
+
+	c.SetDisablePathNormalizing(true)
+	require.False(t, c.writesPathAsBuilt(), "the host client already created still normalizes")
+
+	resp, err = c.Get("http://example.com/a//b")
+	require.NoError(t, err)
+	resp.Close()
+	require.Equal(t, "/a/b", rec.next(t), "the host kept the setting it was created with")
+
+	_, err = c.Get("http://example.com/api/:id", Config{PathParam: map[string]string{"id": "x/../../admin"}})
+	require.ErrorIs(t, err, ErrPathParamInPath)
+	require.Empty(t, rec.target, "the request was sent")
+}
+
 // FuzzPathParamTarget asserts the property that matters at the other end of
 // the wire: whatever the value, the request either fails or targets exactly the
 // path the template names. The string-level fuzz below cannot see this — the
@@ -496,26 +963,57 @@ func FuzzPathParamTarget(f *testing.F) {
 	f.Fuzz(func(t *testing.T, val string) {
 		t.Parallel()
 
-		client := New()
-		req := AcquireRequest().
-			SetClient(client).
-			SetURL("http://example.com/api/v1/:id/end").
-			SetPathParam("id", val)
-		defer ReleaseRequest(req)
+		checkPathParamTarget(t, New(), val)
+	})
+}
 
-		if err := parserRequestURL(client, req); err != nil {
-			return
-		}
+// FuzzPathParamTargetAsWritten is the same property for a client that sends the
+// path as built. An escape holds a "/" in its segment there, but not a dot
+// segment, which the server resolves however the client writes it.
+func FuzzPathParamTargetAsWritten(f *testing.F) {
+	for _, seed := range []string{"", "..", ".", "...", "a/b", "../../admin", "%2e%2e", "..%2f", `a\b`, "a;b", "\r\n", "//", "....//", ".%2e", "%252e%252e", "a?b", "a#b", "ü"} {
+		f.Add(seed)
+	}
 
-		uri := req.RawRequest.URI()
-		path := string(uri.Path())
-		require.True(t, strings.HasPrefix(path, "/api/v1/"), "value left the template path: %q", path)
-		require.True(t, strings.HasSuffix(path, "/end"), "value left the template path: %q", path)
-		require.Equal(t, 4, strings.Count(path, "/"), "value changed the segment count: %q", path)
-		require.Equal(t, "example.com", string(uri.Host()), "value changed the host")
+	f.Fuzz(func(t *testing.T, val string) {
+		t.Parallel()
+
+		checkPathParamTarget(t, New().SetDisablePathNormalizing(true), val)
 	})
 }
 
+// checkPathParamTarget builds the URL of "/api/v1/:id/end" with val for id and
+// requires that it either fails or still targets exactly that path, with val as
+// one non-empty segment that is no dot segment. The path is read from the
+// request target, which is what goes out on the wire: the normalized path, or
+// the original one when the client sends paths as written.
+func checkPathParamTarget(t *testing.T, client *Client, val string) {
+	t.Helper()
+
+	req := AcquireRequest().
+		SetClient(client).
+		SetURL("http://example.com/api/v1/:id/end").
+		SetPathParam("id", val)
+	defer ReleaseRequest(req)
+
+	if err := parserRequestURL(client, req); err != nil {
+		return
+	}
+
+	uri := req.RawRequest.URI()
+	path, _, _ := strings.Cut(string(uri.RequestURI()), "?")
+	require.True(t, strings.HasPrefix(path, "/"), "value left the template path: %q", path)
+
+	segments := strings.Split(path[1:], "/")
+	require.Len(t, segments, 4, "value changed the segment count: %q", path)
+	require.Equal(t, "api", segments[0], "value left the template path: %q", path)
+	require.Equal(t, "v1", segments[1], "value left the template path: %q", path)
+	require.Equal(t, "end", segments[3], "value left the template path: %q", path)
+	require.NotEmpty(t, segments[2], "value dropped its segment: %q", path)
+	require.NotContains(t, []string{".", ".."}, segments[2], "value made a dot segment: %q", path)
+	require.Equal(t, "example.com", string(uri.Host()), "value changed the host")
+}
+
 // FuzzPathParamHost is the same property for the authority: a value either
 // fails or stays one label of the domain the template names. This is the one
 // that has to hold, because getting it wrong sends the request elsewhere.
@@ -553,7 +1051,7 @@ func FuzzPathParamHost(f *testing.F) {
 // hold: whatever the value contains, it stays one path segment and survives a
 // decode unchanged.
 func FuzzSubstitutePathParams(f *testing.F) {
-	for _, seed := range []string{"", "5", "a/b", "a?b", "a#b", "100%", ":name", "a b", "ünïcode", "%2F", "//", "?#/"} {
+	for _, seed := range []string{"", "5", "a/b", "a?b", "a#b", "100%", ":name", "a b", "ünïcode", "%2F", "//", "?#/", ".", "..", "..."} {
 		f.Add(seed)
 	}
 
@@ -561,6 +1059,10 @@ func FuzzSubstitutePathParams(f *testing.F) {
 		t.Parallel()
 
 		got, err := substitutePathParams("/a/:p/b", true, PathParam{"p": val})
+		if cannotFillSegment(val) {
+			require.ErrorIs(t, err, ErrPathParamInPath)
+			return
+		}
 		require.NoError(t, err)
 
 		parts := strings.Split(got, "/")
diff --git a/client/hooks_test.go b/client/hooks_test.go
index 0ece54ef346..ed469fc9b15 100644
--- a/client/hooks_test.go
+++ b/client/hooks_test.go
@@ -8,6 +8,7 @@ import (
 	"net"
 	"net/url"
 	"path/filepath"
+	"strconv"
 	"strings"
 	"testing"
 
@@ -207,9 +208,21 @@ func Test_Parser_Request_URL(t *testing.T) {
 		require.Equal(t, "http://example.com/api/a%3Fb", req.RawRequest.URI().String())
 	})
 
-	t.Run("path param value keeps its escaped separator when normalizing is off", func(t *testing.T) {
+	t.Run("path param value keeps its escaped separator when the client does not normalize", func(t *testing.T) {
 		t.Parallel()
-		client := New()
+		client := New().SetDisablePathNormalizing(true)
+		req := AcquireRequest().
+			SetURL("http://example.com/api/:id").
+			SetPathParam("id", "a/b")
+
+		err := parserRequestURL(client, req)
+		require.NoError(t, err)
+		require.Equal(t, "http://example.com/api/a%2Fb", req.RawRequest.URI().String())
+	})
+
+	t.Run("a request can ask for its escaped separator from a client that does not normalize", func(t *testing.T) {
+		t.Parallel()
+		client := NewWithClient(&fasthttp.Client{DisablePathNormalizing: true})
 		req := AcquireRequest().
 			SetURL("http://example.com/api/:id").
 			SetPathParam("id", "a/b").
@@ -220,6 +233,31 @@ func Test_Parser_Request_URL(t *testing.T) {
 		require.Equal(t, "http://example.com/api/a%2Fb", req.RawRequest.URI().String())
 	})
 
+	// The wrapped client rewrites the path whatever the request says, so the
+	// request alone cannot make a separator in a value safe.
+	t.Run("a separator in a value is rejected when only the request disables normalizing", func(t *testing.T) {
+		t.Parallel()
+		client := New()
+		req := AcquireRequest().
+			SetURL("http://example.com/api/:id").
+			SetPathParam("id", "a/b").
+			SetDisablePathNormalizing(true)
+
+		err := parserRequestURL(client, req)
+		require.ErrorIs(t, err, ErrPathParamInPath)
+	})
+
+	t.Run("a separator in a value is rejected when only the fasthttp client does not normalize", func(t *testing.T) {
+		t.Parallel()
+		client := NewWithClient(&fasthttp.Client{DisablePathNormalizing: true})
+		req := AcquireRequest().
+			SetURL("http://example.com/api/:id").
+			SetPathParam("id", "a/b")
+
+		err := parserRequestURL(client, req)
+		require.ErrorIs(t, err, ErrPathParamInPath)
+	})
+
 	t.Run("a separator in a value is rejected when normalizing will decode it", func(t *testing.T) {
 		t.Parallel()
 		client := New()
@@ -520,6 +558,42 @@ func Test_Parser_Request_Header(t *testing.T) {
 		require.Equal(t, []byte("https://example.com"), req.RawRequest.Header.Referer())
 	})
 
+	// An empty "Referer:" says nothing that a missing header does not, and it
+	// went out on every request that never asked for one.
+	t.Run("no referer sends no Referer header", func(t *testing.T) {
+		t.Parallel()
+		client := New()
+		req := AcquireRequest()
+
+		err := parserRequestHeader(client, req)
+		require.NoError(t, err)
+		require.False(t, hasRefererHeader(&req.RawRequest.Header))
+	})
+
+	t.Run("a Referer set through the headers is replaced, not kept empty", func(t *testing.T) {
+		t.Parallel()
+		client := New()
+		req := AcquireRequest().SetHeader(fiber.HeaderReferer, "https://header.example")
+
+		err := parserRequestHeader(client, req)
+		require.NoError(t, err)
+		require.False(t, hasRefererHeader(&req.RawRequest.Header))
+	})
+
+	t.Run("a referer that is no longer set does not linger on a resend", func(t *testing.T) {
+		t.Parallel()
+		client := New()
+		req := AcquireRequest().SetReferer("https://example.com")
+
+		require.NoError(t, parserRequestHeader(client, req))
+		require.Equal(t, []byte("https://example.com"), req.RawRequest.Header.Referer())
+
+		// Clearing the request value leaves the client's, which is unset.
+		req.SetReferer("")
+		require.NoError(t, parserRequestHeader(client, req))
+		require.False(t, hasRefererHeader(&req.RawRequest.Header))
+	})
+
 	t.Run("client cookie should be set", func(t *testing.T) {
 		t.Parallel()
 		client := New().
@@ -1099,3 +1173,40 @@ func Test_Client_ResponseCookie_UnparsableAttribute(t *testing.T) {
 	require.Equal(t, "/api", string(got.Path()))
 	require.True(t, got.Expire().IsZero() || got.Expire().Equal(fasthttp.CookieExpireUnlimited))
 }
+
+// hasRefererHeader reports whether h carries a Referer header, an empty one
+// included: Referer answers with an empty value for a missing header and for an
+// empty one alike.
+func hasRefererHeader(h *fasthttp.RequestHeader) bool {
+	for name := range h.All() {
+		if strings.EqualFold(string(name), fiber.HeaderReferer) {
+			return true
+		}
+	}
+	return false
+}
+
+// Test_Client_NoRefererByDefault checks the request a server receives: a client
+// with no referer configured must not send the header at all.
+func Test_Client_NoRefererByDefault(t *testing.T) {
+	t.Parallel()
+
+	server := startTestServer(t, func(app *fiber.App) {
+		app.Get("/", func(c fiber.Ctx) error {
+			return c.SendString(strconv.FormatBool(hasRefererHeader(&c.Request().Header)))
+		})
+	})
+	defer server.stop()
+
+	client := New().SetDial(server.dial())
+
+	resp, err := client.Get("http://example.com/")
+	require.NoError(t, err)
+	require.Equal(t, "false", resp.String())
+	resp.Close()
+
+	resp, err = client.Get("http://example.com/", Config{Referer: "https://example.org/"})
+	require.NoError(t, err)
+	require.Equal(t, "true", resp.String())
+	resp.Close()
+}
diff --git a/client/transport_test.go b/client/transport_test.go
index db5f75b70c0..940a3895de5 100644
--- a/client/transport_test.go
+++ b/client/transport_test.go
@@ -901,6 +901,247 @@ func Test_httpClientTransport_Interface(t *testing.T) {
 	}
 }
 
+// Test_Transport_PathNormalizing covers the setting that decides what reaches the
+// wire: the wrapped client's own field, read and written through every kind of
+// transport.
+func Test_Transport_PathNormalizing(t *testing.T) {
+	t.Parallel()
+
+	t.Run("fasthttp.Client the Fiber client made", func(t *testing.T) {
+		t.Parallel()
+
+		tr := newOwnedStandardClientTransport()
+		fc := tr.client
+		require.False(t, tr.DisablePathNormalizing())
+
+		tr.SetDisablePathNormalizing(true)
+		require.True(t, tr.DisablePathNormalizing())
+		require.True(t, fc.DisablePathNormalizing)
+
+		tr.SetDisablePathNormalizing(false)
+		require.False(t, tr.DisablePathNormalizing())
+		require.False(t, fc.DisablePathNormalizing)
+	})
+
+	t.Run("fasthttp.Client handed over normalizing", func(t *testing.T) {
+		t.Parallel()
+
+		fc := &fasthttp.Client{}
+		tr := newStandardClientTransport(fc)
+		require.False(t, tr.DisablePathNormalizing())
+
+		// The field is written, so hosts not served yet get it, but the
+		// transport cannot say the hosts served already follow.
+		tr.SetDisablePathNormalizing(true)
+		require.True(t, fc.DisablePathNormalizing)
+		require.False(t, tr.DisablePathNormalizing())
+
+		tr.SetDisablePathNormalizing(false)
+		require.False(t, fc.DisablePathNormalizing)
+		require.False(t, tr.DisablePathNormalizing())
+	})
+
+	t.Run("fasthttp.Client handed over with the setting on", func(t *testing.T) {
+		t.Parallel()
+
+		fc := &fasthttp.Client{DisablePathNormalizing: true}
+		tr := newStandardClientTransport(fc)
+		require.True(t, tr.DisablePathNormalizing())
+
+		tr.SetDisablePathNormalizing(false)
+		require.False(t, tr.DisablePathNormalizing())
+		require.False(t, fc.DisablePathNormalizing)
+
+		// Still known: no request has gone out in between.
+		tr.SetDisablePathNormalizing(true)
+		require.True(t, tr.DisablePathNormalizing())
+	})
+
+	t.Run("fasthttp.HostClient", func(t *testing.T) {
+		t.Parallel()
+
+		hc := &fasthttp.HostClient{}
+		tr := newHostClientTransport(hc)
+		require.False(t, tr.DisablePathNormalizing())
+
+		tr.SetDisablePathNormalizing(true)
+		require.True(t, tr.DisablePathNormalizing())
+		require.True(t, hc.DisablePathNormalizing)
+
+		tr.SetDisablePathNormalizing(false)
+		require.False(t, hc.DisablePathNormalizing)
+	})
+
+	t.Run("fasthttp.LBClient writes every host client, nested ones included", func(t *testing.T) {
+		t.Parallel()
+
+		direct := &fasthttp.HostClient{Addr: "a.example:80"}
+		inner := &fasthttp.HostClient{Addr: "b.example:80"}
+		deeper := &fasthttp.HostClient{Addr: "c.example:80"}
+		tr := newLBClientTransport(&fasthttp.LBClient{Clients: []fasthttp.BalancingClient{
+			direct,
+			&lbBalancingClient{client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{
+				inner,
+				&lbBalancingClient{client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{deeper}}},
+			}}},
+		}})
+		require.False(t, tr.DisablePathNormalizing())
+
+		tr.SetDisablePathNormalizing(true)
+		require.True(t, tr.DisablePathNormalizing())
+		for _, hc := range []*fasthttp.HostClient{direct, inner, deeper} {
+			require.True(t, hc.DisablePathNormalizing, hc.Addr)
+		}
+
+		tr.SetDisablePathNormalizing(false)
+		for _, hc := range []*fasthttp.HostClient{direct, inner, deeper} {
+			require.False(t, hc.DisablePathNormalizing, hc.Addr)
+		}
+	})
+
+	t.Run("fasthttp.LBClient reports false while any client normalizes", func(t *testing.T) {
+		t.Parallel()
+
+		quiet := &fasthttp.HostClient{Addr: "a.example:80", DisablePathNormalizing: true}
+		normalizing := &fasthttp.HostClient{Addr: "b.example:80"}
+
+		tests := []struct {
+			name    string
+			clients []fasthttp.BalancingClient
+			want    bool
+		}{
+			{name: "all leave the path alone", clients: []fasthttp.BalancingClient{quiet, quiet}, want: true},
+			{name: "one normalizes", clients: []fasthttp.BalancingClient{quiet, normalizing}},
+			{name: "a nested balancer holds one that normalizes", clients: []fasthttp.BalancingClient{
+				quiet, &lbBalancingClient{client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{quiet, normalizing}}},
+			}},
+			{name: "a nested balancer where all leave it alone", clients: []fasthttp.BalancingClient{
+				quiet, &lbBalancingClient{client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{quiet}}},
+			}, want: true},
+			{name: "a nested balancer with no clients", clients: []fasthttp.BalancingClient{
+				quiet, &lbBalancingClient{client: &fasthttp.LBClient{}},
+			}},
+			{name: "a client that cannot be inspected", clients: []fasthttp.BalancingClient{quiet, stubBalancingClient{}}},
+			{name: "a wrapper exposing no balancer", clients: []fasthttp.BalancingClient{quiet, &lbBalancingClient{}}},
+			{name: "no clients", clients: nil},
+		}
+		for _, tc := range tests {
+			t.Run(tc.name, func(t *testing.T) {
+				t.Parallel()
+				tr := newLBClientTransport(&fasthttp.LBClient{Clients: tc.clients})
+				require.Equal(t, tc.want, tr.DisablePathNormalizing())
+			})
+		}
+	})
+
+	t.Run("setting an empty balancer is harmless", func(t *testing.T) {
+		t.Parallel()
+
+		tr := newLBClientTransport(&fasthttp.LBClient{})
+		tr.SetDisablePathNormalizing(true)
+		require.False(t, tr.DisablePathNormalizing(), "nothing behind it can be told")
+	})
+}
+
+// Test_Client_SetDisablePathNormalizing_AppliesToTheWrappedClient checks the
+// setter reaches the fasthttp client each constructor wraps, and that Reset
+// returns to a default client that normalizes.
+func Test_Client_SetDisablePathNormalizing_AppliesToTheWrappedClient(t *testing.T) {
+	t.Parallel()
+
+	host := &fasthttp.HostClient{Addr: "example.com:80"}
+	lbHost := &fasthttp.HostClient{Addr: "example.com:80"}
+	std := &fasthttp.Client{}
+
+	tests := []struct {
+		client *Client
+		field  func() bool
+		name   string
+		// lifts is whether the setter alone makes the client send paths as built
+		// as far as Fiber can tell. A fasthttp.Client handed to NewWithClient may
+		// have served hosts already, so it does not.
+		lifts bool
+	}{
+		{name: "New", client: New(), lifts: true},
+		{name: "NewWithClient", client: NewWithClient(std), field: func() bool { return std.DisablePathNormalizing }},
+		{name: "NewWithHostClient", client: NewWithHostClient(host), field: func() bool { return host.DisablePathNormalizing }, lifts: true},
+		{
+			name:   "NewWithLBClient",
+			client: NewWithLBClient(&fasthttp.LBClient{Clients: []fasthttp.BalancingClient{lbHost}}),
+			field:  func() bool { return lbHost.DisablePathNormalizing },
+			lifts:  true,
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			c := tc.client
+			field := tc.field
+			if field == nil { // New: the client creates its own fasthttp client
+				field = func() bool { return c.FasthttpClient().DisablePathNormalizing }
+			}
+			require.False(t, c.writesPathAsBuilt())
+
+			c.SetDisablePathNormalizing(true)
+			require.True(t, c.DisablePathNormalizing())
+			require.True(t, field())
+			require.Equal(t, tc.lifts, c.writesPathAsBuilt())
+
+			c.SetDisablePathNormalizing(false)
+			require.False(t, c.DisablePathNormalizing())
+			require.False(t, field())
+			require.False(t, c.writesPathAsBuilt())
+		})
+	}
+
+	t.Run("NewWithClient created with the setting on", func(t *testing.T) {
+		t.Parallel()
+
+		std := &fasthttp.Client{DisablePathNormalizing: true}
+		c := NewWithClient(std)
+		require.True(t, c.writesPathAsBuilt())
+		require.False(t, c.DisablePathNormalizing(), "the Fiber setting is not what turned it on")
+
+		c.SetDisablePathNormalizing(false)
+		require.False(t, std.DisablePathNormalizing)
+		require.False(t, c.writesPathAsBuilt())
+	})
+
+	t.Run("Reset", func(t *testing.T) {
+		t.Parallel()
+
+		c := New().SetDisablePathNormalizing(true)
+		require.True(t, c.writesPathAsBuilt())
+
+		c.Reset()
+		require.False(t, c.DisablePathNormalizing())
+		require.False(t, c.writesPathAsBuilt())
+		require.False(t, c.FasthttpClient().DisablePathNormalizing)
+	})
+}
+
+// Test_Client_PathNormalizing_UnknownTransport covers a transport that has no
+// path normalizing setting to read: it counts as one that normalizes, so setting
+// the flag does nothing to it and the path parameter check stays on.
+func Test_Client_PathNormalizing_UnknownTransport(t *testing.T) {
+	t.Parallel()
+
+	c := newClient(newBlockingErrTransport(nil))
+	require.NotPanics(t, func() { c.SetDisablePathNormalizing(true) })
+	require.True(t, c.DisablePathNormalizing())
+	require.False(t, c.writesPathAsBuilt())
+
+	req := AcquireRequest().
+		SetURL("http://example.com/api/:id").
+		SetPathParam("id", "x/../../admin").
+		SetDisablePathNormalizing(true)
+	t.Cleanup(func() { ReleaseRequest(req) })
+
+	require.ErrorIs(t, parserRequestURL(c, req), ErrPathParamInPath)
+}
+
 // Test_Transport_DoRedirects_KeepsPathNormalizingDisabled covers a transport
 // wrapping a client that asked for the path to be left alone.
 //
diff --git a/ctx_test.go b/ctx_test.go
index e9edcc41993..de9350cb0d4 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -19,6 +19,7 @@ import (
 	"io"
 	"io/fs"
 	"math"
+	"mime"
 	"mime/multipart"
 	"net"
 	"net/http"
@@ -29,6 +30,7 @@ import (
 	"runtime"
 	"strconv"
 	"strings"
+	"sync"
 	"sync/atomic"
 	"testing"
 	"testing/fstest"
@@ -10579,6 +10581,104 @@ func Test_Ctx_Type(t *testing.T) {
 	require.Equal(t, "text/html; charset=iso-8859-1", string(c.Response().Header.Peek("Content-Type")))
 }
 
+// registerTestMIMETypes adds extensions the standard library answers with
+// parameters of its own, which is what utils.GetMIME falls back to for an
+// extension outside its table (csv and mjs among them). They are registered here
+// so the tests do not depend on the MIME database of the machine that runs them.
+var registerTestMIMETypes = sync.OnceFunc(func() {
+	for ext, mimeType := range map[string]string{
+		".fibertestcsv":     "text/x-fibercsv; charset=utf-8",
+		".fibertestlatin":   "text/x-fiberlatin; charset=iso-8859-1",
+		".fibertestparam":   "application/x-fiberparam; version=2",
+		".fibertestboth":    "application/x-fiberboth; version=2; charset=utf-8",
+		".fibertestcaps":    "text/x-fibercaps; Charset=UTF-8",
+		".fibertestspacing": "text/x-fiberspacing ;  charset=utf-8 ; version=3",
+	} {
+		if err := mime.AddExtensionType(ext, mimeType); err != nil {
+			panic(err)
+		}
+	}
+})
+
+// go test -run Test_Ctx_Type_NeverTwoCharsets
+//
+// Whatever the machine's MIME database holds, no extension may produce two
+// charsets, with or without an explicit one. utils.GetMIME hands back the bare
+// type for an extension outside its table (utils v2.6.2 and later); with the
+// parameters of the standard library's answer left on, "text/csv; charset=utf-8"
+// plus the charset Type appends sent two.
+func Test_Ctx_Type_NeverTwoCharsets(t *testing.T) {
+	t.Parallel()
+	registerTestMIMETypes()
+
+	extensions := []string{
+		"csv", "mjs", "md", "markdown", "ics", "vcf", "tsv", "go", "log", "vtt", "py", "c", "h", "java", "yaml", "toml",
+		"html", "htm", "css", "js", "json", "xml", "txt", "svg", "wasm", "pdf", "png", "unknownext",
+		"fibertestcsv", "fibertestlatin", "fibertestparam", "fibertestboth", "fibertestcaps", "fibertestspacing",
+	}
+
+	app := New()
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(c)
+
+	for _, ext := range extensions {
+		for _, charset := range [][]string{nil, {"utf-8"}, {"iso-8859-1"}} {
+			c.Type(ext, charset...)
+			contentType := string(c.Response().Header.Peek(HeaderContentType))
+			require.LessOrEqual(t, strings.Count(strings.ToLower(contentType), "charset="), 1,
+				"Type(%q, %v) sent %q", ext, charset, contentType)
+			if len(charset) > 0 {
+				require.Contains(t, contentType, "charset="+charset[0], "Type(%q, %v) sent %q", ext, charset, contentType)
+			}
+		}
+	}
+}
+
+// go test -run Test_Ctx_Attachment_Charset
+func Test_Ctx_Attachment_Charset(t *testing.T) {
+	t.Parallel()
+	registerTestMIMETypes()
+
+	app := New()
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(c)
+
+	c.Attachment("report.fibertestcsv")
+	require.Equal(t, "text/x-fibercsv; charset=utf-8", string(c.Response().Header.Peek(HeaderContentType)))
+	require.Equal(t, `attachment; filename="report.fibertestcsv"`, string(c.Response().Header.Peek(HeaderContentDisposition)))
+
+	c.Attachment("notes.txt")
+	require.Equal(t, "text/plain; charset=utf-8", string(c.Response().Header.Peek(HeaderContentType)))
+
+	c.Attachment("image.png")
+	require.Equal(t, "image/png", string(c.Response().Header.Peek(HeaderContentType)))
+}
+
+// go test -run Test_Ctx_Is_And_Accepts_ExtensionWithCharset
+//
+// Is and Accepts compare the type itself, so they match an extension only while
+// utils.GetMIME answers it without parameters: "text/x-fibercsv; charset=utf-8"
+// is not the "text/x-fibercsv" a request names.
+func Test_Ctx_Is_And_Accepts_ExtensionWithCharset(t *testing.T) {
+	t.Parallel()
+	registerTestMIMETypes()
+
+	app := New()
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(c)
+
+	c.Request().Header.SetContentType("text/x-fibercsv; charset=utf-8")
+	require.True(t, c.Is("fibertestcsv"))
+	require.False(t, c.Is("fibertestlatin"))
+
+	c.Request().Header.Set(HeaderAccept, "text/x-fibercsv")
+	require.Equal(t, "fibertestcsv", c.Accepts("fibertestcsv"))
+	require.Empty(t, c.Accepts("fibertestlatin"))
+
+	c.Request().Header.Set(HeaderAccept, "text/*")
+	require.Equal(t, "fibertestcsv", c.Accepts("fibertestcsv"))
+}
+
 // go test -run Test_shouldIncludeCharset
 func Test_shouldIncludeCharset(t *testing.T) {
 	t.Parallel()
diff --git a/middleware/basicauth/basicauth_test.go b/middleware/basicauth/basicauth_test.go
index ea5fb98b1b5..79f67ba3d6e 100644
--- a/middleware/basicauth/basicauth_test.go
+++ b/middleware/basicauth/basicauth_test.go
@@ -221,6 +221,121 @@ func Test_BasicAuth_AuthorizerCtx(t *testing.T) {
 	require.True(t, called)
 }
 
+// Test_BasicAuth_NoConfig covers New() called without a Config. It used to hand
+// back the package default untouched, whose Authorizer, Unauthorized and
+// BadRequest are nil, so the first request called a nil function. With no users
+// and no Authorizer every request has to be refused, never served or crashed on.
+func Test_BasicAuth_NoConfig(t *testing.T) {
+	t.Parallel()
+
+	for name, handler := range map[string]fiber.Handler{
+		"New()":         New(),
+		"New(Config{})": New(Config{}),
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(handler)
+			app.Get("/", func(c fiber.Ctx) error {
+				return c.SendStatus(fiber.StatusTeapot)
+			})
+
+			tests := []struct {
+				name          string
+				authorization string
+				want          int
+			}{
+				{name: "no credentials", want: fiber.StatusUnauthorized},
+				{name: "credentials for a user nobody configured", authorization: "Basic " + base64.StdEncoding.EncodeToString([]byte("john:doe")), want: fiber.StatusUnauthorized},
+				{name: "empty username and password", authorization: "Basic " + base64.StdEncoding.EncodeToString([]byte(":")), want: fiber.StatusUnauthorized},
+				{name: "another scheme", authorization: "Bearer token", want: fiber.StatusUnauthorized},
+				{name: "malformed credentials", authorization: "Basic notbase64", want: fiber.StatusBadRequest},
+			}
+			for _, tc := range tests {
+				t.Run(tc.name, func(t *testing.T) {
+					t.Parallel()
+
+					req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+					if tc.authorization != "" {
+						req.Header.Set(fiber.HeaderAuthorization, tc.authorization)
+					}
+
+					resp, err := app.Test(req)
+					require.NoError(t, err)
+					require.Equal(t, tc.want, resp.StatusCode)
+					if tc.want == fiber.StatusUnauthorized {
+						require.Equal(t, `Basic realm="Restricted", charset="UTF-8"`, resp.Header.Get(fiber.HeaderWWWAuthenticate))
+					}
+				})
+			}
+		})
+	}
+}
+
+// Test_BasicAuth_ConfigDefault_NoConfig pins that the no-config path runs the same
+// defaulting as the config path, so no handler is left nil.
+func Test_BasicAuth_ConfigDefault_NoConfig(t *testing.T) {
+	t.Parallel()
+
+	cfg := configDefault()
+	require.NotNil(t, cfg.Authorizer)
+	require.NotNil(t, cfg.Unauthorized)
+	require.NotNil(t, cfg.BadRequest)
+	require.Equal(t, ConfigDefault.Realm, cfg.Realm)
+	require.Equal(t, ConfigDefault.Charset, cfg.Charset)
+	require.Equal(t, ConfigDefault.HeaderLimit, cfg.HeaderLimit)
+	require.False(t, cfg.Authorizer("john", "doe", nil), "nobody is configured")
+
+	// The package default itself stays what it documents.
+	require.Nil(t, ConfigDefault.Authorizer)
+	require.Nil(t, ConfigDefault.Unauthorized)
+	require.Nil(t, ConfigDefault.BadRequest)
+}
+
+// Test_BasicAuth_Unauthorized_KeepsVary covers the default 401 handler, which
+// replaced a Vary an earlier middleware had set (Origin from CORS, for one)
+// instead of adding Authorization to it.
+func Test_BasicAuth_Unauthorized_KeepsVary(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(func(c fiber.Ctx) error {
+		if earlier := c.Get("X-Earlier-Vary"); earlier != "" {
+			c.Set(fiber.HeaderVary, earlier)
+		}
+		return c.Next()
+	})
+	app.Use(New(Config{Users: map[string]string{"john": sha256Hash("doe")}}))
+
+	tests := []struct {
+		name    string
+		earlier string
+		want    string
+	}{
+		{name: "no earlier Vary", want: "Authorization"},
+		{name: "an earlier field is kept", earlier: "Origin", want: "Origin, Authorization"},
+		{name: "several earlier fields are kept", earlier: "Origin, Accept-Encoding", want: "Origin, Accept-Encoding, Authorization"},
+		{name: "a field already listed is not repeated", earlier: "Origin, authorization", want: "Origin, authorization"},
+		{name: "a wildcard stays the only member", earlier: "*", want: "*"},
+	}
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+			if tc.earlier != "" {
+				req.Header.Set("X-Earlier-Vary", tc.earlier)
+			}
+
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusUnauthorized, resp.StatusCode)
+			require.Equal(t, []string{tc.want}, resp.Header.Values(fiber.HeaderVary))
+		})
+	}
+}
+
 func Test_BasicAuth_WWWAuthenticateHeader(t *testing.T) {
 	t.Parallel()
 	app := fiber.New()
diff --git a/middleware/cache/cache_test.go b/middleware/cache/cache_test.go
index d7b16155c13..536a8bc236c 100644
--- a/middleware/cache/cache_test.go
+++ b/middleware/cache/cache_test.go
@@ -3126,6 +3126,73 @@ func Test_CacheOnlyIfCachedStaleNotServed(t *testing.T) {
 	require.Equal(t, 1, count)
 }
 
+// Test_CacheOnlyIfCachedWithNoCache covers a request that asks for a stored
+// response and refuses to have it served unvalidated. RFC 9111 Section 5.2.1.7
+// has a cache that cannot satisfy only-if-cached without contacting the origin
+// answer 504, and validating a stored response is contacting the origin. The
+// fresh entry used to fall through to the handler instead.
+func Test_CacheOnlyIfCachedWithNoCache(t *testing.T) {
+	t.Parallel()
+
+	requests := []struct {
+		header map[string]string
+		name   string
+	}{
+		{name: "no-cache beside only-if-cached", header: map[string]string{fiber.HeaderCacheControl: "no-cache, only-if-cached"}},
+		{name: "only-if-cached before no-cache", header: map[string]string{fiber.HeaderCacheControl: "only-if-cached, no-cache"}},
+		{name: "Pragma no-cache", header: map[string]string{fiber.HeaderCacheControl: "only-if-cached", fiber.HeaderPragma: "no-cache"}},
+		{name: "max-age=0 behaves the same way", header: map[string]string{fiber.HeaderCacheControl: "max-age=0, only-if-cached"}},
+	}
+
+	for _, storageName := range []string{"in-memory", "storage"} {
+		for _, tc := range requests {
+			t.Run(storageName+"/"+tc.name, func(t *testing.T) {
+				t.Parallel()
+
+				cfg := Config{}
+				if storageName == "storage" {
+					cfg.Storage = memory.New()
+				}
+
+				app := fiber.New()
+				app.Use(New(cfg))
+
+				var calls atomic.Int32
+				app.Get("/", func(c fiber.Ctx) error {
+					c.Set(fiber.HeaderCacheControl, "public, max-age=60")
+					return c.SendString("origin-" + strconv.Itoa(int(calls.Add(1))))
+				})
+
+				// A fresh entry, stored by an ordinary request.
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+				require.Equal(t, int32(1), calls.Load())
+
+				req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+				for k, v := range tc.header {
+					req.Header.Set(k, v)
+				}
+				resp, err = app.Test(req)
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusGatewayTimeout, resp.StatusCode)
+				require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+				require.Equal(t, int32(1), calls.Load(), "only-if-cached must not reach the handler")
+
+				// The refusal leaves the stored response alone.
+				resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusOK, resp.StatusCode)
+				require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+				body, err := io.ReadAll(resp.Body)
+				require.NoError(t, err)
+				require.Equal(t, "origin-1", string(body))
+				require.Equal(t, int32(1), calls.Load())
+			})
+		}
+	}
+}
+
 func Test_CacheMaxStaleServesStaleResponse(t *testing.T) {
 	t.Parallel()
 
diff --git a/middleware/limiter/limiter_test.go b/middleware/limiter/limiter_test.go
index e46a2822039..a97bb4176c8 100644
--- a/middleware/limiter/limiter_test.go
+++ b/middleware/limiter/limiter_test.go
@@ -1041,6 +1041,99 @@ func Test_Limiter_Sliding_ExpirationFunc_FallbackOnNegativeDuration(t *testing.T
 	require.Equal(t, fiber.StatusTooManyRequests, resp.StatusCode)
 }
 
+// Test_Limiter_ExpirationFunc_NonPositiveUsesConfiguredExpiration covers an
+// ExpirationFunc that returns zero or less: the window is the configured
+// Expiration, not the package default of one minute. Only the existing tests
+// for this fallback checked that the limiter still limits, so a configured
+// ten-second window was a minute long for those requests, and Retry-After and
+// X-RateLimit-Reset said so.
+func Test_Limiter_ExpirationFunc_NonPositiveUsesConfiguredExpiration(t *testing.T) {
+	t.Parallel()
+
+	const expiration = 10 * time.Second
+
+	strategies := []struct {
+		handler Handler
+		// storage returns the store the strategy is tested with: the fixed window
+		// keeps its entry in storage, whose own expiry would otherwise run on
+		// real time while the test moves a fake clock.
+		storage func() fiber.Storage
+		name    string
+	}{
+		{name: "fixed", handler: FixedWindow{}, storage: func() fiber.Storage { return newInjectedClockStorage() }},
+		{name: "sliding", handler: SlidingWindow{}, storage: func() fiber.Storage { return nil }},
+	}
+
+	for _, strategy := range strategies {
+		for _, returned := range []time.Duration{0, -time.Second} {
+			t.Run(strategy.name+"/"+returned.String(), func(t *testing.T) {
+				t.Parallel()
+
+				clock := newTestClock(time.Now().Truncate(time.Second))
+				app := fiber.New()
+				app.Use(New(Config{
+					Max:               1,
+					Expiration:        expiration,
+					ExpirationFunc:    func(fiber.Ctx) time.Duration { return returned },
+					LimiterMiddleware: strategy.handler,
+					clock:             clock.Now,
+					Storage:           strategy.storage(),
+				}))
+				app.Get("/", func(c fiber.Ctx) error {
+					return c.SendStatus(fiber.StatusOK)
+				})
+
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusOK, resp.StatusCode)
+				require.Equal(t, "10", resp.Header.Get(xRateLimitReset), "the window is the configured Expiration")
+
+				resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusTooManyRequests, resp.StatusCode)
+				require.Equal(t, "10", resp.Header.Get(fiber.HeaderRetryAfter))
+
+				// Just over the configured window, the client is admitted again. Two
+				// whole windows are needed for the sliding one to forget the last.
+				clock.Add(2*expiration + time.Second)
+
+				resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusOK, resp.StatusCode)
+			})
+		}
+	}
+}
+
+// Test_Limiter_ExpirationFunc_PositiveStillWins checks the other side of the
+// fallback: a positive value from ExpirationFunc keeps overriding Expiration.
+func Test_Limiter_ExpirationFunc_PositiveStillWins(t *testing.T) {
+	t.Parallel()
+
+	for name, handler := range map[string]Handler{"fixed": FixedWindow{}, "sliding": SlidingWindow{}} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			clock := newTestClock(time.Now().Truncate(time.Second))
+			app := fiber.New()
+			app.Use(New(Config{
+				Max:               5,
+				Expiration:        time.Minute,
+				ExpirationFunc:    func(fiber.Ctx) time.Duration { return 3 * time.Second },
+				LimiterMiddleware: handler,
+				clock:             clock.Now,
+			}))
+			app.Get("/", func(c fiber.Ctx) error {
+				return c.SendStatus(fiber.StatusOK)
+			})
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, "3", resp.Header.Get(xRateLimitReset))
+		})
+	}
+}
+
 func Test_Limiter_SubSecondExpirationIsOneSecondWindow(t *testing.T) {
 	t.Parallel()
 
diff --git a/middleware/session/middleware_test.go b/middleware/session/middleware_test.go
index a2574a934e7..d77a15d3bf3 100644
--- a/middleware/session/middleware_test.go
+++ b/middleware/session/middleware_test.go
@@ -8,9 +8,12 @@ import (
 	"io"
 	"net/http"
 	"net/http/httptest"
+	"runtime"
 	"sort"
+	"strconv"
 	"strings"
 	"sync"
+	"sync/atomic"
 	"testing"
 	"time"
 
@@ -21,6 +24,7 @@ import (
 	fiberlog "github.com/gofiber/fiber/v3/log"
 	"github.com/gofiber/fiber/v3/middleware/logger"
 	"github.com/gofiber/utils/v2"
+	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
 )
@@ -944,3 +948,250 @@ func Test_Session_Save_After_Handler_Cancel(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, "world", string(body))
 }
+
+// Test_Session_FromContext_RetainedContext covers a context kept past the end of
+// its request, which PassLocalsToContext exists to allow: a goroutine started by
+// the handler holds c.Context() and looks the session up later. The lookup used
+// to return the pooled *Middleware that request had released, and once another
+// request acquired it that goroutine read and wrote the other request's session.
+func Test_Session_FromContext_RetainedContext(t *testing.T) {
+	t.Parallel()
+
+	for _, pass := range []bool{true, false} {
+		name := "default"
+		if pass {
+			name = "PassLocalsToContext"
+		}
+
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{PassLocalsToContext: pass})
+			app.Use(New())
+
+			// app.Test finishes a request before it returns, so these are written by
+			// one handler and read by the next without overlapping.
+			var (
+				retained context.Context
+				stale    *Middleware
+				current  *Middleware
+				staleID  string
+			)
+			app.Get("/a", func(c fiber.Ctx) error {
+				FromContext(c).Set("user", "alice")
+				retained = c.Context()
+				return c.SendString("a")
+			})
+			app.Get("/b", func(c fiber.Ctx) error {
+				current = FromContext(c)
+				current.Set("user", "bob")
+
+				// What a goroutine that outlived request /a does.
+				stale = FromContext(retained)
+				if stale != nil {
+					staleID = stale.ID()
+					stale.Set("user", "mallory")
+				}
+				return c.SendString("b")
+			})
+
+			// Under -race a pool drops one Put in four, so a reused object is only
+			// seen on some rounds; repeating makes the old behavior certain to show.
+			for range 40 {
+				stale, current, staleID = nil, nil, ""
+
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/a", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+				// The request is over: its context no longer leads to a session.
+				require.Nil(t, FromContext(retained), "the released middleware is still reachable")
+
+				resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/b", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+				require.Nil(t, stale, "a retained context reached request /b's session")
+				require.Empty(t, staleID)
+				require.NotNil(t, current)
+			}
+		})
+	}
+}
+
+// Test_Session_FromContext_RetainedContext_AfterHandler looks the session up
+// from a goroutine that is still running when the handler returns, which is the
+// race the pooled pointer made dangerous: it has to see nil once the middleware
+// is released, and never a half-reset object.
+func Test_Session_FromContext_RetainedContext_AfterHandler(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{PassLocalsToContext: true})
+	app.Use(New())
+
+	var (
+		wg      sync.WaitGroup
+		inside  *Middleware
+		release = make(chan struct{})
+		seen    = make(chan *Middleware, 1)
+	)
+	app.Get("/", func(c fiber.Ctx) error {
+		ctx := c.Context()
+		inside = FromContext(ctx)
+
+		wg.Go(func() {
+			<-release
+			seen <- FromContext(ctx)
+		})
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.NotNil(t, inside, "the context must resolve while the request runs")
+
+	close(release)
+	wg.Wait()
+	require.Nil(t, <-seen)
+}
+
+// Test_Session_FromContext_RetainedContext_Concurrent runs many overlapping
+// requests, each leaving a goroutine behind that keeps looking its session up
+// through the context it kept. Whatever the interleaving, the lookup has to give
+// that request's own middleware while it runs and nil once it is over. Comparing
+// pointers alone cannot show the old fault, since the pooled object kept its
+// address and only changed owner.
+func Test_Session_FromContext_RetainedContext_Concurrent(t *testing.T) {
+	t.Parallel()
+
+	const (
+		requests = 64
+		lookups  = 400
+	)
+
+	app := fiber.New(fiber.Config{PassLocalsToContext: true})
+	app.Use(New())
+
+	var (
+		wg       sync.WaitGroup
+		finished [requests]atomic.Bool
+		stale    atomic.Int64
+		foreign  atomic.Int64
+	)
+	app.Get("/", func(c fiber.Ctx) error {
+		n, err := strconv.Atoi(c.Get("X-Request"))
+		if err != nil {
+			return fmt.Errorf("bad X-Request header: %w", err)
+		}
+		over := &finished[n]
+		own := FromContext(c)
+		ctx := c.Context()
+
+		wg.Go(func() {
+			for range lookups {
+				// Read before the lookup: a flag already set means the request had
+				// ended before the lookup began, so it has to find nothing.
+				ended := over.Load()
+				switch got := FromContext(ctx); {
+				case got == nil:
+				case ended:
+					stale.Add(1)
+				case got != own:
+					foreign.Add(1)
+				}
+				runtime.Gosched()
+			}
+		})
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	var clients sync.WaitGroup
+	for n := range requests {
+		clients.Go(func() {
+			req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+			req.Header.Set("X-Request", strconv.Itoa(n))
+			resp, err := app.Test(req)
+			if assert.NoError(t, err) {
+				assert.Equal(t, fiber.StatusOK, resp.StatusCode)
+			}
+			// app.Test returns after the middleware has released its object.
+			finished[n].Store(true)
+		})
+	}
+	clients.Wait()
+	wg.Wait()
+
+	require.Zero(t, stale.Load(), "a retained context still resolved a session after its request ended")
+	require.Zero(t, foreign.Load(), "a retained context reached another request's middleware")
+}
+
+// Test_Session_ReleaseMiddleware_DoesNotRecycleAPublishedOne pins the other half:
+// a middleware the request context holds is dropped, not pooled, so a pointer
+// that was looked up while the request ran can never be handed to another one.
+func Test_Session_ReleaseMiddleware_DoesNotRecycleAPublishedOne(t *testing.T) {
+	t.Parallel()
+
+	published := acquireMiddleware()
+	published.escaped = true
+	releaseMiddleware(published)
+	require.True(t, published.released.Load())
+
+	local := acquireMiddleware()
+	releaseMiddleware(local)
+	require.False(t, local.released.Load(), "a middleware only the locals reach goes back to the pool unmarked")
+
+	// sync.Pool gives no promise about what comes back, but it can only return
+	// what was put in, so the published one must never appear.
+	for range 1000 {
+		got := acquireMiddleware()
+		require.NotSame(t, published, got)
+		releaseMiddleware(got)
+	}
+}
+
+// Benchmark_Middleware drives the whole handler, which the store benchmarks do
+// not: it is where the middleware object is acquired, published to the request
+// context and released again.
+//
+// go test -v -run=^$ -bench=Benchmark_Middleware -benchmem -count=4
+func Benchmark_Middleware(b *testing.B) {
+	for _, tc := range []struct {
+		name string
+		pass bool
+	}{
+		{name: "default"},
+		{name: "PassLocalsToContext", pass: true},
+	} {
+		b.Run(tc.name, func(b *testing.B) {
+			app := fiber.New(fiber.Config{PassLocalsToContext: tc.pass})
+			app.Use(New())
+			app.Get("/", func(c fiber.Ctx) error {
+				FromContext(c).Set("john", "doe")
+				return nil
+			})
+			handler := app.Handler()
+
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Request.Header.SetMethod(fiber.MethodGet)
+			fctx.Request.SetRequestURI("/")
+
+			// The first request creates the session and the rest load it, so the
+			// store does not grow while the benchmark runs.
+			handler(fctx)
+			setCookie := fasthttp.AcquireCookie()
+			defer fasthttp.ReleaseCookie(setCookie)
+			require.NoError(b, setCookie.ParseBytes(fctx.Response.Header.Peek(fiber.HeaderSetCookie)))
+			sessionID := string(setCookie.Value())
+
+			b.ReportAllocs()
+			for b.Loop() {
+				fctx.ResetUserValues()
+				fctx.Response.Reset()
+				fctx.Request.Header.SetCookie("session_id", sessionID)
+				handler(fctx)
+			}
+			require.Equal(b, fiber.StatusOK, fctx.Response.StatusCode())
+		})
+	}
+}

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path addon/retry/exponential_backoff_test.go --path client/client_test.go --path client/hooks_pathparam_test.go --path client/hooks_test.go --path client/transport_test.go --path ctx_test.go --path middleware/basicauth/basicauth_test.go --path middleware/cache/cache_test.go --path middleware/limiter/limiter_test.go --path middleware/session/middleware_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./addon/retry ./client ./ ./middleware/basicauth ./middleware/cache ./middleware/limiter ./middleware/session')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./addon/retry ./client ./ ./middleware/basicauth ./middleware/cache ./middleware/limiter ./middleware/session' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
