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
for f in adapter_test.go app_integration_test.go app_test.go client/cancel_test.go client/core_test.go client/transport_test.go ctx_test.go internal/fieldname/fieldname_test.go internal/redirectbody/redirectbody_test.go middleware/adaptor/adaptor_test.go middleware/cache/cache_security_test.go middleware/csrf/csrf_test.go middleware/proxy/proxy_test.go middleware/proxy/security_test.go middleware/session/data_test.go middleware/session/session_test.go middleware/static/static_test.go middleware/timeout/timeout_test.go mount_test.go; do if git cat-file -e f994fd2e2c618c33c2129759f2e2f3475be7111d:"$f" 2>/dev/null; then git checkout f994fd2e2c618c33c2129759f2e2f3475be7111d -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - f994fd2e2c618c33c2129759f2e2f3475be7111d "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/adapter_test.go b/adapter_test.go
index 099fc0e8ec1..3dbcae0cc4f 100644
--- a/adapter_test.go
+++ b/adapter_test.go
@@ -580,7 +580,7 @@ func TestWrapHTTPHandler_StreamedTrailerCap(t *testing.T) {
 	ln := startRawServer(t, app)
 
 	raw := "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n" +
-		rawFieldLines("X-", "v", fieldname.MaxTrailers+1) + "\r\n"
+		apptest.FieldLines("X-", "v", fieldname.MaxTrailers+1) + "\r\n"
 	rawExpectStatus(t, ln, raw, StatusRequestHeaderFieldsTooLarge)
 }
 
diff --git a/app_integration_test.go b/app_integration_test.go
index 6c9e4f65df3..ed9a5173083 100644
--- a/app_integration_test.go
+++ b/app_integration_test.go
@@ -30,7 +30,6 @@ import (
 	"github.com/gofiber/fiber/v3/middleware/requestid"
 	"github.com/gofiber/fiber/v3/middleware/session"
 	"github.com/valyala/fasthttp"
-	"github.com/valyala/fasthttp/fasthttputil"
 )
 
 type integrationCustomCtx struct {
@@ -44,22 +43,7 @@ func newIntegrationCustomCtx(app *fiber.App) fiber.CustomCtx {
 func performOversizedRequest(t *testing.T, app *fiber.App, configure func(req *fasthttp.Request)) *fasthttp.Response {
 	t.Helper()
 
-	ln := fasthttputil.NewInmemoryListener()
-	errCh := make(chan error, 1)
-
-	go func() { errCh <- app.Listener(ln, fiber.ListenConfig{DisableStartupMessage: true}) }()
-
-	t.Cleanup(func() {
-		require.NoError(t, app.Shutdown())
-		if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
-			require.NoError(t, err)
-		}
-	})
-
-	require.Eventually(t, func() bool {
-		conn, err := ln.Dial()
-		return err == nil && conn.Close() == nil
-	}, time.Second, 10*time.Millisecond)
+	ln := apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true})
 
 	req := fasthttp.AcquireRequest()
 	defer fasthttp.ReleaseRequest(req)
diff --git a/app_test.go b/app_test.go
index d2124610dd3..d5ce9a6197f 100644
--- a/app_test.go
+++ b/app_test.go
@@ -3089,28 +3089,7 @@ func startRawServer(t *testing.T, app *App) *fasthttputil.InmemoryListener {
 func startRawServerWith(t *testing.T, app *App, beforeServe func(*App) error) *fasthttputil.InmemoryListener {
 	t.Helper()
 
-	ln := fasthttputil.NewInmemoryListener()
-	errCh := make(chan error, 1)
-	go func() {
-		errCh <- app.Listener(ln, ListenConfig{DisableStartupMessage: true, BeforeServeFunc: beforeServe})
-	}()
-
-	t.Cleanup(func() {
-		require.NoError(t, app.Shutdown())
-		if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
-			require.NoError(t, err)
-		}
-	})
-
-	require.Eventually(t, func() bool {
-		conn, err := ln.Dial()
-		if err != nil {
-			return false
-		}
-		return conn.Close() == nil
-	}, time.Second, 5*time.Millisecond)
-
-	return ln
+	return apptest.Serve(t, app, ListenConfig{DisableStartupMessage: true, BeforeServeFunc: beforeServe})
 }
 
 // dialer opens connections to the server under test.
@@ -3202,15 +3181,6 @@ func rawExpectStatus(t *testing.T, server dialer, raw string, status int) rawRes
 	return responses[0]
 }
 
-// rawFieldLines returns n header or trailer lines named prefix0, prefix1, ... that all hold value.
-func rawFieldLines(prefix, value string, n int) string {
-	var lines strings.Builder
-	for i := range n {
-		fmt.Fprintf(&lines, "%s%d: %s\r\n", prefix, i, value)
-	}
-	return lines.String()
-}
-
 // An Accept-Encoding with no value reaches AcceptsEncodings as present but empty,
 // which wants no content coding, and is not read as an absent one, which accepts any.
 func Test_App_AcceptsEncodings_EmptyField_Request(t *testing.T) {
diff --git a/client/cancel_test.go b/client/cancel_test.go
new file mode 100644
index 00000000000..4a4befd4fe2
--- /dev/null
+++ b/client/cancel_test.go
@@ -0,0 +1,203 @@
+package client
+
+import (
+	"context"
+	"errors"
+	"net"
+	"sync"
+	"sync/atomic"
+	"testing"
+	"time"
+
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/gofiber/fiber/v3/internal/apptest"
+)
+
+// connFaults are the errors a faultConn answers with: its deadline setters and its writes fail as set.
+type connFaults struct {
+	deadline, writeDeadline, readDeadline, write error
+}
+
+// faultConn is a connection that fails as its faults say and sends on closed once when it is closed.
+type faultConn struct {
+	net.Conn
+	closed chan<- struct{}
+	faults connFaults
+	once   sync.Once
+}
+
+func (c *faultConn) SetDeadline(t time.Time) error {
+	if c.faults.deadline != nil {
+		return c.faults.deadline
+	}
+	return c.Conn.SetDeadline(t) //nolint:wrapcheck // a transparent wrapper
+}
+
+func (c *faultConn) SetWriteDeadline(t time.Time) error {
+	if c.faults.writeDeadline != nil {
+		return c.faults.writeDeadline
+	}
+	return c.Conn.SetWriteDeadline(t) //nolint:wrapcheck // a transparent wrapper
+}
+
+func (c *faultConn) SetReadDeadline(t time.Time) error {
+	if c.faults.readDeadline != nil {
+		return c.faults.readDeadline
+	}
+	return c.Conn.SetReadDeadline(t) //nolint:wrapcheck // a transparent wrapper
+}
+
+func (c *faultConn) Write(p []byte) (int, error) {
+	if c.faults.write != nil {
+		return 0, c.faults.write
+	}
+	return c.Conn.Write(p) //nolint:wrapcheck // a transparent wrapper
+}
+
+func (c *faultConn) Close() error {
+	c.once.Do(func() { c.closed <- struct{}{} })
+	return c.Conn.Close() //nolint:wrapcheck // a transparent wrapper
+}
+
+// timeoutError is a write error that reports a timeout, as a passed deadline does.
+type timeoutError struct{}
+
+func (timeoutError) Error() string { return "write timed out" }
+func (timeoutError) Timeout() bool { return true }
+
+// faultDial dials ts through a faultConn with faults, sending on closed when the connection is closed.
+func faultDial(ts *testServer, faults connFaults, closed chan<- struct{}) fasthttp.DialFunc {
+	return func(addr string) (net.Conn, error) {
+		conn, err := ts.dial()(addr)
+		if err != nil {
+			return nil, err
+		}
+		return &faultConn{Conn: conn, closed: closed, faults: faults}, nil
+	}
+}
+
+// okServer serves "ok" at / and stops when the test ends.
+func okServer(t *testing.T) *testServer {
+	t.Helper()
+	ts := startTestServer(t, func(app *fiber.App) {
+		app.Get("/", func(c fiber.Ctx) error { return c.SendString("ok") })
+	})
+	t.Cleanup(ts.stop)
+	return ts
+}
+
+// Test_RoundTripCancelable_Faults checks the exchange of a client made by New under a context that can
+// be canceled, which the client's own transport round-trips: the connection is closed, never pooled,
+// when a deadline cannot be set or the write fails, a write that times out reports fasthttp's timeout,
+// the host client's read and write timeouts bound the exchange as under fasthttp's transport, and
+// unnormalized header names and a streamed response go through as usual.
+func Test_RoundTripCancelable_Faults(t *testing.T) {
+	t.Parallel()
+	errDeadline := errors.New("deadline refused")
+	errWrite := errors.New("write refused")
+	for _, tc := range []struct {
+		faults   connFaults
+		err      error
+		setup    func(c *fasthttp.Client)
+		name     string
+		timeouts bool // the host client's read and write timeouts are set
+	}{
+		{name: "a failing deadline ends the attempt", faults: connFaults{deadline: errDeadline}, err: errDeadline},
+		{name: "a failing write deadline ends the attempt", faults: connFaults{writeDeadline: errDeadline}, timeouts: true, err: errDeadline},
+		{name: "a failing read deadline ends the attempt", faults: connFaults{readDeadline: errDeadline}, timeouts: true, err: errDeadline},
+		{name: "a failing write ends the attempt", faults: connFaults{write: errWrite}, err: errWrite},
+		{name: "a write that times out reports the timeout", faults: connFaults{write: timeoutError{}}, err: fasthttp.ErrTimeout},
+		{name: "the host client's timeouts bound the exchange", timeouts: true},
+		{name: "unnormalized header names go through", setup: func(c *fasthttp.Client) { c.DisableHeaderNamesNormalizing = true }},
+		{name: "a streamed response keeps fasthttp's transport", setup: func(c *fasthttp.Client) { c.StreamResponseBody = true }},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			closed := make(chan struct{}, 16)
+			client := New().SetDial(faultDial(okServer(t), tc.faults, closed))
+			hc := client.FasthttpClient()
+			hc.MaxIdemponentCallAttempts = 1 // the error reported is the attempt's own
+			if tc.timeouts {
+				hc.ReadTimeout, hc.WriteTimeout = time.Second, time.Second
+			}
+			if tc.setup != nil {
+				tc.setup(hc)
+			}
+			ctx, cancel := context.WithCancel(t.Context())
+			defer cancel()
+
+			resp, err := client.R().SetContext(ctx).Get("http://example.com/")
+			if tc.err != nil {
+				require.ErrorIs(t, err, tc.err)
+				apptest.Recv(t, closed, 2*time.Second, "the connection of the failed attempt was not closed")
+				return
+			}
+			require.NoError(t, err)
+			require.Equal(t, "ok", resp.String())
+			resp.Close()
+		})
+	}
+}
+
+// Test_RoundTripCancelable_CanceledBeforeAttach checks that a connection dialed for a call whose context
+// was canceled during the dial is closed rather than used or pooled.
+func Test_RoundTripCancelable_CanceledBeforeAttach(t *testing.T) {
+	t.Parallel()
+	ts := okServer(t)
+	ctx, cancel := context.WithCancel(t.Context())
+	t.Cleanup(cancel)
+	closed := make(chan struct{}, 1)
+	proceed := make(chan struct{})
+	client := New().SetDial(func(addr string) (net.Conn, error) {
+		conn, err := ts.dial()(addr)
+		if err != nil {
+			return nil, err
+		}
+		// The call ends while the dial is in progress; the dial returns once it has.
+		cancel()
+		<-proceed
+		return &faultConn{Conn: conn, closed: closed}, nil
+	})
+
+	_, err := client.R().SetContext(ctx).Get("http://example.com/")
+	require.ErrorIs(t, err, ErrTimeoutOrCancel)
+	close(proceed)
+	apptest.Recv(t, closed, 2*time.Second, "the connection dialed for the canceled call was not closed")
+}
+
+// Test_RoundTripCancelable_MaxConnDuration checks that a connection older than the host client's
+// MaxConnDuration is sent its last request with Connection: close and closed after the response.
+func Test_RoundTripCancelable_MaxConnDuration(t *testing.T) {
+	t.Parallel()
+	var closeAsked atomic.Bool
+	ts := startTestServer(t, func(app *fiber.App) {
+		app.Get("/", func(c fiber.Ctx) error {
+			closeAsked.Store(c.Request().Header.ConnectionClose())
+			return c.SendString("ok")
+		})
+	})
+	t.Cleanup(ts.stop)
+	closed := make(chan struct{}, 16)
+	client := New().SetDial(faultDial(ts, connFaults{}, closed))
+	client.FasthttpClient().MaxConnDuration = 10 * time.Millisecond
+	ctx, cancel := context.WithCancel(t.Context())
+	defer cancel()
+
+	// The pooled connection ages past MaxConnDuration between two requests. A slow run may age the
+	// first one before its own check, which starts the next request on a fresh connection.
+	for range 4 {
+		resp, err := client.R().SetContext(ctx).Get("http://example.com/")
+		require.NoError(t, err)
+		require.Equal(t, "ok", resp.String())
+		resp.Close()
+		if closeAsked.Load() {
+			break
+		}
+		time.Sleep(20 * time.Millisecond)
+	}
+	require.True(t, closeAsked.Load(), "no request asked the server to close the aged connection")
+	apptest.Recv(t, closed, 2*time.Second, "the aged connection was not closed")
+}
diff --git a/client/core_test.go b/client/core_test.go
index a40b5cb8026..a8953e22f84 100644
--- a/client/core_test.go
+++ b/client/core_test.go
@@ -824,21 +824,102 @@ func silentServer(t *testing.T) (dial fasthttp.DialFunc, hungUp <-chan struct{})
 	return func(string) (net.Conn, error) { return ln.Dial() }, closed
 }
 
-func Test_Execute_TimeoutEndsTheExchange(t *testing.T) {
+// Test_Execute_CancelEndsTheExchange checks that an exchange with a server that never answers ends
+// at the transport of a client made by New, the connection closed instead of waiting on the
+// server, over a plain and over a TLS connection alike: when the context is canceled, with and
+// without a deadline, also with a ConfigureClient hook of the caller's own in place of the
+// client's, and when the client's timeout passes.
+func Test_Execute_CancelEndsTheExchange(t *testing.T) {
 	t.Parallel()
-	for _, url := range []string{"http://example.com/", "https://example.com/"} {
-		t.Run(url, func(t *testing.T) {
-			t.Parallel()
-			dial, hungUp := silentServer(t)
-			client := New().SetDial(dial).SetTimeout(50 * time.Millisecond)
+	// cancelOnceConnected cancels ctx once a connection is open, so the cancellation reaches an exchange in flight.
+	cancelOnceConnected := func(dial fasthttp.DialFunc, cancel context.CancelFunc) fasthttp.DialFunc {
+		return func(addr string) (net.Conn, error) {
+			conn, err := dial(addr)
+			if err == nil {
+				cancel()
+			}
+			return conn, err
+		}
+	}
+	for _, tc := range []struct {
+		// setup returns the client and the context of the request, set up so the exchange ends.
+		setup func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context)
+		name  string
+	}{
+		{name: "cancel-only", setup: func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context) {
+			t.Helper()
+			ctx, cancel := context.WithCancel(t.Context())
+			t.Cleanup(cancel)
+			return New().SetDial(cancelOnceConnected(dial, cancel)), ctx
+		}},
+		{name: "deadline", setup: func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context) {
+			t.Helper()
+			ctx, cancel := context.WithTimeout(t.Context(), time.Minute)
+			t.Cleanup(cancel)
+			return New().SetDial(cancelOnceConnected(dial, cancel)), ctx
+		}},
+		{name: "cancel-only with a replaced hook", setup: func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context) {
+			t.Helper()
+			ctx, cancel := context.WithCancel(t.Context())
+			t.Cleanup(cancel)
+			client := New().SetDial(cancelOnceConnected(dial, cancel))
+			client.FasthttpClient().ConfigureClient = func(hc *fasthttp.HostClient) error { hc.MaxConns = 8; return nil }
+			return client, ctx
+		}},
+		{name: "client timeout", setup: func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context) {
+			t.Helper()
+			return New().SetDial(dial).SetTimeout(50 * time.Millisecond), context.Background()
+		}},
+		{name: "client timeout under a cancel-only context", setup: func(t *testing.T, dial fasthttp.DialFunc) (*Client, context.Context) {
+			t.Helper()
+			ctx, cancel := context.WithCancel(t.Context())
+			t.Cleanup(cancel)
+			return New().SetDial(dial).SetTimeout(50 * time.Millisecond), ctx
+		}},
+	} {
+		for _, url := range []string{"http://example.com/", "https://example.com/"} {
+			t.Run(tc.name+" "+url, func(t *testing.T) {
+				t.Parallel()
+				dial, hungUp := silentServer(t)
+				client, ctx := tc.setup(t, dial)
+
+				_, err := client.R().SetContext(ctx).Get(url)
+				require.ErrorIs(t, err, ErrTimeoutOrCancel)
+				apptest.Recv(t, hungUp, 2*time.Second, "the connection is still open after the call ended")
+			})
+		}
+	}
+}
 
-			_, err := client.Get(url)
-			require.ErrorIs(t, err, ErrTimeoutOrCancel)
+// Test_Execute_CancelOnlyContextKeepsConnectionsUsable checks that requests under a context that can
+// be canceled, but is not, share their connections and answer as usual, a HEAD included.
+func Test_Execute_CancelOnlyContextKeepsConnectionsUsable(t *testing.T) {
+	t.Parallel()
+	ts := startTestServer(t, func(app *fiber.App) {
+		app.Get("/", func(c fiber.Ctx) error { return c.SendString("ok") })
+	})
+	t.Cleanup(ts.stop)
+	client := New().SetDial(ts.dial())
 
-			apptest.Recv(t, hungUp, 2*time.Second, "the connection is still open long after the call timed out")
-		})
+	ctx, cancel := context.WithCancel(t.Context())
+	defer cancel()
+	for range 2 {
+		resp, err := client.R().SetContext(ctx).Get("http://example.com/")
+		require.NoError(t, err)
+		require.Equal(t, "ok", resp.String())
+		resp.Close()
 	}
+	resp, err := client.R().SetContext(ctx).Head("http://example.com/")
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Empty(t, resp.Body())
+	resp.Close()
+}
 
+// Test_Execute_TimeoutEndsTheExchange checks what of the client's timeout reaches the redirect hops
+// and the retries; Test_Execute_CancelEndsTheExchange covers the exchange itself.
+func Test_Execute_TimeoutEndsTheExchange(t *testing.T) {
+	t.Parallel()
 	t.Run("redirects share the deadline", func(t *testing.T) {
 		t.Parallel()
 		var deadline time.Time
diff --git a/client/transport_test.go b/client/transport_test.go
index 9b3776deb4d..d8482ac5f05 100644
--- a/client/transport_test.go
+++ b/client/transport_test.go
@@ -1,8 +1,6 @@
 package client
 
 import (
-	"bufio"
-	"bytes"
 	"crypto/tls"
 	"errors"
 	"net"
@@ -1252,81 +1250,48 @@ func Test_Transport_DoRedirects_KeepsPathNormalizingDisabled(t *testing.T) {
 	}
 }
 
-// Test_DropRequestBody_RemovesExpect covers the 100-continue expectation, which
-// may not be generated without content (RFC 9110 Section 10.1.1). Left on the
-// bodyless follow-up, a strict target answers 417 instead of serving it.
-func Test_DropRequestBody_RemovesExpect(t *testing.T) {
+// TestDoRedirectsWithClient_DropsTrailerSection pins that a 302 drops the trailer section with the
+// body: fasthttp files a value set under an announced name with that section and returns it to the
+// header section when Trailer alone is deleted, so the value would reach the target, possibly another
+// host, as a header line. A section naming more fields than fieldname.MaxTrailers fails the redirect.
+func TestDoRedirectsWithClient_DropsTrailerSection(t *testing.T) {
 	t.Parallel()
-	req := clientTestPooled(t, fasthttp.AcquireRequest, fasthttp.ReleaseRequest)
-	req.Header.SetMethod(fasthttp.MethodPost)
-	req.Header.Set(fasthttp.HeaderExpect, "100-continue")
-	req.Header.SetContentType("application/x-www-form-urlencoded")
-	req.SetBodyString("a=1")
-
-	dropRequestBody(req)
+	newReq := func(t *testing.T, names int) (*fasthttp.Request, *fasthttp.Response) {
+		t.Helper()
 
-	require.Empty(t, req.Header.Peek(fasthttp.HeaderExpect))
-	require.Empty(t, req.Body())
-}
+		req, resp := clientTestCReqResp(t)
+		req.SetRequestURI("http://example.com/start")
+		req.Header.SetMethod(fasthttp.MethodPost)
+		req.SetBodyStream(strings.NewReader("hello"), -1)
+		for i := range names {
+			name := "X-Body-Signature-" + strconv.Itoa(i)
+			require.NoError(t, req.Header.AddTrailer(name))
+			req.Header.Set(name, "sig-of-the-body")
+		}
+		return req, resp
+	}
 
-// Test_DropRequestBody_ClearsTheParsedForm pins why the PostArgs reset is there:
-// Request.Write falls back to the parsed form when the body is empty, so a
-// caller that had read PostArgs would otherwise have sent the dropped body on
-// the redirected GET.
-func Test_DropRequestBody_ClearsTheParsedForm(t *testing.T) {
-	t.Parallel()
-	req := clientTestPooled(t, fasthttp.AcquireRequest, fasthttp.ReleaseRequest)
-	req.SetRequestURI("http://example.com/y")
-	req.Header.SetMethod(fasthttp.MethodPost)
-	req.Header.SetContentType("application/x-www-form-urlencoded")
-	req.SetBodyString("a=1")
-	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
-
-	req.Header.SetMethod(fasthttp.MethodGet)
-	dropRequestBody(req)
-
-	var buf bytes.Buffer
-	w := bufio.NewWriter(&buf)
-	require.NoError(t, req.Write(w))
-	require.NoError(t, w.Flush())
-	require.NotContains(t, buf.String(), "a=1", "the dropped form must not come back as the body")
-}
+	t.Run("dropped with the body", func(t *testing.T) {
+		t.Parallel()
+		req, resp := newReq(t, 1)
+		require.Contains(t, req.String(), "sig-of-the-body", "sent as a trailer field")
 
-// Test_DropRequestBody_ReusedRequestSendsTheNewBody covers the request a caller
-// gets back and then reuses without resetting it.
-//
-// fasthttp clears its parsed-form flag beside the values here, which this cannot
-// reach: the field is unexported and only Request.Reset clears it, which would
-// take the URI and headers the redirect loop is still using. What survives that
-// gap has to be the part that matters — the body actually sent, and the earlier
-// form not reappearing in it or in a later read. An untouched fasthttp request
-// is no better here: SetBody does not invalidate the parsed form either, so it
-// answers a reused PostArgs with the previous body's values.
-func Test_DropRequestBody_ReusedRequestSendsTheNewBody(t *testing.T) {
-	t.Parallel()
-	req := clientTestPooled(t, fasthttp.AcquireRequest, fasthttp.ReleaseRequest)
-	req.SetRequestURI("http://example.com/y")
-	req.Header.SetMethod(fasthttp.MethodPost)
-	req.Header.SetContentType("application/x-www-form-urlencoded")
-	req.SetBodyString("a=1")
-	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
+		client := clientTestCRedirectStub(fasthttp.StatusFound, "http://attacker.example/collect")
+		require.NoError(t, doRedirectsWithClient(req, resp, &redirectOptions{maxRedirects: 5}, client))
+		require.Equal(t, "http://attacker.example/collect", req.URI().String())
+		require.Empty(t, req.Header.PeekTrailerKeys())
+		require.Empty(t, req.Header.Peek("X-Body-Signature-0"))
+		require.NotContains(t, req.String(), "sig-of-the-body")
+	})
 
-	dropRequestBody(req)
+	t.Run("too many names", func(t *testing.T) {
+		t.Parallel()
+		req, resp := newReq(t, fieldname.MaxTrailers+1)
 
-	// The caller reuses the request for a second POST.
-	req.Header.SetMethod(fasthttp.MethodPost)
-	req.Header.SetContentType("application/x-www-form-urlencoded")
-	req.SetBodyString("b=2")
-
-	require.NotContains(t, req.PostArgs().String(), "a=1",
-		"a reused request must not report the previous body's form values")
-
-	var buf bytes.Buffer
-	w := bufio.NewWriter(&buf)
-	require.NoError(t, req.Write(w))
-	require.NoError(t, w.Flush())
-	require.Contains(t, buf.String(), "b=2", "the reused request sends the body it was given")
-	require.NotContains(t, buf.String(), "a=1")
+		client := clientTestCRedirectStub(fasthttp.StatusFound, "http://attacker.example/collect")
+		require.ErrorIs(t, doRedirectsWithClient(req, resp, &redirectOptions{maxRedirects: 5}, client), ErrRedirectTrailers)
+		require.Equal(t, 1, client.CallCount(), "the target is not contacted")
+	})
 }
 
 // Test_Response_ResetDropsOversizedOriginBuffers covers the recorded origin on a
diff --git a/ctx_test.go b/ctx_test.go
index ce4eb211c0b..0c89ed75590 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -2746,7 +2746,7 @@ func Test_Ctx_HeaderWrittenUnderTrailerName_StreamedBody(t *testing.T) {
 			ln := startRawServer(t, app)
 
 			const chunked = "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n"
-			many := rawFieldLines("X-", "v", fieldname.MaxTrailers-2)
+			many := apptest.FieldLines("X-", "v", fieldname.MaxTrailers-2)
 			heads := []string{"", "X-User: admin\r\nX-Role: admin\r\n", "X-User: admin\r\nTrailer: X-User, X-Role\r\n"}
 			post := func(path, head, trailers string) string {
 				return "POST " + path + " HTTP/1.1\r\nHost: example.com\r\n" + head + chunked + trailers +
@@ -8950,8 +8950,8 @@ func Benchmark_Ctx_GetReqHeaders_TrailerSection(b *testing.B) {
 		b.Run(strconv.Itoa(n), func(b *testing.B) {
 			c := apptest.Ctx(b, New())
 
-			raw := "POST / HTTP/1.1\r\nHost: example.com\r\n" + rawFieldLines("H", "1", n) +
-				"Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n" + rawFieldLines("T", "1", n) + "\r\n"
+			raw := "POST / HTTP/1.1\r\nHost: example.com\r\n" + apptest.FieldLines("H", "1", n) +
+				"Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n" + apptest.FieldLines("T", "1", n) + "\r\n"
 			require.NoError(b, c.Request().Read(bufio.NewReaderSize(strings.NewReader(raw), len(raw))))
 			require.Len(b, c.Request().Header.PeekTrailerKeys(), n)
 
diff --git a/internal/fieldname/fieldname_test.go b/internal/fieldname/fieldname_test.go
index fff26e82519..cb0a69d4aea 100644
--- a/internal/fieldname/fieldname_test.go
+++ b/internal/fieldname/fieldname_test.go
@@ -10,6 +10,8 @@ import (
 	"time"
 
 	"github.com/stretchr/testify/require"
+
+	"github.com/gofiber/fiber/v3/internal/apptest"
 	"github.com/valyala/fasthttp"
 )
 
@@ -43,6 +45,20 @@ func readRequest(tb testing.TB, raw string, canonical bool) *fasthttp.Request {
 	return req
 }
 
+// readResponse parses raw, trailer section included, into a response that normalizes header names if canonical.
+//
+//nolint:revive // flag-parameter: canonical is a property of the header store
+func readResponse(tb testing.TB, raw string, canonical bool) *fasthttp.Response {
+	tb.Helper()
+
+	resp := &fasthttp.Response{}
+	if !canonical {
+		resp.Header.DisableNormalizing()
+	}
+	require.NoError(tb, resp.Read(bufio.NewReader(strings.NewReader(raw))))
+	return resp
+}
+
 // lineValues converts header lines to strings, nil where there are none.
 func lineValues(lines [][]byte) []string {
 	var out []string
@@ -160,11 +176,7 @@ func Test_First_Lines_ResponseLineUnderTrailerName(t *testing.T) {
 	for _, canonical := range []bool{true, false} {
 		t.Run(fmt.Sprintf("canonical=%v", canonical), func(t *testing.T) {
 			t.Parallel()
-			resp := &fasthttp.Response{}
-			if !canonical {
-				resp.Header.DisableNormalizing()
-			}
-			require.NoError(t, resp.Read(bufio.NewReader(strings.NewReader(raw))))
+			resp := readResponse(t, raw, canonical)
 			require.NotEmpty(t, resp.Header.PeekTrailerKeys())
 
 			require.Equal(t, "private, no-store", string(First(&resp.Header, fasthttp.HeaderCacheControl, canonical)))
@@ -225,11 +237,7 @@ func Test_DropTrailers(t *testing.T) {
 
 	t.Run("too many names", func(t *testing.T) {
 		t.Parallel()
-		var trailers strings.Builder
-		for i := range MaxTrailers + 1 {
-			fmt.Fprintf(&trailers, "X-%d: v\r\n", i)
-		}
-		req := readRequest(t, post+"X-0: header\r\n"+chunked+trailers.String()+"\r\n", true)
+		req := readRequest(t, post+"X-0: header\r\n"+chunked+apptest.FieldLines("X-", "v", MaxTrailers+1)+"\r\n", true)
 		before := req.Header.String()
 
 		require.False(t, DropTrailers(&req.Header))
@@ -238,6 +246,72 @@ func Test_DropTrailers(t *testing.T) {
 	})
 }
 
+// Test_DropResponseTrailers pins that an upstream's trailer section is discarded, announced or not, and never
+// returned to the header section, while the header lines sharing its names stay.
+func Test_DropResponseTrailers(t *testing.T) {
+	t.Parallel()
+	const (
+		status  = "HTTP/1.1 200 OK\r\n"
+		chunked = "Transfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n"
+	)
+
+	tests := []struct {
+		kept      map[string]string // header lines a trailer field shares a name with, read back after the drop
+		name      string
+		raw       string
+		wantLines []string
+	}{
+		{name: "unannounced", raw: status + chunked + "X-Trail: promoted\r\n\r\n"},
+		{name: "announced", raw: status + "Trailer: X-Trail\r\n" + chunked + "X-Trail: promoted\r\n\r\n"},
+		{name: "announced only", raw: status + "Trailer: X-Trail\r\nContent-Length: 2\r\n\r\nok"},
+		{
+			name: "header line beside a trailer", raw: status + "X-Trail: header\r\nTrailer: X-Trail\r\n" + chunked + "X-Trail: promoted\r\n\r\n",
+			wantLines: []string{"header"},
+		},
+		{
+			// fasthttp manages Date itself and ignores one added as a header: the line is put back another way.
+			name: "date line beside a date trailer", raw: status + "Date: Mon, 01 Jan 2024 00:00:00 GMT\r\nTrailer: Date\r\n" +
+				chunked + "Date: Tue, 02 Jan 2024 00:00:00 GMT\r\n\r\n",
+			kept: map[string]string{fasthttp.HeaderDate: "Mon, 01 Jan 2024 00:00:00 GMT"},
+		},
+		{
+			name: "server line beside a server trailer", raw: status + "Server: upstream\r\nTrailer: Server\r\n" + chunked +
+				"Server: other\r\n\r\n",
+			kept: map[string]string{fasthttp.HeaderServer: "upstream"},
+		},
+	}
+
+	for _, tc := range tests {
+		for _, canonical := range []bool{true, false} {
+			t.Run(fmt.Sprintf("%s canonical=%v", tc.name, canonical), func(t *testing.T) {
+				t.Parallel()
+				resp := readResponse(t, tc.raw, canonical)
+
+				require.True(t, DropResponseTrailers(&resp.Header))
+
+				require.Empty(t, resp.Header.PeekTrailerKeys())
+				require.Empty(t, resp.Header.Peek(fasthttp.HeaderTrailer))
+				require.Equal(t, tc.wantLines, lineValues(Lines(&resp.Header, "X-Trail", canonical)))
+				for name, value := range tc.kept {
+					require.Equal(t, value, string(resp.Header.Peek(name)), name)
+					require.Len(t, Lines(&resp.Header, name, canonical), 1, name)
+				}
+				require.Equal(t, "ok", string(resp.Body()))
+			})
+		}
+	}
+
+	t.Run("too many names", func(t *testing.T) {
+		t.Parallel()
+		resp := readResponse(t, status+chunked+apptest.FieldLines("X-", "v", MaxTrailers+1)+"\r\n", true)
+		before := resp.Header.String()
+
+		require.False(t, DropResponseTrailers(&resp.Header))
+		require.Equal(t, before, resp.Header.String())
+		require.Len(t, resp.Header.PeekTrailerKeys(), MaxTrailers+1)
+	})
+}
+
 // Test_ClearTrailers pins that the header comes back as it was without the trailer section, whatever the number of
 // names, with every value read before still holding what it held.
 func Test_ClearTrailers(t *testing.T) {
@@ -250,11 +324,8 @@ func Test_ClearTrailers(t *testing.T) {
 		for _, canonical := range []bool{true, false} {
 			t.Run(fmt.Sprintf("names=%d canonical=%v", names, canonical), func(t *testing.T) {
 				t.Parallel()
-				var extra strings.Builder
-				for i := range names - 2 {
-					fmt.Fprintf(&extra, "X-T%d: v\r\n", i)
-				}
-				req := readRequest(t, head+"X-Role: x\r\nX-Evil: x\r\n"+extra.String()+"\r\n", canonical)
+				extra := apptest.FieldLines("X-T", "v", names-2)
+				req := readRequest(t, head+"X-Role: x\r\nX-Evil: x\r\n"+extra+"\r\n", canonical)
 				want := readRequest(t, head+"\r\n", canonical)
 				require.Len(t, req.Header.PeekTrailerKeys(), names)
 				raw := string(req.Header.RawHeaders())
diff --git a/internal/redirectbody/redirectbody_test.go b/internal/redirectbody/redirectbody_test.go
new file mode 100644
index 00000000000..aa1a3198823
--- /dev/null
+++ b/internal/redirectbody/redirectbody_test.go
@@ -0,0 +1,96 @@
+package redirectbody
+
+import (
+	"bufio"
+	"bytes"
+	"testing"
+
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// pooledRequest returns a pooled request that goes back to the pool when t ends.
+func pooledRequest(t *testing.T) *fasthttp.Request {
+	t.Helper()
+
+	req := fasthttp.AcquireRequest()
+	t.Cleanup(func() { fasthttp.ReleaseRequest(req) })
+	return req
+}
+
+// Test_Drop_RemovesExpect covers the 100-continue expectation, which
+// may not be generated without content (RFC 9110 Section 10.1.1). Left on the
+// bodyless follow-up, a strict target answers 417 instead of serving it.
+func Test_Drop_RemovesExpect(t *testing.T) {
+	t.Parallel()
+	req := pooledRequest(t)
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.Set(fasthttp.HeaderExpect, "100-continue")
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+
+	require.True(t, Drop(req))
+
+	require.Empty(t, req.Header.Peek(fasthttp.HeaderExpect))
+	require.Empty(t, req.Body())
+}
+
+// Test_Drop_ClearsTheParsedForm pins why the PostArgs reset is there:
+// Request.Write falls back to the parsed form when the body is empty, so a
+// caller that had read PostArgs would otherwise have sent the dropped body on
+// the redirected GET.
+func Test_Drop_ClearsTheParsedForm(t *testing.T) {
+	t.Parallel()
+	req := pooledRequest(t)
+	req.SetRequestURI("http://example.com/y")
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
+
+	req.Header.SetMethod(fasthttp.MethodGet)
+	require.True(t, Drop(req))
+
+	var buf bytes.Buffer
+	w := bufio.NewWriter(&buf)
+	require.NoError(t, req.Write(w))
+	require.NoError(t, w.Flush())
+	require.NotContains(t, buf.String(), "a=1", "the dropped form must not come back as the body")
+}
+
+// Test_Drop_ReusedRequestSendsTheNewBody covers the request a caller
+// gets back and then reuses without resetting it.
+//
+// fasthttp clears its parsed-form flag beside the values here, which this cannot
+// reach: the field is unexported and only Request.Reset clears it, which would
+// take the URI and headers the redirect loop is still using. What survives that
+// gap has to be the part that matters — the body actually sent, and the earlier
+// form not reappearing in it or in a later read. An untouched fasthttp request
+// is no better here: SetBody does not invalidate the parsed form either, so it
+// answers a reused PostArgs with the previous body's values.
+func Test_Drop_ReusedRequestSendsTheNewBody(t *testing.T) {
+	t.Parallel()
+	req := pooledRequest(t)
+	req.SetRequestURI("http://example.com/y")
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
+
+	require.True(t, Drop(req))
+
+	// The caller reuses the request for a second POST.
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("b=2")
+
+	require.NotContains(t, req.PostArgs().String(), "a=1",
+		"a reused request must not report the previous body's form values")
+
+	var buf bytes.Buffer
+	w := bufio.NewWriter(&buf)
+	require.NoError(t, req.Write(w))
+	require.NoError(t, w.Flush())
+	require.Contains(t, buf.String(), "b=2", "the reused request sends the body it was given")
+	require.NotContains(t, buf.String(), "a=1")
+}
diff --git a/middleware/adaptor/adaptor_test.go b/middleware/adaptor/adaptor_test.go
index 431903fd891..c1779661e1f 100644
--- a/middleware/adaptor/adaptor_test.go
+++ b/middleware/adaptor/adaptor_test.go
@@ -30,7 +30,6 @@ import (
 	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
-	"github.com/valyala/fasthttp/fasthttputil"
 )
 
 const (
@@ -729,25 +728,13 @@ func Test_StreamedTrailerCap(t *testing.T) {
 		return err
 	})
 
-	ln := fasthttputil.NewInmemoryListener()
-	errCh := make(chan error, 1)
-	go func() { errCh <- app.Listener(ln, fiber.ListenConfig{DisableStartupMessage: true}) }()
-	t.Cleanup(func() {
-		require.NoError(t, app.Shutdown())
-		if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
-			require.NoError(t, err)
-		}
-	})
+	ln := apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true})
 
-	var trailers strings.Builder
-	for i := range fieldname.MaxTrailers + 1 {
-		fmt.Fprintf(&trailers, "X-%d: v\r\n", i)
-	}
+	trailers := apptest.FieldLines("X-", "v", fieldname.MaxTrailers+1)
 	for _, path := range []string{"/handler", "/middleware", "/convert"} {
-		conn, err := ln.Dial()
-		require.NoError(t, err)
-		_, err = conn.Write([]byte("POST " + path + " HTTP/1.1\r\nHost: app.example\r\nTransfer-Encoding: chunked\r\n" +
-			"Connection: close\r\n\r\n5\r\nhello\r\n0\r\n" + trailers.String() + "\r\n"))
+		conn := apptest.Dial(t, ln)
+		_, err := conn.Write([]byte("POST " + path + " HTTP/1.1\r\nHost: app.example\r\nTransfer-Encoding: chunked\r\n" +
+			"Connection: close\r\n\r\n5\r\nhello\r\n0\r\n" + trailers + "\r\n"))
 		require.NoError(t, err)
 		resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
 		require.NoError(t, err)
@@ -1879,20 +1866,8 @@ func Test_HTTPMiddleware_TrailerDoesNotBecomeHeader(t *testing.T) {
 				return c.SendString("ok")
 			})
 
-			ln := fasthttputil.NewInmemoryListener()
-			errCh := make(chan error, 1)
-			go func() { errCh <- app.Listener(ln, fiber.ListenConfig{DisableStartupMessage: true}) }()
-			t.Cleanup(func() {
-				require.NoError(t, app.Shutdown())
-				if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
-					require.NoError(t, err)
-				}
-			})
-
-			conn, err := ln.Dial()
-			require.NoError(t, err)
-			defer conn.Close() //nolint:errcheck // closed by the server already
-			_, err = conn.Write([]byte("POST / HTTP/1.1\r\nHost: app.example\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" +
+			conn := apptest.Dial(t, apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true}))
+			_, err := conn.Write([]byte("POST / HTTP/1.1\r\nHost: app.example\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" +
 				"3\r\na=1\r\n0\r\n" + owned + ": admin\r\n\r\n"))
 			require.NoError(t, err)
 			resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
diff --git a/middleware/cache/cache_security_test.go b/middleware/cache/cache_security_test.go
index 58244fba7d1..f7f74936927 100644
--- a/middleware/cache/cache_security_test.go
+++ b/middleware/cache/cache_security_test.go
@@ -23,7 +23,6 @@ import (
 	"github.com/gofiber/fiber/v3/internal/storagetest"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
-	"github.com/valyala/fasthttp/fasthttputil"
 )
 
 // Test_Cache_Security_UnusualInputs tests that requests and responses shaped to
@@ -2080,22 +2079,13 @@ func Test_Cache_Security_RefusedRequestIsNotStored(t *testing.T) {
 				app.Use(func(c fiber.Ctx) error { return c.Status(fiber.StatusNotFound).SendString("no such page") })
 			}
 
-			ln := fasthttputil.NewInmemoryListener()
-			errCh := make(chan error, 1)
-			go func() { errCh <- app.Listener(ln, fiber.ListenConfig{DisableStartupMessage: true}) }()
-			t.Cleanup(func() {
-				require.NoError(t, app.Shutdown())
-				require.NoError(t, <-errCh)
-			})
+			ln := apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true})
 
 			// send writes GET target and the header lines extra, ended by their blank line, and reads the answer.
 			send := func(target, extra string) reply {
-				conn, err := ln.Dial()
-				require.NoError(t, err)
-				defer conn.Close() //nolint:errcheck // usually closed by the server already
-				require.NoError(t, conn.SetDeadline(time.Now().Add(5*time.Second)))
+				conn := apptest.Dial(t, ln)
 				const lines = " HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n"
-				_, err = conn.Write([]byte("GET " + target + lines + extra))
+				_, err := conn.Write([]byte("GET " + target + lines + extra))
 				require.NoError(t, err)
 				resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
 				require.NoError(t, err)
@@ -2117,3 +2107,107 @@ func Test_Cache_Security_RefusedRequestIsNotStored(t *testing.T) {
 		})
 	}
 }
+
+// Test_Cache_VaryOnHeaderAddedBehindTheCache checks that a response varying on a request header an inner
+// middleware added is not stored: its key, built from the header as the lookup saw it, would serve the first
+// client's page to every other client. A header rewritten in place or removed keeps the lookup's key and stays
+// cacheable, as the response is then the one for what the client sent.
+func Test_Cache_VaryOnHeaderAddedBehindTheCache(t *testing.T) {
+	t.Parallel()
+	type step struct {
+		body, cache string
+		headers     []string // name and value pairs the request sends
+	}
+	fromSession := func(c fiber.Ctx) { c.Request().Header.Set("X-User-Id", c.Cookies("session")) }
+	for name, tc := range map[string]struct {
+		rewrite func(c fiber.Ctx)
+		vary    string // the response's Vary
+		echo    string // the header the body echoes; vary when empty
+		steps   []step
+	}{
+		"added": {
+			rewrite: fromSession,
+			vary:    "X-User-Id",
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "session=alice"}, body: "X-User-Id=alice", cache: cacheUnreachable},
+				{headers: []string{fiber.HeaderCookie, "session=bob"}, body: "X-User-Id=bob", cache: cacheUnreachable},
+			},
+		},
+		// The client's value stays in the key, as a rewrite's does: the response has to vary on
+		// the input it was derived from as well (the next case), as cache.md says.
+		// The cookies make one field line, so an added cookie is told by its name.
+		"cookie added": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.SetCookie("session", c.Get("X-Login")) },
+			vary:    fiber.HeaderCookie,
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "theme=dark", "X-Login", "alice"}, body: "Cookie=theme=dark; session=alice", cache: cacheUnreachable},
+				{headers: []string{fiber.HeaderCookie, "theme=dark", "X-Login", "bob"}, body: "Cookie=theme=dark; session=bob", cache: cacheUnreachable},
+			},
+		},
+		// Added with Add rather than set: the client's cookie of the same name stays beside it.
+		"cookie added beside one of the same name": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.Add(fiber.HeaderCookie, "user="+c.Get("X-Login")) },
+			vary:    fiber.HeaderCookie,
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "user=0", "X-Login", "alice"}, body: "Cookie=user=0; user=alice", cache: cacheUnreachable},
+				{headers: []string{fiber.HeaderCookie, "user=0", "X-Login", "bob"}, body: "Cookie=user=0; user=bob", cache: cacheUnreachable},
+			},
+		},
+		"overwritten": {
+			rewrite: fromSession,
+			vary:    "X-User-Id",
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheMiss},
+				{headers: []string{fiber.HeaderCookie, "session=bob", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheHit},
+			},
+		},
+		"overwritten, varying on its input too": {
+			rewrite: fromSession,
+			vary:    "Cookie, X-User-Id",
+			echo:    "X-User-Id",
+			steps: []step{
+				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheMiss},
+				{headers: []string{fiber.HeaderCookie, "session=bob", "X-User-Id", "0"}, body: "X-User-Id=bob", cache: cacheMiss},
+				{headers: []string{fiber.HeaderCookie, "session=alice", "X-User-Id", "0"}, body: "X-User-Id=alice", cache: cacheHit},
+			},
+		},
+		"removed": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.Del("X-Debug") },
+			vary:    "X-Debug",
+			steps: []step{
+				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheMiss},
+				{headers: []string{"X-Debug", "2"}, body: "X-Debug=", cache: cacheMiss},
+				{headers: []string{"X-Debug", "1"}, body: "X-Debug=", cache: cacheHit},
+			},
+		},
+		"rewritten in place": {
+			rewrite: func(c fiber.Ctx) { c.Request().Header.Set("X-Tenant", strings.ToUpper(c.Get("X-Tenant"))) },
+			vary:    "X-Tenant",
+			steps: []step{
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheMiss},
+				{headers: []string{"X-Tenant", "acme"}, body: "X-Tenant=ACME", cache: cacheHit},
+				{headers: []string{"X-Tenant", "other"}, body: "X-Tenant=OTHER", cache: cacheMiss},
+			},
+		},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			app.Use(New())
+			app.Use(func(c fiber.Ctx) error { tc.rewrite(c); return c.Next() })
+			echo := tc.echo
+			if echo == "" {
+				echo = tc.vary
+			}
+			app.Get("/", func(c fiber.Ctx) error {
+				c.Set(fiber.HeaderVary, tc.vary)
+				return c.SendString(echo + "=" + c.Get(echo))
+			})
+			for _, s := range tc.steps {
+				got := cacheTestCGet(t, app, "/", s.headers...)
+				require.Equal(t, fiber.StatusOK, got.status, s.headers)
+				cacheTestCRequireReply(t, got, s.cache, s.body, s.headers)
+			}
+		})
+	}
+}
diff --git a/middleware/csrf/csrf_test.go b/middleware/csrf/csrf_test.go
index 53495b5e360..aa02a3f7ac8 100644
--- a/middleware/csrf/csrf_test.go
+++ b/middleware/csrf/csrf_test.go
@@ -982,14 +982,7 @@ func Test_CSRF_UnsafeHeaderValue(t *testing.T) {
 
 	resp := apptest.Expect(t, app, "/", fiber.StatusOK)
 
-	var token string
-	for _, c := range resp.Cookies() {
-		if c.Name != ConfigDefault.CookieName {
-			continue
-		}
-		token = c.Value
-		break
-	}
+	token := responseCookie(t, resp, ConfigDefault.CookieName).Value
 
 	t.Log("token", token)
 
@@ -1911,14 +1904,7 @@ func Test_CSRF_Security_CookieAttributes(t *testing.T) {
 
 	resp := apptest.Do(t, app, "/")
 
-	var cookie *http.Cookie
-	for _, ck := range resp.Cookies() {
-		if ck.Name == "__Host-csrf" {
-			cookie = ck
-			break
-		}
-	}
-	require.NotNil(t, cookie, "CSRF cookie should be set")
+	cookie := responseCookie(t, resp, "__Host-csrf")
 	require.True(t, cookie.HttpOnly, "cookie must be HttpOnly")
 	require.True(t, cookie.Secure, "cookie must be Secure")
 	require.Equal(t, http.SameSiteStrictMode, cookie.SameSite, "cookie must be SameSite=Strict")
@@ -2188,3 +2174,99 @@ func Test_CSRF_VaryDoesNotShareFieldsWithCustomCtx(t *testing.T) {
 		"the custom Vary must still be the one that ran")
 	require.Equal(t, []string{fiber.HeaderCookie}, varyCookie)
 }
+
+// responseCookie returns the cookie named name that resp set.
+func responseCookie(t *testing.T, resp *http.Response, name string) *http.Cookie {
+	t.Helper()
+
+	for _, ck := range resp.Cookies() {
+		if ck.Name == name {
+			return ck
+		}
+	}
+	require.FailNow(t, "cookie not set", name)
+	return nil
+}
+
+// cookieHeaderOf returns the cookies resp set as one Cookie header value.
+func cookieHeaderOf(resp *http.Response) string {
+	var pairs []string
+	for _, ck := range resp.Cookies() {
+		pairs = append(pairs, ck.Name+"="+ck.Value)
+	}
+	return strings.Join(pairs, "; ")
+}
+
+// Test_CSRF_SessionModeCookieExpiresWithTheToken pins that in session mode the cookie expires when the stored
+// token does: a token left as it is, with more than half its lifetime left, keeps its expiration, and one
+// renewed gets the full IdleTimeout again.
+func Test_CSRF_SessionModeCookieExpiresWithTheToken(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	sessHandler, store := session.NewWithStore()
+	app.Use(sessHandler)
+	app.Use(New(Config{Session: store}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("ok") })
+
+	resp := apptest.Expect(t, app, "/", fiber.StatusOK)
+	cookieHeader := cookieHeaderOf(resp)
+	sessionID := responseCookie(t, resp, "session_id").Value
+	token := responseCookie(t, resp, "csrf_").Value
+
+	// In order: the rows plant the one session's token.
+	for _, tc := range []struct {
+		name       string
+		left, want time.Duration
+	}{
+		{name: "left as it is", left: 16 * time.Minute, want: 16 * time.Minute},
+		{name: "renewed", left: 14 * time.Minute, want: 30 * time.Minute},
+	} {
+		sess, err := store.GetByID(context.Background(), sessionID)
+		require.NoError(t, err, tc.name)
+		sess.Set(sessionKey, Token{Key: token, Raw: dummyValue, Expiration: time.Now().Add(tc.left)})
+		require.NoError(t, sess.Save(), tc.name)
+		sess.Release()
+
+		resp = apptest.Expect(t, app, apptest.Req(fiber.MethodGet, "/", apptest.WithHeader(fiber.HeaderCookie, cookieHeader)), fiber.StatusOK)
+		require.WithinDuration(t, time.Now().Add(tc.want), responseCookie(t, resp, "csrf_").Expires, 5*time.Second, tc.name)
+	}
+}
+
+// Test_CSRF_SessionModeKeepsConcurrentSessionChange pins that a request the middleware runs for in session mode
+// does not count as a writer of the session: the token it finds fresh is left as it is, so a change another
+// request stored while this one ran, such as a role taken away, is not undone when it finishes.
+func Test_CSRF_SessionModeKeepsConcurrentSessionChange(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	sessHandler, store := session.NewWithStore()
+	app.Use(sessHandler)
+	app.Use(New(Config{Session: store}))
+	entered, proceed := make(chan struct{}), make(chan struct{})
+	app.Get("/login", func(c fiber.Ctx) error { session.FromContext(c).Set("role", "admin"); return c.SendString("ok") })
+	app.Get("/slow", func(c fiber.Ctx) error { close(entered); <-proceed; return c.SendString("slow done") })
+	app.Get("/demote", func(c fiber.Ctx) error { session.FromContext(c).Set("role", "user"); return c.SendString("ok") })
+	app.Get("/role", func(c fiber.Ctx) error {
+		role, ok := session.FromContext(c).Get("role").(string)
+		if !ok {
+			role = "" // a missing role reads as empty
+		}
+		return c.SendString(role)
+	})
+
+	resp := apptest.Expect(t, app, "http://app.example.com/login", fiber.StatusOK)
+	cookieHeader := cookieHeaderOf(resp)
+	withCookies := func(path string) *http.Request {
+		return apptest.Req(fiber.MethodGet, "http://app.example.com"+path, apptest.WithHeader(fiber.HeaderCookie, cookieHeader))
+	}
+
+	done := make(chan error, 1)
+	go func() {
+		_, err := app.Test(withCookies("/slow"), fiber.TestConfig{Timeout: 10 * time.Second})
+		done <- err
+	}()
+	apptest.Recv(t, entered, 5*time.Second)
+	apptest.Expect(t, app, withCookies("/demote"), fiber.StatusOK)
+	close(proceed)
+	require.NoError(t, apptest.Recv(t, done, 10*time.Second))
+	apptest.ExpectBody(t, app, withCookies("/role"), fiber.StatusOK, "user")
+}
diff --git a/middleware/proxy/proxy_test.go b/middleware/proxy/proxy_test.go
index a1aef657493..2ad15e14045 100644
--- a/middleware/proxy/proxy_test.go
+++ b/middleware/proxy/proxy_test.go
@@ -6,9 +6,11 @@ import (
 	"errors"
 	"fmt"
 	"io"
+	"maps"
 	"net"
 	"net/http"
 	"net/http/httptest"
+	"net/url"
 	"os"
 	"slices"
 	"strconv"
@@ -1030,12 +1032,7 @@ func Test_Proxy_TrailerSectionWhateverThePolicy(t *testing.T) {
 			t.Parallel()
 			policy := proxyTestAllowPrivatePolicy()
 			policy.KeepHopByHopHeaders = keep
-			for name, handler := range map[string]fiber.Handler{
-				"Balancer": Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy}),
-				"Forward": func(c fiber.Ctx) error {
-					return forwardWithRealIP(c, "http://"+addr, normalizePolicy(policy))
-				},
-			} {
+			for name, handler := range proxyTestHandlersUnder(addr, policy, nil) {
 				app := fiber.New()
 				app.Use(func(c fiber.Ctx) error {
 					// Announced after the router dropped the client's, as only the application can.
@@ -1060,6 +1057,219 @@ func Test_Proxy_TrailerSectionWhateverThePolicy(t *testing.T) {
 	}
 }
 
+// proxyTestHandlersUnder returns the Balancer and the Forward handler proxying to addr under
+// policy, each running after, when given, once the upstream answered: as Balancer's
+// ModifyResponse, and after Forward returns.
+func proxyTestHandlersUnder(addr string, policy SecurityPolicy, after fiber.Handler) map[string]fiber.Handler {
+	return map[string]fiber.Handler{
+		"Balancer": Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy, ModifyResponse: after}),
+		"Forward": func(c fiber.Ctx) error {
+			if err := forwardWithRealIP(c, "http://"+addr, normalizePolicy(policy)); err != nil || after == nil {
+				return err
+			}
+			return after(c)
+		},
+	}
+}
+
+// proxyTestBalancingClient is a BalancingClient of the caller's own type, which Balancer cannot ask whether it
+// streams response bodies.
+type proxyTestBalancingClient struct {
+	*fasthttp.HostClient
+}
+
+// proxyTestMemoryClient is a BalancingClient of the caller's own type that answers from memory, through the
+// response's buffer or with a raw body, and sends the body as the response holds it.
+type proxyTestMemoryClient struct {
+	sent chan<- []byte
+	body []byte
+	raw  bool
+}
+
+func (c proxyTestMemoryClient) DoDeadline(_ *fasthttp.Request, resp *fasthttp.Response, _ time.Time) error {
+	resp.SetStatusCode(fiber.StatusOK)
+	if c.raw {
+		resp.SetBodyRaw(c.body)
+	} else {
+		resp.SetBody(c.body)
+	}
+	c.sent <- resp.Body()
+	return nil
+}
+
+func (proxyTestMemoryClient) PendingRequests() int { return 0 }
+
+// Test_Proxy_Balancer_CustomClientBodyMoved checks that a body a client of the caller's own type buffers reaches
+// the response whole and in place: the buffer, or the raw body, moves over rather than being copied.
+func Test_Proxy_Balancer_CustomClientBodyMoved(t *testing.T) {
+	t.Parallel()
+	for _, tc := range []struct {
+		name string
+		raw  bool
+	}{{name: "buffered"}, {name: "raw", raw: true}} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			body := []byte(strings.Repeat("upstream ", 1024))
+			sent, adopted := make(chan []byte, 1), make(chan []byte, 1)
+			app := fiber.New()
+			app.Use(Balancer(Config{
+				Client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{
+					proxyTestMemoryClient{sent: sent, body: body, raw: tc.raw},
+				}},
+				ModifyResponse: func(c fiber.Ctx) error { adopted <- c.Response().Body(); return nil },
+			}))
+
+			apptest.ExpectBody(t, app, "/", fiber.StatusOK, string(body))
+			set, got := apptest.Recv(t, sent, time.Second), apptest.Recv(t, adopted, time.Second)
+			require.Same(t, &set[0], &got[0], "the body was copied")
+			if tc.raw {
+				require.Same(t, &body[0], &got[0], "the raw body was copied")
+			}
+		})
+	}
+}
+
+// proxyTestStreamingHandlersUnder is proxyTestHandlersUnder for clients that stream response bodies: Balancer
+// with a HostClient of its own, bare or behind a type of the caller's, Forward and Do with a Client, and Do with
+// the response set to stream.
+func proxyTestStreamingHandlersUnder(addr string, policy SecurityPolicy, after fiber.Handler) map[string]fiber.Handler {
+	streaming := &fasthttp.Client{StreamResponseBody: true}
+	do := func(c fiber.Ctx, cli *fasthttp.Client) error {
+		send := func(cli *fasthttp.Client, req *fasthttp.Request, res *fasthttp.Response, _ *url.URL) error {
+			return cli.Do(req, res)
+		}
+		if err := doActionWithPolicy(c, "http://"+addr, normalizePolicy(policy), nil, send, cli); err != nil || after == nil {
+			return err
+		}
+		return after(c)
+	}
+	return map[string]fiber.Handler{
+		"Balancer streaming": Balancer(Config{
+			Client:         &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{&fasthttp.HostClient{Addr: addr, StreamResponseBody: true}}},
+			SecurityPolicy: &policy,
+			ModifyResponse: after,
+		}),
+		"Balancer streaming behind a custom client": Balancer(Config{
+			Client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{
+				proxyTestBalancingClient{&fasthttp.HostClient{Addr: addr, StreamResponseBody: true}},
+			}},
+			SecurityPolicy: &policy,
+			ModifyResponse: after,
+		}),
+		"Forward streaming": func(c fiber.Ctx) error {
+			if err := forwardWithRealIP(c, "http://"+addr, normalizePolicy(policy), streaming); err != nil || after == nil {
+				return err
+			}
+			return after(c)
+		},
+		"Do streaming": func(c fiber.Ctx) error { return do(c, streaming) },
+		"Do with a streamed response": func(c fiber.Ctx) error {
+			c.Response().StreamBody = true
+			return do(c, &fasthttp.Client{})
+		},
+	}
+}
+
+// Test_Proxy_UpstreamTrailerSectionDropped checks that the trailer section of an upstream response reaches the
+// client neither as trailers nor as header lines, announced or not, whatever the hop-by-hop policy and whether
+// the client buffers the response or streams it, and that a section naming more than fieldname.MaxTrailers
+// fields is a 502 carrying none of the upstream's fields.
+func Test_Proxy_UpstreamTrailerSectionDropped(t *testing.T) {
+	t.Parallel()
+	// Not a Fiber app: net/http writes the trailer section of a chunked response.
+	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		w.Header().Set("X-Kept", "header")
+		if r.Header.Get("X-Sized") != "" {
+			// A body of known size, which a client that streams response bodies buffers all the same.
+			w.Header().Set("Content-Length", "2")
+			fmt.Fprint(w, "ok")
+			return
+		}
+		if r.Header.Get("X-No-Type") != "" {
+			// No Content-Type, which the app is set not to add one for.
+			w.Header()["Content-Type"] = nil
+			fmt.Fprint(w, "ok")
+			return
+		}
+		w.Header().Set(fiber.HeaderTrailer, "X-Trail")
+		// X-Many asks for fieldname.MaxTrailers more fields, announced in Trailer or not.
+		many := r.Header.Get("X-Many")
+		if many == "announced" {
+			for i := range fieldname.MaxTrailers {
+				w.Header().Add(fiber.HeaderTrailer, "X-"+strconv.Itoa(i))
+			}
+		}
+		w.WriteHeader(http.StatusOK)
+		fmt.Fprint(w, "ok")
+		w.Header().Set("X-Trail", "promoted")
+		w.Header().Set(http.TrailerPrefix+"X-Unannounced", "u2")
+		for i := 0; many != "" && i < fieldname.MaxTrailers; i++ {
+			name := "X-" + strconv.Itoa(i)
+			if many == "unannounced" {
+				name = http.TrailerPrefix + name
+			}
+			w.Header().Set(name, "v")
+		}
+	}))
+	t.Cleanup(upstream.Close)
+	addr := upstream.Listener.Addr().String()
+
+	for _, keep := range []bool{false, true} {
+		t.Run(fmt.Sprintf("keep=%v", keep), func(t *testing.T) {
+			t.Parallel()
+			policy := proxyTestAllowPrivatePolicy()
+			policy.KeepHopByHopHeaders = keep
+			// A hook, like a Do caller, sees the response without its trailer section.
+			hookSaw := func(c fiber.Ctx) error {
+				c.Set("X-Hook", fmt.Sprintf("%d:%s", len(c.Response().Header.PeekTrailerKeys()), c.Response().Header.Peek("X-Trail")))
+				return nil
+			}
+			handlers := map[string]fiber.Handler{}
+			streaming := proxyTestStreamingHandlersUnder(addr, policy, hookSaw)
+			maps.Copy(handlers, proxyTestHandlersUnder(addr, policy, hookSaw))
+			maps.Copy(handlers, streaming)
+			for name, handler := range handlers {
+				app := fiber.New(fiber.Config{DisableDefaultContentType: true})
+				app.Get("/", handler)
+
+				resp := apptest.ExpectBody(t, app, "/", fiber.StatusOK, "ok")
+				require.Equal(t, "header", resp.Header.Get("X-Kept"), name)
+				require.Equal(t, "0:", resp.Header.Get("X-Hook"), name)
+				for _, dropped := range []string{"X-Trail", "X-Unannounced", fiber.HeaderTrailer} {
+					require.Empty(t, resp.Header.Values(dropped), name+" "+dropped)
+				}
+				require.Empty(t, resp.Trailer, name)
+
+				for _, many := range []string{"announced", "unannounced"} {
+					req := apptest.Req(fiber.MethodGet, "/", apptest.WithHeader("X-Many", many))
+					if _, streams := streaming[name]; streams && many == "unannounced" {
+						// Received once the body has been read, with the response of the proxy's own.
+						resp = apptest.ExpectBody(t, app, req, fiber.StatusOK, "ok")
+						require.Equal(t, "0:", resp.Header.Get("X-Hook"), name+" "+many)
+						require.Empty(t, resp.Trailer, name+" "+many)
+						continue
+					}
+					resp = apptest.Expect(t, app, req, fiber.StatusBadGateway)
+					require.Empty(t, resp.Header.Values("X-Kept"), name+" "+many)
+				}
+
+				resp = apptest.ExpectBody(t, app, apptest.Req(fiber.MethodGet, "/", apptest.WithHeader("X-Sized", "1")), fiber.StatusOK, "ok")
+				require.Equal(t, "header", resp.Header.Get("X-Kept"), name)
+				require.Equal(t, "0:", resp.Header.Get("X-Hook"), name)
+
+				// No body to stream: the response is buffered, by a client that streams as well.
+				resp = apptest.ExpectBody(t, app, apptest.Req(fiber.MethodHead, "/"), fiber.StatusOK, "")
+				require.Equal(t, "header", resp.Header.Get("X-Kept"), name)
+				require.Equal(t, "0:", resp.Header.Get("X-Hook"), name)
+
+				// The app's choice of no default Content-Type holds for a response read into one of the proxy's own.
+				resp = apptest.ExpectBody(t, app, apptest.Req(fiber.MethodGet, "/", apptest.WithHeader("X-No-Type", "1")), fiber.StatusOK, "ok")
+				require.Empty(t, resp.Header.Values(fiber.HeaderContentType), name)
+			}
+		})
+	}
+}
+
 // Test_Proxy_StreamedBodyTrailerSection checks that the trailer section of a streamed body
 // reaches the upstream neither as header lines nor as trailers, and does not take the
 // place of a header written once the body has been read, whatever the hop-by-hop policy.
@@ -1579,10 +1789,10 @@ func Test_Proxy_Do_HTTP_Prefix_URL(t *testing.T) {
 	app := fiber.New()
 	app.Get("/*", func(c fiber.Ctx) error {
 		path := c.OriginalURL()
-		url := strings.TrimPrefix(path, "/")
+		target := strings.TrimPrefix(path, "/")
 
-		require.Equal(t, "http://"+addr, url)
-		if err := Do(c, url); err != nil {
+		require.Equal(t, "http://"+addr, target)
+		if err := Do(c, target); err != nil {
 			return err
 		}
 		c.Response().Header.Del(fiber.HeaderServer)
@@ -2186,7 +2396,8 @@ func Test_Proxy_Balancer_MaxResponseBodySize(t *testing.T) {
 	}{
 		"over the limit":   {limit: 16, wantErr: true},
 		"within the limit": {limit: 128},
-		"unbounded":        {limit: 0},
+		"default":          {limit: 0},
+		"unbounded":        {limit: -1},
 	} {
 		t.Run(name, func(t *testing.T) {
 			t.Parallel()
@@ -2209,6 +2420,50 @@ func Test_Proxy_Balancer_MaxResponseBodySize(t *testing.T) {
 	}
 }
 
+// withDefaultRequestTimeoutForTest shortens the default client's request bound until tb ends.
+func withDefaultRequestTimeoutForTest(tb testing.TB, timeout time.Duration) {
+	tb.Helper()
+	prev := defaultRequestTimeout.Swap(int64(timeout))
+	tb.Cleanup(func() { defaultRequestTimeout.Store(prev) })
+}
+
+// Test_Proxy_DefaultBounds pins the bounds of the default client: a request has defaultRequestTimeout for
+// the whole exchange, in one attempt, unless DoTimeout or DoDeadline set the request's own bound, longer
+// included, and a response body of at most defaultMaxResponseBodySize.
+//
+// conventions:ignore parallel: it shortens the package-level bound every default-client request reads, and measures it
+func Test_Proxy_DefaultBounds(t *testing.T) {
+	withDefaultRequestTimeoutForTest(t, 150*time.Millisecond)
+	var hits atomic.Int32
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		hits.Add(1)
+		time.Sleep(400 * time.Millisecond)
+		return c.SendString("proxied")
+	})
+
+	app := fiber.New()
+	app.Get("/do", func(c fiber.Ctx) error { return Do(c, "http://"+addr) })
+	app.Get("/timeout", func(c fiber.Ctx) error { return DoTimeout(c, "http://"+addr, time.Second) })
+	app.Get("/deadline", func(c fiber.Ctx) error { return DoDeadline(c, "http://"+addr, time.Now().Add(time.Second)) })
+
+	resp := apptest.Expect(t, app, "/do", fiber.StatusInternalServerError)
+	require.Equal(t, fasthttp.ErrTimeout.Error(), apptest.Body(t, resp))
+	require.Equal(t, int32(1), hits.Load(), "the bound is the request's: no second attempt at the upstream")
+	for _, path := range []string{"/timeout", "/deadline"} {
+		apptest.ExpectBody(t, app, path, fiber.StatusOK, "proxied")
+	}
+	require.Equal(t, int32(3), hits.Load())
+
+	require.Zero(t, defaultClient.ReadTimeout, "a client timeout would cap DoTimeout and be set again per attempt")
+	require.Zero(t, defaultClient.WriteTimeout)
+	require.Equal(t, defaultMaxResponseBodySize, defaultClient.MaxResponseBodySize)
+	require.Equal(t, defaultMaxResponseBodySize, configDefault(Config{Servers: []string{"http://upstream.example"}}).MaxResponseBodySize)
+	cfg := configDefault(Config{Servers: []string{"http://upstream.example"}, MaxResponseBodySize: -1})
+	require.Equal(t, -1, cfg.MaxResponseBodySize)
+	hc := newHostClient(mustParseTestURL(t, "http://upstream.example:8080"), &cfg, DefaultSecurityPolicy())
+	require.Equal(t, 0, hc.MaxResponseBodySize)
+}
+
 // Headers larger than WriteBufferSize must still arrive whole.
 func Test_Proxy_Balancer_WriteBufferSize(t *testing.T) {
 	t.Parallel()
diff --git a/middleware/proxy/security_test.go b/middleware/proxy/security_test.go
index a3477d045b7..9471d7bc28d 100644
--- a/middleware/proxy/security_test.go
+++ b/middleware/proxy/security_test.go
@@ -1354,13 +1354,14 @@ func Test_Security_RedirectRequest_DropsFraming(t *testing.T) {
 	proxyTestReadRequest(t, req, raw)
 	require.Equal(t, -1, req.Header.ContentLength(), "the request is chunked")
 
-	redirectRequest(req)
+	require.True(t, redirectRequest(req))
 
 	wire := req.String()
 	requestLine, _, _ := strings.Cut(wire, "\r\n")
 	require.Equal(t, "GET /start HTTP/1.1", requestLine)
 	require.NotContains(t, wire, "Transfer-Encoding")
 	require.NotContains(t, wire, "Trailer")
+	require.NotContains(t, wire, "X-Sum", "the trailer section goes with the body, not into the header section")
 	require.NotContains(t, wire, "abc")
 }
 
diff --git a/middleware/session/data_test.go b/middleware/session/data_test.go
index 2a770c3b04a..47fbf750662 100644
--- a/middleware/session/data_test.go
+++ b/middleware/session/data_test.go
@@ -247,34 +247,36 @@ func Test_ValueMayAlias(t *testing.T) {
 
 func Test_Data_DirtyTracking(t *testing.T) {
 	t.Parallel()
-	// cleanData returns pooled data holding key/value with the dirty flag cleared,
+	// cleanData returns pooled data holding key/value with both flags cleared,
 	// standing in for the state a successful decode leaves behind.
 	cleanData := func(t *testing.T, key, value any) *data {
 		t.Helper()
 		d := sessionTestData(t, key, value)
 		d.dirty.Store(false)
+		d.mutated.Store(false)
 		return d
 	}
 
-	t.Run("Set marks dirty", func(t *testing.T) {
+	t.Run("Set marks mutated", func(t *testing.T) {
 		t.Parallel()
 		d := cleanData(t, "user", "fenny")
 		d.Set("role", "admin")
-		require.True(t, d.dirty.Load())
+		require.True(t, d.mutated.Load())
+		require.False(t, d.dirty.Load(), "a change is not a stale snapshot")
 	})
 
-	t.Run("Delete marks dirty", func(t *testing.T) {
+	t.Run("Delete marks mutated", func(t *testing.T) {
 		t.Parallel()
 		d := cleanData(t, "user", "fenny")
 		d.Delete("user")
-		require.True(t, d.dirty.Load())
+		require.True(t, d.mutated.Load())
 	})
 
-	t.Run("Reset marks dirty", func(t *testing.T) {
+	t.Run("Reset marks mutated", func(t *testing.T) {
 		t.Parallel()
 		d := cleanData(t, "user", "fenny")
 		d.Reset()
-		require.True(t, d.dirty.Load())
+		require.True(t, d.mutated.Load())
 	})
 
 	t.Run("Get of a scalar stays clean", func(t *testing.T) {
diff --git a/middleware/session/session_test.go b/middleware/session/session_test.go
index b60c87fd767..035b4e51c82 100644
--- a/middleware/session/session_test.go
+++ b/middleware/session/session_test.go
@@ -1922,3 +1922,131 @@ func Test_Session_RegenerateAfterConcurrentEnd_OldIDWrittenBack(t *testing.T) {
 	require.Nil(t, sessionTestStored(t, store, id).Get("user"))
 	sessionTestRequireGone(t, store, inFlight.ID())
 }
+
+// Test_Session_UnchangedRequestKeepsConcurrentChange pins that a request which changed nothing, a read of a value
+// it could change in place included, does not store its snapshot over a change another request stored meanwhile,
+// also when it rotates the ID, which then carries that change; a request that did change the session, with Set or
+// in place through a value Get returned, stores its snapshot over it.
+func Test_Session_UnchangedRequestKeepsConcurrentChange(t *testing.T) {
+	t.Parallel()
+	editTags := func(s *Session) {
+		tags, ok := s.Get("tags").([]string)
+		require.True(t, ok)
+		tags[0] = "y"
+	}
+	for name, tc := range map[string]struct {
+		touch      func(*Session)
+		want       string
+		tags       []string
+		regenerate bool
+	}{
+		"scalar read":                            {touch: func(s *Session) { _ = s.Get("role") }, want: "user", tags: []string{"x"}},
+		"slice read":                             {touch: func(s *Session) { _ = s.Get("tags") }, want: "user", tags: []string{"x"}},
+		"slice read and regenerate":              {touch: func(s *Session) { _ = s.Get("tags") }, regenerate: true, want: "user", tags: []string{"x"}},
+		"nothing and regenerate":                 {touch: func(*Session) {}, regenerate: true, want: "user", tags: []string{"x"}},
+		"changed":                                {touch: func(s *Session) { s.Set("role", "owner") }, want: "owner", tags: []string{"x"}},
+		"changed and regenerate":                 {touch: func(s *Session) { s.Set("role", "owner") }, regenerate: true, want: "owner", tags: []string{"x"}},
+		"changed through a slice":                {touch: editTags, want: "admin", tags: []string{"y"}},
+		"changed through a slice and regenerate": {touch: editTags, regenerate: true, want: "admin", tags: []string{"y"}},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			store := NewStore(Config{Storage: memory.New()})
+			store.RegisterType([]string{})
+			id := seedSession(t, app, store, func(s *Session) { s.Set("role", "admin"); s.Set("tags", []string{"x"}) })
+
+			inFlight := loadSession(t, app, store, id)
+			tc.touch(inFlight)
+			other := loadSession(t, app, store, id)
+			other.Set("role", "user")
+			require.NoError(t, other.Save())
+			if tc.regenerate {
+				require.NoError(t, inFlight.Regenerate())
+				require.NotEqual(t, id, inFlight.ID())
+			}
+			require.NoError(t, inFlight.Save())
+
+			stored := sessionTestStored(t, store, inFlight.ID())
+			require.Equal(t, tc.want, stored.Get("role"))
+			require.Equal(t, tc.tags, stored.Get("tags"), "a value changed in place is the request's own change; one only read is not")
+			if tc.regenerate {
+				sessionTestRequireGone(t, store, id)
+			}
+		})
+	}
+}
+
+// Test_Session_RegenerateKeepsSessionOnUndecodableChange pins that a Regenerate which cannot decode what
+// another request stored, bytes a newer instance wrote for instance, still rotates the ID and keeps this
+// request's snapshot: the old key is already deleted, so storing nothing would log the user out.
+func Test_Session_RegenerateKeepsSessionOnUndecodableChange(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	store := NewStore(Config{Storage: memory.New()})
+	id := seedSession(t, app, store, func(s *Session) { s.Set("role", "admin") })
+
+	inFlight := loadSession(t, app, store, id)
+	other := loadSession(t, app, store, id)
+	other.Set("role", "user")
+	require.NoError(t, other.Save())
+	require.NoError(t, store.Storage.Set(inFlight.storageKey(), []byte("not a session"), 0))
+
+	require.Error(t, inFlight.Regenerate())
+	require.NotEqual(t, id, inFlight.ID())
+	require.Equal(t, "admin", inFlight.Get("role"), "the snapshot is left as it was")
+	require.NoError(t, inFlight.Save())
+
+	stored := sessionTestStored(t, store, inFlight.ID())
+	require.Equal(t, "admin", stored.Get("role"))
+	sessionTestRequireGone(t, store, id)
+}
+
+// Test_Session_RegenerateDropsKeyAnotherRequestDeleted pins that the change a Regenerate carries over
+// replaces the snapshot: a key the other request deleted does not survive the rotation.
+func Test_Session_RegenerateDropsKeyAnotherRequestDeleted(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	store := NewStore(Config{Storage: memory.New()})
+	id := seedSession(t, app, store, func(s *Session) { s.Set("role", "admin"); s.Set("gone", "x") })
+
+	inFlight := loadSession(t, app, store, id)
+	other := loadSession(t, app, store, id)
+	other.Delete("gone")
+	other.Set("role", "user")
+	require.NoError(t, other.Save())
+
+	require.NoError(t, inFlight.Regenerate())
+	require.Nil(t, inFlight.Get("gone"))
+	inFlight.Set("note", "y")
+	require.NoError(t, inFlight.Save())
+
+	stored := sessionTestStored(t, store, inFlight.ID())
+	require.Nil(t, stored.Get("gone"))
+	require.Equal(t, "user", stored.Get("role"))
+	require.Equal(t, "y", stored.Get("note"))
+}
+
+// Test_Session_RegenerateReportsStorageError checks that Regenerate reports the storage failing to read
+// what another request stored since the load and leaves the session as it is: the old ID still holds
+// that request's change.
+func Test_Session_RegenerateReportsStorageError(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	storage := storagetest.New()
+	store := NewStore(Config{Storage: storage})
+	id := seedSession(t, app, store, func(s *Session) { s.Set("role", "admin") })
+
+	inFlight := loadSession(t, app, store, id)
+	other := loadSession(t, app, store, id)
+	other.Set("role", "user")
+	require.NoError(t, other.Save())
+
+	errRead := errors.New("storage read failed")
+	storage.SetErr(storagetest.OpGet, storageKeyPrefix+id, errRead)
+	require.ErrorIs(t, inFlight.Regenerate(), errRead)
+	require.Equal(t, id, inFlight.ID())
+
+	storage.ClearErrs()
+	require.Equal(t, "user", sessionTestStored(t, store, id).Get("role"))
+}
diff --git a/middleware/static/static_test.go b/middleware/static/static_test.go
index e980e5dab8a..aa97c463506 100644
--- a/middleware/static/static_test.go
+++ b/middleware/static/static_test.go
@@ -16,7 +16,6 @@ import (
 
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
-	"github.com/valyala/fasthttp/fasthttputil"
 
 	"github.com/gofiber/fiber/v3"
 	"github.com/gofiber/fiber/v3/internal/apptest"
@@ -87,7 +86,7 @@ func Test_Static_Index_Default(t *testing.T) {
 
 	app.Get("", New("../../.github/"))
 
-	app.Get("test", New("", Config{IndexNames: []string{"index.html"}}))
+	app.Get("test", New(".", Config{IndexNames: []string{"index.html"}}))
 
 	resp := staticTestExpect(t, app, "/", 200, fiber.MIMETextHTMLCharsetUTF8)
 	require.Contains(t, apptest.Body(t, resp), "Hello, World!")
@@ -336,19 +335,8 @@ func Test_Static_RefusedRequestServesNoFile(t *testing.T) {
 	app.All("/admin/*", func(c fiber.Ctx) error { return c.SendStatus(fiber.StatusUnauthorized) })
 	app.Use(New(staticTestRoot(t, map[string]string{"admin/secret.txt": "TOP-SECRET"})))
 
-	ln := fasthttputil.NewInmemoryListener()
-	errCh := make(chan error, 1)
-	go func() { errCh <- app.Listener(ln, fiber.ListenConfig{DisableStartupMessage: true}) }()
-	t.Cleanup(func() {
-		require.NoError(t, app.Shutdown())
-		require.NoError(t, <-errCh)
-	})
-
-	conn, err := ln.Dial()
-	require.NoError(t, err)
-	defer conn.Close() //nolint:errcheck // closed by the server already
-	require.NoError(t, conn.SetDeadline(time.Now().Add(5*time.Second)))
-	_, err = conn.Write([]byte("GET /admin/secret.txt HTTP/1.1\r\nHost: example.com\r\nContent-Length: 99999\r\n\r\n"))
+	conn := apptest.Dial(t, apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true}))
+	_, err := conn.Write([]byte("GET /admin/secret.txt HTTP/1.1\r\nHost: example.com\r\nContent-Length: 99999\r\n\r\n"))
 	require.NoError(t, err)
 
 	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
@@ -2225,3 +2213,13 @@ func Benchmark_Static_Browse(b *testing.B) {
 		})
 	}
 }
+
+func Test_Static_EmptyRoot(t *testing.T) {
+	t.Parallel()
+	require.PanicsWithValue(t, errEmptyRoot, func() { New("") })
+	require.NotPanics(t, func() { New("", Config{FS: os.DirFS(testCSSDir)}) })
+
+	app := fiber.New()
+	app.Get("/*", New("", Config{FS: os.DirFS(testCSSDir)}))
+	staticTestExpect(t, app, "/style.css", fiber.StatusOK, fiber.MIMETextCSSCharsetUTF8)
+}
diff --git a/middleware/timeout/timeout_test.go b/middleware/timeout/timeout_test.go
index e2adfb16ae4..4ccdb14f6a0 100644
--- a/middleware/timeout/timeout_test.go
+++ b/middleware/timeout/timeout_test.go
@@ -1,12 +1,14 @@
 package timeout
 
 import (
+	"bufio"
 	"cmp"
 	"context"
 	"errors"
 	"fmt"
 	"io"
 	"net"
+	"net/http"
 	"strconv"
 	"strings"
 	"sync/atomic"
@@ -733,9 +735,11 @@ func Test_Timeout_NestedInnerFirst(t *testing.T) {
 func Test_Timeout_EnclosingDeadlineRunsInline(t *testing.T) {
 	t.Parallel()
 	app := fiber.New()
-	app.Use(outerTimeout(Config{Timeout: 20 * time.Millisecond}))
-	app.Get("/wait", New(untilDeadline, Config{Timeout: time.Second}))
-	app.Get("/panic", New(func(fiber.Ctx) error { panic("boom") }, Config{Timeout: time.Second}))
+	app.Get("/wait", outerTimeout(Config{Timeout: 20 * time.Millisecond}), New(untilDeadline, Config{Timeout: time.Second}))
+	// The enclosing deadline of the route that must answer before it is a second off, as a slow run has
+	// blown a 20 ms one: inline all the same, as the deadline comes before the route's own.
+	boom := func(fiber.Ctx) error { panic("boom") }
+	app.Get("/panic", outerTimeout(Config{Timeout: time.Second}), New(boom, Config{Timeout: 2 * time.Second}))
 
 	apptest.Expect(t, app, "/wait", fiber.StatusServiceUnavailable)
 
@@ -998,3 +1002,47 @@ func Test_Timeout_ReturnsErrServiceUnavailable(t *testing.T) {
 		})
 	}
 }
+
+// A HEAD response carries no body (RFC 9110 §9.3.2); one sent by the timeout path would be read as the start of
+// the next response on the connection.
+func Test_Timeout_HEADResponseHasNoBody(t *testing.T) {
+	t.Parallel()
+	for name, tc := range map[string]struct {
+		body   string
+		cfg    Config
+		status int
+	}{
+		"default": {cfg: Config{Timeout: 20 * time.Millisecond}, status: fiber.StatusServiceUnavailable, body: fiber.ErrServiceUnavailable.Message},
+		"OnTimeout": {
+			cfg: Config{Timeout: 20 * time.Millisecond, OnTimeout: func(c fiber.Ctx) error {
+				return c.Status(fiber.StatusGatewayTimeout).SendString("custom timeout")
+			}},
+			status: fiber.StatusGatewayTimeout, body: "custom timeout",
+		},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			// Held until the timeout response has been read: released by the deadline, the handler could
+			// answer first.
+			release := make(chan struct{})
+			defer close(release)
+			app.Get("/slow", New(func(fiber.Ctx) error { <-release; return nil }, tc.cfg))
+			app.Get("/fast", func(c fiber.Ctx) error { return c.SendString("fast") })
+
+			conn := apptest.Dial(t, apptest.Serve(t, app, fiber.ListenConfig{DisableStartupMessage: true}))
+			_, err := conn.Write([]byte("HEAD /slow HTTP/1.1\r\nHost: example.com\r\n\r\nGET /fast HTTP/1.1\r\nHost: example.com\r\n\r\n"))
+			require.NoError(t, err)
+
+			br := bufio.NewReader(conn)
+			head, err := http.ReadResponse(br, &http.Request{Method: fiber.MethodHead})
+			require.NoError(t, err)
+			require.NoError(t, head.Body.Close())
+			require.Equal(t, tc.status, head.StatusCode)
+			require.Equal(t, strconv.Itoa(len(tc.body)), head.Header.Get(fiber.HeaderContentLength))
+			next, err := br.ReadString('\n')
+			require.NoError(t, err)
+			require.Equal(t, "HTTP/1.1 200 OK\r\n", next)
+		})
+	}
+}
diff --git a/mount_test.go b/mount_test.go
index 1f11e4bf823..c2a1c47c8f5 100644
--- a/mount_test.go
+++ b/mount_test.go
@@ -589,6 +589,58 @@ func Test_App_Mount_AutoHeadKeepsMiddleware(t *testing.T) {
 	}
 }
 
+// Test_App_Mount_ParentDisableHeadAutoRegister verifies that an app that turned the automatic HEAD
+// routes off takes none from the apps mounted into it: a guard it registered with Get has no HEAD
+// companion, so a HEAD route flattened from a sub-app would run the handler without it.
+func Test_App_Mount_ParentDisableHeadAutoRegister(t *testing.T) {
+	t.Parallel()
+	// The shared variants, plus the shapes a parent's opt-out has to reach: a group, a nested
+	// mount, and apps started before they were mounted.
+	host := apptest.WithHost("example.com")
+	extra := []routerMountVariant{
+		{name: "group", prefix: "/admin", host: host, mount: func(app, sub *App) { app.Group("/admin").Use("/", sub) }},
+		{name: "nested", prefix: "/admin", host: host, mount: func(app, sub *App) {
+			mid := New()
+			mid.Use("/", sub)
+			app.Use("/admin", mid)
+		}},
+		{name: "started before mounting", prefix: "/admin", host: host, mount: func(app, sub *App) {
+			sub.Handler()
+			app.Use("/admin", sub)
+		}},
+		{name: "domain started before mounting", prefix: "/admin", host: apptest.WithHost("api.example.com"), mount: func(app, sub *App) {
+			sub.Handler()
+			app.Domain("api.example.com").Use("/admin", sub)
+		}},
+	}
+	for _, tc := range slices.Concat(routerMountVariants, extra) {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			app := New(Config{DisableHeadAutoRegister: true})
+			app.Get(tc.prefix+"/*", func(c Ctx) error {
+				c.Set("X-Guard", "ran")
+				return c.Next()
+			})
+			sub := New()
+			sub.Get("/x", func(c Ctx) error {
+				c.Set("X-Secret", "leaked")
+				return c.SendString("admin")
+			})
+			tc.mount(app, sub)
+
+			target := tc.prefix + "/x"
+			resp := apptest.ExpectBody(t, app, apptest.Req(MethodGet, target, tc.host), StatusOK, "admin")
+			require.Equal(t, "ran", resp.Header.Get("X-Guard"))
+			// Twice: the second pass sees the mount already expanded into the parent's stack.
+			for range 2 {
+				resp = apptest.Expect(t, app, apptest.Req(MethodHead, target, tc.host), StatusMethodNotAllowed)
+				require.Empty(t, resp.Header.Get("X-Secret"))
+			}
+			require.Empty(t, app.Stack()[app.methodInt(MethodHead)])
+		})
+	}
+}
+
 // Test_App_Mount_RootMountKeepsParentAutoHead verifies that a mounted app which
 // does not serve HEAD only withholds automatic HEAD routes from its own routes.
 // A mount at "/" covers every path, and the app above keeps its own.

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path adapter_test.go --path app_integration_test.go --path app_test.go --path client/cancel_test.go --path client/core_test.go --path client/transport_test.go --path ctx_test.go --path internal/fieldname/fieldname_test.go --path internal/redirectbody/redirectbody_test.go --path middleware/adaptor/adaptor_test.go --path middleware/cache/cache_security_test.go --path middleware/csrf/csrf_test.go --path middleware/proxy/proxy_test.go --path middleware/proxy/security_test.go --path middleware/session/data_test.go --path middleware/session/session_test.go --path middleware/static/static_test.go --path middleware/timeout/timeout_test.go --path mount_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/fieldname ./internal/redirectbody ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/proxy ./middleware/session ./middleware/static ./middleware/timeout')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./client ./internal/fieldname ./internal/redirectbody ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/proxy ./middleware/session ./middleware/static ./middleware/timeout' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
