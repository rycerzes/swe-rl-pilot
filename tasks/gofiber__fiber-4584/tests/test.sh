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
for f in binder/form_test.go client/cookiejar_test.go client/response_test.go client/transport_test.go ctx_test.go extractors/extractors_test.go helpers_test.go internal/fieldname/fieldname_test.go internal/mediatype/mediatype_test.go internal/urlnorm/urlnorm_test.go listen_test.go middleware/adaptor/adaptor_test.go middleware/cache/cache_security_test.go middleware/cache/cache_test.go middleware/cache/coverage_test.go middleware/cache/keygen_test.go middleware/csrf/csrf_test.go middleware/logger/logger_test.go middleware/proxy/bench_test.go middleware/proxy/fuzz_test.go middleware/proxy/proxy_test.go middleware/proxy/security_test.go middleware/redirect/redirect_test.go redirect_test.go router_test.go; do if git cat-file -e a2a6d290f4a1e70e977ff996e7242bc3a7b3f4aa:"$f" 2>/dev/null; then git checkout a2a6d290f4a1e70e977ff996e7242bc3a7b3f4aa -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - a2a6d290f4a1e70e977ff996e7242bc3a7b3f4aa "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/binder/form_test.go b/binder/form_test.go
index 33e11a6095a..456de6ca20c 100644
--- a/binder/form_test.go
+++ b/binder/form_test.go
@@ -56,6 +56,48 @@ func Test_FormBinder_Bind(t *testing.T) {
 	require.False(t, b.EnableSplitting)
 }
 
+// Test_FormBinder_Bind_MixedCaseContentType covers callers that drive the
+// binder directly, which do not go through Fiber's header normalization. Media
+// types and parameter names are case-insensitive (RFC 9110 Sections 8.3.1 and
+// 5.6.6), but fasthttp's PostArgs and MultipartForm match them case-sensitively
+// — so the binder has to fold them before handing the request over.
+func Test_FormBinder_Bind_MixedCaseContentType(t *testing.T) {
+	t.Parallel()
+
+	type User struct {
+		Name string `form:"name"`
+	}
+
+	t.Run("urlencoded", func(t *testing.T) {
+		t.Parallel()
+
+		req := fasthttp.AcquireRequest()
+		t.Cleanup(func() { fasthttp.ReleaseRequest(req) })
+		req.Header.SetMethod("POST")
+		req.Header.SetContentType("Application/X-WWW-Form-Urlencoded")
+		req.SetBodyString("name=john")
+
+		var user User
+		require.NoError(t, (&FormBinding{}).Bind(req, &user))
+		require.Equal(t, "john", user.Name)
+	})
+
+	t.Run("multipart", func(t *testing.T) {
+		t.Parallel()
+
+		req := fasthttp.AcquireRequest()
+		t.Cleanup(func() { fasthttp.ReleaseRequest(req) })
+		req.Header.SetMethod("POST")
+		// The boundary parameter *name* is folded, its value is not.
+		req.Header.SetContentType(`Multipart/Form-Data; BOUNDARY=AbC`)
+		req.SetBodyString("--AbC\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\njohn\r\n--AbC--\r\n")
+
+		var user User
+		require.NoError(t, (&FormBinding{}).Bind(req, &user))
+		require.Equal(t, "john", user.Name)
+	})
+}
+
 func Test_FormBinder_Bind_ParseError(t *testing.T) {
 	b := &FormBinding{}
 	type User struct {
diff --git a/client/cookiejar_test.go b/client/cookiejar_test.go
index e970aca8377..2bb36a5de71 100644
--- a/client/cookiejar_test.go
+++ b/client/cookiejar_test.go
@@ -10,6 +10,7 @@ import (
 	"testing"
 	"time"
 
+	"github.com/gofiber/fiber/v3"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
 	"golang.org/x/net/publicsuffix"
@@ -1608,3 +1609,75 @@ func Test_CookieJar_BoundsCookiesPerRequest(t *testing.T) {
 		fasthttp.ReleaseCookie(c)
 	}
 }
+
+// Test_CookieJar_AttributesCookiesToRespondingHost asserts that Set-Cookie from
+// a redirect target is stored against that target, not against the host the
+// caller originally addressed. Crediting it to the original host would let any
+// redirect target plant cookies for an origin it does not control, and those
+// cookies would then ride along on every later request to that origin.
+func Test_CookieJar_AttributesCookiesToRespondingHost(t *testing.T) {
+	t.Parallel()
+
+	server := startTestServer(t, func(app *fiber.App) {
+		app.Get("/start", func(c fiber.Ctx) error {
+			return c.Redirect().Status(fiber.StatusFound).To("http://attacker.example/plant")
+		})
+		app.Get("/plant", func(c fiber.Ctx) error {
+			c.Cookie(&fiber.Cookie{Name: "session", Value: "planted"})
+			return c.SendString("ok")
+		})
+		app.Get("/direct", func(c fiber.Ctx) error {
+			c.Cookie(&fiber.Cookie{Name: "session", Value: "legitimate"})
+			return c.SendString("ok")
+		})
+	})
+	// Cleanup, not defer: the parallel subtests below resume only after this
+	// function returns, so a deferred stop would race them.
+	t.Cleanup(server.stop)
+
+	jarCookies := func(t *testing.T, jar *CookieJar, host string) map[string]string {
+		t.Helper()
+
+		uri := fasthttp.AcquireURI()
+		defer fasthttp.ReleaseURI(uri)
+		uri.SetScheme("http")
+		uri.SetHost(host)
+		uri.SetPath("/")
+
+		out := make(map[string]string)
+		for _, ck := range jar.Get(uri) {
+			out[string(ck.Key())] = string(ck.Value())
+			fasthttp.ReleaseCookie(ck) // Get hands back copies it acquired from the pool.
+		}
+		return out
+	}
+
+	t.Run("redirect target cannot plant cookies for the origin", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+		client := New().SetDial(server.dial()).SetCookieJar(jar)
+
+		resp, err := client.Get("http://good.example/start", Config{MaxRedirects: 5})
+		require.NoError(t, err)
+		defer resp.Close()
+
+		require.Empty(t, jarCookies(t, jar, "good.example"))
+		require.Equal(t, map[string]string{"session": "planted"}, jarCookies(t, jar, "attacker.example"))
+	})
+
+	t.Run("a response with no redirect is still stored", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer ReleaseCookieJar(jar)
+		client := New().SetDial(server.dial()).SetCookieJar(jar)
+
+		resp, err := client.Get("http://good.example/direct")
+		require.NoError(t, err)
+		defer resp.Close()
+
+		require.Equal(t, map[string]string{"session": "legitimate"}, jarCookies(t, jar, "good.example"))
+	})
+}
diff --git a/client/response_test.go b/client/response_test.go
index c8270c3e151..aa843dd83ff 100644
--- a/client/response_test.go
+++ b/client/response_test.go
@@ -17,6 +17,7 @@ import (
 	"github.com/stretchr/testify/require"
 
 	"github.com/gofiber/fiber/v3"
+	"github.com/valyala/fasthttp"
 )
 
 func Test_Response_Status(t *testing.T) {
@@ -954,3 +955,110 @@ func (m *mockWriteCloser) Close() error {
 	m.closed = true
 	return nil
 }
+
+// Test_Response_RespondedOrigin covers the fallbacks in the recorded origin.
+//
+// The pair is what credits a Set-Cookie to the host that actually served the
+// response rather than the one the caller addressed. A Response assembled
+// outside the normal execution path never has it recorded, and must fall back
+// to the request's own URI rather than attributing the cookie to nothing.
+func Test_Response_RespondedOrigin(t *testing.T) {
+	t.Parallel()
+
+	// Built per subtest: these run in parallel, so a URI released when the
+	// parent returns would be reset out from under them.
+	askedURI := func(t *testing.T) *fasthttp.URI {
+		t.Helper()
+		u := fasthttp.AcquireURI()
+		t.Cleanup(func() { fasthttp.ReleaseURI(u) })
+		require.NoError(t, u.Parse(nil, []byte("http://asked.example/asked")))
+		return u
+	}
+
+	t.Run("nothing recorded falls back", func(t *testing.T) {
+		t.Parallel()
+
+		resp := AcquireResponse()
+		defer ReleaseResponse(resp)
+
+		host, path := resp.respondedOrigin(askedURI(t))
+		require.Equal(t, "asked.example", string(host))
+		require.Equal(t, "/asked", string(path))
+	})
+
+	t.Run("a nil URI records nothing", func(t *testing.T) {
+		t.Parallel()
+
+		resp := AcquireResponse()
+		defer ReleaseResponse(resp)
+
+		resp.setRespondedURI(nil)
+
+		host, path := resp.respondedOrigin(askedURI(t))
+		require.Equal(t, "asked.example", string(host), "a nil URI must leave the fallback in place")
+		require.Equal(t, "/asked", string(path))
+	})
+
+	t.Run("what was recorded wins", func(t *testing.T) {
+		t.Parallel()
+
+		served := fasthttp.AcquireURI()
+		t.Cleanup(func() { fasthttp.ReleaseURI(served) })
+		require.NoError(t, served.Parse(nil, []byte("http://served.example/served")))
+
+		fallback := askedURI(t)
+
+		resp := AcquireResponse()
+		defer ReleaseResponse(resp)
+
+		resp.setRespondedURI(served)
+
+		host, path := resp.respondedOrigin(fallback)
+		require.Equal(t, "served.example", string(host))
+		require.Equal(t, "/served", string(path))
+
+		// Reset clears it, so a pooled Response cannot credit the next
+		// response to the previous one's origin.
+		resp.Reset()
+		host, path = resp.respondedOrigin(fallback)
+		require.Equal(t, "asked.example", string(host))
+		require.Equal(t, "/asked", string(path))
+	})
+}
+
+// Test_Response_RespondedOriginOnlyRecordedForAJar covers where the recorded
+// origin comes from. Only the cookie-jar hook reads it, so a client without one
+// pays nothing to record it, and the fallback answers with the requested URI.
+func Test_Response_RespondedOriginOnlyRecordedForAJar(t *testing.T) {
+	t.Parallel()
+
+	server := startTestServer(t, func(app *fiber.App) {
+		app.Get("/x", func(c fiber.Ctx) error {
+			c.Cookie(&fiber.Cookie{Name: "a", Value: "1"})
+			return c.SendString("hi")
+		})
+	})
+	t.Cleanup(server.stop)
+
+	t.Run("no jar records nothing", func(t *testing.T) {
+		t.Parallel()
+
+		resp, err := New().SetDial(server.dial()).Get("http://example.com/x")
+		require.NoError(t, err)
+		defer resp.Close()
+		require.Empty(t, resp.respondedHost)
+		require.Empty(t, resp.respondedPath)
+	})
+
+	t.Run("a jar gets the origin", func(t *testing.T) {
+		t.Parallel()
+
+		jar := AcquireCookieJar()
+		defer jar.Release()
+		resp, err := New().SetDial(server.dial()).SetCookieJar(jar).Get("http://example.com/x")
+		require.NoError(t, err)
+		defer resp.Close()
+		require.Equal(t, "example.com", string(resp.respondedHost))
+		require.Equal(t, "/x", string(resp.respondedPath))
+	})
+}
diff --git a/client/transport_test.go b/client/transport_test.go
index c1205efe2d0..8ff24e4ce63 100644
--- a/client/transport_test.go
+++ b/client/transport_test.go
@@ -1,15 +1,22 @@
 package client
 
 import (
+	"bufio"
+	"bytes"
 	"crypto/tls"
 	"errors"
 	"net"
+	"strconv"
+	"strings"
 	"sync/atomic"
 	"testing"
 	"time"
 
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/assert"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
+	"github.com/valyala/fasthttp/fasthttputil"
 )
 
 type stubBalancingClient struct{}
@@ -250,6 +257,106 @@ func TestWalkBalancingClientWithBreak(t *testing.T) {
 	}))
 }
 
+// TestDoRedirectsWithClient_DropsBodyForAnyMethod pins net/http's
+// redirectBehavior: 301, 302 and 303 all turn a body-carrying method into GET
+// and drop the body, for every method rather than just POST, and drop the body
+// even where the method already was GET or HEAD.
+//
+// Fiber's client drives QUERY requests through this loop too (client/core.go),
+// and both branches used to be gated on IsPost — so a QUERY kept its method and
+// its body across the redirect and replayed that body to the new location,
+// which may be a different host than the caller addressed.
+func TestDoRedirectsWithClient_DropsBodyForAnyMethod(t *testing.T) {
+	t.Parallel()
+
+	for _, status := range []int{fasthttp.StatusMovedPermanently, fasthttp.StatusFound, fasthttp.StatusSeeOther} {
+		for _, method := range []string{fasthttp.MethodPost, fasthttp.MethodPut, fasthttp.MethodPatch, fasthttp.MethodDelete, "QUERY"} {
+			t.Run(strconv.Itoa(status)+"/"+method, func(t *testing.T) {
+				t.Parallel()
+
+				req := fasthttp.AcquireRequest()
+				resp := fasthttp.AcquireResponse()
+				defer fasthttp.ReleaseRequest(req)
+				defer fasthttp.ReleaseResponse(resp)
+
+				req.SetRequestURI("http://example.com/start")
+				req.Header.SetMethod(method)
+				req.Header.SetContentType("application/json")
+				req.Header.Set(fasthttp.HeaderContentEncoding, "gzip")
+				req.Header.Set(fasthttp.HeaderTrailer, "X-Checksum")
+				req.SetBodyString(`{"q":"secret"}`)
+
+				client := &stubRedirectClient{calls: []stubRedirectCall{
+					{status: ptrInt(status), location: ptrString("http://other.example/next")},
+					{status: ptrInt(fasthttp.StatusOK)},
+				}}
+				require.NoError(t, doRedirectsWithClient(req, resp, -1, client))
+
+				require.Equal(t, fasthttp.MethodGet, string(req.Header.Method()))
+				require.Empty(t, req.Body(), "the body must not reach the redirect target")
+				require.Empty(t, req.Header.ContentType())
+				require.Empty(t, req.Header.Peek(fasthttp.HeaderContentEncoding), "a coding without a body to decode")
+				require.Empty(t, req.Header.Peek(fasthttp.HeaderTrailer), "a Trailer only frames a body that is gone")
+				require.Empty(t, req.Header.Peek(fasthttp.HeaderTransferEncoding))
+			})
+		}
+	}
+
+	// 307 and 308 exist to preserve the method and body, so they are untouched.
+	for _, status := range []int{fasthttp.StatusTemporaryRedirect, fasthttp.StatusPermanentRedirect} {
+		t.Run(strconv.Itoa(status)+"/preserved", func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseRequest(req)
+			defer fasthttp.ReleaseResponse(resp)
+
+			req.SetRequestURI("http://example.com/start")
+			req.Header.SetMethod(fasthttp.MethodPost)
+			req.Header.SetContentType("application/json")
+			req.SetBodyString("body-must-survive")
+
+			client := &stubRedirectClient{calls: []stubRedirectCall{
+				{status: ptrInt(status), location: ptrString("/next")},
+				{status: ptrInt(fasthttp.StatusOK)},
+			}}
+			require.NoError(t, doRedirectsWithClient(req, resp, -1, client))
+
+			require.Equal(t, fasthttp.MethodPost, string(req.Header.Method()))
+			require.Equal(t, "body-must-survive", string(req.Body()))
+		})
+	}
+
+	// GET and HEAD keep their method: RFC 9110 Section 15.4.4 says GET *or* HEAD.
+	// The body still goes, or a GET carrying one replays it to the target.
+	for _, method := range []string{fasthttp.MethodGet, fasthttp.MethodHead} {
+		t.Run(method+" keeps its method but not its body", func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseRequest(req)
+			defer fasthttp.ReleaseResponse(resp)
+
+			req.SetRequestURI("http://example.com/start")
+			req.Header.SetMethod(method)
+			req.Header.SetContentType("application/json")
+			req.SetBodyString(`{"q":"secret"}`)
+
+			client := &stubRedirectClient{calls: []stubRedirectCall{
+				{status: ptrInt(fasthttp.StatusSeeOther), location: ptrString("http://other.example/next")},
+				{status: ptrInt(fasthttp.StatusOK)},
+			}}
+			require.NoError(t, doRedirectsWithClient(req, resp, -1, client))
+
+			require.Equal(t, method, string(req.Header.Method()))
+			require.Empty(t, req.Body(), "the body must not reach the redirect target")
+			require.Empty(t, req.Header.ContentType())
+		})
+	}
+}
+
 func TestDoRedirectsWithClientBranches(t *testing.T) {
 	t.Parallel()
 
@@ -287,8 +394,12 @@ func TestDoRedirectsWithClientBranches(t *testing.T) {
 	req.SetRequestURI("http://example.com/again")
 	req.SetBodyString("payload")
 
+	// A limit of zero issues the request and counts the first redirect against
+	// it, as fasthttp's own DoRedirects does. Returning nil made a request that
+	// finished indistinguishable from one that stopped at a hop, and the request
+	// is left as it was sent, since the error comes before any rewrite.
 	singleCall := &stubRedirectClient{calls: []stubRedirectCall{{status: ptrInt(fasthttp.StatusFound), location: ptrString("/ignored")}}}
-	require.NoError(t, doRedirectsWithClient(req, resp, 0, singleCall))
+	require.ErrorIs(t, doRedirectsWithClient(req, resp, 0, singleCall), fasthttp.ErrTooManyRedirects)
 	require.Equal(t, fasthttp.StatusFound, resp.StatusCode())
 	require.Equal(t, fasthttp.MethodPost, string(req.Header.Method()))
 	require.Equal(t, "http://example.com/again", req.URI().String())
@@ -330,23 +441,288 @@ func TestDoRedirectsWithClientBranches(t *testing.T) {
 // and credentials never leave the TLS boundary.
 func TestComposeRedirectURL_RejectsHTTPSDowngrade(t *testing.T) {
 	t.Parallel()
-	_, err := composeRedirectURL("https://example.com/login", []byte("http://example.com/after"), false)
+	_, _, err := composeRedirectURL("https://example.com/login", []byte("http://example.com/after"), false)
 	require.ErrorIs(t, err, ErrRedirectDowngrade)
 
 	// Same-origin HTTP→HTTP is fine.
-	out, err := composeRedirectURL("http://example.com/a", []byte("http://example.com/b"), false)
+	out, host, err := composeRedirectURL("http://example.com/a", []byte("http://example.com/b"), false)
 	require.NoError(t, err)
 	require.Equal(t, "http://example.com/b", out)
+	require.Equal(t, "example.com", host)
 
 	// HTTPS→HTTPS is fine.
-	out, err = composeRedirectURL("https://example.com/a", []byte("https://example.com/b"), false)
+	out, host, err = composeRedirectURL("https://example.com/a", []byte("https://example.com/b"), false)
 	require.NoError(t, err)
 	require.Equal(t, "https://example.com/b", out)
+	require.Equal(t, "example.com", host)
 
 	// HTTP→HTTPS upgrade is fine.
-	out, err = composeRedirectURL("http://example.com/a", []byte("https://example.com/b"), false)
+	out, host, err = composeRedirectURL("http://example.com/a", []byte("https://example.com/b"), false)
 	require.NoError(t, err)
 	require.Equal(t, "https://example.com/b", out)
+	require.Equal(t, "example.com", host)
+
+	// A cross-host redirect reports the new host so the caller can drop
+	// origin-scoped credentials.
+	out, host, err = composeRedirectURL("http://example.com/a", []byte("http://other.example/b"), false)
+	require.NoError(t, err)
+	require.Equal(t, "http://other.example/b", out)
+	require.Equal(t, "other.example", host)
+}
+
+// TestTrustedRedirectTarget_NoInitialHostname pins the degenerate case: with no
+// initial hostname there is no origin for the target to be a subdomain of, and
+// every host is a suffix match for the empty string — so the subdomain test has
+// to be skipped entirely rather than letting a trailing dot pass for one.
+func TestTrustedRedirectTarget_NoInitialHostname(t *testing.T) {
+	t.Parallel()
+
+	require.False(t, trustedRedirectTarget("evil.com.", ""))
+	require.False(t, trustedRedirectTarget("evil.com", ""))
+	require.False(t, trustedRedirectTarget(".", ""))
+	// Both empty is not a host change, so credentials still apply.
+	require.True(t, trustedRedirectTarget("", ""))
+}
+
+// TestHostnameWithoutPort covers the host normalization the credential checks
+// are built on. Its output feeds the same-origin and suffix tests in
+// trustedRedirectTarget, so two different spellings must never fold to the same
+// name — hence unwrapping exactly one matched bracket pair rather than trimming
+// every bracket off both ends.
+func TestHostnameWithoutPort(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ in, want string }{
+		{"example.com", "example.com"},
+		{"example.com:8080", "example.com"},
+		{"[::1]", "::1"},
+		{"[::1]:8080", "::1"},
+		{"[2001:db8::1]:443", "2001:db8::1"},
+		{"", ""},
+		{":8080", ""},
+		// An IPv6 literal written without brackets: the last colon belongs to
+		// the address, not to a port. Truncating there would fold distinct
+		// hosts onto one name.
+		{"fe80::1", "fe80::1"},
+		{"fe80::2", "fe80::2"},
+		{"2001:db8::1", "2001:db8::1"},
+		// Not a bracketed literal: one stray bracket is left where it is
+		// rather than silently folded away.
+		{"[[x]]", "[x]"},
+		{"[x", "[x"},
+		{"x]", "x]"},
+	} {
+		require.Equal(t, tc.want, hostnameWithoutPort(tc.in), "input %q", tc.in)
+	}
+}
+
+// TestDoRedirectsWithClient_StripsCredentialsCrossHost verifies that
+// origin-scoped credentials are dropped as soon as a redirect leaves the host
+// they were issued for, and survive redirects that stay on it.
+func TestDoRedirectsWithClient_StripsCredentialsCrossHost(t *testing.T) {
+	t.Parallel()
+
+	newReq := func() *fasthttp.Request {
+		req := fasthttp.AcquireRequest()
+		req.SetRequestURI("http://example.com/start")
+		req.Header.Set(fasthttp.HeaderAuthorization, "Bearer secret")
+		req.Header.Set(fasthttp.HeaderProxyAuthorization, "Basic secret")
+		req.Header.Set(fasthttp.HeaderCookie, "session=secret")
+		return req
+	}
+
+	t.Run("subdomain of the initial host keeps credentials", func(t *testing.T) {
+		t.Parallel()
+
+		req := newReq()
+		defer fasthttp.ReleaseRequest(req)
+		resp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(resp)
+
+		client := &stubRedirectClient{calls: []stubRedirectCall{
+			{status: ptrInt(fasthttp.StatusFound), location: ptrString("http://www.example.com/next")},
+			{status: ptrInt(fasthttp.StatusOK)},
+		}}
+		require.NoError(t, doRedirectsWithClient(req, resp, 5, client))
+		require.Equal(t, "Bearer secret", string(req.Header.Peek(fasthttp.HeaderAuthorization)))
+	})
+
+	t.Run("explicit default port keeps credentials", func(t *testing.T) {
+		t.Parallel()
+
+		req := newReq()
+		defer fasthttp.ReleaseRequest(req)
+		resp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(resp)
+
+		client := &stubRedirectClient{calls: []stubRedirectCall{
+			{status: ptrInt(fasthttp.StatusFound), location: ptrString("http://example.com:80/next")},
+			{status: ptrInt(fasthttp.StatusOK)},
+		}}
+		require.NoError(t, doRedirectsWithClient(req, resp, 5, client))
+		require.Equal(t, "Bearer secret", string(req.Header.Peek(fasthttp.HeaderAuthorization)))
+	})
+
+	t.Run("same host keeps credentials", func(t *testing.T) {
+		t.Parallel()
+
+		req := newReq()
+		defer fasthttp.ReleaseRequest(req)
+		resp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(resp)
+
+		client := &stubRedirectClient{calls: []stubRedirectCall{
+			{status: ptrInt(fasthttp.StatusFound), location: ptrString("http://example.com/next")},
+			{status: ptrInt(fasthttp.StatusOK)},
+		}}
+		require.NoError(t, doRedirectsWithClient(req, resp, 5, client))
+		require.Equal(t, "Bearer secret", string(req.Header.Peek(fasthttp.HeaderAuthorization)))
+		require.Equal(t, "Basic secret", string(req.Header.Peek(fasthttp.HeaderProxyAuthorization)))
+		require.Equal(t, "session=secret", string(req.Header.Peek(fasthttp.HeaderCookie)))
+	})
+
+	t.Run("cross host drops credentials", func(t *testing.T) {
+		t.Parallel()
+
+		req := newReq()
+		defer fasthttp.ReleaseRequest(req)
+		resp := fasthttp.AcquireResponse()
+		defer fasthttp.ReleaseResponse(resp)
+
+		client := &stubRedirectClient{calls: []stubRedirectCall{
+			{status: ptrInt(fasthttp.StatusFound), location: ptrString("http://attacker.example/collect")},
+			{status: ptrInt(fasthttp.StatusOK)},
+		}}
+		require.NoError(t, doRedirectsWithClient(req, resp, 5, client))
+		require.Equal(t, "http://attacker.example/collect", req.URI().String())
+		require.Empty(t, req.Header.Peek(fasthttp.HeaderAuthorization))
+		require.Empty(t, req.Header.Peek(fasthttp.HeaderProxyAuthorization))
+		require.Empty(t, req.Header.Peek(fasthttp.HeaderCookie))
+	})
+}
+
+// TestDoRedirectsWithClient_ValidatesTargets covers the target validation that
+// every transport now shares through doRedirectsWithClient.
+func TestDoRedirectsWithClient_ValidatesTargets(t *testing.T) {
+	t.Parallel()
+
+	cases := []struct {
+		wantErr  error
+		name     string
+		base     string
+		location string
+	}{
+		{name: "https downgrade", base: "https://example.com/login", location: "http://example.com/after", wantErr: ErrRedirectDowngrade},
+		{name: "foreign scheme", base: "http://example.com/a", location: "ftp://example.com/b", wantErr: fasthttp.ErrorInvalidURI},
+		{name: "control character", base: "http://example.com/a", location: "/b\x00c", wantErr: fasthttp.ErrorInvalidURI},
+	}
+
+	for _, tc := range cases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(req)
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseResponse(resp)
+
+			req.SetRequestURI(tc.base)
+			client := &stubRedirectClient{calls: []stubRedirectCall{
+				{status: ptrInt(fasthttp.StatusFound), location: ptrString(tc.location)},
+			}}
+			require.ErrorIs(t, doRedirectsWithClient(req, resp, 5, client), tc.wantErr)
+		})
+	}
+}
+
+// TestClient_DoRedirects_RejectsHTTPSDowngrade drives the transport New()
+// actually builds over a real TLS hop. It used to delegate to fasthttp's loop,
+// which follows an HTTPS-to-HTTP redirect and, the host being unchanged, keeps
+// the credentials on it.
+//
+// Only the plaintext hop is left undialable: reaching it produces a dial error
+// rather than ErrRedirectDowngrade, so the assertion cannot pass vacuously.
+func TestClient_DoRedirects_RejectsHTTPSDowngrade(t *testing.T) {
+	t.Parallel()
+
+	cert, err := tls.LoadX509KeyPair("../.github/testdata/ssl.pem", "../.github/testdata/ssl.key")
+	require.NoError(t, err)
+
+	ln := fasthttputil.NewInmemoryListener()
+	app := fiber.New()
+	app.Get("/start", func(c fiber.Ctx) error {
+		return c.Redirect().Status(fiber.StatusFound).To("http://example.com/collect")
+	})
+
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		assert.NoError(t, app.Listener(
+			tls.NewListener(ln, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}),
+			fiber.ListenConfig{DisableStartupMessage: true},
+		))
+	}()
+	defer func() {
+		require.NoError(t, app.Shutdown())
+		<-done
+	}()
+
+	client := New().
+		SetDial(func(addr string) (net.Conn, error) {
+			if strings.HasSuffix(addr, ":443") {
+				return ln.Dial()
+			}
+			return nil, errors.New("the plaintext hop must never be dialed")
+		}).
+		SetTLSConfig(&tls.Config{InsecureSkipVerify: true}) // self-signed test certificate
+
+	_, err = client.Get("https://example.com/start", Config{
+		Header:       map[string]string{fiber.HeaderAuthorization: "Bearer secret"},
+		MaxRedirects: 5,
+	})
+	require.ErrorIs(t, err, ErrRedirectDowngrade)
+}
+
+// TestClient_DoRedirects_StripsCredentialsCrossHost exercises the default
+// transport end to end: the redirect validation must apply to the client
+// callers actually get from New(), not only to the load-balanced transport.
+func TestClient_DoRedirects_StripsCredentialsCrossHost(t *testing.T) {
+	t.Parallel()
+
+	server := startTestServer(t, func(app *fiber.App) {
+		app.Get("/start", func(c fiber.Ctx) error {
+			return c.Redirect().Status(fiber.StatusFound).To("http://attacker.example/collect")
+		})
+		app.Get("/same-host", func(c fiber.Ctx) error {
+			return c.Redirect().Status(fiber.StatusFound).To("http://example.com/collect")
+		})
+		app.Get("/collect", func(c fiber.Ctx) error {
+			return c.SendString(c.Get(fiber.HeaderAuthorization) + "|" + c.Get(fiber.HeaderCookie))
+		})
+	})
+	defer server.stop()
+
+	client := New().SetDial(server.dial())
+	credentials := Config{
+		Header:       map[string]string{fiber.HeaderAuthorization: "Bearer secret"},
+		Cookie:       map[string]string{"session": "secret"},
+		MaxRedirects: 5,
+	}
+
+	// Control: a redirect that stays on the issuing host carries them through,
+	// so the cross-host assertion below cannot pass vacuously.
+	sameHost, err := client.Get("http://example.com/same-host", credentials)
+	require.NoError(t, err)
+	defer sameHost.Close()
+	require.Equal(t, fiber.StatusOK, sameHost.StatusCode())
+	require.Equal(t, "Bearer secret|session=secret", sameHost.String())
+
+	resp, err := client.Get("http://example.com/start", credentials)
+	require.NoError(t, err)
+	defer resp.Close()
+
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Equal(t, "|", resp.String())
 }
 
 func TestDoRedirectsWithClientDefaultLimit(t *testing.T) {
@@ -528,3 +904,316 @@ func Test_httpClientTransport_Interface(t *testing.T) {
 		})
 	}
 }
+
+// Test_Transport_DoRedirects_KeepsPathNormalizingDisabled covers a transport
+// wrapping a client that asked for the path to be left alone.
+//
+// fasthttp's own DoRedirects sets the flag on req.URI() before serializing it.
+// This loop serializes first, so without the same step the very first request
+// went out with "/a//b" collapsed — the redirect implementation changing the
+// path the caller asked for.
+func Test_Transport_DoRedirects_KeepsPathNormalizingDisabled(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name     string
+		wantPath string
+		disable  bool
+	}{
+		{name: "disabled keeps the path as written", wantPath: "/a//b", disable: true},
+		{name: "enabled normalizes as before", wantPath: "/a/b", disable: false},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			ln := fasthttputil.NewInmemoryListener()
+			seen := make(chan string, 4)
+			server := &fasthttp.Server{Handler: func(ctx *fasthttp.RequestCtx) {
+				seen <- string(ctx.Request.URI().PathOriginal())
+				ctx.SetStatusCode(fasthttp.StatusOK)
+			}}
+			done := make(chan struct{})
+			go func() {
+				defer close(done)
+				assert.NoError(t, server.Serve(ln))
+			}()
+			defer func() {
+				require.NoError(t, server.Shutdown())
+				<-done
+			}()
+
+			transport := newStandardClientTransport(&fasthttp.Client{
+				DisablePathNormalizing: tc.disable,
+				Dial:                   func(string) (net.Conn, error) { return ln.Dial() },
+			})
+
+			req, resp := fasthttp.AcquireRequest(), fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseRequest(req)
+			defer fasthttp.ReleaseResponse(resp)
+			req.SetRequestURI("http://example.com/a//b")
+
+			require.NoError(t, transport.DoRedirects(req, resp, 3))
+			require.Equal(t, fasthttp.StatusOK, resp.StatusCode())
+			require.Equal(t, tc.wantPath, <-seen)
+		})
+	}
+}
+
+// Test_DropRequestBody_RemovesExpect covers the 100-continue expectation, which
+// may not be generated without content (RFC 9110 Section 10.1.1). Left on the
+// bodyless follow-up, a strict target answers 417 instead of serving it.
+func Test_DropRequestBody_RemovesExpect(t *testing.T) {
+	t.Parallel()
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.Set(fasthttp.HeaderExpect, "100-continue")
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+
+	dropRequestBody(req)
+
+	require.Empty(t, req.Header.Peek(fasthttp.HeaderExpect))
+	require.Empty(t, req.Body())
+}
+
+// Test_DropRequestBody_ClearsTheParsedForm pins why the PostArgs reset is there:
+// Request.Write falls back to the parsed form when the body is empty, so a
+// caller that had read PostArgs would otherwise have sent the dropped body on
+// the redirected GET.
+func Test_DropRequestBody_ClearsTheParsedForm(t *testing.T) {
+	t.Parallel()
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.SetRequestURI("http://example.com/y")
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
+
+	req.Header.SetMethod(fasthttp.MethodGet)
+	dropRequestBody(req)
+
+	var buf bytes.Buffer
+	w := bufio.NewWriter(&buf)
+	require.NoError(t, req.Write(w))
+	require.NoError(t, w.Flush())
+	require.NotContains(t, buf.String(), "a=1", "the dropped form must not come back as the body")
+}
+
+// Test_DropRequestBody_ReusedRequestSendsTheNewBody covers the request a caller
+// gets back and then reuses without resetting it.
+//
+// fasthttp clears its parsed-form flag beside the values here, which this cannot
+// reach: the field is unexported and only Request.Reset clears it, which would
+// take the URI and headers the redirect loop is still using. What survives that
+// gap has to be the part that matters — the body actually sent, and the earlier
+// form not reappearing in it or in a later read. An untouched fasthttp request
+// is no better here: SetBody does not invalidate the parsed form either, so it
+// answers a reused PostArgs with the previous body's values.
+func Test_DropRequestBody_ReusedRequestSendsTheNewBody(t *testing.T) {
+	t.Parallel()
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.SetRequestURI("http://example.com/y")
+	req.Header.SetMethod(fasthttp.MethodPost)
+	req.Header.SetContentType("application/x-www-form-urlencoded")
+	req.SetBodyString("a=1")
+	require.Equal(t, "a=1", req.PostArgs().String(), "the caller reads the form first")
+
+	dropRequestBody(req)
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
+
+// Test_Response_ResetDropsOversizedOriginBuffers covers the recorded origin on a
+// pooled Response. A redirect target chooses that path, so an oversized buffer
+// is kept out of the pool rather than carried by every later response.
+func Test_Response_ResetDropsOversizedOriginBuffers(t *testing.T) {
+	t.Parallel()
+
+	resp := &Response{RawResponse: fasthttp.AcquireResponse()}
+	defer fasthttp.ReleaseResponse(resp.RawResponse)
+
+	var uri fasthttp.URI
+	uri.SetHost("example.com")
+	uri.SetPath("/" + strings.Repeat("a", maxOriginBuf))
+	resp.setRespondedURI(&uri)
+	require.Greater(t, cap(resp.respondedPath), maxOriginBuf)
+
+	resp.Reset()
+	require.Empty(t, resp.respondedPath)
+	require.LessOrEqual(t, cap(resp.respondedPath), maxOriginBuf, "the oversized buffer is not pooled")
+
+	// An ordinary one is kept, so the common path still reuses its buffer.
+	uri.SetPath("/short")
+	resp.setRespondedURI(&uri)
+	before := cap(resp.respondedPath)
+	resp.Reset()
+	require.Equal(t, before, cap(resp.respondedPath), "a modest buffer survives for reuse")
+}
+
+// Test_DoRedirects_NilResponse covers the response fasthttp's own DoRedirects
+// documents as optional — "Response is ignored if resp is nil". Its loop reads
+// resp.Header regardless and panics on it; this one acquires its own instead.
+func Test_DoRedirects_NilResponse(t *testing.T) {
+	t.Parallel()
+
+	ln := fasthttputil.NewInmemoryListener()
+	hops := 0
+	server := &fasthttp.Server{Handler: func(ctx *fasthttp.RequestCtx) {
+		hops++
+		if string(ctx.Path()) == "/start" {
+			ctx.Response.Header.Set(fiber.HeaderLocation, "/end")
+			ctx.SetStatusCode(fasthttp.StatusFound)
+			return
+		}
+		ctx.SetStatusCode(fasthttp.StatusOK)
+	}}
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		assert.NoError(t, server.Serve(ln))
+	}()
+	defer func() {
+		require.NoError(t, server.Shutdown())
+		<-done
+	}()
+
+	transport := newStandardClientTransport(&fasthttp.Client{
+		Dial: func(string) (net.Conn, error) { return ln.Dial() },
+	})
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.SetRequestURI("http://example.com/start")
+
+	require.NotPanics(t, func() {
+		require.NoError(t, transport.DoRedirects(req, nil, 3))
+	})
+	require.Equal(t, 2, hops, "the redirect was still followed")
+}
+
+// Test_Transport_DoRedirects_RefusesUnparsableInitialURI covers the URI the
+// caller supplies, as against the redirect targets covered below.
+//
+// Request.URI swallows the parse error the same way UpdateBytes does, so the
+// loop read a half-parsed URI: "http://example.com:abc/x" keeps the malformed
+// authority as its host and loses its path. A HostClient dials its fixed Addr
+// whatever the URI says, so that host would have gone out as the Host header of
+// a request the caller never wrote. fasthttp's own loop calls the
+// error-returning parser after every SetRequestURI; this one now does too.
+func Test_Transport_DoRedirects_RefusesUnparsableInitialURI(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name    string
+		uri     string
+		wantErr bool
+	}{
+		{name: "invalid port", uri: "http://example.com:abc/x", wantErr: true},
+		{name: "unclosed bracket", uri: "http://[::1/x", wantErr: true},
+		{name: "a URI that parses is sent", uri: "http://example.com/x", wantErr: false},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			stub := &stubRedirectClient{}
+			req := fasthttp.AcquireRequest()
+			resp := fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseRequest(req)
+			defer fasthttp.ReleaseResponse(resp)
+			req.SetRequestURI(tc.uri)
+
+			err := doRedirectsWithClient(req, resp, 3, stub)
+			if tc.wantErr {
+				require.ErrorIs(t, err, fasthttp.ErrorInvalidURI)
+				require.Equal(t, 0, stub.CallCount(),
+					"a malformed URI must be refused before anything is sent")
+				return
+			}
+			require.NoError(t, err)
+			require.Equal(t, 1, stub.CallCount())
+		})
+	}
+}
+
+// Test_Transport_DoRedirects_RefusesUnparsableTarget covers a Location fasthttp
+// cannot parse. URI.UpdateBytes discards that error and keeps whatever it read,
+// so "http://example.com:abc/x" left the host "example.com:abc" and lost the
+// path — and a HostClient, which connects to its fixed Addr regardless, would
+// have sent a second request carrying that Host. fasthttp's own redirect loop
+// returns the error instead, so this one does too.
+func Test_Transport_DoRedirects_RefusesUnparsableTarget(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name     string
+		location string
+		wantErr  bool
+	}{
+		{name: "invalid port", location: "http://example.com:abc/x", wantErr: true},
+		{name: "space in the host", location: "http://exa mple.com/x", wantErr: true},
+		{name: "unclosed bracket", location: "http://[::1/x", wantErr: true},
+		{name: "a target that parses is followed", location: "/next", wantErr: false},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			ln := fasthttputil.NewInmemoryListener()
+			var hops atomic.Int64
+			server := &fasthttp.Server{Handler: func(ctx *fasthttp.RequestCtx) {
+				if hops.Add(1) == 1 {
+					ctx.Response.Header.Set(fiber.HeaderLocation, tc.location)
+					ctx.SetStatusCode(fasthttp.StatusFound)
+					return
+				}
+				ctx.SetStatusCode(fasthttp.StatusOK)
+			}}
+			done := make(chan struct{})
+			go func() {
+				defer close(done)
+				assert.NoError(t, server.Serve(ln))
+			}()
+			defer func() {
+				require.NoError(t, server.Shutdown())
+				<-done
+			}()
+
+			transport := newStandardClientTransport(&fasthttp.Client{
+				Dial: func(string) (net.Conn, error) { return ln.Dial() },
+			})
+
+			req, resp := fasthttp.AcquireRequest(), fasthttp.AcquireResponse()
+			defer fasthttp.ReleaseRequest(req)
+			defer fasthttp.ReleaseResponse(resp)
+			req.SetRequestURI("http://example.com/start")
+
+			err := transport.DoRedirects(req, resp, 3)
+			if tc.wantErr {
+				require.ErrorIs(t, err, fasthttp.ErrorInvalidURI)
+				require.Equal(t, int64(1), hops.Load(), "the malformed target must not be requested")
+				return
+			}
+			require.NoError(t, err)
+			require.Equal(t, fasthttp.StatusOK, resp.StatusCode())
+			require.Equal(t, int64(2), hops.Load())
+		})
+	}
+}
diff --git a/ctx_test.go b/ctx_test.go
index 6f28f2167e2..f63d71b9209 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -2732,6 +2732,45 @@ func Test_Ctx_FormValue_NonMultipart(t *testing.T) {
 	require.Equal(t, "fallback", c.FormValue("missing", "fallback"))
 }
 
+// Test_Ctx_Form_MixedCaseContentType asserts that Ctx's own form accessors
+// accept the media type and parameter names in any case (RFC 9110 Sections
+// 8.3.1 and 5.6.6). fasthttp matches both case-sensitively, so without the
+// normalization these return nothing at all — and a handler should not have to
+// call Bind first to get its own form back.
+func Test_Ctx_Form_MixedCaseContentType(t *testing.T) {
+	t.Parallel()
+
+	t.Run("urlencoded", func(t *testing.T) {
+		t.Parallel()
+
+		app := New()
+		c := app.AcquireCtx(&fasthttp.RequestCtx{}).(*DefaultCtx) //nolint:errcheck,forcetypeassert // not needed
+
+		c.Request().Header.SetMethod(MethodPost)
+		c.Request().Header.Set(HeaderContentType, "Application/X-WWW-Form-Urlencoded")
+		c.Request().SetBodyString("name=carol")
+
+		require.Equal(t, "carol", c.FormValue("name"))
+	})
+
+	t.Run("multipart", func(t *testing.T) {
+		t.Parallel()
+
+		app := New()
+		c := app.AcquireCtx(&fasthttp.RequestCtx{}).(*DefaultCtx) //nolint:errcheck,forcetypeassert // not needed
+
+		// The boundary parameter *name* is folded, its value is not.
+		c.Request().Header.SetMethod(MethodPost)
+		c.Request().Header.Set(HeaderContentType, `Multipart/Form-Data; BOUNDARY=AbC`)
+		c.Request().SetBodyString("--AbC\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\ncarol\r\n--AbC--\r\n")
+
+		form, err := c.MultipartForm()
+		require.NoError(t, err)
+		require.Equal(t, []string{"carol"}, form.Value["name"])
+		require.Equal(t, "carol", c.FormValue("name"))
+	})
+}
+
 func Benchmark_Ctx_Fresh_StaleEtag(b *testing.B) {
 	app := New()
 	c := app.AcquireCtx(&fasthttp.RequestCtx{})
@@ -5350,6 +5389,45 @@ func Test_Ctx_Scheme_HeaderNormalization(t *testing.T) {
 	c.Request().Header.Reset()
 }
 
+// go test -run Test_Ctx_Scheme_RejectsForeignSchemes
+func Test_Ctx_Scheme_RejectsForeignSchemes(t *testing.T) {
+	t.Parallel()
+
+	app := New(Config{
+		TrustProxy: true,
+		TrustProxyConfig: TrustProxyConfig{
+			Proxies: []string{"0.0.0.0"},
+		},
+	})
+
+	freq := &fasthttp.RequestCtx{}
+	freq.SetRemoteAddr(net.Addr(&net.TCPAddr{IP: net.ParseIP("0.0.0.0")}))
+
+	c := app.AcquireCtx(freq)
+
+	// A scheme Fiber does not serve must never reach BaseURL or the
+	// same-origin comparisons that consume Scheme.
+	for _, header := range []string{HeaderXForwardedProto, HeaderXForwardedProtocol, HeaderXUrlScheme} {
+		for _, value := range []string{"javascript", "ftp", "data", "HTTPS evil", ""} {
+			c.Request().Header.Set(header, value)
+			require.Equal(t, schemeHTTP, c.Scheme(), "%s: %q", header, value)
+			c.Request().Header.Reset()
+		}
+	}
+
+	// A rejected value must not clobber a valid one supplied by another header.
+	c.Request().Header.Set(HeaderXForwardedProto, schemeHTTPS)
+	c.Request().Header.Set(HeaderXUrlScheme, "javascript")
+	require.Equal(t, schemeHTTPS, c.Scheme())
+	c.Request().Header.Reset()
+
+	// BaseURL is the reason this matters: a foreign scheme spliced in here
+	// yields a URL an application may hand to a browser.
+	c.Request().URI().SetHost("example.com")
+	c.Request().Header.Set(HeaderXForwardedProto, "javascript")
+	require.Equal(t, "http://example.com", c.BaseURL())
+}
+
 // go test -v -run=^$ -bench=Benchmark_Ctx_Scheme -benchmem -count=4
 func Benchmark_Ctx_Scheme(b *testing.B) {
 	app := New()
@@ -7827,6 +7905,119 @@ func Test_Ctx_JSONP(t *testing.T) {
 	})
 }
 
+// go test -run Test_Ctx_JSONP_SanitizesCallback
+func Test_Ctx_JSONP_SanitizesCallback(t *testing.T) {
+	t.Parallel()
+
+	// The callback name is emitted verbatim into a same-origin
+	// text/javascript body, and JSONP callers take it from the query string by
+	// design, so anything that could open a statement, a string, or a comment
+	// has to be stripped before it gets there.
+	tests := []struct {
+		name     string
+		callback string
+		expected string
+	}{
+		{name: "statement injection", callback: "alert(1);//", expected: "alert1"},
+		{name: "markup injection", callback: "</script><img src=x onerror=alert(1)>", expected: "scriptimgsrcxonerroralert1"},
+		{name: "eval payload", callback: "eval(atob('YWxlcnQoMSk='));x", expected: "evalatobYWxlcnQoMSkx"},
+		{name: "newline", callback: "cb\nalert(1)", expected: "cbalert1"},
+		{name: "quote", callback: `cb"+alert(1)+"`, expected: "cbalert1"},
+
+		// Legitimate member expressions must survive untouched.
+		{name: "plain identifier", callback: "cb", expected: "cb"},
+		{name: "property access", callback: "window.cb", expected: "window.cb"},
+		{name: "bracket index", callback: "ns.cb[0]", expected: "ns.cb[0]"},
+		{name: "dollar and underscore", callback: "$.jsonp_1", expected: "$.jsonp_1"},
+
+		// Nothing callable left: fall back rather than emit a body that throws.
+		{name: "fully stripped", callback: "()+-;", expected: "callback"},
+		{name: "empty", callback: "", expected: "callback"},
+		{name: "bare number", callback: "123", expected: "callback"},
+		{name: "leading digit", callback: "0.0", expected: "callback"},
+		{name: "dots only", callback: "...", expected: "callback"},
+		{name: "unbalanced bracket", callback: "a[", expected: "callback"},
+		{name: "empty index", callback: "a[]", expected: "callback"},
+		{name: "empty label", callback: "a..b", expected: "callback"},
+
+		// An identifier may not resume straight after a closing bracket; only
+		// '.', '[' or another ']' may follow one.
+		{name: "identifier after index", callback: "cb[0]x", expected: "callback"},
+		{name: "digit after index", callback: "cb[0]1", expected: "callback"},
+		{name: "index after index", callback: "cb[0][1]", expected: "cb[0][1]"},
+		{name: "property after index", callback: "cb[0].x", expected: "cb[0].x"},
+		{name: "nested index", callback: "a[b[0]]", expected: "a[b[0]]"},
+
+		// An index that opens with a digit is a number, so it is digits to the
+		// closing bracket. Anything else there is made of allowed bytes and still
+		// emits a body that throws.
+		{name: "multi digit index", callback: "cb[10]", expected: "cb[10]"},
+		{name: "identifier index", callback: "cb[i]", expected: "cb[i]"},
+		{name: "index with trailing letters", callback: "cb[0foo]", expected: "callback"},
+		{name: "hex-looking index", callback: "ns[0x]", expected: "callback"},
+		{name: "dotted number index", callback: "ns[1.2.3]", expected: "callback"},
+		{name: "index into a number", callback: "cb[0[1]]", expected: "callback"},
+
+		// Only a token opened by '[' may be a number. A property named after a dot
+		// may not, however deep in brackets the dot sits.
+		{name: "numeric property in index", callback: "cb[a.0]", expected: "callback"},
+		{name: "numeric property nested", callback: "cb[x[a.1]]", expected: "callback"},
+		{name: "numeric property trailing", callback: "cb[a.b.0]", expected: "callback"},
+		{name: "identifier property in index", callback: "cb[a.b]", expected: "cb[a.b]"},
+
+		// A reserved word is refused only where the word is read as a name: the
+		// head of the expression and the head inside each index. After a dot it is
+		// a property name, which any word may be.
+		{name: "reserved word alone", callback: "for", expected: "callback"},
+		{name: "reserved word in index", callback: "cb[new]", expected: "callback"},
+
+		// A keyword that is itself a complete expression parses where one is
+		// read, so these are left alone.
+		{name: "this heads the expression", callback: "this.cb", expected: "this.cb"},
+		{name: "literal heads the expression", callback: "null.x", expected: "null.x"},
+		{name: "literal in an index", callback: "cb[true]", expected: "cb[true]"},
+		{name: "this in an index", callback: "cb[this]", expected: "cb[this]"},
+		{name: "reserved word heads an index", callback: "cb[new.a]", expected: "callback"},
+		{name: "reserved word as property", callback: "cb.new", expected: "cb.new"},
+		{name: "reserved word as nested property", callback: "cb[a.class]", expected: "cb[a.class]"},
+		{name: "reserved word as prefix", callback: "news", expected: "news"},
+
+		// "let" is a keyword only where a "[" follows it at the head of the
+		// statement the body is: "let[a](…);" is read as a destructuring
+		// declaration and throws, while every other position is a call.
+		{name: "let indexed at the head", callback: "let[a]", expected: "callback"},
+		{name: "let indexed by a number", callback: "let[0]", expected: "callback"},
+		{name: "let alone", callback: "let", expected: "let"},
+		{name: "let with a property", callback: "let.a", expected: "let.a"},
+		{name: "let indexed deeper", callback: "cb[let[a]]", expected: "cb[let[a]]"},
+
+		// A JSONP body is parsed as a classic script in sloppy mode, where
+		// "await" is an identifier unless it stands in a module or an async
+		// function, and "yield" unless in strict mode or a generator. Both are
+		// callable names here; V8 parses every one of these.
+		{name: "await heads the expression", callback: "await.cb", expected: "await.cb"},
+		{name: "await in an index", callback: "cb[await]", expected: "cb[await]"},
+		{name: "yield heads the expression", callback: "yield.cb", expected: "yield.cb"},
+		{name: "yield in an index", callback: "cb[yield]", expected: "cb[yield]"},
+		{name: "let as a property", callback: "cb.let[0]", expected: "cb.let[0]"},
+	}
+
+	app := New()
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			defer app.ReleaseCtx(c)
+
+			require.NoError(t, c.JSONP(Map{"a": 1}, tc.callback))
+			require.Equal(t, tc.expected+`({"a":1});`, string(c.Response().Body()))
+			require.Equal(t, "text/javascript; charset=utf-8", string(c.Response().Header.Peek(HeaderContentType)))
+			require.Equal(t, "nosniff", string(c.Response().Header.Peek(HeaderXContentTypeOptions)))
+		})
+	}
+}
+
 // go test -v  -run=^$ -bench=Benchmark_Ctx_JSONP -benchmem -count=4
 func Benchmark_Ctx_JSONP(b *testing.B) {
 	app := New()
diff --git a/extractors/extractors_test.go b/extractors/extractors_test.go
index e27c16dac2b..86356fb5f30 100644
--- a/extractors/extractors_test.go
+++ b/extractors/extractors_test.go
@@ -1,7 +1,9 @@
 package extractors
 
 import (
+	"bufio"
 	"context"
+	"fmt"
 	"net/http"
 	"strings"
 	"testing"
@@ -216,6 +218,123 @@ func Test_Extractor_Chain(t *testing.T) {
 	})
 }
 
+// Test_Extractor_FromHeader_CombinesRepeatedLines covers a field carried on
+// several lines. FromHeader is given its name by the application, and a name it
+// is given may be a list field a peer may legally send twice, so the lines are
+// combined the way RFC 9110 §5.3 says a recipient may rather than refused as an
+// ambiguous single value.
+func Test_Extractor_FromHeader_CombinesRepeatedLines(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+			ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+			defer app.ReleaseCtx(ctx)
+			if !normalize {
+				ctx.Request().Header.DisableNormalizing()
+			}
+
+			ctx.Request().Header.Add("Accept", "text/html")
+			// The second spelling is the one HTTP/2 and 3 put on the wire.
+			ctx.Request().Header.Add("accept", "application/json")
+
+			value, err := FromHeader("Accept").Extract(ctx)
+			require.NoError(t, err)
+			require.Equal(t, "text/html, application/json", value)
+		})
+	}
+}
+
+// Test_Extractor_FromHeader_CookieKeepsItsOwnSeparator covers FromHeader named
+// with Cookie, whose crumbs are joined with "; " (RFC 6265 §5.4) rather than
+// with the comma a list field takes.
+//
+// fasthttp keeps cookies in a store of their own that PeekAll enumerates one at
+// a time, so the generic join produced "a=1, b=2" for a request that said
+// "a=1; b=2" — a value no cookie parser downstream would read back.
+func Test_Extractor_FromHeader_CookieKeepsItsOwnSeparator(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(ctx)
+
+	// Read from the wire rather than Set: a request carrying Cookie twice, which
+	// is what an HTTP/1 gateway writes for the split field HTTP/2 permits. Only
+	// then does fasthttp hand the crumbs back one at a time.
+	raw := "GET / HTTP/1.1\r\nHost: example.com\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n"
+	require.NoError(t, ctx.Request().Header.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	value, err := FromHeader(fiber.HeaderCookie).Extract(ctx)
+	require.NoError(t, err)
+	require.Equal(t, "a=1; b=2", value)
+}
+
+// Test_Extractor_FromHeader_SingleLineIsUnchanged is the control for the test
+// above: one line is returned as it arrived, with no separator introduced.
+func Test_Extractor_FromHeader_SingleLineIsUnchanged(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(ctx)
+	ctx.Request().Header.Set("X-API-Key", "abc123")
+
+	value, err := FromHeader("X-API-Key").Extract(ctx)
+	require.NoError(t, err)
+	require.Equal(t, "abc123", value)
+}
+
+// Test_Extractor_FromAuthHeader_RepeatedLineIsNotACredential covers a message
+// carrying Authorization twice, which is what a middleware clearing the field
+// leaves behind when the client sent another spelling of it.
+//
+// Under DisableHeaderNormalizing a byte-exact Set writes the canonical name and
+// leaves the client's lower-case line — the spelling HTTP/2 and 3 put on the
+// wire — in place beside it. Reading either one lets whoever wrote the other
+// decide: the first line is the cleared value only where fasthttp happens to
+// store it first, and the first non-empty one is always the client's. Neither
+// is an answer, so no credential is extracted and the caller refuses.
+func Test_Extractor_FromAuthHeader_RepeatedLineIsNotACredential(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	extractor := FromAuthHeader("Bearer")
+
+	// Both orders fasthttp stores, depending on whether the client's line was
+	// already under the canonical name when the middleware cleared it.
+	for _, order := range [][2][2]string{
+		{{"authorization", "Bearer client"}, {"Authorization", ""}},
+		{{"Authorization", ""}, {"authorization", "Bearer client"}},
+	} {
+		ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+		ctx.Request().Header.DisableNormalizing()
+		for _, line := range order {
+			ctx.Request().Header.Add(line[0], line[1])
+		}
+
+		token, err := extractor.Extract(ctx)
+		require.ErrorIs(t, err, ErrNotFound,
+			"a second Authorization line makes the credential ambiguous, whichever order it is stored in")
+		require.Empty(t, token)
+		app.ReleaseCtx(ctx)
+	}
+
+	// A single line is still extracted, so the assertions above cannot pass by
+	// refusing everything.
+	ctx := app.AcquireCtx(&fasthttp.RequestCtx{})
+	defer app.ReleaseCtx(ctx)
+	ctx.Request().Header.DisableNormalizing()
+	ctx.Request().Header.Set("authorization", "Bearer client")
+
+	token, err := extractor.Extract(ctx)
+	require.NoError(t, err)
+	require.Equal(t, "client", token)
+}
+
 // go test -run Test_Extractor_FromAuthHeader_EdgeCases
 func Test_Extractor_FromAuthHeader_EdgeCases(t *testing.T) {
 	t.Parallel()
@@ -1101,3 +1220,64 @@ func Benchmark_isValidToken68(b *testing.B) {
 	}
 	_ = got
 }
+
+// Test_FromHeader_IgnoresHeaderNameCase pins that a token is found under the
+// name it actually arrived as.
+//
+// Ctx.Get compares the stored key byte for byte, so under
+// DisableHeaderNormalizing a token sent under the lower-case name that HTTP/2
+// and HTTP/3 put on the wire was not found, and the request refused for
+// carrying no token when it carried one.
+func Test_FromHeader_IgnoresHeaderNameCase(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			for _, sent := range []string{"X-Csrf-Token", "x-csrf-token", "X-CSRF-TOKEN"} {
+				app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+				c := app.AcquireCtx(&fasthttp.RequestCtx{})
+				if !normalize {
+					c.Request().Header.DisableNormalizing()
+				}
+				c.Request().Header.Set(sent, "the-token")
+
+				got, err := FromHeader("X-Csrf-Token").Extract(c)
+				require.NoError(t, err, "sent as %q", sent)
+				require.Equal(t, "the-token", got, "sent as %q", sent)
+				app.ReleaseCtx(c)
+			}
+		})
+	}
+}
+
+// Test_FromAuthHeader_IgnoresHeaderNameCase pins the same for the Authorization
+// reader, which reaches every keyauth and bearer-token caller.
+//
+// FromHeader was fixed first and this one was missed: a lower-case
+// "authorization:" read as absent, so the scheme check never ran and the
+// request was refused for carrying no credential when it carried one.
+func Test_FromAuthHeader_IgnoresHeaderNameCase(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			for _, sent := range []string{"Authorization", "authorization", "AUTHORIZATION"} {
+				app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+				c := app.AcquireCtx(&fasthttp.RequestCtx{})
+				if !normalize {
+					c.Request().Header.DisableNormalizing()
+				}
+				c.Request().Header.Set(sent, "Bearer the-token")
+
+				got, err := FromAuthHeader("Bearer").Extract(c)
+				require.NoError(t, err, "sent as %q", sent)
+				require.Equal(t, "the-token", got, "sent as %q", sent)
+				app.ReleaseCtx(c)
+			}
+		})
+	}
+}
diff --git a/helpers_test.go b/helpers_test.go
index 78cda93e1bf..19bec65f6bc 100644
--- a/helpers_test.go
+++ b/helpers_test.go
@@ -1929,85 +1929,3 @@ func Test_appendLowerASCII(t *testing.T) {
 		})
 	}
 }
-
-// Test_normalizeContentTypeMediaType pins the RFC 9110 case rules the
-// Content-Type normalizer implements: the media type (Section 8.3.1) and each
-// parameter name (Section 5.6.6) are case-insensitive and get folded, while
-// parameter values are left byte-for-byte alone. Folding a value would corrupt
-// a multipart boundary, which is case-sensitive.
-func Test_normalizeContentTypeMediaType(t *testing.T) {
-	t.Parallel()
-
-	testCases := []struct {
-		name string
-		in   string
-		want string
-	}{
-		{name: "no parameters", in: "Application/JSON", want: "application/json"},
-		{name: "already lower", in: "application/json", want: "application/json"},
-		{name: "empty", in: "", want: ""},
-		{
-			name: "parameter name folded, value preserved",
-			in:   "Multipart/Form-Data; BOUNDARY=AbC123",
-			want: "multipart/form-data; boundary=AbC123",
-		},
-		{
-			name: "whitespace after the semicolon",
-			in:   "Text/Plain;\t CHARSET=UTF-8",
-			want: "text/plain;\t charset=UTF-8",
-		},
-		{
-			name: "several parameters",
-			in:   "Text/Plain; CHARSET=UTF-8; Format=Flowed",
-			want: "text/plain; charset=UTF-8; format=Flowed",
-		},
-		{
-			// A quoted-string may itself contain ';', so it must be consumed as
-			// a unit or the next parameter name would be mislocated.
-			name: "semicolon inside a quoted value",
-			in:   `Text/Plain; NAME="a;B"; Charset=UTF-8`,
-			want: `text/plain; name="a;B"; charset=UTF-8`,
-		},
-		{
-			name: "escaped quote inside a quoted value",
-			in:   `Text/Plain; NAME="a\"; B"; Charset=UTF-8`,
-			want: `text/plain; name="a\"; B"; charset=UTF-8`,
-		},
-		{
-			name: "unterminated quoted value",
-			in:   `Text/Plain; NAME="abc`,
-			want: `text/plain; name="abc`,
-		},
-		{
-			// A bare parameter with no '=' must not swallow what follows it.
-			name: "valueless parameter",
-			in:   "Text/Plain; FLAG; CHARSET=UTF-8",
-			want: "text/plain; flag; charset=UTF-8",
-		},
-		{
-			name: "trailing semicolon",
-			in:   "Text/Plain;",
-			want: "text/plain;",
-		},
-		{
-			name: "empty parameter between semicolons",
-			in:   "Text/Plain;; CHARSET=UTF-8",
-			want: "text/plain;; charset=UTF-8",
-		},
-	}
-
-	for _, tc := range testCases {
-		t.Run(tc.name, func(t *testing.T) {
-			t.Parallel()
-
-			h := &fasthttp.RequestHeader{}
-			h.SetContentType(tc.in)
-
-			require.Equal(t, tc.want, string(normalizeContentTypeMediaType(h)))
-			// The fold is in place, so the header itself must now read back
-			// normalized — that is what makes fasthttp's case-sensitive
-			// multipart lookups work.
-			require.Equal(t, tc.want, string(h.ContentType()))
-		})
-	}
-}
diff --git a/internal/fieldname/fieldname_test.go b/internal/fieldname/fieldname_test.go
new file mode 100644
index 00000000000..e4b42861c98
--- /dev/null
+++ b/internal/fieldname/fieldname_test.go
@@ -0,0 +1,114 @@
+package fieldname
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
+// readRequestHeader parses raw as a request, which is the only way to build the
+// two-line shapes below: they are what a peer or an intermediary puts on the
+// wire, not something the setters express directly.
+//
+//nolint:revive // flag-parameter: canonical is a property of the header store
+func readRequestHeader(tb testing.TB, raw string, canonical bool) *fasthttp.RequestHeader {
+	tb.Helper()
+
+	h := &fasthttp.RequestHeader{}
+	if !canonical {
+		h.DisableNormalizing()
+	}
+	require.NoError(tb, h.Read(bufio.NewReader(bytes.NewBufferString(raw))))
+	return h
+}
+
+// Test_First_EmptyLineIsNotNil pins the fasthttp behavior First's fast path
+// rests on: Peek answers nil for a field that is absent and a non-nil empty
+// slice for one that is present and empty. First skips its second walk on the
+// nil answer, so were the two to become indistinguishable it would read only
+// the first line again — silently, and only for the messages this guards
+// against. This test is what makes that loud instead.
+func Test_First_EmptyLineIsNotNil(t *testing.T) {
+	t.Parallel()
+
+	h := readRequestHeader(t, "GET / HTTP/1.1\r\nHost: app.example\r\nOrigin:\r\n\r\n", true)
+
+	require.Nil(t, h.Peek("Absent"), "Peek must answer nil for a field that is not there")
+
+	present := h.Peek("Origin")
+	require.Empty(t, present)
+	require.NotNil(t, present, "Peek must answer a non-nil empty slice for a field line that is present and empty")
+}
+
+// Test_First_EmptyLineDoesNotHideTheValue covers the read First exists for: a
+// field name carried twice, the first line empty. Peek reports that first line
+// whatever it holds, so the value beside it was invisible to every caller — a
+// response's "Cache-Control: private" behind an empty line of the same name
+// read as a response that said nothing about caching.
+//
+// Origin is used here only because it is a name fasthttp keeps no slot for, the
+// same as the response fields this now serves; the request-side reads that must
+// refuse a repeated field rather than resolve it go through headerlookup.Value.
+func Test_First_EmptyLineDoesNotHideTheValue(t *testing.T) {
+	t.Parallel()
+
+	const origin = "http://evil.example"
+
+	tests := []struct {
+		name      string
+		raw       string
+		want      string
+		canonical bool
+	}{
+		{
+			name:      "empty line ahead of the value",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\nOrigin:\r\nOrigin: " + origin + "\r\n\r\n",
+			canonical: true,
+			want:      origin,
+		},
+		{
+			name:      "empty line ahead of another spelling",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\nOrigin:\r\norigin: " + origin + "\r\n\r\n",
+			canonical: false,
+			want:      origin,
+		},
+		{
+			name:      "another spelling alone",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\norigin: " + origin + "\r\n\r\n",
+			canonical: false,
+			want:      origin,
+		},
+		{
+			name:      "the ordinary single line",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\nOrigin: " + origin + "\r\n\r\n",
+			canonical: true,
+			want:      origin,
+		},
+		{
+			// Present and empty is still nothing a caller can act on, so it
+			// reads as absent rather than as a value of "".
+			name:      "only an empty line",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\nOrigin:\r\n\r\n",
+			canonical: true,
+			want:      "",
+		},
+		{
+			name:      "absent",
+			raw:       "GET / HTTP/1.1\r\nHost: app.example\r\n\r\n",
+			canonical: true,
+			want:      "",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			h := readRequestHeader(t, tc.raw, tc.canonical)
+			require.Equal(t, tc.want, string(First(h, fasthttp.HeaderOrigin, tc.canonical)))
+		})
+	}
+}
diff --git a/internal/mediatype/mediatype_test.go b/internal/mediatype/mediatype_test.go
new file mode 100644
index 00000000000..9629fdbb5d5
--- /dev/null
+++ b/internal/mediatype/mediatype_test.go
@@ -0,0 +1,161 @@
+package mediatype
+
+import (
+	"testing"
+
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// Test_NormalizeRequestContentType pins the RFC 9110 case rules this package
+// implements: the media type (Section 8.3.1) and each parameter name
+// (Section 5.6.6) are case-insensitive and get folded, while parameter values
+// are left byte-for-byte alone. Folding a value would corrupt a multipart
+// boundary, which is case-sensitive and has to keep matching the body.
+func Test_NormalizeRequestContentType(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name string
+		in   string
+		want string
+	}{
+		{"already lowercase", "application/json", "application/json"},
+		{"media type only", "Application/JSON", "application/json"},
+		{"media type with parameter", "Multipart/Form-Data; BOUNDARY=AbC", "multipart/form-data; boundary=AbC"},
+		{"parameter value untouched", "text/plain; charset=UTF-8", "text/plain; charset=UTF-8"},
+		{"several parameters", "TEXT/Plain; Charset=UTF-8; Format=Flowed", "text/plain; charset=UTF-8; format=Flowed"},
+		{"no space after semicolon", "Text/HTML;Charset=UTF-8", "text/html;charset=UTF-8"},
+		{"tab after semicolon", "Text/HTML;\tCharset=UTF-8", "text/html;\tcharset=UTF-8"},
+		{"tab and space after semicolon", "Text/Plain;\t CHARSET=UTF-8", "text/plain;\t charset=UTF-8"},
+		{"empty parameter between semicolons", "Text/Plain;; CHARSET=UTF-8", "text/plain;; charset=UTF-8"},
+		{"quoted value holding a semicolon", `Multipart/Form-Data; Boundary="a;B"; Name=X`, `multipart/form-data; boundary="a;B"; name=X`},
+		{"parameter with no value", "Text/Plain; Flag; Charset=x", "text/plain; flag; charset=x"},
+		{"trailing semicolon", "Text/Plain;", "text/plain;"},
+		{"empty", "", ""},
+
+		// An unterminated quote consumes the rest of the list, and a quoted-pair
+		// keeps the value going (RFC 9110 Section 5.6.6). Everything inside the
+		// quotes is a value, so no parameter name in there is folded: fasthttp
+		// matches "boundary" case-sensitively, and folding one hidden in a value
+		// is what would promote it over the boundary the author wrote.
+		{"unterminated quote", `Multipart/Form-Data; X="abc`, `multipart/form-data; x="abc`},
+		{"quoted-pair keeps the value open", `Multipart/Form-Data; X="\"; BOUNDARY=abc`, `multipart/form-data; x="\"; BOUNDARY=abc`},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var h fasthttp.RequestHeader
+			h.SetContentType(tc.in)
+
+			require.Equal(t, tc.want, string(NormalizeRequestContentType(&h)))
+			// The header itself has to change, not a copy: fasthttp's form and
+			// multipart parsers read the request's own bytes.
+			require.Equal(t, tc.want, string(h.ContentType()))
+
+			// Idempotent, since every accessor that folds may be called
+			// repeatedly within one request.
+			require.Equal(t, tc.want, string(NormalizeRequestContentType(&h)))
+		})
+	}
+}
+
+func Test_IsForm(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		in   string
+		want bool
+	}{
+		{"application/x-www-form-urlencoded", true},
+		{"Application/X-WWW-Form-Urlencoded", true},
+		{"multipart/form-data", true},
+		{"Multipart/Form-Data; boundary=abc", true},
+		{"multipart/form-data ; boundary=abc", true},
+		{"multipart/form-data\t;boundary=abc", true},
+
+		{"application/json", false},
+		{"text/plain", false},
+		{"", false},
+		{"multipart/mixed", false},
+		{"application/x-www-form-urlencoded-not", false},
+		// A leading space is not trimmed: fasthttp does not produce one, and
+		// accepting it here would diverge from the parsers this gates.
+		{" multipart/form-data", false},
+	} {
+		require.Equal(t, tc.want, IsForm([]byte(tc.in)), "input %q", tc.in)
+	}
+}
+
+// Test_NormalizeRequestContentType_KeepsBoundaryUsable is the property the
+// whole package exists for: fasthttp locates the multipart boundary with
+// case-sensitive comparisons, so a legal "Multipart/Form-Data" with an
+// upper-case "BOUNDARY=" must still parse, and the boundary value itself must
+// survive unfolded so it keeps matching the body.
+func Test_NormalizeRequestContentType_KeepsBoundaryUsable(t *testing.T) {
+	t.Parallel()
+
+	var req fasthttp.Request
+	req.Header.SetContentType(`Multipart/Form-Data; BOUNDARY=AbCdEf`)
+	req.SetBody([]byte("--AbCdEf\r\nContent-Disposition: form-data; name=\"who\"\r\n\r\nworld\r\n--AbCdEf--\r\n"))
+
+	NormalizeRequestContentType(&req.Header)
+	require.Equal(t, "AbCdEf", string(req.Header.MultipartFormBoundary()))
+
+	form, err := req.MultipartForm()
+	require.NoError(t, err)
+	require.Equal(t, []string{"world"}, form.Value["who"])
+}
+
+// Test_NormalizeRequestContentType_QuotedPair covers a quoted-pair inside a
+// parameter value.
+//
+// Ending the quoted-string at an escaped quote folds the rest of it as though
+// those were parameters. fasthttp matches "boundary" case-sensitively and takes
+// the first one, so lowercasing a decoy it would otherwise walk past is what
+// makes it the boundary it picks — and the real one is never reached.
+func Test_NormalizeRequestContentType_QuotedPair(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name string
+		in   string
+		want string
+	}{
+		{
+			name: "escaped quote does not end the value",
+			in:   `Multipart/Form-Data; X="\"; BOUNDARY=bogus"; BOUNDARY=Real`,
+			want: `multipart/form-data; x="\"; BOUNDARY=bogus"; boundary=Real`,
+		},
+		{
+			name: "trailing backslash cannot escape past the end",
+			in:   `Multipart/Form-Data; X="ab\`,
+			want: `multipart/form-data; x="ab\`,
+		},
+		{
+			name: "escaped backslash still closes the value",
+			in:   `Multipart/Form-Data; X="a\\"; BOUNDARY=Real`,
+			want: `multipart/form-data; x="a\\"; boundary=Real`,
+		},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var h fasthttp.RequestHeader
+			h.SetContentType(tc.in)
+			require.Equal(t, tc.want, string(NormalizeRequestContentType(&h)))
+		})
+	}
+}
+
+// Test_NormalizeRequestContentType_DecoyBoundaryLosesToReal is the same input
+// read the way fasthttp reads it: the boundary it selects has to be the one the
+// author wrote, not the one hidden in an earlier parameter's value.
+func Test_NormalizeRequestContentType_DecoyBoundaryLosesToReal(t *testing.T) {
+	t.Parallel()
+
+	var h fasthttp.RequestHeader
+	h.SetContentType(`Multipart/Form-Data; X="\"; BOUNDARY=bogus"; BOUNDARY=Real`)
+	NormalizeRequestContentType(&h)
+	require.Equal(t, "Real", string(h.MultipartFormBoundary()))
+}
diff --git a/internal/urlnorm/urlnorm_test.go b/internal/urlnorm/urlnorm_test.go
new file mode 100644
index 00000000000..ef24f824262
--- /dev/null
+++ b/internal/urlnorm/urlnorm_test.go
@@ -0,0 +1,44 @@
+package urlnorm
+
+import (
+	"testing"
+
+	"github.com/stretchr/testify/require"
+)
+
+// Test_RootedPath pins the one shape a URL composed from a named route may take:
+// a path on the origin now being served, opening exactly one slash. Two would
+// open an authority, so "//evil.com" resolves against "https://good.example" as
+// "https://evil.com" — a value spliced at the front must never reach that.
+func Test_RootedPath(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name     string
+		location string
+		want     string
+	}{
+		{"ordinary path", "/user/john", "/user/john"},
+		{"value adds a slash", "//evil.com", "/evil.com"},
+		{"value adds a backslash", `/\evil.com`, "/evil.com"},
+		{"value adds several", "///evil.com", "/evil.com"},
+		{"value is only slashes", "//", "/"},
+		{"backslash is folded", `\internal`, "/internal"},
+		// Tab, LF and CR go first, or one hides behind the leading slash.
+		{"control bytes cannot hide a slash", "/\t/evil.com", "/evil.com"},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, RootedPath(tc.location))
+		})
+	}
+}
+
+func Test_LeadingSlashes(t *testing.T) {
+	t.Parallel()
+
+	require.Equal(t, 0, LeadingSlashes("internal"))
+	require.Equal(t, 1, LeadingSlashes("/internal"))
+	require.Equal(t, 2, LeadingSlashes("//internal"))
+	require.Equal(t, 2, LeadingSlashes(`/\internal`))
+}
diff --git a/listen_test.go b/listen_test.go
index 2307a7b828e..27ba0f1354f 100644
--- a/listen_test.go
+++ b/listen_test.go
@@ -599,6 +599,103 @@ func Test_Listen_TLSConfig_WithTLSConfigFunc(t *testing.T) {
 	require.False(t, calledTLSConfigFunc)
 }
 
+// go test -run Test_Listen_TLSConfig_WarnsSupersededFields
+func Test_Listen_TLSConfig_WarnsSupersededFields(t *testing.T) {
+	// Not parallel: it captures the package-level log output, and Go keeps no
+	// parallel test in flight while a serial one runs. Test_Listen_TLSConfig_WithTLSConfigFunc
+	// is parallel and warns, so it would otherwise write into this buffer.
+	cert, err := tls.LoadX509KeyPair("./.github/testdata/ssl.pem", "./.github/testdata/ssl.key")
+	require.NoError(t, err)
+
+	var buf bytes.Buffer
+	withCapturedLogOutput(t, &buf)
+
+	app := New()
+	go func() {
+		time.Sleep(500 * time.Millisecond)
+		assert.NoError(t, app.Shutdown())
+	}()
+
+	require.NoError(t, app.Listen(":0", ListenConfig{
+		DisableStartupMessage: true,
+		TLSConfig: &tls.Config{
+			MinVersion:   tls.VersionTLS12,
+			Certificates: []tls.Certificate{cert},
+		},
+		// Superseded by TLSConfig. CertClientFile is the one that matters: a
+		// listener that silently drops it serves every client without asking
+		// for a certificate, which reads as working mTLS until someone checks.
+		CertClientFile: "./.github/testdata/ca-chain.cert.pem",
+		TLSConfigFunc:  func(*tls.Config) {},
+		// The supplied TLSConfig permits TLS 1.2, so this request is dropped.
+		TLSMinVersion: tls.VersionTLS13,
+	}))
+
+	out := buf.String()
+	require.Contains(t, out, "CertClientFile")
+	// Not "no client certificate will be required": the supplied TLSConfig may
+	// ask for one itself, and then one is. What the warning has to say is which
+	// of the two decides, and that ClientAuth is what decides it.
+	require.Contains(t, out, "required only if TLSConfig sets ClientAuth to a Require mode")
+	require.Contains(t, out, "TLSConfigFunc")
+	require.Contains(t, out, "TLSMinVersion")
+}
+
+// go test -run Test_Listen_TLSConfig_NoWarningWhenAlone
+func Test_Listen_TLSConfig_NoWarningWhenAlone(t *testing.T) {
+	// Not parallel: captures the package-level log output.
+	cert, err := tls.LoadX509KeyPair("./.github/testdata/ssl.pem", "./.github/testdata/ssl.key")
+	require.NoError(t, err)
+
+	var buf bytes.Buffer
+	withCapturedLogOutput(t, &buf)
+
+	app := New()
+	go func() {
+		time.Sleep(500 * time.Millisecond)
+		assert.NoError(t, app.Shutdown())
+	}()
+
+	require.NoError(t, app.Listen(":0", ListenConfig{
+		DisableStartupMessage: true,
+		TLSConfig: &tls.Config{
+			MinVersion:   tls.VersionTLS12,
+			Certificates: []tls.Certificate{cert},
+		},
+	}))
+
+	require.NotContains(t, buf.String(), "supersedes")
+}
+
+// go test -run Test_Listener_WarnsIgnoredTLSFields
+func Test_Listener_WarnsIgnoredTLSFields(t *testing.T) {
+	// Not parallel: captures the package-level log output.
+	var buf bytes.Buffer
+	withCapturedLogOutput(t, &buf)
+
+	ln, err := net.Listen(NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+
+	app := New()
+	go func() {
+		time.Sleep(500 * time.Millisecond)
+		assert.NoError(t, app.Shutdown())
+	}()
+
+	// Listener serves ln untouched, so mTLS here is silently absent unless the
+	// caller wrapped the listener themselves.
+	require.NoError(t, app.Listener(ln, ListenConfig{
+		DisableStartupMessage: true,
+		CertClientFile:        "./.github/testdata/ca-chain.cert.pem",
+	}))
+
+	out := buf.String()
+	require.Contains(t, out, "CertClientFile is ignored")
+	// The supplied listener may already require a certificate, so the warning
+	// names what decides rather than asserting none is asked for.
+	require.Contains(t, out, "required only if the supplied listener already asks for one")
+}
+
 // go test -run Test_Listen_AutoCert_Conflicts
 func Test_Listen_AutoCert_Conflicts(t *testing.T) {
 	t.Parallel()
@@ -1115,3 +1212,229 @@ func captureOutput(f func()) string {
 func emptyHandler(_ Ctx) error {
 	return nil
 }
+
+// go test -run Test_WarnIgnoredTLSFieldsOnListener_Branches
+//
+// Listener serves the listener it is handed, so every TLS field in the config
+// is dropped. The end-to-end tests above cover CertClientFile, which returns
+// before the rest; this drives the remaining fields, the singular/plural
+// wording, and the two suffixes — a plain listener is not serving TLS at all,
+// which is worth saying, and a TLS one already is.
+func Test_WarnIgnoredTLSFieldsOnListener_Branches(t *testing.T) {
+	// Not parallel: captures the package-level log output.
+	cert, err := tls.LoadX509KeyPair("./.github/testdata/ssl.pem", "./.github/testdata/ssl.key")
+	require.NoError(t, err)
+
+	plain, err := net.Listen(NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() { _ = plain.Close() }) //nolint:errcheck // closing a test listener
+
+	secure, err := net.Listen(NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	tlsLn := tls.NewListener(secure, &tls.Config{
+		MinVersion:   tls.VersionTLS12,
+		Certificates: []tls.Certificate{cert},
+	})
+	t.Cleanup(func() { _ = tlsLn.Close() }) //nolint:errcheck // closing a test listener
+
+	tests := []struct {
+		listener net.Listener
+		contains []string
+		absent   []string
+		name     string
+		cfg      ListenConfig
+	}{
+		{
+			name:     "nothing to report",
+			cfg:      ListenConfig{},
+			listener: plain,
+			absent:   []string{"ignored"},
+		},
+		{
+			name:     "one field reads singular",
+			cfg:      ListenConfig{TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}},
+			listener: tlsLn,
+			contains: []string{"TLSConfig", "is ignored."},
+			absent:   []string{"not serving TLS"},
+		},
+		{
+			// A plain listener is not serving TLS at all, which is the more
+			// surprising half and is said outright.
+			name:     "a plain listener says so",
+			cfg:      ListenConfig{TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}},
+			listener: plain,
+			contains: []string{"TLSConfig", "is ignored", "this listener is not serving TLS"},
+		},
+		{
+			name: "several fields read plural",
+			cfg: ListenConfig{
+				CertFile:      "./.github/testdata/ssl.pem",
+				CertKeyFile:   "./.github/testdata/ssl.key",
+				TLSConfigFunc: func(*tls.Config) {},
+			},
+			listener: plain,
+			contains: []string{"CertFile/CertKeyFile", "TLSConfigFunc", "are ignored"},
+		},
+		{
+			name:     "the certificate manager counts too",
+			cfg:      ListenConfig{AutoCertManager: &autocert.Manager{}},
+			listener: plain,
+			contains: []string{"AutoCertManager", "is ignored"},
+		},
+		{
+			name:     "a raised minimum version is named",
+			cfg:      ListenConfig{TLSMinVersion: tls.VersionTLS13},
+			listener: plain,
+			contains: []string{"TLSMinVersion", "is ignored"},
+		},
+		{
+			// The default and the unset zero both mean nothing was displaced.
+			name:     "the default minimum version is not",
+			cfg:      ListenConfig{TLSMinVersion: tls.VersionTLS12},
+			listener: plain,
+			absent:   []string{"ignored"},
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			var buf bytes.Buffer
+			withCapturedLogOutput(t, &buf)
+
+			cfg := tc.cfg
+			warnIgnoredTLSFieldsOnListener(&cfg, tc.listener)
+
+			out := buf.String()
+			for _, want := range tc.contains {
+				require.Contains(t, out, want)
+			}
+			for _, unwanted := range tc.absent {
+				require.NotContains(t, out, unwanted)
+			}
+		})
+	}
+}
+
+// go test -run Test_WarnSupersededTLSFields_Branches
+//
+// TLSConfig replaces the other TLS settings rather than seeding them, so each
+// one it displaces is named. The end-to-end test above covers the pair a real
+// deployment hits; this drives the two that are otherwise unreached.
+func Test_WarnSupersededTLSFields_Branches(t *testing.T) {
+	// Not parallel: captures the package-level log output.
+	tests := []struct {
+		name     string
+		contains []string
+		absent   []string
+		cfg      ListenConfig
+	}{
+		{
+			name:   "nothing to report",
+			cfg:    ListenConfig{},
+			absent: []string{"supersedes"},
+		},
+		{
+			name:     "certificate files",
+			cfg:      ListenConfig{CertFile: "./.github/testdata/ssl.pem"},
+			contains: []string{"supersedes CertFile/CertKeyFile"},
+		},
+		{
+			name:     "certificate manager",
+			cfg:      ListenConfig{AutoCertManager: &autocert.Manager{}},
+			contains: []string{"supersedes AutoCertManager"},
+		},
+		{
+			name:     "a raised minimum version",
+			cfg:      ListenConfig{TLSMinVersion: tls.VersionTLS13},
+			contains: []string{"supersedes TLSMinVersion"},
+		},
+		{
+			// The default and the unset zero both mean nothing was displaced.
+			name:   "the default minimum version is not reported",
+			cfg:    ListenConfig{TLSMinVersion: tls.VersionTLS12},
+			absent: []string{"supersedes"},
+		},
+		{
+			name: "all of them at once",
+			cfg: ListenConfig{
+				CertKeyFile:     "./.github/testdata/ssl.key",
+				AutoCertManager: &autocert.Manager{},
+				TLSConfigFunc:   func(*tls.Config) {},
+				TLSMinVersion:   tls.VersionTLS13,
+			},
+			contains: []string{"CertFile/CertKeyFile", "TLSMinVersion", "AutoCertManager", "TLSConfigFunc"},
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			var buf bytes.Buffer
+			withCapturedLogOutput(t, &buf)
+
+			cfg := tc.cfg
+			warnSupersededTLSFields(&cfg)
+
+			out := buf.String()
+			for _, want := range tc.contains {
+				require.Contains(t, out, want)
+			}
+			for _, unwanted := range tc.absent {
+				require.NotContains(t, out, unwanted)
+			}
+		})
+	}
+}
+
+// Test_Listen_StaleTLSMinVersionReachesTheDiagnostics covers where the
+// unsupported-version check is asked.
+//
+// A stale tls.VersionTLS11 beside a TLSConfig, or on App.Listener, is a value
+// neither path reads. Rejecting it in the defaults panicked before either
+// warning could run, so the caller learned nothing about the field being
+// ignored — the one thing worth telling them. Where the version is read, it is
+// still rejected.
+//
+//nolint:tparallel // the warning subtests capture the package-level log output
+func Test_Listen_StaleTLSMinVersionReachesTheDiagnostics(t *testing.T) {
+	t.Run("superseded by TLSConfig", func(t *testing.T) {
+		var buf bytes.Buffer
+		withCapturedLogOutput(t, &buf)
+
+		cfg := listenConfigDefault(ListenConfig{
+			TLSConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
+			TLSMinVersion: tls.VersionTLS11,
+		})
+		require.NotPanics(t, func() { warnSupersededTLSFields(&cfg) })
+		require.Contains(t, buf.String(), "TLSMinVersion")
+	})
+
+	t.Run("ignored on a supplied listener", func(t *testing.T) {
+		var buf bytes.Buffer
+		withCapturedLogOutput(t, &buf)
+
+		ln, err := net.Listen(NetworkTCP4, "127.0.0.1:0")
+		require.NoError(t, err)
+		defer func() { require.NoError(t, ln.Close()) }()
+
+		cfg := listenConfigDefault(ListenConfig{TLSMinVersion: tls.VersionTLS11})
+		require.NotPanics(t, func() { warnIgnoredTLSFieldsOnListener(&cfg, ln) })
+		require.Contains(t, buf.String(), "TLSMinVersion")
+	})
+
+	t.Run("still rejected where it is read", func(t *testing.T) {
+		t.Parallel()
+
+		cfg := listenConfigDefault(ListenConfig{TLSMinVersion: tls.VersionTLS11})
+		require.PanicsWithValue(t,
+			"unsupported TLS version, please use tls.VersionTLS12 or tls.VersionTLS13",
+			func() { validateTLSMinVersion(&cfg) })
+	})
+
+	t.Run("the default is accepted", func(t *testing.T) {
+		t.Parallel()
+
+		cfg := listenConfigDefault()
+		require.Equal(t, uint16(tls.VersionTLS12), cfg.TLSMinVersion)
+		require.NotPanics(t, func() { validateTLSMinVersion(&cfg) })
+	})
+}
diff --git a/middleware/adaptor/adaptor_test.go b/middleware/adaptor/adaptor_test.go
index 56c149ab73a..84de0377758 100644
--- a/middleware/adaptor/adaptor_test.go
+++ b/middleware/adaptor/adaptor_test.go
@@ -2234,3 +2234,250 @@ func Test_FiberApp_RemoteAddrSurvivesPooling(t *testing.T) {
 		require.Equal(t, addr, retained[i].String())
 	}
 }
+
+// Test_HTTPMiddleware_PropagatesHeaderRemoval asserts that a header the wrapped
+// net/http middleware deletes stays deleted for the fiber handler. Copying only
+// what r.Header still holds would leave the original value in place, silently
+// defeating middleware whose purpose is to strip a header.
+func Test_HTTPMiddleware_PropagatesHeaderRemoval(t *testing.T) {
+	t.Parallel()
+
+	type seen struct {
+		forwardedFor  string
+		authorization string
+		kept          string
+		contentType   string
+		body          string
+	}
+
+	var got seen
+
+	app := fiber.New()
+	app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			r.Header.Del("X-Forwarded-For")
+			r.Header.Del(fiber.HeaderAuthorization)
+			next.ServeHTTP(w, r)
+		})
+	}))
+	app.Post("/", func(c fiber.Ctx) error {
+		got = seen{
+			forwardedFor:  c.Get("X-Forwarded-For"),
+			authorization: c.Get(fiber.HeaderAuthorization),
+			kept:          c.Get("X-Kept"),
+			contentType:   c.Get(fiber.HeaderContentType),
+			body:          string(c.Body()),
+		}
+		return c.SendString("ok")
+	})
+
+	req := httptest.NewRequest(fiber.MethodPost, "/", strings.NewReader("a=1"))
+	req.Header.Set(fiber.HeaderContentType, "application/x-www-form-urlencoded")
+	req.Header.Set("X-Forwarded-For", "1.2.3.4")
+	req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
+	req.Header.Set("X-Kept", "still here")
+
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	require.Empty(t, got.forwardedFor)
+	require.Empty(t, got.authorization)
+	// Headers the middleware left alone survive, and the framing headers it
+	// never touches must not be collateral damage.
+	require.Equal(t, "still here", got.kept)
+	require.Equal(t, "application/x-www-form-urlencoded", got.contentType)
+	require.Equal(t, "a=1", got.body)
+}
+
+// Test_HTTPMiddleware_HeaderFidelity asserts that the fiber request ends up
+// holding exactly what the wrapped net/http middleware left in r.Header.
+//
+// fasthttpadaptor builds r.Header from b2s views into fiber's own header
+// storage, so a copy-back that writes while reading corrupts itself: values got
+// duplicated, sanitized values kept their originals alongside them, and the
+// rewritten Host came back spliced with the bytes of the old one.
+func Test_HTTPMiddleware_HeaderFidelity(t *testing.T) {
+	t.Parallel()
+
+	forwardedFor := func(t *testing.T, mw func(http.Handler) http.Handler) ([]string, string, string) {
+		t.Helper()
+
+		var (
+			values  []string
+			uriHost string
+			hdrHost string
+		)
+		app := fiber.New()
+		app.Use(HTTPMiddleware(mw))
+		app.Get("/", func(c fiber.Ctx) error {
+			for _, v := range c.Request().Header.PeekAll("X-Forwarded-For") {
+				values = append(values, string(v))
+			}
+			uriHost, hdrHost = c.Host(), c.Get(fiber.HeaderHost)
+			return c.SendString("ok")
+		})
+
+		req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+		req.Host = "original.example"
+		req.Header.Add("X-Forwarded-For", "1.1.1.1")
+		req.Header.Add("X-Forwarded-For", "2.2.2.2")
+
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusOK, resp.StatusCode)
+		return values, uriHost, hdrHost
+	}
+
+	t.Run("pass-through preserves every value exactly once", func(t *testing.T) {
+		t.Parallel()
+
+		got, _, _ := forwardedFor(t, func(next http.Handler) http.Handler { return next })
+		require.Equal(t, []string{"1.1.1.1", "2.2.2.2"}, got)
+	})
+
+	t.Run("collapsing a multi-valued header drops the originals", func(t *testing.T) {
+		t.Parallel()
+
+		got, _, _ := forwardedFor(t, func(next http.Handler) http.Handler {
+			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+				r.Header.Set("X-Forwarded-For", "9.9.9.9")
+				next.ServeHTTP(w, r)
+			})
+		})
+		// Leaving "2.2.2.2" behind would hand the spoofed value straight to
+		// c.IPs() and the TrustProxy chain walk.
+		require.Equal(t, []string{"9.9.9.9"}, got)
+	})
+
+	t.Run("assigning nil removes the header", func(t *testing.T) {
+		t.Parallel()
+
+		got, _, _ := forwardedFor(t, func(next http.Handler) http.Handler {
+			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+				r.Header["X-Forwarded-For"] = nil
+				next.ServeHTTP(w, r)
+			})
+		})
+		require.Empty(t, got)
+	})
+
+	t.Run("rewritten host is not spliced with the old one", func(t *testing.T) {
+		t.Parallel()
+
+		_, uriHost, hdrHost := forwardedFor(t, func(next http.Handler) http.Handler {
+			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+				r.Host = "internal.svc"
+				next.ServeHTTP(w, r)
+			})
+		})
+		require.Equal(t, "internal.svc", uriHost)
+		require.Equal(t, "internal.svc", hdrHost)
+	})
+}
+
+// Test_HTTPMiddleware_PropagatesConnectionRewrite covers Connection, which names
+// the hop-by-hop fields a proxy is to strip.
+//
+// Middleware rewrites that list — dropping the edit left the handler, and any
+// proxy reading it downstream, working from the list the client sent. The header
+// also drives fasthttp's close flag, which has to survive the round trip.
+func Test_HTTPMiddleware_PropagatesConnectionRewrite(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name  string
+		sent  string
+		write string // "" leaves the header alone
+		want  string
+	}{
+		{name: "rewritten", sent: "keep-alive, X-Client-Token", write: "keep-alive", want: "keep-alive"},
+		{name: "extended", sent: "keep-alive", write: "keep-alive, X-Internal", want: "keep-alive, X-Internal"},
+		{name: "untouched close survives", sent: "close", want: "close"},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var got string
+			var gotClose bool
+
+			app := fiber.New()
+			app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+					if tc.write != "" {
+						r.Header.Set(fiber.HeaderConnection, tc.write)
+					}
+					next.ServeHTTP(w, r)
+				})
+			}))
+			app.Get("/", func(c fiber.Ctx) error {
+				got = c.Get(fiber.HeaderConnection)
+				gotClose = c.Request().Header.ConnectionClose()
+				return c.SendString("ok")
+			})
+
+			req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+			req.Header.Set(fiber.HeaderConnection, tc.sent)
+
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+			require.Equal(t, tc.want, got)
+			require.Equal(t, tc.want == "close", gotClose, "the close flag follows the value")
+		})
+	}
+}
+
+// Test_HTTPMiddleware_JoinsRepeatedConnectionValues covers middleware that
+// writes Connection as several slice entries, which is how net/http represents a
+// combined value. fasthttp keeps the field in a slot of its own, so a second Add
+// replaced the first rather than appending: the earlier token vanished, taking
+// with it whatever it had marked hop-by-hop, and a "close" written that way
+// stopped closing the connection.
+func Test_HTTPMiddleware_JoinsRepeatedConnectionValues(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name      string
+		want      string
+		write     []string
+		wantClose bool
+	}{
+		{name: "token list", write: []string{"keep-alive", "X-Internal"}, want: "keep-alive, X-Internal"},
+		// Where "close" is among the tokens the flag wins, since fasthttp holds
+		// one or the other and the server reads only the flag. Peek answers
+		// "close" once it is set, so the other tokens go — the alternative was a
+		// connection the client asked to close being kept open.
+		{name: "close first", write: []string{"close", "X-Internal"}, want: "close", wantClose: true},
+		{name: "close last", write: []string{"X-Internal", "close"}, want: "close", wantClose: true},
+		{name: "close cased", write: []string{"X-Internal", "CLOSE"}, want: "close", wantClose: true},
+		{name: "close alone still closes", write: []string{"close"}, want: "close", wantClose: true},
+		{name: "single entry is unchanged", write: []string{"keep-alive"}, want: "keep-alive"},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var got string
+			var gotClose bool
+
+			app := fiber.New()
+			app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+					r.Header[http.CanonicalHeaderKey(fiber.HeaderConnection)] = tc.write
+					next.ServeHTTP(w, r)
+				})
+			}))
+			app.Get("/", func(c fiber.Ctx) error {
+				got = c.Get(fiber.HeaderConnection)
+				gotClose = c.Request().Header.ConnectionClose()
+				return c.SendString("ok")
+			})
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+			require.Equal(t, tc.want, got)
+			require.Equal(t, tc.wantClose, gotClose)
+		})
+	}
+}
diff --git a/middleware/cache/cache_security_test.go b/middleware/cache/cache_security_test.go
index ec91cf4ae2b..de8cbaeafb2 100644
--- a/middleware/cache/cache_security_test.go
+++ b/middleware/cache/cache_security_test.go
@@ -1,6 +1,8 @@
 package cache
 
 import (
+	"bufio"
+	"context"
 	"crypto/sha256"
 	"encoding/hex"
 	"fmt"
@@ -14,7 +16,9 @@ import (
 	"time"
 
 	"github.com/gofiber/fiber/v3"
+	"github.com/gofiber/fiber/v3/internal/storage/memory"
 	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
 )
 
 // Test_Cache_Security_DoS_ExcessiveQueryParams tests protection against DoS via excessive query parameters
@@ -441,6 +445,246 @@ func Test_Cache_Security_MultiDimensionInjection(t *testing.T) {
 	require.Equal(t, len(testCases), count, "All test cases should create distinct cache entries")
 }
 
+// Test_Cache_Security_KeyHeaderRepeatedFieldLines asserts that every field line
+// of a key header reaches the cache key.
+//
+// A name may arrive on more than one line, and that is equivalent to the
+// comma-joined form on the wire (RFC 9110 Section 5.2). The key used to hash
+// only the first line, so a request sending the header twice keyed identically
+// to one sending just that first value — and got served its cached response.
+func Test_Cache_Security_KeyHeaderRepeatedFieldLines(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Expiration: 1 * time.Hour,
+		KeyHeaders: []string{"X-Tenant"},
+	}))
+	app.Get("/", func(c fiber.Ctx) error {
+		values := c.Request().Header.PeekAll("X-Tenant")
+		parts := make([]string, 0, len(values))
+		for _, v := range values {
+			parts = append(parts, string(v)+";")
+		}
+		return c.SendString("tenant:" + strings.Join(parts, ""))
+	})
+
+	do := func(lines ...string) (body, cacheStatus string) { //nolint:nonamedreturns // names document the pair
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.SetMethod(fiber.MethodGet)
+		req.SetRequestURI("/")
+		req.SetHost("example.com")
+		for _, l := range lines {
+			req.Header.Add("X-Tenant", l)
+		}
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	body, status := do("public", "acme-private")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "tenant:public;acme-private;", body)
+
+	body, status = do("public")
+	require.Equal(t, cacheMiss, status, "the single-line request must not hit the two-line entry")
+	require.Equal(t, "tenant:public;", body)
+
+	// The header being absent is also its own variant, not the same as one
+	// present with an empty value.
+	_, status = do()
+	require.Equal(t, cacheMiss, status)
+	_, status = do("")
+	require.Equal(t, cacheMiss, status, "an empty value must not key like an absent header")
+
+	// Each variant still caches on its own key.
+	body, status = do("public", "acme-private")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "tenant:public;acme-private;", body)
+
+	body, status = do("public")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "tenant:public;", body)
+}
+
+// Test_Cache_Security_MultiLineResponseHeaders asserts that the directives
+// deciding cacheability are read from every field line, not just the first.
+//
+// Repeated field lines are equivalent to the comma-joined form on the wire
+// (RFC 9110 Section 5.2), so a "Vary: X-Tenant", a "Vary: *" or a
+// "Cache-Control: no-store" on a second line binds exactly as much as one on
+// the first. Reading only the first line dropped them: the Vary case served one
+// tenant's response to another, and the other two cached a response the origin
+// had said not to store.
+func Test_Cache_Security_MultiLineResponseHeaders(t *testing.T) {
+	t.Parallel()
+
+	newApp := func(decorate func(c fiber.Ctx)) *fiber.App {
+		app := fiber.New()
+		app.Use(New(Config{Expiration: time.Hour}))
+		app.Get("/", func(c fiber.Ctx) error {
+			decorate(c)
+			return c.SendString("tenant:" + c.Get("X-Tenant"))
+		})
+		return app
+	}
+
+	do := func(app *fiber.App, tenant string) (body, cacheStatus string) { //nolint:nonamedreturns // names document the pair
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.SetMethod(fiber.MethodGet)
+		req.SetRequestURI("/")
+		req.SetHost("example.com")
+		req.Header.Set("X-Tenant", tenant)
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	t.Run("vary on a later line still partitions", func(t *testing.T) {
+		t.Parallel()
+
+		app := newApp(func(c fiber.Ctx) {
+			c.Response().Header.Add(fiber.HeaderVary, fiber.HeaderAcceptEncoding)
+			c.Response().Header.Add(fiber.HeaderVary, "X-Tenant")
+		})
+
+		body, status := do(app, "acme")
+		require.Equal(t, cacheMiss, status)
+		require.Equal(t, "tenant:acme", body)
+
+		body, status = do(app, "globex")
+		require.Equal(t, cacheMiss, status, "a different X-Tenant must not hit acme's entry")
+		require.Equal(t, "tenant:globex", body)
+
+		// Each tenant still caches on its own key.
+		body, status = do(app, "acme")
+		require.Equal(t, cacheHit, status)
+		require.Equal(t, "tenant:acme", body)
+	})
+
+	t.Run("vary star on a later line blocks caching", func(t *testing.T) {
+		t.Parallel()
+
+		app := newApp(func(c fiber.Ctx) {
+			c.Response().Header.Add(fiber.HeaderVary, fiber.HeaderAcceptEncoding)
+			c.Response().Header.Add(fiber.HeaderVary, "*")
+		})
+
+		_, status := do(app, "acme")
+		require.Equal(t, cacheUnreachable, status)
+		body, status := do(app, "globex")
+		require.Equal(t, cacheUnreachable, status)
+		require.Equal(t, "tenant:globex", body)
+	})
+
+	t.Run("no-store on a later line blocks caching", func(t *testing.T) {
+		t.Parallel()
+
+		app := newApp(func(c fiber.Ctx) {
+			c.Response().Header.Add(fiber.HeaderCacheControl, "max-age=600")
+			c.Response().Header.Add(fiber.HeaderCacheControl, "no-store")
+		})
+
+		_, status := do(app, "acme")
+		require.Equal(t, cacheUnreachable, status)
+		body, status := do(app, "globex")
+		require.Equal(t, cacheUnreachable, status)
+		require.Equal(t, "tenant:globex", body)
+	})
+}
+
+// Test_JoinedHeader covers the field-line joiner the cacheability checks read
+// through, including that a value returned for one name survives the PeekAll
+// calls made for the next — those reuse the header's slice-header scratch, not
+// the value bytes it points at.
+func Test_JoinedHeader(t *testing.T) {
+	t.Parallel()
+
+	var h fasthttp.ResponseHeader
+	require.Nil(t, joinedHeader(&h, fiber.HeaderVary, true), "absent header")
+
+	h.Add(fiber.HeaderCacheControl, "no-store")
+	h.Add(fiber.HeaderVary, fiber.HeaderAcceptEncoding)
+	h.Add(fiber.HeaderVary, "X-Tenant")
+
+	cacheControl := joinedHeader(&h, fiber.HeaderCacheControl, true)
+	require.Equal(t, "no-store", string(cacheControl))
+
+	require.Equal(t, "Accept-Encoding,X-Tenant", string(joinedHeader(&h, fiber.HeaderVary, true)))
+	require.Equal(t, "no-store", string(cacheControl), "an earlier result must survive a later PeekAll")
+
+	var req fasthttp.RequestHeader
+	req.Add(fiber.HeaderCacheControl, "max-age=0")
+	req.Add(fiber.HeaderCacheControl, "no-store")
+	require.Equal(t, "max-age=0,no-store", string(joinedHeader(&req, fiber.HeaderCacheControl, true)))
+}
+
+// Test_Cache_Security_CookieKeyedOnEveryFieldLine asserts that a Cookie
+// arriving on more than one field line is keyed on in full.
+//
+// fasthttp answers Cookie from its own store, and what it reports depends on
+// whether that store has been collected: uncollected, Peek returns only the
+// first field line and PeekAll returns them unmerged; collected, both return one
+// merged entry. Reading either directly let a request sending
+//
+//	Cookie: a=1
+//	Cookie: session=<someone>
+//
+// key like one sending just "a=1", so the second client was served the first
+// one's page.
+func Test_Cache_Security_CookieKeyedOnEveryFieldLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour, KeyHeaders: []string{"Cookie"}}))
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendString("page-for:" + c.Cookies("session"))
+	})
+
+	do := func(lines ...string) (body, cacheStatus string) { //nolint:nonamedreturns // names document the pair
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, "Cookie: "+l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	body, status := do("a=1", "session=attacker")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "page-for:attacker", body)
+
+	body, status = do("a=1")
+	require.Equal(t, cacheMiss, status, "a request without the session cookie must not hit that entry")
+	require.Equal(t, "page-for:", body)
+
+	body, status = do("a=1", "session=victim")
+	require.Equal(t, cacheMiss, status, "a different session must not hit the attacker's entry")
+	require.Equal(t, "page-for:victim", body)
+
+	// Each variant still caches on its own key, and the key does not depend on
+	// whether the handler happened to read a cookie first.
+	body, status = do("a=1", "session=attacker")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "page-for:attacker", body)
+
+	body, status = do("a=1", "session=victim")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "page-for:victim", body)
+}
+
 // Test_Cache_Security_BackslashEscaping tests that backslashes are properly escaped
 func Test_Cache_Security_BackslashEscaping(t *testing.T) {
 	t.Parallel()
@@ -733,3 +977,1236 @@ func Test_Cache_Security_QueryBody_CannotInjectAuthorizationSuffix(t *testing.T)
 	require.Equal(t, "handler auth=", string(body))
 	require.Equal(t, int32(2), count.Load())
 }
+
+// Test_VaryCookie_KeyIsStableAcrossCookieCollection pins the reason
+// keyFieldLines forces fasthttp's lazy cookie collection before reading the
+// field lines.
+//
+// The Vary key is built twice per miss: once before the handler runs, and once
+// after, to store under. A handler that reads a cookie triggers collection in
+// between, and collection re-serializes every Cookie line into a single merged
+// entry. Peeking the raw lines on one side of that and the merged entry on the
+// other made the two keys differ, so the entry was stored under a key no lookup
+// would ever produce — every request missed, and each one stranded another
+// entry.
+func Test_VaryCookie_KeyIsStableAcrossCookieCollection(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Response().Header.Set(fiber.HeaderVary, fiber.HeaderCookie)
+		// Reading a cookie is what forces collection mid-request.
+		return c.SendString("page-for:" + c.Cookies("session"))
+	})
+
+	do := func(lines ...string) (string, string) {
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, "Cookie: "+l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	body, status := do("a=1", "session=alice")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "page-for:alice", body)
+
+	body, status = do("a=1", "session=alice")
+	require.Equal(t, cacheHit, status,
+		"the store key and the lookup key must agree across cookie collection")
+	require.Equal(t, "page-for:alice", body)
+
+	// Stability must not have come from keying everything alike: a different
+	// session still parts company, and the merged single-line spelling of the
+	// same cookies reaches the entry the two lines stored.
+	body, status = do("a=1", "session=bob")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "page-for:bob", body)
+
+	body, status = do("a=1; session=alice")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "page-for:alice", body)
+}
+
+// Test_Authorization_SecondFieldLine asserts a credential is seen wherever it
+// sits among the Authorization field lines. Peek returns only the first, so a
+// scan of it alone read an empty first line as "no credential" — and the
+// request would then have been keyed and served as anonymous, handing it
+// whatever the anonymous entry held.
+func Test_Authorization_SecondFieldLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("anonymous body") })
+
+	do := func(lines ...string) string {
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, "Authorization: "+l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	// Prime an anonymous entry.
+	require.Equal(t, cacheMiss, do())
+	require.Equal(t, cacheHit, do())
+
+	// The credential is on the second line. Since this response permits no
+	// shared caching, carrying one means the entry is refused outright — which
+	// only happens if the scan looked past the empty first line.
+	require.Equal(t, cacheUnreachable, do("", "Bearer alice"),
+		"a credential on a later field line must not be read as anonymous")
+}
+
+// Test_AuthorizationHash_CoversEveryFieldLine asserts the value hashed into the
+// key is the whole comma-joined credential. Hashing only the first field line
+// put two principals that share it in the same partition, so one read the
+// other's response.
+func Test_AuthorizationHash_CoversEveryFieldLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error {
+		// Opt in to shared caching so an authorized response is stored at all,
+		// which is what lets the key partition be observed.
+		c.Set(fiber.HeaderCacheControl, "public")
+		// Echo the last field line so the body shows which principal the
+		// handler ran for. Indexed defensively: a single-line case added later
+		// should fail the assertion, not panic here.
+		lines := c.Request().Header.PeekAll(fiber.HeaderAuthorization)
+		last := ""
+		if len(lines) > 0 {
+			last = string(lines[len(lines)-1])
+		}
+		return c.SendString("body for:" + last)
+	})
+
+	do := func(lines ...string) (string, string) {
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, "Authorization: "+l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	// Both principals share the first field line and differ only on the second.
+	body, status := do("Bearer shared", "Bearer alice")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "body for:Bearer alice", body)
+
+	body, status = do("Bearer shared", "Bearer alice")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "body for:Bearer alice", body)
+
+	body, status = do("Bearer shared", "Bearer bob")
+	require.Equal(t, cacheMiss, status,
+		"principals differing only on a later field line must not share a partition")
+	require.Equal(t, "body for:Bearer bob", body)
+}
+
+// Test_RequestPragma_SecondFieldLine asserts the RFC 9111 §5.4 no-cache
+// fallback is honored on a repeated Pragma line, not only the first.
+func Test_RequestPragma_SecondFieldLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("body") })
+
+	do := func(lines ...string) string {
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, "Pragma: "+l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	require.Equal(t, cacheMiss, do())
+	require.Equal(t, cacheHit, do())
+	require.Equal(t, cacheMiss, do("token", "no-cache"),
+		"no-cache on a later Pragma line must still force revalidation")
+}
+
+// Test_StoreResponseHeaders_DropsTrailer pins the hop-by-hop header's real
+// name. The list said "Trailers", which is not a header, so the actual Trailer
+// field was stored and replayed — announcing to every later client a trailer
+// that only the connection it came from ever sent.
+func Test_StoreResponseHeaders_DropsTrailer(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour, StoreResponseHeaders: true}))
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Response().Header.Set("Trailer", "Expires")
+		c.Response().Header.Set("X-Keep", "kept")
+		return c.SendString("hi")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+	require.Empty(t, resp.Header.Values("Trailer"))
+	// A stored header that is not hop-by-hop still comes back, so the assertion
+	// above is about Trailer and not about header storage being off.
+	require.Equal(t, "kept", resp.Header.Get("X-Keep"))
+}
+
+// Test_SetCookie2ResponseIsNotStored covers the obsolete RFC 2965 spelling.
+// fasthttp does not route it into its cookie store, so h.Cookies() alone does
+// not see it and the response would have been stored and shared.
+func Test_SetCookie2ResponseIsNotStored(t *testing.T) {
+	t.Parallel()
+
+	var calls atomic.Int32
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error {
+		n := calls.Add(1)
+		c.Response().Header.Set("Set-Cookie2", fmt.Sprintf(`session="secret-%d"; Version="1"`, n))
+		return c.SendString(fmt.Sprintf("page-for-client-%d", n))
+	})
+
+	for i := 1; i <= 2; i++ {
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.Equal(t, fmt.Sprintf("page-for-client-%d", i), string(body))
+	}
+	require.Equal(t, int32(2), calls.Load())
+}
+
+// Test_joinKeyHeaderValues_Framing asserts the length prefixes keep the join
+// injective. It is what stops two different field-line splits of the same bytes
+// from digesting alike once a dimension is too long to store verbatim, and a
+// plain concatenation would collide on the first pair below.
+func Test_joinKeyHeaderValues_Framing(t *testing.T) {
+	t.Parallel()
+
+	join := func(values ...string) string {
+		b := make([][]byte, len(values))
+		for i, v := range values {
+			b[i] = []byte(v)
+		}
+		return string(joinKeyHeaderValues(b))
+	}
+
+	require.NotEqual(t, join("ab"), join("a", "b"))
+	require.NotEqual(t, join("a", "bc"), join("ab", "c"))
+	require.NotEqual(t, join(""), join(), "absent and present-empty are different")
+	require.NotEqual(t, join("", ""), join(""))
+	// A value that spells its own framing cannot forge a boundary.
+	require.NotEqual(t, join("\x01a\x01b"), join("a", "b"))
+	// The encoding itself: a uvarint length before each value, which is what
+	// makes the boundaries readable and so the join injective.
+	require.Equal(t, "\x01a\x01b", join("a", "b"))
+}
+
+// Test_VaryContentType_KeyIsStableAcrossTheFormFold pins that a Vary'd
+// Content-Type keys the same before and after the handler runs.
+//
+// The key is built twice per miss — once to look an entry up, once to store it
+// — and the form accessors lowercase the request's own Content-Type in place in
+// between. Reading whatever spelling arrived on one side and the folded value
+// on the other stored each entry under a key no lookup would produce, so a
+// route with "Vary: Content-Type" missed on every second request and stranded
+// an entry each time.
+func Test_VaryContentType_KeyIsStableAcrossTheFormFold(t *testing.T) {
+	t.Parallel()
+
+	for _, spelling := range []string{
+		"Application/X-WWW-Form-Urlencoded",
+		"application/x-www-form-urlencoded",
+		"Multipart/Form-Data; BOUNDARY=AbC",
+	} {
+		t.Run(spelling, func(t *testing.T) {
+			t.Parallel()
+
+			var calls atomic.Int32
+			app := fiber.New()
+			app.Use(New(Config{
+				Expiration: time.Hour,
+				Methods:    []string{fiber.MethodGet, fiber.MethodPost},
+			}))
+			app.Post("/", func(c fiber.Ctx) error {
+				calls.Add(1)
+				c.Response().Header.Set(fiber.HeaderVary, fiber.HeaderContentType)
+				// Reading a form value is what folds the header mid-request.
+				return c.SendString("v=" + c.FormValue("a"))
+			})
+
+			do := func() string {
+				req := httptest.NewRequest(fiber.MethodPost, "/", strings.NewReader("a=1"))
+				req.Header.Set(fiber.HeaderContentType, spelling)
+				resp, err := app.Test(req)
+				require.NoError(t, err)
+				return resp.Header.Get("X-Cache")
+			}
+
+			require.Equal(t, cacheMiss, do())
+			require.Equal(t, cacheHit, do(), "the store key and the lookup key must agree across the fold")
+			require.Equal(t, cacheHit, do())
+			require.Equal(t, int32(1), calls.Load())
+		})
+	}
+}
+
+// Test_Vary_PartitionsWithoutHeaderNormalizing asserts a Vary'd dimension keys
+// the same whether or not fasthttp normalizes header names.
+//
+// PeekAll compares stored keys byte for byte. With DisableHeaderNormalizing the
+// store keeps the spelling the client sent, while the names reaching the key
+// come lower-cased from parseVary — so every lookup missed and the dimension
+// dropped out of the key silently. A request sending application/json was then
+// served the entry stored for a form.
+func Test_Vary_PartitionsWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	for _, disable := range []bool{false, true} {
+		t.Run(fmt.Sprintf("DisableHeaderNormalizing=%v", disable), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: disable})
+			app.Use(New(Config{
+				Expiration: time.Hour,
+				Methods:    []string{fiber.MethodGet, fiber.MethodPost},
+			}))
+			app.Post("/", func(c fiber.Ctx) error {
+				c.Response().Header.Set(fiber.HeaderVary, fiber.HeaderContentType)
+				return c.SendString("body-for:" + c.Get(fiber.HeaderContentType))
+			})
+
+			do := func(ct string) (string, string) {
+				req := httptest.NewRequest(fiber.MethodPost, "/", strings.NewReader("a=1"))
+				req.Header.Set(fiber.HeaderContentType, ct)
+				resp, err := app.Test(req)
+				require.NoError(t, err)
+				body, err := io.ReadAll(resp.Body)
+				require.NoError(t, err)
+				return string(body), resp.Header.Get("X-Cache")
+			}
+
+			body, status := do("application/x-www-form-urlencoded")
+			require.Equal(t, cacheMiss, status)
+			require.Equal(t, "body-for:application/x-www-form-urlencoded", body)
+
+			body, status = do("application/json")
+			require.Equal(t, cacheMiss, status, "a different Content-Type must not hit the form entry")
+			require.Equal(t, "body-for:application/json", body)
+
+			body, status = do("application/json")
+			require.Equal(t, cacheHit, status)
+			require.Equal(t, "body-for:application/json", body)
+		})
+	}
+}
+
+// Test_KeyHeaders_PartitionWithoutHeaderNormalizing is the same property for a
+// dimension named by KeyHeaders rather than by the response's Vary.
+func Test_KeyHeaders_PartitionWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	for _, disable := range []bool{false, true} {
+		t.Run(fmt.Sprintf("DisableHeaderNormalizing=%v", disable), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: disable})
+			app.Use(New(Config{Expiration: time.Hour, KeyHeaders: []string{"X-Tenant"}}))
+			app.Get("/", func(c fiber.Ctx) error {
+				return c.SendString("body-for:" + c.Get("X-Tenant"))
+			})
+
+			do := func(tenant string) (string, string) {
+				req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+				req.Header.Set("X-Tenant", tenant)
+				resp, err := app.Test(req)
+				require.NoError(t, err)
+				body, err := io.ReadAll(resp.Body)
+				require.NoError(t, err)
+				return string(body), resp.Header.Get("X-Cache")
+			}
+
+			body, status := do("acme")
+			require.Equal(t, cacheMiss, status)
+			require.Equal(t, "body-for:acme", body)
+
+			body, status = do("beta")
+			require.Equal(t, cacheMiss, status, "a different tenant must not hit the first one's entry")
+			require.Equal(t, "body-for:beta", body)
+
+			body, status = do("acme")
+			require.Equal(t, cacheHit, status)
+			require.Equal(t, "body-for:acme", body)
+		})
+	}
+}
+
+// Test_CachedRedirectKeepsItsLocation asserts a cached 3xx is replayed with
+// somewhere to go.
+//
+// 300 and 301 are cacheable statuses, but with the default
+// StoreResponseHeaders:false only the body, status, Content-Type and
+// Content-Encoding were kept — so the first client got "301 Location: /new" and
+// every client after it a bare 301 it could not follow.
+func Test_CachedRedirectKeepsItsLocation(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/old", func(c fiber.Ctx) error {
+		c.Set("X-Extra", "not-stored")
+		return c.Redirect().Status(fiber.StatusMovedPermanently).To("/new")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/old", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
+	require.Equal(t, "/new", resp.Header.Get("Location"))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/old", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
+	require.Equal(t, "/new", resp.Header.Get("Location"), "a cached redirect must keep its destination")
+	// Only the destination is kept, not response headers at large — that is
+	// still what StoreResponseHeaders is for.
+	require.Empty(t, resp.Header.Get("X-Extra"))
+}
+
+// Test_Authorization_DetectedWithoutHeaderNormalizing asserts a credential is
+// seen whatever case its field name arrived in.
+//
+// hasAuthorization and the auth hash read the header by its canonical name,
+// which fasthttp answers only while it normalizes what it stored. With
+// DisableHeaderNormalizing an "authorization:" sent in lower case matched
+// nothing, so the request read as anonymous: its response was stored in the
+// anonymous partition and replayed to the next client that asked, bearer token
+// and all.
+func Test_Authorization_DetectedWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error {
+		// With normalizing off a handler reads the name as it arrived.
+		if tok := c.Get("authorization"); tok != "" {
+			return c.SendString("PRIVATE for " + tok)
+		}
+		return c.SendString("PUBLIC")
+	})
+
+	do := func(header string) (string, string) {
+		raw := "GET / HTTP/1.1\r\nHost: example.com\r\n"
+		if header != "" {
+			raw += header + "\r\n"
+		}
+		raw += "\r\n"
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.DisableNormalizing()
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	body, status := do("authorization: Bearer alice-secret")
+	require.Equal(t, cacheUnreachable, status, "an authorized response must not enter the shared store")
+	require.Equal(t, "PRIVATE for Bearer alice-secret", body)
+
+	body, status = do("")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "PUBLIC", body, "an anonymous request must not be served the authorized response")
+
+	body, status = do("")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "PUBLIC", body)
+}
+
+// Test_RequestDirectives_HonoredWithoutHeaderNormalizing covers the same
+// lookup for the request directives, which are read the same way: a lower-case
+// "cache-control: no-store" was ignored outright.
+func Test_RequestDirectives_HonoredWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("body") })
+
+	do := func(header string) string {
+		raw := "GET / HTTP/1.1\r\nHost: example.com\r\n"
+		if header != "" {
+			raw += header + "\r\n"
+		}
+		raw += "\r\n"
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.DisableNormalizing()
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	require.Equal(t, cacheMiss, do(""))
+	require.Equal(t, cacheHit, do(""))
+	require.Empty(t, do("cache-control: no-store"), "no-store must be honored whatever case it arrived in")
+	require.Equal(t, cacheMiss, do("cache-control: no-cache"), "no-cache must force revalidation")
+}
+
+// Test_Authorization_MixedCaseFieldLines closes the other half of the
+// case-insensitive lookup.
+//
+// Falling back to a case-insensitive walk only when the byte-for-byte lookup
+// came back empty was not enough: with DisableHeaderNormalizing a request can
+// send both spellings, and an empty canonical "Authorization:" line satisfies
+// the fast path, so the credential on the lowercase line beside it was never
+// looked at. The request read as anonymous and its private response was stored
+// in the anonymous partition.
+func Test_Authorization_MixedCaseFieldLines(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{Expiration: time.Hour}))
+	app.Get("/", func(c fiber.Ctx) error {
+		tok := c.Get("Authorization")
+		if tok == "" {
+			tok = c.Get("authorization")
+		}
+		if tok == "" {
+			return c.SendString("PUBLIC")
+		}
+		return c.SendString("PRIVATE for " + tok)
+	})
+
+	do := func(lines ...string) (string, string) {
+		parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+		for _, l := range lines {
+			parts = append(parts, l+"\r\n")
+		}
+		raw := strings.Join(append(parts, "\r\n"), "")
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.DisableNormalizing()
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	// The canonical line is present but empty, so the byte-for-byte lookup
+	// succeeds and would have stopped there.
+	body, status := do("Authorization:", "authorization: Bearer alice")
+	require.Equal(t, cacheUnreachable, status, "the credential on the second spelling must still be seen")
+	require.Equal(t, "PRIVATE for Bearer alice", body)
+
+	body, status = do()
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "PUBLIC", body, "an anonymous request must not be served the authorized response")
+}
+
+// Test_Cache_NonCanonicalResponseNamesAreNotDuplicated checks that the fields
+// this middleware writes from an entry are not emitted a second time beside the
+// spelling the handler chose for them.
+//
+// Under DisableHeaderNormalizing the stored key is whatever the handler wrote,
+// so a byte-for-byte lookup found neither the value to honor nor the line to
+// replace. Every field then went out twice, and the second Cache-Control was
+// the "public" this middleware synthesizes on a hit when it believes the
+// response carries none — telling a downstream shared cache it may store and
+// share a response whose origin never said so.
+func Test_Cache_NonCanonicalResponseNamesAreNotDuplicated(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+			app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+			app.Get("/", func(c fiber.Ctx) error {
+				// Lower case throughout, which is legal on the wire and is what
+				// DisableHeaderNormalizing preserves.
+				c.Response().Header.Set("cache-control", "max-age=60")
+				c.Response().Header.Set("age", "0")
+				c.Response().Header.Set("etag", `"v1"`)
+				c.Response().Header.Set("expires", "Wed, 21 Oct 2099 07:28:00 GMT")
+				c.Response().Header.Set("date", "Wed, 21 Oct 2020 07:28:00 GMT")
+				return c.SendString("body")
+			})
+
+			single := []string{
+				fiber.HeaderCacheControl,
+				fiber.HeaderAge,
+				fiber.HeaderETag,
+				fiber.HeaderExpires,
+				fiber.HeaderDate,
+			}
+
+			for _, want := range []string{cacheMiss, cacheHit} {
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, want, resp.Header.Get("X-Cache"))
+
+				for _, name := range single {
+					require.Len(t, resp.Header.Values(name), 1,
+						"%s must be sent on exactly one field line (%s): %v",
+						name, want, resp.Header.Values(name))
+				}
+
+				// The origin said max-age, never public. Synthesizing one is
+				// what lifts RFC 9111 Section 3.5 for a downstream shared cache.
+				require.NotContains(t, resp.Header.Get(fiber.HeaderCacheControl), "public",
+					"the handler's Cache-Control must be the one that goes out (%s)", want)
+			}
+		})
+	}
+}
+
+// Test_Cache_NonCanonicalResponseNamesAreHonored checks that the values behind
+// those spellings still decide what they are supposed to decide, whichever
+// spelling the handler used.
+func Test_Cache_NonCanonicalResponseNamesAreHonored(t *testing.T) {
+	t.Parallel()
+
+	// Each case asserts the same outcome under both header-name settings: the
+	// spelling a handler picks is not allowed to change what the cache does.
+	tests := []struct {
+		handler  fiber.Handler
+		assert   func(t *testing.T, resp *http.Response)
+		name     string
+		statuses []string
+	}{
+		{
+			name: "a cached redirect keeps its destination",
+			handler: func(c fiber.Ctx) error {
+				c.Status(fiber.StatusMovedPermanently)
+				c.Response().Header.Set("location", "/new")
+				return nil
+			},
+			statuses: []string{cacheMiss, cacheHit},
+			assert: func(t *testing.T, resp *http.Response) {
+				t.Helper()
+				require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
+				require.Equal(t, "/new", resp.Header.Get(fiber.HeaderLocation))
+			},
+		},
+		{
+			// Stale on arrival, so there is nothing worth storing. Missing the
+			// header meant storing it for the configured minute instead.
+			name: "an Expires in the past is not stored",
+			handler: func(c fiber.Ctx) error {
+				c.Response().Header.Set("expires", "Wed, 21 Oct 2020 07:28:00 GMT")
+				return c.SendString("body")
+			},
+			statuses: []string{cacheUnreachable, cacheUnreachable},
+			assert: func(t *testing.T, resp *http.Response) {
+				t.Helper()
+				require.Equal(t, "Wed, 21 Oct 2020 07:28:00 GMT", resp.Header.Get(fiber.HeaderExpires))
+			},
+		},
+		{
+			// no-store is a refusal to keep the response at all.
+			name: "no-store is obeyed",
+			handler: func(c fiber.Ctx) error {
+				c.Response().Header.Set("cache-control", "no-store")
+				return c.SendString("body")
+			},
+			statuses: []string{cacheUnreachable, cacheUnreachable},
+			assert:   func(_ *testing.T, _ *http.Response) {},
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			for _, normalize := range []bool{true, false} {
+				app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+				app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+				app.Get("/", tc.handler)
+
+				for _, want := range tc.statuses {
+					resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+					require.NoError(t, err)
+					require.Equal(t, want, resp.Header.Get("X-Cache"), "normalize=%v", normalize)
+					tc.assert(t, resp)
+				}
+			}
+		})
+	}
+}
+
+// Test_Cache_OuterMiddlewareHeaderNamesAreNotDuplicated covers the other side
+// of the same lookup: a middleware that runs before this one has already
+// written to the response by the time a hit is served, so the fields replayed
+// from the entry are written over lines that are there in whatever spelling
+// that middleware chose.
+//
+// Set matches the key byte for byte, so under DisableHeaderNormalizing it
+// appended rather than replaced and the response went out with both — the
+// stored value and a stale copy of the same field, with nothing to say which
+// one a recipient should read.
+func Test_Cache_OuterMiddlewareHeaderNamesAreNotDuplicated(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+			app.Use(func(c fiber.Ctx) error {
+				c.Response().Header.Set("cache-control", "max-age=5")
+				c.Response().Header.Set("etag", `"outer"`)
+				c.Response().Header.Set("expires", "Wed, 21 Oct 2099 07:28:00 GMT")
+				return c.Next()
+			})
+			app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+			app.Get("/", func(c fiber.Ctx) error {
+				return c.SendString("body")
+			})
+
+			for _, want := range []string{cacheMiss, cacheHit} {
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, want, resp.Header.Get("X-Cache"))
+
+				for _, name := range []string{fiber.HeaderCacheControl, fiber.HeaderETag, fiber.HeaderExpires} {
+					require.Len(t, resp.Header.Values(name), 1,
+						"%s must be sent on exactly one field line (%s): %v",
+						name, want, resp.Header.Values(name))
+				}
+			}
+		})
+	}
+}
+
+// Test_Cache_SetCookie2IsSeenWhateverItsCase checks the second cookie header
+// against the same standard as the first.
+//
+// Set-Cookie has a store of its own in fasthttp, which every spelling is routed
+// into, so the guard found it either way. Set-Cookie2 — the obsolete RFC 2965
+// spelling, which hands the client a session just the same — is an ordinary
+// field, so a byte-for-byte lookup found only the canonical one. A handler
+// writing it in lower case had a personalized response stored and replayed to
+// every later client whose request matched the key.
+func Test_Cache_SetCookie2IsSeenWhateverItsCase(t *testing.T) {
+	t.Parallel()
+
+	for _, name := range []string{"Set-Cookie2", "set-cookie2"} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+			app.Use(New(Config{Expiration: time.Minute}))
+
+			var n atomic.Int64
+			app.Get("/", func(c fiber.Ctx) error {
+				id := n.Add(1)
+				c.Response().Header.Set(name, fmt.Sprintf("session=client-%d; Version=1", id))
+				return c.SendString(fmt.Sprintf("private to client-%d", id))
+			})
+
+			for range 2 {
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"),
+					"a response naming a cookie is never stored")
+			}
+			require.Equal(t, int64(2), n.Load(), "each client must reach the handler")
+		})
+	}
+}
+
+// Test_Cache_QuotedDirectiveDoesNotAuthorizeSharing covers a Cache-Control
+// whose extension value is a quoted-string containing commas.
+//
+// The directive scan split on every comma, so the tokens inside the quotes were
+// read as directives of their own. A response saying nothing about sharing was
+// therefore taken to have said "public" — enough to pass the gate that lets a
+// cookie-setting response be stored, after which its body went to later clients
+// with only the cookie removed. RFC 9111 §5.2 makes the value a quoted-string;
+// a comma inside one does not end the directive.
+func Test_Cache_QuotedDirectiveDoesNotAuthorizeSharing(t *testing.T) {
+	t.Parallel()
+
+	for _, cc := range []string{
+		`ext="a, public, b"`,
+		`ext="a, s-maxage=99, b"`,
+		// The escaped quote must not end the value early either, or the scan
+		// resumes inside the string and finds the token after it.
+		`ext="a\", public, b"`,
+	} {
+		t.Run(cc, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Expiration: time.Minute}))
+
+			var n atomic.Int64
+			app.Get("/", func(c fiber.Ctx) error {
+				id := n.Add(1)
+				c.Response().Header.Set(fiber.HeaderCacheControl, cc)
+				c.Response().Header.Set(fiber.HeaderSetCookie, fmt.Sprintf("session=client-%d", id))
+				return c.SendString(fmt.Sprintf("private to client-%d", id))
+			})
+
+			for range 2 {
+				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+				require.NoError(t, err)
+				require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"),
+					"a token inside a quoted extension value does not authorize sharing")
+			}
+			require.Equal(t, int64(2), n.Load(), "each client must reach the handler")
+		})
+	}
+}
+
+// Test_Cache_QuotedDirectiveStillReadsRealOnes is the control for the test
+// above: a quoted value must not hide the directives written beside it.
+func Test_Cache_QuotedDirectiveStillReadsRealOnes(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Minute}))
+
+	var n atomic.Int64
+	app.Get("/", func(c fiber.Ctx) error {
+		id := n.Add(1)
+		c.Response().Header.Set(fiber.HeaderCacheControl, `ext="a, b", public`)
+		c.Response().Header.Set(fiber.HeaderSetCookie, fmt.Sprintf("session=client-%d", id))
+		return c.SendString(fmt.Sprintf("shared-%d", id))
+	})
+
+	first, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, first.Header.Get("X-Cache"))
+
+	second, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, second.Header.Get("X-Cache"),
+		"public written outside the quotes still authorizes sharing")
+	require.Equal(t, int64(1), n.Load())
+}
+
+// Test_Cache_EveryStaleSpellingIsReplaced covers a response that already
+// carries two spellings of a field this middleware writes.
+//
+// Writing through the first one found and stopping there left the other in
+// place, so the value written here went out beside a stale copy of the same
+// field — the pair the write exists to prevent, reached by a response that had
+// already been touched twice before the cache saw it.
+func Test_Cache_EveryStaleSpellingIsReplaced(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	// Two middlewares ahead of the cache, each choosing its own spelling.
+	// Three spellings of each field: the canonical one SetBytesV replaces on its
+	// own, plus two more that only the scan can reach. One is what a loop that
+	// stops at the first match leaves behind.
+	app.Use(func(c fiber.Ctx) error {
+		c.Response().Header.Set("cache-control", "max-age=5")
+		c.Response().Header.Set("etag", `"lower"`)
+		return c.Next()
+	})
+	app.Use(func(c fiber.Ctx) error {
+		c.Response().Header.Add("CACHE-CONTROL", "max-age=7")
+		c.Response().Header.Add("ETAG", `"upper"`)
+		return c.Next()
+	})
+	app.Use(func(c fiber.Ctx) error {
+		c.Response().Header.Add(fiber.HeaderCacheControl, "max-age=6")
+		c.Response().Header.Add(fiber.HeaderETag, `"canonical"`)
+		return c.Next()
+	})
+	app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("body") })
+
+	// The miss carries both lines because both middlewares wrote one and the
+	// cache writes neither on that path — their business, not this one's.
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+
+	// The hit is where this middleware writes them from the entry, and there it
+	// owns the field: one line, whatever spellings it had to replace.
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+
+	for _, name := range []string{fiber.HeaderCacheControl, fiber.HeaderETag} {
+		require.Len(t, resp.Header.Values(name), 1,
+			"%s must be sent on exactly one field line: %v", name, resp.Header.Values(name))
+	}
+}
+
+// Test_Cache_CookieKeyedEntriesStayPerSession pins that a cache keyed on Cookie
+// keeps one entry per session whatever the header-name setting is.
+//
+// The Cookie dimension is read after forcing fasthttp's cookie collection,
+// which moves the field lines out of the general header store — so a
+// case-insensitive walk of that store finds nothing there. It finds them all
+// the same, because the iterator yields the collected cookies separately under
+// the canonical name. Were that not so, every request would hash an empty
+// Cookie dimension and distinct sessions would collapse onto one key, which is
+// one client's private response served to another.
+func Test_Cache_CookieKeyedEntriesStayPerSession(t *testing.T) {
+	t.Parallel()
+
+	for _, mode := range []string{"KeyHeaders", "Vary"} {
+		for _, normalize := range []bool{true, false} {
+			t.Run(fmt.Sprintf("%s/normalize=%v", mode, normalize), func(t *testing.T) {
+				t.Parallel()
+
+				cfg := Config{Expiration: time.Minute}
+				if mode == "KeyHeaders" {
+					cfg.KeyHeaders = []string{fiber.HeaderCookie}
+				}
+
+				app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+				app.Use(New(cfg))
+				app.Get("/", func(c fiber.Ctx) error {
+					if mode == "Vary" {
+						c.Set(fiber.HeaderVary, fiber.HeaderCookie)
+					}
+					return c.SendString("private to " + c.Cookies("sess"))
+				})
+				h := app.Handler()
+
+				do := func(cookieHeader, session string) (string, string) {
+					req := fasthttp.AcquireRequest()
+					defer fasthttp.ReleaseRequest(req)
+					if !normalize {
+						req.Header.DisableNormalizing()
+					}
+					req.Header.SetMethod(fiber.MethodGet)
+					req.SetRequestURI("/")
+					req.Header.SetHost("example.com")
+					req.Header.Set(cookieHeader, "sess="+session)
+
+					ctx := &fasthttp.RequestCtx{}
+					ctx.Init(req, nil, nil)
+					h(ctx)
+					return string(ctx.Response.Body()), string(ctx.Response.Header.Peek("X-Cache"))
+				}
+
+				// alice populates an entry and then reads her own back, so a
+				// miss below means a different key rather than an uncacheable
+				// response.
+				_, _ = do(fiber.HeaderCookie, "alice")
+				body, status := do(fiber.HeaderCookie, "alice")
+				require.Equal(t, cacheHit, status)
+				require.Equal(t, "private to alice", body)
+
+				body, status = do(fiber.HeaderCookie, "bob")
+				require.Equal(t, cacheMiss, status, "bob must not land on alice's entry")
+				require.Equal(t, "private to bob", body)
+
+				// And the same when the name arrives in lower case, which is
+				// what HTTP/2 and HTTP/3 put on the wire.
+				body, status = do("cookie", "carol")
+				require.Equal(t, cacheMiss, status, "carol must not land on an earlier session's entry")
+				require.Equal(t, "private to carol", body)
+
+				body, status = do("cookie", "carol")
+				require.Equal(t, cacheHit, status)
+				require.Equal(t, "private to carol", body)
+			})
+		}
+	}
+}
+
+// Test_Cache_LongHeaderNameIsNotIgnored covers the length guard on the
+// ignore-list lookup. No name this middleware refuses to carry between
+// requests is anywhere near that long, so a longer one is by definition not
+// one of them and must be stored and replayed like any other.
+func Test_Cache_LongHeaderNameIsNotIgnored(t *testing.T) {
+	t.Parallel()
+
+	long := "X-" + strings.Repeat("a", maxIgnoredHeaderLen)
+	require.Greater(t, len(long), maxIgnoredHeaderLen)
+
+	app := fiber.New()
+	app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Set(long, "kept")
+		return c.SendString("body")
+	})
+
+	for _, want := range []string{cacheMiss, cacheHit} {
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, want, resp.Header.Get("X-Cache"))
+		require.Equal(t, "kept", resp.Header.Get(long), "a name too long to be on the list is carried (%s)", want)
+	}
+}
+
+// Test_Cache_ReplayClearsEveryStoredSpelling covers the clear that runs before
+// the stored field lines are appended back.
+//
+// DelBytes matches the stored key byte for byte, so under
+// DisableHeaderNormalizing a line this response already carries under another
+// spelling survived it and the append landed beside it — two lines of one
+// field, which is the pair the clear exists to prevent. The fields the
+// middleware writes from the entry's own slots go through setFieldLine and were
+// already covered; these are the ones replayed from StoreResponseHeaders.
+func Test_Cache_ReplayClearsEveryStoredSpelling(t *testing.T) {
+	t.Parallel()
+
+	// The spelling this middleware sees on the way out varies per request, so
+	// the entry stores one and the response being replayed onto carries
+	// another.
+	var n atomic.Int64
+	spellings := []string{"X-Tenant", "x-tenant", "X-TENANT"}
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(func(c fiber.Ctx) error {
+		c.Response().Header.Set(spellings[n.Add(1)%int64(len(spellings))], "from-middleware")
+		return c.Next()
+	})
+	app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("body") })
+
+	for _, want := range []string{cacheMiss, cacheHit, cacheHit} {
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, want, resp.Header.Get("X-Cache"))
+		require.Len(t, resp.Header.Values("X-Tenant"), 1,
+			"one field line whatever spelling each hop chose (%s): %v", want, resp.Header.Values("X-Tenant"))
+	}
+}
+
+// Test_Cache_AuthorizationFieldLinesFramed covers the framing of the
+// Authorization value that goes into the key.
+//
+// Joining field lines with a comma renders "Bearer a,Bearer b" the same whether
+// it arrived as one line or as two, and this middleware treats a second line as
+// a second credential, so the two layouts shared a partition: with a response
+// opting into shared caching, the single-line request was served the two-line
+// request's body.
+func Test_Cache_AuthorizationFieldLinesFramed(t *testing.T) {
+	t.Parallel()
+
+	var handlerRuns atomic.Int64
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Minute}))
+	app.Get("/", func(c fiber.Ctx) error {
+		handlerRuns.Add(1)
+		c.Set(fiber.HeaderCacheControl, "public, max-age=60")
+		return c.SendString(c.Get(fiber.HeaderAuthorization))
+	})
+
+	twoLines := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	twoLines.Header.Add(fiber.HeaderAuthorization, "Bearer shared")
+	twoLines.Header.Add(fiber.HeaderAuthorization, "Bearer alice")
+	resp, err := app.Test(twoLines)
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+
+	oneLine := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	oneLine.Header.Set(fiber.HeaderAuthorization, "Bearer shared,Bearer alice")
+	resp, err = app.Test(oneLine)
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"),
+		"a lone comma-joined credential must not land on the two-line entry")
+	require.Equal(t, int64(2), handlerRuns.Load(), "each layout is its own principal")
+}
+
+// Test_Cache_LegacyStoredSetCookieIsUnsafe covers an entry left by a version
+// that stored Set-Cookie among the response headers.
+//
+// The body beside that cookie is personalized for whoever caused the miss, so
+// omitting only the cookie on replay still hands that body to everyone matching
+// the key. The entry is dropped instead.
+func Test_Cache_LegacyStoredSetCookieIsUnsafe(t *testing.T) {
+	t.Parallel()
+
+	store := memory.New()
+	var handlerRuns atomic.Int64
+	app := fiber.New()
+	app.Use(New(Config{
+		Storage:              store,
+		StoreResponseHeaders: true,
+		Expiration:           time.Minute,
+		KeyGenerator:         func(_ fiber.Ctx) string { return "k" },
+	}))
+	app.Get("/", func(c fiber.Ctx) error {
+		handlerRuns.Add(1)
+		return c.SendString("alice-only")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+
+	// Rewrite the stored entry the way the older version left it.
+	key := cacheKeyVersion + "|GET|k"
+	m := newManager(store, false)
+	e, err := m.get(context.Background(), key)
+	require.NoError(t, err)
+	require.NotNil(t, e)
+	e.headers = append(e.headers, cachedHeader{
+		key:   []byte(fiber.HeaderSetCookie),
+		value: []byte("session=alice; Path=/"),
+	})
+	require.NoError(t, m.set(context.Background(), key, e, time.Minute))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"),
+		"an entry carrying a cookie is not replayed")
+	require.Equal(t, int64(2), handlerRuns.Load(), "the handler answers instead")
+	require.Empty(t, resp.Header.Get(fiber.HeaderSetCookie), "and the stored cookie goes nowhere")
+}
+
+// Test_Cache_ProxiedResponseCasingIsRead covers a response whose field names the
+// app config does not describe.
+//
+// A proxy hands c.Response() to an outbound fasthttp.Client, and fasthttp stamps
+// that client's DisableHeaderNamesNormalizing onto the response it parses into.
+// A default-normalizing app can therefore hold a lower-case "cache-control:
+// private" — which, read byte-exact, cached one client's body and replayed it to
+// the next under a synthesized "public, max-age".
+func Test_Cache_ProxiedResponseCasingIsRead(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name      string
+		directive string
+	}{
+		{"private", "private"},
+		{"no-store", "no-store"},
+		{"no-cache", "no-cache"},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var handlerRuns atomic.Int64
+			app := fiber.New()
+			app.Use(New(Config{StoreResponseHeaders: true, Expiration: time.Minute}))
+			app.Get("/", func(c fiber.Ctx) error {
+				handlerRuns.Add(1)
+				// What the outbound client left behind, without the round trip.
+				c.Response().Header.DisableNormalizing()
+				c.Response().Header.Set("cache-control", tc.directive)
+				return c.SendString("secret-for-" + c.Get("X-User"))
+			})
+
+			for _, user := range []string{"alice", "bob"} {
+				req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+				req.Header.Set("X-User", user)
+				resp, err := app.Test(req)
+				require.NoError(t, err)
+
+				body, err := io.ReadAll(resp.Body)
+				require.NoError(t, err)
+				require.Equal(t, "secret-for-"+user, string(body), "each client gets its own body")
+				require.Equal(t, tc.directive, resp.Header.Get(fiber.HeaderCacheControl),
+					"the restriction the origin sent survives")
+			}
+			require.Equal(t, int64(2), handlerRuns.Load(), "nothing was cached")
+		})
+	}
+}
+
+// Test_Cache_LegacyAnonymousEntryIsNotRead covers an entry a previous version
+// stored. It detected Authorization byte-exactly, so under DisableHeaderNormalizing
+// a request bearing a lower-case "authorization" was taken for anonymous and its
+// response cached under the anonymous key. Only lookups that carry the header
+// moved to a partition of their own, so on a store that survived the upgrade an
+// anonymous request would still find that entry and be served the authenticated
+// body. The key namespace is versioned so no such entry is ever read.
+func Test_Cache_LegacyAnonymousEntryIsNotRead(t *testing.T) {
+	t.Parallel()
+
+	storage := memory.New()
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{
+		Storage:    storage,
+		Expiration: time.Minute,
+		KeyGenerator: func(c fiber.Ctx) string {
+			// A custom generator, as an application preserving the old key format
+			// across the upgrade would have.
+			return c.Path()
+		},
+	}))
+	app.Get("/me", func(c fiber.Ctx) error { return c.SendString("handler ran") })
+
+	// Seed what the previous version wrote for alice: the anonymous key, holding
+	// her authenticated body.
+	legacy := &item{
+		body:      []byte("alice's private page"),
+		ctype:     []byte(fiber.MIMETextPlainCharsetUTF8),
+		status:    fiber.StatusOK,
+		exp:       uint64(time.Now().Add(time.Minute).Unix()),
+		ttl:       uint64(time.Minute / time.Second),
+		headers:   nil,
+		cencoding: nil,
+	}
+	raw, err := legacy.MarshalMsg(nil)
+	require.NoError(t, err)
+	require.NoError(t, storage.Set("GET|/me", raw, time.Minute))
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/me", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "handler ran", string(body), "the legacy anonymous entry must not be served")
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+}
diff --git a/middleware/cache/cache_test.go b/middleware/cache/cache_test.go
index f1bcd88a3b6..810f873acdf 100644
--- a/middleware/cache/cache_test.go
+++ b/middleware/cache/cache_test.go
@@ -268,7 +268,7 @@ func TestCacheStorageGetError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["get|GET|/|q=|h=accept:|accept-encoding:|accept-language:"] = errors.New("boom")
+	storage.errs["get|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -294,7 +294,7 @@ func TestCacheStorageSetError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["set|GET|/|q=|h=accept:|accept-encoding:|accept-language:_body"] = errors.New("boom")
+	storage.errs["set|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -320,14 +320,14 @@ func TestCacheStorageDeleteError(t *testing.T) {
 	t.Parallel()
 
 	storage := newFailingCacheStorage()
-	storage.errs["del|GET|/|q=|h=accept:|accept-encoding:|accept-language:"] = errors.New("boom")
+	storage.errs["del|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	// Use an obviously expired timestamp without relying on time-based conversions
 	expired := &item{exp: 1}
 	raw, err := expired.MarshalMsg(nil)
 	require.NoError(t, err)
 
-	storage.data["GET|/|q=|h=accept:|accept-encoding:|accept-language:"] = raw
+	storage.data[cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = raw
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -409,8 +409,8 @@ func TestCacheEvictionPropagatesRequestContextToDelete(t *testing.T) {
 	}
 
 	require.ElementsMatch(t, []string{
-		"GET|/first|q=|h=accept:|accept-encoding:|accept-language:",
-		"GET|/first|q=|h=accept:|accept-encoding:|accept-language:_body",
+		cacheKeyVersion + "|GET|/first|q=|h=accept:0|accept-encoding:0|accept-language:0",
+		cacheKeyVersion + "|GET|/first|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
 	}, keys)
 }
 
@@ -418,7 +418,7 @@ func TestCacheCleanupPropagatesRequestContextToDelete(t *testing.T) {
 	t.Parallel()
 
 	storage := newContextRecorderStorage()
-	storage.errs["set|GET|/|q=|h=accept:|accept-encoding:|accept-language:"] = errors.New("boom")
+	storage.errs["set|"+cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0"] = errors.New("boom")
 
 	var captured error
 	app := fiber.New(fiber.Config{
@@ -447,7 +447,7 @@ func TestCacheCleanupPropagatesRequestContextToDelete(t *testing.T) {
 
 	records := storage.recordedDeletes()
 	require.Len(t, records, 1)
-	require.Equal(t, "GET|/|q=|h=accept:|accept-encoding:|accept-language:_body", records[0].key)
+	require.Equal(t, cacheKeyVersion+"|GET|/|q=|h=accept:0|accept-encoding:0|accept-language:0_body", records[0].key)
 	require.Equal(t, "cleanup", records[0].value)
 	require.True(t, records[0].canceled)
 }
@@ -499,8 +499,8 @@ func TestCacheStorageOperationsObserveRequestContext(t *testing.T) {
 	require.Len(t, setRecords, 2)
 	for _, rec := range setRecords {
 		require.Contains(t, []string{
-			"GET|/cache|q=|h=accept:|accept-encoding:|accept-language:",
-			"GET|/cache|q=|h=accept:|accept-encoding:|accept-language:_body",
+			cacheKeyVersion + "|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0",
+			cacheKeyVersion + "|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body",
 		}, rec.key)
 		require.Equal(t, "store", rec.value)
 		require.True(t, rec.canceled)
@@ -515,11 +515,11 @@ func TestCacheStorageOperationsObserveRequestContext(t *testing.T) {
 			continue
 		}
 
-		if rec.key == "GET|/cache|q=|h=accept:|accept-encoding:|accept-language:" {
+		if rec.key == cacheKeyVersion+"|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0" {
 			require.True(t, rec.canceled)
 			fetchEntry = true
 		}
-		if rec.key == "GET|/cache|q=|h=accept:|accept-encoding:|accept-language:_body" {
+		if rec.key == cacheKeyVersion+"|GET|/cache|q=|h=accept:0|accept-encoding:0|accept-language:0_body" {
 			require.True(t, rec.canceled)
 			fetchBody = true
 		}
@@ -1383,7 +1383,7 @@ func Test_Cache_DefaultKeyDimensions(t *testing.T) {
 		expectedBoundedPath := "sha256:" + hex.EncodeToString(hash[:])
 		require.Len(t, expectedBoundedPath, len("sha256:")+sha256.Size*2)
 
-		expectedPrefix := fiber.MethodGet + "|" + expectedBoundedPath
+		expectedPrefix := cacheKeyVersion + "|" + fiber.MethodGet + "|" + expectedBoundedPath
 		foundBoundedKey := false
 		for key := range storage.data {
 			require.NotContains(t, key, oversizedPath)
@@ -1653,6 +1653,239 @@ func Test_AdditionalE2EResponseHeaders(t *testing.T) {
 	require.Equal(t, "foobar", resp.Header.Get("X-Foobar"))
 }
 
+// Test_SetCookieResponseIsNotStored asserts that a response handing the client
+// a cookie is not stored at all.
+//
+// The entry would be served to every client whose request matches its key, and
+// a response that sets a cookie has personalized itself for the one client that
+// caused the miss. Keeping Set-Cookie out of the stored headers is not enough —
+// the body is the payload, so the second client below would read the first
+// one's page.
+func Test_SetCookieResponseIsNotStored(t *testing.T) {
+	t.Parallel()
+
+	var calls int
+	app := fiber.New()
+	app.Use(New(Config{StoreResponseHeaders: true}))
+	app.Get("/", func(c fiber.Ctx) error {
+		calls++
+		c.Cookie(&fiber.Cookie{Name: "session", Value: fmt.Sprintf("secret-%d", calls)})
+		return c.SendString(fmt.Sprintf("page-for-client-%d", calls))
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+	require.Contains(t, resp.Header.Get("Set-Cookie"), "session=secret-1")
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "page-for-client-1", string(body))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+	require.Contains(t, resp.Header.Get("Set-Cookie"), "session=secret-2")
+	body, err = io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "page-for-client-2", string(body), "the second client must not read the first one's page")
+	require.Equal(t, 2, calls, "the handler must run for both clients")
+}
+
+// Test_SetCookieResponseRevalidateDirectivesAreNotConsent asserts that
+// must-revalidate and proxy-revalidate do not buy a cookie-setting response a
+// place in the store.
+//
+// RFC 9111 §3.5 lets must-revalidate carry a response to an authorized request,
+// because a cache honoring it goes back to the origin once the entry is stale
+// and the origin re-checks the credential. Neither half of that holds here: the
+// directive says when a stale entry may be reused, not that the body is
+// impersonal, and this middleware never revalidates — it serves the stored body
+// for the whole configured expiration. Reusing the authorization test for the
+// cookie gate therefore handed the first client's page to the second.
+func Test_SetCookieResponseRevalidateDirectivesAreNotConsent(t *testing.T) {
+	t.Parallel()
+
+	for _, directive := range []string{"must-revalidate", "proxy-revalidate"} {
+		t.Run(directive, func(t *testing.T) {
+			t.Parallel()
+
+			var calls int
+			app := fiber.New()
+			app.Use(New(Config{StoreResponseHeaders: true}))
+			app.Get("/", func(c fiber.Ctx) error {
+				calls++
+				c.Set(fiber.HeaderCacheControl, directive)
+				c.Cookie(&fiber.Cookie{Name: "session", Value: fmt.Sprintf("secret-%d", calls)})
+				return c.SendString(fmt.Sprintf("page-for-client-%d", calls))
+			})
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+
+			resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.Equal(t, "page-for-client-2", string(body), "the second client must not read the first one's page")
+			require.Equal(t, 2, calls, "the handler must run for both clients")
+		})
+	}
+}
+
+// Test_SetCookieResponseSharedCacheOptIn asserts the escape hatch still works:
+// a response that says outright a shared cache may hold it is taken at its
+// word, so the gate above is about the revalidate directives specifically and
+// not a blanket refusal of every cookie-setting response.
+func Test_SetCookieResponseSharedCacheOptIn(t *testing.T) {
+	t.Parallel()
+
+	for _, directive := range []string{"public", "s-maxage=60"} {
+		t.Run(directive, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{StoreResponseHeaders: true}))
+			app.Get("/", func(c fiber.Ctx) error {
+				c.Set(fiber.HeaderCacheControl, directive)
+				c.Cookie(&fiber.Cookie{Name: "session", Value: "shared"})
+				return c.SendString("hi")
+			})
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+			// Without this the test passes vacuously: a response carrying no
+			// cookie is stored anyway, so the assertions below would not
+			// distinguish "the opt-in beat the cookie gate" from "there was no
+			// cookie to gate".
+			require.Contains(t, resp.Header.Get("Set-Cookie"), "session=shared")
+
+			resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+			require.Empty(t, resp.Header.Values("Set-Cookie"), "the stored entry must not replay the cookie")
+		})
+	}
+}
+
+// Test_SetCookieFromInnerMiddlewareIsSeen pins the ordering the cookie gate can
+// actually enforce: a middleware that writes its cookie on the way out is seen
+// when it sits inside the cache, because its post-Next work has already run by
+// the time the store decision is made.
+//
+// The reverse order is a hazard the gate cannot see. With the cookie-writing
+// middleware outside, its post-Next work runs after the cache has stored, so
+// the entry is kept and the next client reads the first one's body. Nothing
+// here can detect that — the response the cache inspects genuinely has no
+// cookie on it yet — so it is documented as an ordering requirement in
+// docs/middleware/cache.md rather than asserted as behavior.
+func Test_SetCookieFromInnerMiddlewareIsSeen(t *testing.T) {
+	t.Parallel()
+
+	var calls int
+	app := fiber.New()
+	app.Use(New())
+	app.Use(func(c fiber.Ctx) error {
+		err := c.Next()
+		c.Cookie(&fiber.Cookie{Name: "session", Value: fmt.Sprintf("secret-%d", calls)})
+		return err
+	})
+	app.Get("/", func(c fiber.Ctx) error {
+		calls++
+		return c.SendString(fmt.Sprintf("page-for-client-%d", calls))
+	})
+
+	for i := 1; i <= 2; i++ {
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, cacheUnreachable, resp.Header.Get("X-Cache"))
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.Equal(t, fmt.Sprintf("page-for-client-%d", i), string(body))
+	}
+	require.Equal(t, 2, calls, "the handler must run for both clients")
+}
+
+// Test_StoreResponseHeaders_DropsSetCookie covers the opt-in path: a route that
+// says a shared cache may store the response is taken at its word, and then the
+// stored copy still leaves Set-Cookie out so the entry cannot hand the first
+// client's session to the rest.
+func Test_StoreResponseHeaders_DropsSetCookie(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		StoreResponseHeaders: true,
+	}))
+
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Set(fiber.HeaderCacheControl, "public, max-age=60")
+		c.Cookie(&fiber.Cookie{Name: "session", Value: "first-client-secret"})
+		c.Response().Header.Add("X-Foobar", "foobar")
+		return c.SendString("hi")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+	require.Contains(t, resp.Header.Get("Set-Cookie"), "session=first-client-secret")
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+	require.Empty(t, resp.Header.Values("Set-Cookie"))
+	// Other stored headers still come back, so the assertion above is about
+	// Set-Cookie specifically and not about header storage being off.
+	require.Equal(t, "foobar", resp.Header.Get("X-Foobar"))
+}
+
+// Test_StoreResponseHeaders_KeepsRepeatedFieldLines asserts that a header sent
+// on more than one field line comes back off a cache hit intact.
+//
+// The restore loop used to replay every stored entry with Set, which overwrites
+// the first matching line and leaves the rest — so a name sent twice collapsed
+// to its last value. Two of the headers below are why that matters: a Vary that
+// loses "Cookie" lets a downstream shared cache serve one user's response to
+// another, and a Content-Security-Policy that loses a line drops from the
+// intersection of both policies (what a browser actually enforces) to whichever
+// one is weaker on its own.
+func Test_StoreResponseHeaders_KeepsRepeatedFieldLines(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		StoreResponseHeaders: true,
+	}))
+
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Response().Header.Add("Vary", "Cookie")
+		c.Response().Header.Add("Vary", "Accept-Encoding")
+		c.Response().Header.Add("Content-Security-Policy", "default-src 'none'")
+		c.Response().Header.Add("Content-Security-Policy", "script-src 'self'")
+		c.Response().Header.Add("X-Single", "only")
+		return c.SendString("hi")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+	require.Equal(t, []string{"Cookie", "Accept-Encoding"}, resp.Header.Values("Vary"))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+	require.Equal(t, []string{"Cookie", "Accept-Encoding"}, resp.Header.Values("Vary"))
+	require.Equal(t,
+		[]string{"default-src 'none'", "script-src 'self'"},
+		resp.Header.Values("Content-Security-Policy"),
+	)
+	// A name sent once is still restored once, so the fix did not turn Set into
+	// an unconditional Add.
+	require.Equal(t, []string{"only"}, resp.Header.Values("X-Single"))
+}
+
 func Test_CacheHeader(t *testing.T) {
 	t.Parallel()
 
@@ -2347,7 +2580,7 @@ func Test_CacheInvalidExpiresStoredAsStale(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, "body1", string(body))
 
-	expectedKey := "GET|/|invalid-expires"
+	expectedKey := cacheKeyVersion + "|GET|/|invalid-expires"
 	require.Contains(t, storage.data, expectedKey)
 	require.Contains(t, storage.data, expectedKey+"_body")
 
diff --git a/middleware/cache/coverage_test.go b/middleware/cache/coverage_test.go
index f55867f04dd..76e1098c607 100644
--- a/middleware/cache/coverage_test.go
+++ b/middleware/cache/coverage_test.go
@@ -6,10 +6,12 @@ import (
 	"context"
 	"errors"
 	"math"
+	"strings"
 	"sync"
 	"testing"
 	"time"
 
+	"github.com/gofiber/fiber/v3"
 	"github.com/stretchr/testify/require"
 	"github.com/tinylib/msgp/msgp"
 	"github.com/valyala/fasthttp"
@@ -334,6 +336,26 @@ func Test_allowsSharedCacheDirectives(t *testing.T) {
 	require.False(t, allowsSharedCacheDirectives(responseCacheControl{}))
 }
 
+func Test_allowsSharedCacheStorage(t *testing.T) {
+	t.Parallel()
+
+	require.True(t, allowsSharedCacheStorage(responseCacheControl{hasPublic: true}))
+	require.True(t, allowsSharedCacheStorage(responseCacheControl{sMaxAgeSet: true}))
+	require.False(t, allowsSharedCacheStorage(responseCacheControl{}))
+
+	// The revalidate directives part company with allowsSharedCacheDirectives:
+	// they say when a stale entry may be reused, not that the body is
+	// impersonal, and this middleware never revalidates.
+	require.False(t, allowsSharedCacheStorage(responseCacheControl{mustRevalidate: true}))
+	require.False(t, allowsSharedCacheStorage(responseCacheControl{proxyRevalidate: true}))
+
+	// private wins over an accompanying opt-in. The store path rejects private
+	// well before the cookie gate, so this is the predicate holding its own
+	// contract rather than a reachable branch.
+	require.False(t, allowsSharedCacheStorage(responseCacheControl{hasPrivate: true, hasPublic: true}))
+	require.False(t, allowsSharedCacheStorage(responseCacheControl{hasPrivate: true, sMaxAgeSet: true}))
+}
+
 func Test_secondsConversions_Overflow(t *testing.T) {
 	t.Parallel()
 
@@ -351,10 +373,14 @@ func Test_makeHashAuthFunc(t *testing.T) {
 
 	pool := &sync.Pool{}
 	fn := makeHashAuthFunc(pool)
-	got := fn([]byte("Bearer token"))
+	got := fn([][]byte{[]byte("Bearer token")})
 	require.Len(t, got, hexLen)
 	// Stable for the same input, and uses the pool on the second call.
-	require.Equal(t, got, fn([]byte("Bearer token")))
+	require.Equal(t, got, fn([][]byte{[]byte("Bearer token")}))
+
+	// Length-prefixed, so a split that concatenates to the same bytes does not
+	// land on the same digest.
+	require.NotEqual(t, fn([][]byte{[]byte("ab")}), fn([][]byte{[]byte("a"), []byte("b")}))
 }
 
 func Test_manager_get_StorageErrors(t *testing.T) {
@@ -502,8 +528,99 @@ func Test_makeBuildVaryKeyFunc(t *testing.T) {
 	hdr.Set("Accept", "application/json")
 	hdr.Set("Accept-Encoding", "gzip")
 
-	key := fn([]string{"accept", "accept-encoding"}, &hdr)
+	key := fn([]string{"accept", "accept-encoding"}, &hdr, true)
 	require.Contains(t, key, "|vary|")
 	// Deterministic for the same inputs (also exercises the pooled buffer path).
-	require.Equal(t, key, fn([]string{"accept", "accept-encoding"}, &hdr))
+	require.Equal(t, key, fn([]string{"accept", "accept-encoding"}, &hdr, true))
+}
+
+// Test_makeBuildVaryKeyFunc_RepeatedFieldLines pins that every field line of a
+// Vary'd header reaches the key.
+//
+// A name may arrive on more than one line, and the split is equivalent to the
+// comma-joined form on the wire (RFC 9110 Section 5.2). The key used to hash
+// only the first line, so a request carrying two X-Tenant lines and one
+// carrying just the first shared an entry — the exact cross-request mixing
+// Vary exists to prevent.
+func Test_makeBuildVaryKeyFunc_RepeatedFieldLines(t *testing.T) {
+	t.Parallel()
+
+	fn := makeBuildVaryKeyFunc(&sync.Pool{})
+
+	key := func(values ...string) string {
+		var hdr fasthttp.RequestHeader
+		for _, v := range values {
+			hdr.Add("X-Tenant", v)
+		}
+		return fn([]string{"x-tenant"}, &hdr, true)
+	}
+
+	both := key("public", "acme-private")
+	require.NotEqual(t, both, key("public"), "a dropped field line must change the key")
+	require.NotEqual(t, both, key("acme-private"))
+	require.NotEqual(t, both, key(), "an absent header must not key like a present one")
+	// Order is part of the value, so a reordering is a different variant.
+	require.NotEqual(t, both, key("acme-private", "public"))
+	// The framing is injective: two lines must not hash like one joined line.
+	require.NotEqual(t, both, key("publicacme-private"))
+	require.NotEqual(t, both, key("public,acme-private"))
+	// And the per-value length prefix is what makes it so. The assertions above
+	// differ in how many lines there are, which is hashed on its own, so they
+	// hold even without the prefix; these two split the same bytes the same
+	// number of ways and collide without it.
+	require.NotEqual(t, key("ab", "c"), key("a", "bc"))
+	require.NotEqual(t, key("a", "bb", "c"), key("aa", "b", "c"))
+	// Same input, same key.
+	require.Equal(t, both, key("public", "acme-private"))
+}
+
+// Test_Cache_VaryRepeatedFieldLines is the end-to-end form: a request that
+// sends one field line must not be served the entry stored for a request that
+// sent two.
+func Test_Cache_VaryRepeatedFieldLines(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Expiration: time.Minute}))
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Set("Vary", "X-Tenant")
+		values := c.Request().Header.PeekAll("X-Tenant")
+		parts := make([]string, 0, len(values))
+		for _, v := range values {
+			parts = append(parts, string(v)+";")
+		}
+		return c.SendString("tenant:" + strings.Join(parts, ""))
+	})
+
+	do := func(lines ...string) (body, cacheStatus string) { //nolint:nonamedreturns // names document the pair
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.SetMethod(fiber.MethodGet)
+		req.SetRequestURI("/")
+		req.SetHost("example.com")
+		for _, l := range lines {
+			req.Header.Add("X-Tenant", l)
+		}
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return string(fctx.Response.Body()), string(fctx.Response.Header.Peek("X-Cache"))
+	}
+
+	body, status := do("public", "acme-private")
+	require.Equal(t, cacheMiss, status)
+	require.Equal(t, "tenant:public;acme-private;", body)
+
+	body, status = do("public")
+	require.Equal(t, cacheMiss, status, "the single-line request must not hit the two-line entry")
+	require.Equal(t, "tenant:public;", body)
+
+	// Each variant still caches on its own key.
+	body, status = do("public", "acme-private")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "tenant:public;acme-private;", body)
+
+	body, status = do("public")
+	require.Equal(t, cacheHit, status)
+	require.Equal(t, "tenant:public;", body)
 }
diff --git a/middleware/cache/keygen_test.go b/middleware/cache/keygen_test.go
index 583e56563a9..62e57603866 100644
--- a/middleware/cache/keygen_test.go
+++ b/middleware/cache/keygen_test.go
@@ -23,23 +23,23 @@ type keygenCase struct {
 
 func keygenCorpus() []keygenCase {
 	return []keygenCase{
-		{name: "noquery", uri: "/demo", want: "/|q=|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "single", uri: "/demo?foo=bar", want: "/|q=foo=bar|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "multi_dup", uri: "/demo?b=2&a=1&a=3", want: "/|q=a=1&a=3&b=2|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "path_delims", uri: "/a|b:c\\d?x=1", want: "/|q=x=1|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "query_escape", uri: "/p?k=a b&z=%2F&k=z", want: "/|q=k=a+b&k=z&z=%2F|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "with_headers", uri: "/p?foo=bar", headers: map[string]string{"Accept": "text/html", "Accept-Encoding": "gzip"}, want: "/|q=foo=bar|h=Accept:text/html|Accept-Encoding:gzip|Accept-Language:"},
-		{name: "with_cookie", uri: "/p?foo=bar", cookie: "sid=abc123", keyCooks: []string{"sid"}, want: "/|q=foo=bar|h=Accept:|Accept-Encoding:|Accept-Language:|c=sid:abc123"},
-		{name: "long_query", uri: "/p?q=" + strings.Repeat("x", 300), want: "/|q=sha256:4d86f7dbfc8b3bfe229da7e27f4ac8f6cf8114e24e5cb6b5af1d09cb4cc3d982|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "long_path", uri: "/" + strings.Repeat("p", 300) + "?a=1", want: "/|q=a=1|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "disable_query", uri: "/p?foo=bar", noQuery: true, want: "/|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "header_val_delims", uri: "/p", headers: map[string]string{"Accept": "a|b:c"}, want: "/|q=|h=Accept:a\\pb\\cc|Accept-Encoding:|Accept-Language:"},
-		{name: "empty_query", uri: "/p?", want: "/|q=|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "many_params", uri: "/p?" + strings.Repeat("k=v&", 200) + "z=1", want: "/|q=sha256:f8f7166c8aec35092b4c6f66a895ec9f302746c6310aa0dbfde45cbd30aa1829|h=Accept:|Accept-Encoding:|Accept-Language:"},
-		{name: "query_empty_body", uri: "/q", method: fiber.MethodQuery, want: "/|q=|h=Accept:|Accept-Encoding:|Accept-Language:|b="},
-		{name: "query_body", uri: "/q", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=|h=Accept:|Accept-Encoding:|Accept-Language:|b=foo=bar"},
-		{name: "query_body_delims", uri: "/q", method: fiber.MethodQuery, body: "a|b:c", want: "/|q=|h=Accept:|Accept-Encoding:|Accept-Language:|b=a\\pb\\cc"},
-		{name: "query_with_querystring", uri: "/q?x=1", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=x=1|h=Accept:|Accept-Encoding:|Accept-Language:|b=foo=bar"},
+		{name: "noquery", uri: "/demo", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "single", uri: "/demo?foo=bar", want: "/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "multi_dup", uri: "/demo?b=2&a=1&a=3", want: "/|q=a=1&a=3&b=2|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "path_delims", uri: "/a|b:c\\d?x=1", want: "/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "query_escape", uri: "/p?k=a b&z=%2F&k=z", want: "/|q=k=a+b&k=z&z=%2F|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "with_headers", uri: "/p?foo=bar", headers: map[string]string{"Accept": "text/html", "Accept-Encoding": "gzip"}, want: "/|q=foo=bar|h=accept:1|text/html|accept-encoding:1|gzip|accept-language:0"},
+		{name: "with_cookie", uri: "/p?foo=bar", cookie: "sid=abc123", keyCooks: []string{"sid"}, want: "/|q=foo=bar|h=accept:0|accept-encoding:0|accept-language:0|c=sid:abc123"},
+		{name: "long_query", uri: "/p?q=" + strings.Repeat("x", 300), want: "/|q=sha256:4d86f7dbfc8b3bfe229da7e27f4ac8f6cf8114e24e5cb6b5af1d09cb4cc3d982|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "long_path", uri: "/" + strings.Repeat("p", 300) + "?a=1", want: "/|q=a=1|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "disable_query", uri: "/p?foo=bar", noQuery: true, want: "/|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "header_val_delims", uri: "/p", headers: map[string]string{"Accept": "a|b:c"}, want: "/|q=|h=accept:1|a\\pb\\cc|accept-encoding:0|accept-language:0"},
+		{name: "empty_query", uri: "/p?", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "many_params", uri: "/p?" + strings.Repeat("k=v&", 200) + "z=1", want: "/|q=sha256:f8f7166c8aec35092b4c6f66a895ec9f302746c6310aa0dbfde45cbd30aa1829|h=accept:0|accept-encoding:0|accept-language:0"},
+		{name: "query_empty_body", uri: "/q", method: fiber.MethodQuery, want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b="},
+		{name: "query_body", uri: "/q", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
+		{name: "query_body_delims", uri: "/q", method: fiber.MethodQuery, body: "a|b:c", want: "/|q=|h=accept:0|accept-encoding:0|accept-language:0|b=a\\pb\\cc"},
+		{name: "query_with_querystring", uri: "/q?x=1", method: fiber.MethodQuery, body: "foo=bar", want: "/|q=x=1|h=accept:0|accept-encoding:0|accept-language:0|b=foo=bar"},
 	}
 }
 
@@ -64,11 +64,16 @@ func buildKeygenCtx(tc *keygenCase) (fiber.Ctx, *Config) {
 	if tc.cookie != "" {
 		c.Request().Header.Set("Cookie", tc.cookie)
 	}
-	cfg := ConfigDefault
-	cfg.DisableQueryKeys = tc.noQuery
+	// Through configDefault, not ConfigDefault: New applies it to every config
+	// it is given, and it lowercases the header dimensions. Keying off the raw
+	// default instead pinned "h=accept:0", a key format no running application
+	// produces — so a change to the normalization would not have been caught by
+	// the fixtures that exist to catch exactly that.
+	in := Config{DisableQueryKeys: tc.noQuery}
 	if tc.keyCooks != nil {
-		cfg.KeyCookies = tc.keyCooks
+		in.KeyCookies = tc.keyCooks
 	}
+	cfg := configDefault(in)
 	return c, &cfg
 }
 
@@ -93,6 +98,13 @@ func Benchmark_defaultKeyGenerator(b *testing.B) {
 
 // Test_defaultKeyGenerator_stableKeys pins the exact cache-key output so the
 // allocation refactor of the canonical* helpers stays byte-for-byte identical.
+//
+// The header dimension reads "name:<count>|value|value": the count is what
+// keeps the framing injective now that every field line of a key header is
+// included, and it also separates an absent header ("name:0") from one present
+// with an empty value ("name:1|"). Changing this format is a deliberate act —
+// live entries keyed by the old shape miss once — so update these strings only
+// alongside a matching change in appendCanonicalHeaderSubset.
 func Test_defaultKeyGenerator_stableKeys(t *testing.T) {
 	t.Parallel()
 	for _, tc := range keygenCorpus() {
diff --git a/middleware/csrf/csrf_test.go b/middleware/csrf/csrf_test.go
index 5f6cf85fb47..21525d46bdf 100644
--- a/middleware/csrf/csrf_test.go
+++ b/middleware/csrf/csrf_test.go
@@ -4,6 +4,7 @@ import (
 	"bytes"
 	"context"
 	"errors"
+	"fmt"
 	"net"
 	"net/http"
 	"net/http/httptest"
@@ -3326,3 +3327,350 @@ func Test_CSRF_Security_TrustedOriginSchemeIsolation(t *testing.T) {
 	// The same host over http is NOT trusted.
 	require.Equal(t, fiber.StatusForbidden, post("http://trusted.example.com"))
 }
+
+// Test_CSRF_OriginCheckIgnoresHeaderNameCase pins that the origin check tells a
+// cross-site POST from a same-site one whatever case the field names arrive in.
+//
+// Ctx.Get compares the stored key byte for byte, so under
+// DisableHeaderNormalizing every read came back empty — and an absent Origin is
+// not a failure here: on a plaintext connection the check is skipped for it. A
+// cross-site request that spelled the header in lower case, which is what
+// HTTP/2 and HTTP/3 put on the wire, was therefore accepted where the canonical
+// spelling was refused.
+func Test_CSRF_OriginCheckIgnoresHeaderNameCase(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+			app.Use(New())
+			app.Get("/", func(c fiber.Ctx) error { return c.SendString(TokenFromContext(c)) })
+			app.Post("/", func(c fiber.Ctx) error { return c.SendString("accepted") })
+			h := app.Handler()
+
+			// A legitimate visit, for the cookie and token a double-submit
+			// check needs. Without them the token check refuses everything and
+			// the origin check is never reached.
+			get := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(get)
+			get.Header.SetMethod(fiber.MethodGet)
+			get.SetRequestURI("/")
+			get.Header.SetHost("example.com")
+			gctx := &fasthttp.RequestCtx{}
+			gctx.Init(get, nil, nil)
+			h(gctx)
+
+			token := string(gctx.Response.Body())
+			require.NotEmpty(t, token)
+			cookie, _, _ := strings.Cut(string(gctx.Response.Header.Peek(fiber.HeaderSetCookie)), ";")
+			require.NotEmpty(t, cookie)
+
+			post := func(originHeader, origin string) int {
+				req := fasthttp.AcquireRequest()
+				defer fasthttp.ReleaseRequest(req)
+				if !normalize {
+					req.Header.DisableNormalizing()
+				}
+				req.Header.SetMethod(fiber.MethodPost)
+				req.SetRequestURI("/")
+				req.Header.SetHost("example.com")
+				req.Header.Set(fiber.HeaderCookie, cookie)
+				req.Header.Set(HeaderName, token)
+				req.Header.Set(originHeader, origin)
+
+				ctx := &fasthttp.RequestCtx{}
+				ctx.Init(req, nil, nil)
+				h(ctx)
+				return ctx.Response.StatusCode()
+			}
+
+			// Same-origin passes under either spelling, so the assertions below
+			// cannot pass by refusing everything.
+			require.Equal(t, fiber.StatusOK, post(fiber.HeaderOrigin, "http://example.com"))
+			require.Equal(t, fiber.StatusOK, post("origin", "http://example.com"))
+
+			require.Equal(t, fiber.StatusForbidden, post(fiber.HeaderOrigin, "http://evil.com"))
+			require.Equal(t, fiber.StatusForbidden, post("origin", "http://evil.com"),
+				"a cross-site origin must be refused whatever case its name arrives in")
+		})
+	}
+}
+
+// Test_CSRF_RepeatedOriginIsRefused pins what a message carrying two Origin
+// lines gets.
+//
+// Ctx.Get answers with the first line stored under the exact key, empty or not,
+// and an empty answer is indistinguishable from an absent header — which the
+// origin check treats as no failure at all, skipping it on a plaintext request.
+// A message carrying "Origin:" ahead of its real Origin therefore turned the
+// check off, under both spellings and whether or not the names are normalized.
+//
+// Origin is a single-value field, so a second line is malformed however it is
+// spelled and whatever it holds. It is refused rather than resolved: reading
+// past the empty line would let whoever wrote the other one pick which is read.
+// That is why the same-origin case below is refused too — the check cannot know
+// which line the request meant.
+func Test_CSRF_RepeatedOriginIsRefused(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: !normalize})
+			app.Use(New())
+			app.Get("/", func(c fiber.Ctx) error { return c.SendString(TokenFromContext(c)) })
+			app.Post("/", func(c fiber.Ctx) error { return c.SendString("accepted") })
+			h := app.Handler()
+
+			get := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(get)
+			get.Header.SetMethod(fiber.MethodGet)
+			get.SetRequestURI("/")
+			get.Header.SetHost("example.com")
+			gctx := &fasthttp.RequestCtx{}
+			gctx.Init(get, nil, nil)
+			h(gctx)
+
+			token := string(gctx.Response.Body())
+			require.NotEmpty(t, token)
+			cookie, _, _ := strings.Cut(string(gctx.Response.Header.Peek(fiber.HeaderSetCookie)), ";")
+			require.NotEmpty(t, cookie)
+
+			post := func(build func(*fasthttp.Request)) int {
+				req := fasthttp.AcquireRequest()
+				defer fasthttp.ReleaseRequest(req)
+				if !normalize {
+					req.Header.DisableNormalizing()
+				}
+				req.Header.SetMethod(fiber.MethodPost)
+				req.SetRequestURI("/")
+				req.Header.SetHost("example.com")
+				req.Header.Set(fiber.HeaderCookie, cookie)
+				req.Header.Set(HeaderName, token)
+				build(req)
+
+				ctx := &fasthttp.RequestCtx{}
+				ctx.Init(req, nil, nil)
+				h(ctx)
+				return ctx.Response.StatusCode()
+			}
+
+			single := func(name, origin string) int {
+				return post(func(req *fasthttp.Request) { req.Header.Set(name, origin) })
+			}
+
+			// shadowed sends an empty Origin line ahead of a second one carrying
+			// origin, which is what a header-writing intermediary in front of the
+			// application can produce. Set then Add stores the two lines fasthttp
+			// parses such a message into.
+			shadowed := func(secondName, origin string) int {
+				return post(func(req *fasthttp.Request) {
+					req.Header.Set(fiber.HeaderOrigin, "")
+					req.Header.Add(secondName, origin)
+				})
+			}
+
+			// A single Origin line still passes, so the assertions below cannot
+			// pass by refusing everything.
+			require.Equal(t, fiber.StatusOK, single(fiber.HeaderOrigin, "http://example.com"))
+			require.Equal(t, fiber.StatusOK, single("origin", "http://example.com"))
+
+			require.Equal(t, fiber.StatusForbidden, shadowed(fiber.HeaderOrigin, "http://evil.com"),
+				"an empty first line must not hide the origin beside it")
+			require.Equal(t, fiber.StatusForbidden, shadowed("origin", "http://evil.com"),
+				"an empty first line must not hide the origin beside it")
+
+			require.Equal(t, fiber.StatusForbidden, shadowed(fiber.HeaderOrigin, "http://example.com"),
+				"a repeated Origin is refused rather than resolved, same-origin included")
+			require.Equal(t, fiber.StatusForbidden, shadowed("origin", "http://example.com"))
+		})
+	}
+}
+
+// Test_CSRF_RepeatedSecFetchSiteAndRefererAreRefused covers the other two
+// single-value fields the check reads, for the same reason as Origin: a second
+// line makes the field unreadable, and neither may be treated as absent — an
+// absent Sec-Fetch-Site is skipped, and an absent Referer on HTTPS is what the
+// Referer check exists to refuse.
+func Test_CSRF_RepeatedSecFetchSiteAndRefererAreRefused(t *testing.T) {
+	t.Parallel()
+
+	// Trusted-proxy app: Ctx.Scheme reads X-Forwarded-Proto only from a trusted
+	// peer, and the Referer check runs only on HTTPS.
+	app := newTrustedApp()
+	app.Use(New())
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString(TokenFromContext(c)) })
+	app.Post("/", func(c fiber.Ctx) error { return c.SendString("accepted") })
+	h := app.Handler()
+
+	get := &fasthttp.RequestCtx{}
+	get.Request.Header.SetMethod(fiber.MethodGet)
+	get.Request.SetRequestURI("/")
+	get.Request.URI().SetScheme("https")
+	get.Request.Header.SetProtocol("https")
+	get.Request.Header.SetHost("example.com")
+	h(get)
+
+	token := string(get.Response.Body())
+	require.NotEmpty(t, token)
+	cookie, _, _ := strings.Cut(string(get.Response.Header.Peek(fiber.HeaderSetCookie)), ";")
+	require.NotEmpty(t, cookie)
+
+	post := func(build func(*fasthttp.RequestCtx)) int {
+		ctx := &fasthttp.RequestCtx{}
+		ctx.Request.Header.SetMethod(fiber.MethodPost)
+		ctx.Request.SetRequestURI("/")
+		ctx.Request.URI().SetScheme("https")
+		ctx.Request.URI().SetHost("example.com")
+		ctx.Request.Header.SetProtocol("https")
+		ctx.Request.Header.SetHost("example.com")
+		// Ctx.Scheme reads this rather than the URI, and the Referer check runs
+		// only on HTTPS.
+		ctx.Request.Header.Set(fiber.HeaderXForwardedProto, "https")
+		ctx.Request.Header.Set(fiber.HeaderCookie, cookie)
+		ctx.Request.Header.Set(HeaderName, token)
+		build(ctx)
+		h(ctx)
+		return ctx.Response.StatusCode()
+	}
+
+	// A same-origin request with one of each still passes, so the refusals
+	// below cannot pass by refusing everything.
+	require.Equal(t, fiber.StatusOK, post(func(ctx *fasthttp.RequestCtx) {
+		ctx.Request.Header.Set(fiber.HeaderSecFetchSite, "same-origin")
+		ctx.Request.Header.Set(fiber.HeaderOrigin, "https://example.com")
+	}))
+	require.Equal(t, fiber.StatusOK, post(func(ctx *fasthttp.RequestCtx) {
+		ctx.Request.Header.Set(fiber.HeaderReferer, "https://example.com/page")
+	}), "no Origin on HTTPS falls through to the Referer check, which this passes")
+
+	require.Equal(t, fiber.StatusForbidden, post(func(ctx *fasthttp.RequestCtx) {
+		ctx.Request.Header.Set(fiber.HeaderSecFetchSite, "same-origin")
+		ctx.Request.Header.Add(fiber.HeaderSecFetchSite, "same-origin")
+		ctx.Request.Header.Set(fiber.HeaderOrigin, "https://example.com")
+	}), "a repeated Sec-Fetch-Site must not be skipped as an absent one is")
+
+	require.Equal(t, fiber.StatusForbidden, post(func(ctx *fasthttp.RequestCtx) {
+		// No Origin, so the check falls through to Referer on this HTTPS request.
+		ctx.Request.Header.Set(fiber.HeaderReferer, "https://example.com/page")
+		ctx.Request.Header.Add(fiber.HeaderReferer, "https://evil.example/page")
+	}), "a repeated Referer is refused rather than resolved to one of the lines")
+}
+
+// Test_CSRF_TrustedOriginIsAllowedWhenCrossSite pins that Sec-Fetch-Site does
+// not decide cross-site on its own.
+//
+// "cross-site" is exactly what a browser sends for a legitimate request to an
+// origin the application trusts, so rejecting it in the header check would make
+// TrustedOrigins unusable; the decision belongs to the origin check, which
+// knows which origins those are.
+func Test_CSRF_TrustedOriginIsAllowedWhenCrossSite(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{TrustedOrigins: []string{"http://partner.com"}}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString(TokenFromContext(c)) })
+	app.Post("/", func(c fiber.Ctx) error { return c.SendString("accepted") })
+	h := app.Handler()
+
+	get := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(get)
+	get.Header.SetMethod(fiber.MethodGet)
+	get.SetRequestURI("/")
+	get.Header.SetHost("example.com")
+	gctx := &fasthttp.RequestCtx{}
+	gctx.Init(get, nil, nil)
+	h(gctx)
+
+	token := string(gctx.Response.Body())
+	require.NotEmpty(t, token)
+	cookie, _, _ := strings.Cut(string(gctx.Response.Header.Peek(fiber.HeaderSetCookie)), ";")
+	require.NotEmpty(t, cookie)
+
+	post := func(origin, secFetchSite string) int {
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.SetMethod(fiber.MethodPost)
+		req.SetRequestURI("/")
+		req.Header.SetHost("example.com")
+		req.Header.Set(fiber.HeaderCookie, cookie)
+		req.Header.Set(HeaderName, token)
+		req.Header.Set(fiber.HeaderOrigin, origin)
+		if secFetchSite != "" {
+			req.Header.Set(fiber.HeaderSecFetchSite, secFetchSite)
+		}
+		ctx := &fasthttp.RequestCtx{}
+		ctx.Init(req, nil, nil)
+		h(ctx)
+		return ctx.Response.StatusCode()
+	}
+
+	require.Equal(t, fiber.StatusOK, post("http://partner.com", "cross-site"),
+		"a trusted origin is allowed even though the browser calls it cross-site")
+	require.Equal(t, fiber.StatusOK, post("http://example.com", "same-origin"))
+
+	// The origin check is still what refuses an untrusted one.
+	require.Equal(t, fiber.StatusForbidden, post("http://evil.com", "cross-site"))
+	// And a value no browser produces is refused by the header check itself.
+	require.Equal(t, fiber.StatusForbidden, post("http://partner.com", "not-a-real-value"))
+}
+
+// Test_CSRF_CrossSiteWithoutOriginOverPlaintext pins what happens when the
+// browser says the request is cross-site but sends no Origin, on a plaintext
+// connection.
+//
+// Sec-Fetch-Site does not decide cross-site on its own, and an absent Origin is
+// not a failure over plaintext — the check is skipped for it, because there is
+// no Referer fallback to fall back to. What is left holding the request is the
+// double-submit token, so that is what this pins: with a valid pair it is
+// accepted, and without one it is not.
+func Test_CSRF_CrossSiteWithoutOriginOverPlaintext(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New())
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString(TokenFromContext(c)) })
+	app.Post("/", func(c fiber.Ctx) error { return c.SendString("accepted") })
+	h := app.Handler()
+
+	get := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(get)
+	get.Header.SetMethod(fiber.MethodGet)
+	get.SetRequestURI("/")
+	get.Header.SetHost("example.com")
+	gctx := &fasthttp.RequestCtx{}
+	gctx.Init(get, nil, nil)
+	h(gctx)
+
+	token := string(gctx.Response.Body())
+	require.NotEmpty(t, token)
+	cookie, _, _ := strings.Cut(string(gctx.Response.Header.Peek(fiber.HeaderSetCookie)), ";")
+	require.NotEmpty(t, cookie)
+
+	post := func(withToken bool) int {
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.SetMethod(fiber.MethodPost)
+		req.SetRequestURI("/")
+		req.Header.SetHost("example.com")
+		req.Header.Set(fiber.HeaderSecFetchSite, "cross-site")
+		// No Origin, and no Referer either.
+		req.Header.Set(fiber.HeaderCookie, cookie)
+		if withToken {
+			req.Header.Set(HeaderName, token)
+		}
+
+		ctx := &fasthttp.RequestCtx{}
+		ctx.Init(req, nil, nil)
+		h(ctx)
+		return ctx.Response.StatusCode()
+	}
+
+	require.Equal(t, fiber.StatusOK, post(true),
+		"over plaintext with no Origin, the token is what the request rests on")
+	require.Equal(t, fiber.StatusForbidden, post(false),
+		"and without it nothing else lets the request through")
+}
diff --git a/middleware/logger/logger_test.go b/middleware/logger/logger_test.go
index 37ac00c2bf3..23df07fc9ff 100644
--- a/middleware/logger/logger_test.go
+++ b/middleware/logger/logger_test.go
@@ -197,10 +197,13 @@ func Test_Logger_TimeUpdaterStopsOnDone(t *testing.T) {
 
 	initial, ok := timestamp.Load().(string)
 	require.True(t, ok)
-	time.Sleep(20 * time.Millisecond)
-	updated, ok := timestamp.Load().(string)
-	require.True(t, ok)
-	require.NotEqual(t, initial, updated)
+	// Wait for a tick rather than assume one lands inside a fixed sleep: the
+	// updater is a goroutine on a 5ms ticker, and a loaded machine ran the whole
+	// sleep before scheduling it.
+	require.Eventually(t, func() bool {
+		updated, isString := timestamp.Load().(string)
+		return isString && updated != initial
+	}, time.Second, time.Millisecond, "timestamp was never updated")
 
 	close(done)
 	select {
@@ -2028,3 +2031,203 @@ func Test_SanitizeValue(t *testing.T) {
 		})
 	}
 }
+
+// Test_Logger_IPs_RepeatedFieldLines asserts ${ips} logs every X-Forwarded-For
+// field line, not just the first.
+//
+// A recipient may combine repeated field lines into the comma-joined form (RFC
+// 9110 §5.2), and Fiber's proxy-header accessors do exactly that — so reading
+// only the first here logged a shorter chain than the one c.IP() and c.IPs()
+// parsed, and the access log did not explain what was actually enforced.
+func Test_Logger_IPs_RepeatedFieldLines(t *testing.T) {
+	t.Parallel()
+
+	buf := bytebufferpool.Get()
+	defer bytebufferpool.Put(buf)
+
+	app := fiber.New(fiber.Config{TrustProxy: true})
+	app.Use(New(Config{Format: "${ips}", Stream: buf}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("hi") })
+
+	raw := "GET / HTTP/1.1\r\nHost: example.com\r\n" +
+		"X-Forwarded-For: 1.1.1.1\r\n" +
+		"X-Forwarded-For: 2.2.2.2, 3.3.3.3\r\n\r\n"
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Init(req, nil, nil)
+	app.Handler()(fctx)
+
+	require.Equal(t, "1.1.1.1,2.2.2.2,3.3.3.3", buf.String(),
+		"every field line must be logged, as the chain the framework parsed")
+}
+
+// Test_Logger_IPs_WithoutHeaderNormalizing asserts the tag logs the chain the
+// framework acted on, whatever case the field name arrived in.
+//
+// Reading the header here rather than asking c.IPs() meant reading it a second
+// way, and PeekAll compares stored names byte for byte — so under
+// DisableHeaderNormalizing a lower-case "x-forwarded-for:" matched nothing and
+// the tag logged an empty chain, while c.IPs() went on parsing it and the trust
+// decisions went on using it.
+func Test_Logger_IPs_WithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name    string
+		lines   []string
+		disable bool
+	}{
+		{"normalized, one line", []string{"X-Forwarded-For: 1.1.1.1, 2.2.2.2"}, false},
+		{"raw, lower-case name", []string{"x-forwarded-for: 1.1.1.1, 2.2.2.2"}, true},
+		{"normalized, two lines", []string{"X-Forwarded-For: 1.1.1.1", "X-Forwarded-For: 2.2.2.2"}, false},
+		{"raw, mixed-case names", []string{"x-forwarded-for: 1.1.1.1", "X-Forwarded-For: 2.2.2.2"}, true},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			buf := bytebufferpool.Get()
+			defer bytebufferpool.Put(buf)
+
+			app := fiber.New(fiber.Config{
+				TrustProxy:               true,
+				DisableHeaderNormalizing: tc.disable,
+			})
+			app.Use(New(Config{Format: "${ips}", Stream: buf}))
+			app.Get("/", func(c fiber.Ctx) error { return c.SendString("hi") })
+
+			parts := []string{"GET / HTTP/1.1\r\nHost: example.com\r\n"}
+			for _, l := range tc.lines {
+				parts = append(parts, l+"\r\n")
+			}
+			raw := strings.Join(append(parts, "\r\n"), "")
+
+			req := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(req)
+			if tc.disable {
+				req.Header.DisableNormalizing()
+			}
+			require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Init(req, nil, nil)
+			app.Handler()(fctx)
+
+			require.Equal(t, "1.1.1.1,2.2.2.2", buf.String(),
+				"the log must show the chain the trust decisions used")
+		})
+	}
+}
+
+// Test_Logger_RegisterContextTag_Sanitizes pins that a value rendered by a
+// registered context tag cannot close the log line it is written on.
+//
+// Every built-in tag passes through the sanitizer; this path did not, so a CR
+// or LF in whatever the application pulled out of the context — in practice
+// request data — started a second entry the reader has no way to tell from a
+// real one.
+func Test_Logger_RegisterContextTag_Sanitizes(t *testing.T) {
+	t.Parallel()
+
+	// Both registries are mutex-guarded and re-registering replaces rather
+	// than fails, so this runs in parallel like every other registry test in
+	// the package. The name has to be its own, though: registration is global
+	// and outlives the test whether or not it is parallel.
+	RegisterContextTag("sanitize-probe", func(_ any) string {
+		return "before\r\nGET /forged HTTP/1.1\nafter"
+	})
+
+	var buf bytes.Buffer
+	app := fiber.New()
+	app.Use(New(Config{
+		Format: "${sanitize-probe}\n",
+		Stream: &buf,
+	}))
+	app.Get("/", func(c fiber.Ctx) error { return c.SendString("ok") })
+
+	_, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+
+	line := buf.String()
+	require.NotContains(t, line, "\r", "a CR must not reach the log")
+	require.Equal(t, 1, strings.Count(line, "\n"), "the entry must occupy one line: %q", line)
+	require.Contains(t, line, "before")
+	require.Contains(t, line, "after")
+}
+
+// Test_TagIPs_PropagatesWriteErrors pins the short-circuits in the ${ips} tag.
+// A sink that fails partway must stop and surface the error rather than
+// carrying on, and the count returned must reflect only what reached the sink.
+func Test_TagIPs_PropagatesWriteErrors(t *testing.T) {
+	t.Parallel()
+
+	// A trusted proxy, so c.IPs() returns the forwarded chain rather than
+	// nothing at all — the tag needs more than one entry to reach the
+	// separator between them.
+	app := fiber.New(fiber.Config{
+		TrustProxy:       true,
+		TrustProxyConfig: fiber.TrustProxyConfig{Loopback: true},
+	})
+	tag := createTagMap(&ConfigDefault)[TagIPs]
+
+	withChain := func(t *testing.T, chain string) fiber.Ctx {
+		t.Helper()
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Request.Header.SetMethod(fiber.MethodGet)
+		fctx.Request.SetRequestURI("/")
+		fctx.Request.Header.Set(fiber.HeaderXForwardedFor, chain)
+		c := app.AcquireCtx(fctx)
+		t.Cleanup(func() { app.ReleaseCtx(c) })
+		return c
+	}
+
+	t.Run("the whole chain is written", func(t *testing.T) {
+		t.Parallel()
+
+		buf := bytebufferpool.Get()
+		defer bytebufferpool.Put(buf)
+
+		n, err := tag(buf, withChain(t, "1.1.1.1, 2.2.2.2"), nil, "")
+		require.NoError(t, err)
+		require.Equal(t, "1.1.1.1,2.2.2.2", buf.String())
+		require.Equal(t, len(buf.String()), n)
+	})
+
+	t.Run("the first entry fails", func(t *testing.T) {
+		t.Parallel()
+
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 0}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := tag(buf, withChain(t, "1.1.1.1, 2.2.2.2"), nil, "")
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Zero(t, n)
+	})
+
+	t.Run("the separator fails", func(t *testing.T) {
+		t.Parallel()
+
+		// One successful write for the first address, then the "," fails.
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 1}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := tag(buf, withChain(t, "1.1.1.1, 2.2.2.2"), nil, "")
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Equal(t, len("1.1.1.1"), n, "only the first address reached the sink")
+	})
+
+	t.Run("the second entry fails", func(t *testing.T) {
+		t.Parallel()
+
+		// The first address and the separator succeed; the second fails.
+		buf := &failingBuffer{ByteBuffer: bytebufferpool.Get(), failAfter: 2}
+		defer bytebufferpool.Put(buf.ByteBuffer)
+
+		n, err := tag(buf, withChain(t, "1.1.1.1, 2.2.2.2"), nil, "")
+		require.ErrorIs(t, err, errWriteFailed)
+		require.Equal(t, len("1.1.1.1,"), n)
+	})
+}
diff --git a/middleware/proxy/bench_test.go b/middleware/proxy/bench_test.go
index 07a726b17e5..f72deda4e0a 100644
--- a/middleware/proxy/bench_test.go
+++ b/middleware/proxy/bench_test.go
@@ -145,7 +145,7 @@ func BenchmarkStripHopByHop_NoConnection(b *testing.B) {
 		req.Reset()
 		seedNoConnectionRequest(req)
 		b.StartTimer()
-		stripHopByHopRequestHeaders(req)
+		stripHopByHopRequestHeaders(req, true)
 	}
 }
 
@@ -158,7 +158,7 @@ func BenchmarkStripHopByHop_WithConnection(b *testing.B) {
 		req.Reset()
 		seedWithConnectionRequest(req)
 		b.StartTimer()
-		stripHopByHopRequestHeaders(req)
+		stripHopByHopRequestHeaders(req, true)
 	}
 }
 
@@ -222,7 +222,7 @@ func BenchmarkFollowRedirects_NoRedirect(b *testing.B) {
 		req.Reset()
 		req.SetRequestURI(initialURL.String())
 		req.Header.SetMethod(fasthttp.MethodGet)
-		if err := followRedirects(cli, req, resp, 3, initialURL, policy); err != nil {
+		if err := followRedirects(cli, req, resp, 3, initialURL, policy, true); err != nil {
 			b.Fatal(err)
 		}
 	}
diff --git a/middleware/proxy/fuzz_test.go b/middleware/proxy/fuzz_test.go
index 13bc17e6c60..fceab22b22a 100644
--- a/middleware/proxy/fuzz_test.go
+++ b/middleware/proxy/fuzz_test.go
@@ -142,7 +142,7 @@ func FuzzConnectionListedHeaders(f *testing.F) {
 		req.Header.Set(fiber.HeaderConnection, v)
 		req.Header.Set("X-Foo", "1")
 		req.Header.Set("X-Bar", "2")
-		delConnectionListedHeaders(&req.Header, req.Header.PeekAll(fiber.HeaderConnection))
+		delConnectionListedHeaders(&req.Header, req.Header.PeekAll(fiber.HeaderConnection), true)
 		if t.Failed() {
 			t.Logf("input: %q", v)
 		}
diff --git a/middleware/proxy/proxy_test.go b/middleware/proxy/proxy_test.go
index 4d8ce9d8b30..ad7004ba438 100644
--- a/middleware/proxy/proxy_test.go
+++ b/middleware/proxy/proxy_test.go
@@ -1,6 +1,7 @@
 package proxy
 
 import (
+	"bufio"
 	"crypto/tls"
 	"io"
 	"net"
@@ -13,6 +14,7 @@ import (
 
 	"github.com/gofiber/fiber/v3"
 	clientpkg "github.com/gofiber/fiber/v3/client"
+	"github.com/gofiber/utils/v2"
 	"github.com/stretchr/testify/require"
 
 	"github.com/gofiber/fiber/v3/internal/tlstest"
@@ -381,6 +383,111 @@ func Test_Proxy_Forward(t *testing.T) {
 	require.Equal(t, "forwarded", string(b))
 }
 
+// go test -run Test_Proxy_Forward_ReplacesClientSuppliedRealIP
+func Test_Proxy_Forward_ReplacesClientSuppliedRealIP(t *testing.T) {
+	t.Parallel()
+
+	// The forwarders overwrite X-Real-IP so the upstream can attribute the
+	// request to the peer Fiber actually saw. Header.Set replaces the first
+	// field line with a given name and leaves any others in place, so a client
+	// that sends the header twice used to keep one of its own values on the
+	// wire — and the upstream, which may read the last line or join the pair
+	// per RFC 9110 Section 5.2, would attribute the request to an address the
+	// client chose.
+	for _, tc := range []struct {
+		handler func(addr string) fiber.Handler
+		name    string
+	}{
+		{
+			name:    "Forward",
+			handler: func(addr string) fiber.Handler { return Forward("http://" + addr) },
+		},
+		{
+			name: "DomainForward",
+			handler: func(addr string) fiber.Handler {
+				return DomainForward("example.com", "http://"+addr)
+			},
+		},
+		{
+			name: "BalancerForward",
+			handler: func(addr string) fiber.Handler {
+				return BalancerForward([]string{"http://" + addr})
+			},
+		},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+				seen := c.Request().Header.PeekAll("X-Real-IP")
+				out := make([]string, 0, len(seen))
+				for _, v := range seen {
+					out = append(out, string(v))
+				}
+				return c.SendString(strings.Join(out, "|"))
+			})
+
+			app := fiber.New()
+			app.Use(tc.handler(addr))
+
+			req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+			req.Host = "example.com"
+			req.Header.Add("X-Real-IP", "7.7.7.7")
+			req.Header.Add("X-Real-IP", "8.8.8.8")
+
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+			b, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+
+			got := string(b)
+			require.NotContains(t, got, "7.7.7.7", "client-supplied X-Real-IP reached the upstream")
+			require.NotContains(t, got, "8.8.8.8", "client-supplied X-Real-IP reached the upstream")
+			require.NotContains(t, got, "|", "more than one X-Real-IP field line reached the upstream")
+			require.NotEmpty(t, got)
+		})
+	}
+}
+
+// Test_Proxy_Forward_RealIPFromProxyHeader pins that replacing X-Real-IP does
+// not destroy the value it is derived from.
+//
+// With Config.ProxyHeader set to "X-Real-IP", c.IP() reads that very header, so
+// deleting it before resolving the address left the upstream with an empty
+// X-Real-IP instead of the client's.
+func Test_Proxy_Forward_RealIPFromProxyHeader(t *testing.T) {
+	t.Parallel()
+
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen := c.Request().Header.PeekAll("X-Real-IP")
+		out := make([]string, 0, len(seen))
+		for _, v := range seen {
+			out = append(out, string(v))
+		}
+		return c.SendString(strings.Join(out, "|"))
+	})
+
+	app := fiber.New(fiber.Config{
+		TrustProxy:       true,
+		TrustProxyConfig: fiber.TrustProxyConfig{Proxies: []string{"0.0.0.0/0"}},
+		ProxyHeader:      "X-Real-IP",
+	})
+	app.Use(Forward("http://" + addr))
+
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Set("X-Real-IP", "203.0.113.9")
+
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	b, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "203.0.113.9", string(b))
+}
+
 // go test -run Test_Proxy_Forward_WithClient_TLSConfig
 func Test_Proxy_Forward_WithClient_TLSConfig(t *testing.T) {
 	restoreGlobalProxyClient(t)
@@ -1250,3 +1357,225 @@ func Test_Proxy_DomainForward_HostMatchIsCaseInsensitive(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, "proxied", string(body), "mixed-case Host must still be proxied")
 }
+
+// sendRawUnnormalized drives one request whose header names are kept exactly as
+// written, the way a front end translating HTTP/2 down to HTTP/1.1 leaves them,
+// and returns the response body.
+func sendRawUnnormalized(t *testing.T, app *fiber.App, raw string) string {
+	t.Helper()
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.Header.DisableNormalizing()
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Init(req, nil, nil)
+	app.Handler()(fctx)
+
+	return string(fctx.Response.Body())
+}
+
+// loopbackAlias returns addr with its host rewritten to "localhost", naming the
+// same listener under a different authority.
+//
+// A cross-host redirect is decided by comparing the authority as written, not
+// by where it resolves, so this is enough to make the hop cross an origin
+// without binding a second loopback address.
+func loopbackAlias(t *testing.T, addr string) string {
+	t.Helper()
+
+	_, port, err := net.SplitHostPort(addr)
+	require.NoError(t, err)
+	return net.JoinHostPort("localhost", port)
+}
+
+// matchingFieldLines reports every field line whose name matches one of names,
+// in the spelling the header store holds.
+func matchingFieldLines(c fiber.Ctx, names ...string) []string {
+	var found []string
+	for k, v := range c.Request().Header.All() {
+		for _, name := range names {
+			if utils.EqualFold(utils.UnsafeString(k), name) {
+				found = append(found, string(k)+"="+string(v))
+			}
+		}
+	}
+	return found
+}
+
+// Test_Proxy_HopByHopHeadersStrippedWhateverTheirCase checks that the RFC 7230
+// Section 6.1 strip holds for a peer that spells the names in lower case, which
+// is what HTTP/2 and HTTP/3 require on the wire.
+//
+// Del matches the stored key byte for byte, so under DisableHeaderNormalizing
+// it removed nothing: the hop-by-hop headers reached the upstream, and so did a
+// field named in Connection, which is a peer smuggling a connection-scoped
+// header through an intermediary required to drop it.
+func Test_Proxy_HopByHopHeadersStrippedWhateverTheirCase(t *testing.T) {
+	t.Parallel()
+
+	seen := make(chan []string, 1)
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen <- matchingFieldLines(c, "Upgrade", "TE", "Keep-Alive", "Connection", "X-Smuggled")
+		return c.SendString("upstream")
+	})
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(Forward("http://" + addr))
+
+	body := sendRawUnnormalized(t, app, "GET / HTTP/1.1\r\nHost: front\r\n"+
+		"connection: x-smuggled\r\n"+
+		"x-smuggled: through-the-proxy\r\n"+
+		"upgrade: websocket\r\n"+
+		"te: trailers\r\n"+
+		"keep-alive: timeout=5\r\n\r\n")
+	require.Equal(t, "upstream", body)
+
+	require.Empty(t, <-seen, "no hop-by-hop or Connection-listed header may reach the upstream")
+}
+
+// Test_Proxy_RealIPReplacedWhateverTheirCase checks that the client cannot keep
+// a claim of its own beside the address this hop writes.
+func Test_Proxy_RealIPReplacedWhateverTheirCase(t *testing.T) {
+	t.Parallel()
+
+	seen := make(chan []string, 1)
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen <- matchingFieldLines(c, realIPHeader)
+		return c.SendString("upstream")
+	})
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(Forward("http://" + addr))
+
+	body := sendRawUnnormalized(t, app, "GET / HTTP/1.1\r\nHost: front\r\n"+
+		"x-real-ip: 6.6.6.6\r\n"+
+		"X-Real-IP: 7.7.7.7\r\n\r\n")
+	require.Equal(t, "upstream", body)
+
+	lines := <-seen
+	require.Len(t, lines, 1, "exactly one X-Real-IP reaches the upstream: %v", lines)
+	require.NotContains(t, lines[0], "6.6.6.6")
+	require.NotContains(t, lines[0], "7.7.7.7")
+}
+
+// Test_Proxy_CrossHostCredentialsStrippedWhateverTheirCase checks that a
+// redirect leaving the host the caller addressed does not carry the caller's
+// credentials to wherever it points.
+func Test_Proxy_CrossHostCredentialsStrippedWhateverTheirCase(t *testing.T) {
+	t.Parallel()
+
+	seen := make(chan []string, 1)
+	_, finalAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen <- matchingFieldLines(c, fiber.HeaderAuthorization, fiber.HeaderCookie)
+		return c.SendString("final")
+	})
+
+	// The redirect has to cross to a different host, and that is decided by
+	// comparing the authority as written rather than where it resolves — so
+	// name the same listener "localhost" instead of binding a second loopback
+	// address. 127.0.0.2 is bound by default only on Linux.
+	_, redirectAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		c.Location("http://" + loopbackAlias(t, finalAddr) + "/")
+		return c.SendStatus(fiber.StatusFound)
+	})
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(func(c fiber.Ctx) error {
+		return DoRedirects(c, "http://"+redirectAddr, 3)
+	})
+
+	body := sendRawUnnormalized(t, app, "GET / HTTP/1.1\r\nHost: front\r\n"+
+		"authorization: Bearer caller-token\r\n"+
+		"cookie: session=caller\r\n\r\n")
+	require.Equal(t, "final", body)
+
+	require.Empty(t, <-seen, "credentials must not follow a redirect off the host they were sent to")
+}
+
+// Test_Proxy_CrossHostStripsEveryCredentialHeader checks that the set dropped
+// on a redirect off the addressed host is the one the client package drops:
+// Cookie2 carries a session exactly as Cookie does, and a list that covers one
+// but not the other leaks through the gap.
+func Test_Proxy_CrossHostStripsEveryCredentialHeader(t *testing.T) {
+	t.Parallel()
+
+	seen := make(chan []string, 1)
+	_, finalAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen <- matchingFieldLines(c,
+			fiber.HeaderAuthorization,
+			fiber.HeaderProxyAuthorization,
+			fiber.HeaderProxyAuthenticate,
+			fiber.HeaderWWWAuthenticate,
+			fiber.HeaderCookie,
+			"Cookie2",
+		)
+		return c.SendString("final")
+	})
+
+	_, redirectAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		c.Location("http://" + loopbackAlias(t, finalAddr) + "/")
+		return c.SendStatus(fiber.StatusFound)
+	})
+
+	app := fiber.New()
+	app.Use(func(c fiber.Ctx) error {
+		return DoRedirects(c, "http://"+redirectAddr, 3)
+	})
+
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Set(fiber.HeaderAuthorization, "Bearer caller-token")
+	req.Header.Set(fiber.HeaderProxyAuthorization, "Basic proxy")
+	req.Header.Set(fiber.HeaderProxyAuthenticate, "Basic realm=x")
+	req.Header.Set(fiber.HeaderWWWAuthenticate, "Basic realm=y")
+	req.Header.Set(fiber.HeaderCookie, "session=caller")
+	req.Header.Set("Cookie2", `$Version="1"`)
+
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	require.Empty(t, <-seen, "no credential header may follow a redirect off the addressed host")
+}
+
+// Test_Proxy_ResponseStripIgnoresTheAppsNormalizationSetting checks the
+// response-side hop-by-hop strip against a proxy whose outbound client
+// preserves upstream header casing while the app itself normalizes.
+//
+// The two settings are independent — the client stamps its own onto the
+// response header on every hop — so reading the app's told the strip nothing
+// about the keys it was about to match, and it removed nothing: the upstream's
+// connection-scoped headers reached the client unchanged.
+func Test_Proxy_ResponseStripIgnoresTheAppsNormalizationSetting(t *testing.T) {
+	t.Parallel()
+
+	// The upstream preserves the casing it writes, and writes its hop-by-hop
+	// headers in lower case.
+	upstream := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	upstream.Get("/", func(c fiber.Ctx) error {
+		c.Response().Header.Set("keep-alive", "timeout=5")
+		c.Response().Header.Set("upgrade", "websocket")
+		c.Response().Header.Set("te", "trailers")
+		return c.SendString("upstream")
+	})
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	addr := ln.Addr().String()
+	startServer(upstream, ln)
+
+	cli := &fasthttp.Client{DisableHeaderNamesNormalizing: true}
+
+	// ...while the app takes the default, so the two settings disagree.
+	app := fiber.New()
+	app.Use(Forward("http://"+addr, cli))
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	for _, name := range []string{fiber.HeaderKeepAlive, fiber.HeaderUpgrade, fiber.HeaderTE} {
+		require.Empty(t, resp.Header.Values(name),
+			"%s must not reach the client whatever case the upstream wrote it in", name)
+	}
+}
diff --git a/middleware/proxy/security_test.go b/middleware/proxy/security_test.go
index 41ce7d2c518..509bd6ecbc2 100644
--- a/middleware/proxy/security_test.go
+++ b/middleware/proxy/security_test.go
@@ -421,7 +421,7 @@ func Test_Security_FollowRedirects_StripsCredentialsCrossHost(t *testing.T) {
 		req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
 		req.Header.Set(fiber.HeaderCookie, "session=abc")
 
-		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://first.example/"), policy))
+		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://first.example/"), policy, true))
 		require.Empty(t, sawAuth, "Authorization must be stripped cross-host")
 		require.Empty(t, sawCookie, "Cookie must be stripped cross-host")
 	})
@@ -446,7 +446,7 @@ func Test_Security_FollowRedirects_StripsCredentialsCrossHost(t *testing.T) {
 		req.Header.SetMethod(fasthttp.MethodGet)
 		req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
 
-		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://same.example/"), policy))
+		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://same.example/"), policy, true))
 		require.Equal(t, "Bearer secret", sawAuth, "Authorization must survive same-host redirect")
 	})
 }
@@ -479,7 +479,7 @@ func Test_Security_FollowRedirects_ReappliesSchemePerHop(t *testing.T) {
 	req.SetRequestURI("http://origin.example/")
 	req.Header.SetMethod(fasthttp.MethodGet)
 
-	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://origin.example/"), policy))
+	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://origin.example/"), policy, true))
 	require.Equal(t, "https", secondHopScheme, "scheme upgrade must carry through to the next hop")
 }
 
@@ -741,7 +741,7 @@ func Test_Security_FollowRedirects_NegativeMaxBecomesZero(t *testing.T) {
 
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	err := followRedirects(client.client, req, resp, -1, mustParseTestURL(t, "http://example.com/start"), policy)
+	err := followRedirects(client.client, req, resp, -1, mustParseTestURL(t, "http://example.com/start"), policy, true)
 	require.ErrorIs(t, err, fasthttp.ErrTooManyRedirects)
 	require.Equal(t, 1, *hits)
 }
@@ -765,7 +765,7 @@ func Test_Security_FollowRedirects_MissingLocation(t *testing.T) {
 
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	err := followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy)
+	err := followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy, true)
 	require.ErrorIs(t, err, fasthttp.ErrMissingLocation)
 }
 
@@ -791,7 +791,7 @@ func Test_Security_FollowRedirects_PostBecomesGetOn303(t *testing.T) {
 
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy))
+	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy, true))
 	require.Equal(t, fasthttp.MethodGet, string(req.Header.Method()))
 	require.Empty(t, req.Body())
 	require.Empty(t, req.Header.ContentType())
@@ -814,7 +814,7 @@ func Test_Security_FollowRedirects_PropagatesClientError(t *testing.T) {
 	req.SetRequestURI("http://example.com/")
 	req.Header.SetMethod(fasthttp.MethodGet)
 
-	err := followRedirects(cli, req, resp, 1, mustParseTestURL(t, "http://example.com/"), DefaultSecurityPolicy())
+	err := followRedirects(cli, req, resp, 1, mustParseTestURL(t, "http://example.com/"), DefaultSecurityPolicy(), true)
 	require.ErrorIs(t, err, sentinel)
 }
 
diff --git a/middleware/redirect/redirect_test.go b/middleware/redirect/redirect_test.go
index 4d01c4eb4e7..c776f5c451f 100644
--- a/middleware/redirect/redirect_test.go
+++ b/middleware/redirect/redirect_test.go
@@ -3,9 +3,13 @@ package redirect
 import (
 	"context"
 	"net/http"
+	"net/url"
+	"strconv"
+	"strings"
 	"testing"
 
 	"github.com/gofiber/fiber/v3"
+	"github.com/gofiber/fiber/v3/internal/urlnorm"
 	"github.com/stretchr/testify/require"
 )
 
@@ -164,160 +168,2596 @@ func Test_Redirect_StartAnchor(t *testing.T) {
 	require.Empty(t, resp.Header.Get("Location"))
 }
 
+// Test_Redirect_SameOriginTargets verifies that captured path segments cannot
+// turn a path-only target into a redirect off this origin.
+//
+// The path arrives with its slash runs intact, so the documented rule
+// "/api/*" -> "/$1" composed "Location: //evil.com" from a request for
+// "/api//evil.com" — a network-path reference the browser follows to evil.com —
+// and "/redirect/*" -> "$1" composed an outright absolute redirect from
+// "/redirect/https://evil.com".
+func Test_Redirect_SameOriginTargets(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		pattern string
+		target  string
+		request string
+		want    string
+	}{
+		{"protocol relative", "/api/*", "/$1", "/api//evil.com", "/evil.com"},
+		{"long slash run", "/redirect/*", "$1", "/redirect///evil.com", "/evil.com"},
+		{"absolute url", "/redirect/*", "$1", "/redirect/https://evil.com", "/https://evil.com"},
+		{"non fetch scheme", "/redirect/*", "$1", "/redirect/javascript:x", "/javascript:x"},
+
+		// Same-origin composition is untouched.
+		{"ordinary capture", "/api/*", "/$1", "/api/users", "/users"},
+		{"capture below a prefix", "/old/*", "/new/$1", "/old//evil.com", "/new//evil.com"},
+		{"relative reference", "/g", "google.com", "/g", "google.com"},
+
+		// A target that names its own authority is the author's call, so it is
+		// left exactly as configured.
+		{"absolute target", "/ext/*", "https://cdn.example.com/$1", "/ext/a", "https://cdn.example.com/a"},
+		{"protocol relative target", "/pr/*", "//cdn.example.com/$1", "/pr/a", "//cdn.example.com/a"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{
+				Rules:      map[string]string{tc.pattern: tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_SameOriginTargets_Unescaped covers the same guard when
+// UnescapePath decodes the capture before it is spliced in.
+//
+// Two rewrites reach a Location before anything navigates: a recipient strips
+// leading and trailing whitespace from the field value (RFC 9110 Section 5.5),
+// and the WHATWG URL parser removes every ASCII tab, LF and CR before parsing.
+// Checking the composed bytes alone missed both, so " //evil.com" and
+// "/\t/evil.com" still reached evil.com.
+func Test_Redirect_SameOriginTargets_Unescaped(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		pattern string
+		target  string
+		request string
+		want    string
+	}{
+		{"leading space", "/r/*", "$1", "/r/%20//evil.com", "/evil.com"},
+		{"leading tab", "/r/*", "$1", "/r/%09//evil.com", "/evil.com"},
+		{"tab before scheme", "/r/*", "$1", "/r/%09https://evil.com", "/https://evil.com"},
+		{"interior tab", "/api/*", "/$1", "/api/%09/evil.com", "/evil.com"},
+
+		// A space is not removed by the URL parser — it gets percent-encoded —
+		// so an interior one cannot form an authority and is left alone.
+		{"interior space", "/api/*", "/$1", "/api/%20/evil.com", "/ /evil.com"},
+		{"ordinary capture", "/api/*", "/$1", "/api/users", "/users"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{tc.pattern: tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_CaptureInsideAuthority asserts that a capture spliced into the
+// target's own authority cannot cut that authority short and pick a different
+// host.
+//
+// A target like "https://$1.assets.example.com/" is a plausible way to route
+// per tenant, and the author means $1 to be a label. A capture holding
+// "evil.com/x" composed "https://evil.com/x.assets.example.com/", whose
+// authority ends at that slash — so the browser went to evil.com.
+func Test_Redirect_CaptureInsideAuthority(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"slash escapes the label", "https://$1.assets.example.com/", "/cdn/evil.com/x", ""},
+		{"slash escapes a mid-authority label", "https://assets.$1.com", "/cdn/evil.com/x", ""},
+		{"protocol relative target", "//$1.assets.example.com/", "/cdn/evil.com/x", ""},
+		{"question mark escapes", "https://$1.assets.example.com/", "/cdn/evil.com%3Fa", ""},
+
+		// An "@" makes everything before it userinfo, so the host becomes the
+		// capture's — no authority-ending byte required.
+		{"at sign makes the host userinfo", "https://$1.assets.example.com/", "/cdn/a@evil.com", ""},
+		{"at sign at the end of the authority", "https://cdn.example.com$1", "/cdn/@evil.com", ""},
+		// A capture that does not open a new component extends the host the
+		// author wrote.
+		{"bare value extends the host", "https://cdn.example.com$1", "/cdn/x", ""},
+
+		// A clean label still composes.
+		{"clean label", "https://$1.assets.example.com/", "/cdn/images", "https://images.assets.example.com/"},
+		{"clean label protocol relative", "//$1.assets.example.com/", "/cdn/images", "//images.assets.example.com/"},
+
+		// A capture in the path may hold slashes freely — it cannot reach the
+		// authority, which the target fixed.
+		{"path capture keeps slashes", "https://cdn.example.com/$1", "/cdn/a/b/c", "https://cdn.example.com/a/b/c"},
+		{"path capture with a host-like value", "https://cdn.example.com/$1", "/cdn/evil.com/x", "https://cdn.example.com/evil.com/x"},
+
+		// A target handing the whole authority to the capture would let the
+		// request choose the host, so the rule never fires. New warns why.
+		{"whole authority is the capture", "https://$1", "/cdn/anything/x", ""},
+		{"protocol relative whole authority", "//$1", "/cdn/anything", ""},
+		{"scheme with no authority", "https:$1", "/cdn//evil.com", ""},
+		// Separators alone pin nothing, so a value opening a path does not end
+		// an authority the author never wrote: "///evil.com." is read host-first.
+		{"separator only before the capture", "//$1.", "/cdn/evil.com", ""},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/cdn/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_CaptureInUserinfo covers a capture the author placed before an
+// "@" they wrote themselves. The host starts after the last "@", so the value is
+// userinfo: ":" separates a password there and a further "@" only lengthens it,
+// while the four bytes that end an authority outright still have to stay out.
+func Test_Redirect_CaptureInUserinfo(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"password", "https://$1@example.com/", "/cdn/user%3Apassword", "https://user:password@example.com/"},
+		{"further at sign", "https://$1@example.com/", "/cdn/a%40evil.com", "https://a@evil.com@example.com/"},
+		{"plain userinfo", "https://$1@example.com/", "/cdn/user", "https://user@example.com/"},
+
+		// The four that end the authority reach the host past the "@".
+		{"slash", "https://$1@example.com/", "/cdn/evil.com%2Fx", ""},
+		{"backslash", "https://$1@example.com/", "/cdn/evil.com%5Cx", ""},
+		{"question mark", "https://$1@example.com/", "/cdn/evil.com%3Fx", ""},
+		{"fragment", "https://$1@example.com/", "/cdn/evil.com%23x", ""},
+
+		// Past the author's "@" the capture is a host label again, so the label
+		// rule applies to it as it would anywhere else in the host.
+		{"label after the at sign", "https://user@$1.example.com/", "/cdn/a%3Ab", ""},
+		{"clean label after the at sign", "https://user@$1.example.com/", "/cdn/images", "https://user@images.example.com/"},
+	}
+
+	// Every composed location names a host the author wrote, whatever the value
+	// put in the userinfo before it.
+	const wantHost = "example.com"
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/cdn/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+
+			// Whatever the value did, the host is still the author's — a label
+			// they left to the capture sits under it.
+			u, err := url.Parse(resp.Header.Get("Location"))
+			require.NoError(t, err)
+			require.True(t, u.Host == wantHost || strings.HasSuffix(u.Host, "."+wantHost), "host %q", u.Host)
+		})
+	}
+}
+
+// Test_Redirect_CaptureEndingTheAuthority covers a target whose placeholder
+// ends its authority, which is a natural way to keep the request's own path:
+// the capture must open a new component rather than extend the host.
+func Test_Redirect_CaptureEndingTheAuthority(t *testing.T) {
+	t.Parallel()
+
+	// "/cdn*" leaves the leading slash in the capture, so $1 supplies the path.
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules:      map[string]string{"/cdn*": "https://cdn.example.com$1"},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	get := func(target string) (int, string) {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, target, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		return resp.StatusCode, resp.Header.Get("Location")
+	}
+
+	status, location := get("/cdn/foo.png")
+	require.Equal(t, fiber.StatusFound, status, "a capture that opens a path must still redirect")
+	require.Equal(t, "https://cdn.example.com/foo.png", location)
+
+	status, location = get("/cdn/a/b/c")
+	require.Equal(t, fiber.StatusFound, status)
+	require.Equal(t, "https://cdn.example.com/a/b/c", location)
+
+	// The capture carries the '@' into the path, past the authority, so the
+	// host is still the author's.
+	status, location = get("/cdn/@evil.com")
+	require.Equal(t, fiber.StatusFound, status)
+	require.Equal(t, "https://cdn.example.com/@evil.com", location)
+}
+
+func Test_AuthorityChunks(t *testing.T) {
+	t.Parallel()
+
+	requireNoAuthorityChunks(t, "https://cdn.example.com/$1", "no token in the authority")
+	requireNoAuthorityChunks(t, "/$1", "no authority at all")
+	requireNoAuthorityChunks(t, "mailto:$1", "a scheme with no // has no authority")
+	requireNoAuthorityChunks(t, "https://cost$.example.com/", "a bare $ is literal text")
+
+	// pins is answered once here, so it is part of what the split produces.
+	require.Equal(t, []authorityChunk{
+		{text: "$1", placeholder: true},
+		{text: ".assets.example.com", pins: true},
+	}, authorityChunks("https://$1.assets.example.com/x"))
+
+	require.Equal(t, []authorityChunk{
+		{text: "cdn.example.com", pins: true},
+		{text: "$1", placeholder: true},
+	}, authorityChunks("https://cdn.example.com$1"))
+
+	require.Equal(t, []authorityChunk{
+		{text: "assets.", pins: true},
+		{text: "$1", placeholder: true},
+		{text: ".com", pins: true},
+	}, authorityChunks("https://assets.$1.com"))
+
+	// And a literal that pins nothing is recorded as such.
+	require.Equal(t, []authorityChunk{
+		{text: "$1", placeholder: true},
+		{text: ":8080"},
+	}, authorityChunks("https://$1:8080"))
+
+	// A literal between two captures is open on the left, unlike one that
+	// starts the authority — the only place that distinction is made.
+	require.Equal(t, []authorityChunk{
+		{text: "$1", placeholder: true},
+		{text: "xyz:"},
+		{text: "$2", placeholder: true},
+	}, authorityChunks("https://$1xyz:$2"))
+
+	require.Equal(t, []authorityChunk{
+		{text: "xyz.example.com", pins: true},
+		{text: "$1", placeholder: true},
+	}, authorityChunks("https://xyz.example.com$1"))
+
+	// A target that is nothing but the token: the author picked the
+	// destination outright, and authorityHolds leaves it alone.
+	require.Equal(t, []authorityChunk{{text: "$1", placeholder: true}}, authorityChunks("https://$1"))
+	require.Equal(t, []authorityChunk{{text: "$12", placeholder: true}}, authorityChunks("//$12"))
+}
+
+// Test_Redirect_CaptureBoundedByTheTarget covers a token that closes the
+// authority but not the target — a port, or a host prefix with a path after it.
+//
+// Such a token is bounded by the author's own text, so it takes the content
+// check rather than the "must open the next component" rule. Treating it like a
+// token at the end of the target made every real value fail that rule, and the
+// affected rules silently stopped redirecting.
+func Test_Redirect_CaptureBoundedByTheTarget(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"port", "https://cdn.example.com:$1/health", "/t/8080", "https://cdn.example.com:8080/health"},
+
+		// The value is still part of the authority, so it may not restructure it.
+		{"at sign in a port", "https://cdn.example.com:$1/health", "/t/80@evil.com", ""},
+
+		// A capture that ends the host is refused even where the target
+		// continues past it: "evil.com" would compose "example.comevil.com",
+		// a domain someone can register. What follows in the target makes no
+		// difference, because the host is already decided by then.
+		{"host extended before a path", "https://example.com$1/health", "/t/evil.com", ""},
+		{"host prefix with a path after", "https://tenant-$1/app", "/t/evil.com", ""},
+		{"slash in a host prefix", "https://tenant-$1/app", "/t/evil.com%2Fx", ""},
+		// Opening a path closes the host at the author's own text.
+		{"capture opens a path", "https://example.com$1/health", "/t/%2Ffoo", "https://example.com/foo/health"},
+
+		// A token right after the port colon ends the target, but a port cannot
+		// extend a host and the URL parser rejects a non-numeric one outright,
+		// so a digit run is honored.
+		{"port at the end of the target", "https://cdn.example.com:$1", "/t/8080", "https://cdn.example.com:8080"},
+		{"non-numeric port", "https://cdn.example.com:$1", "/t/80@evil.com", ""},
+		{"port extended into a host", "https://cdn.example.com:$1", "/t/8080.evil.com", ""},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/t/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_CaptureClosingTheHost covers the two ways a capture can end up
+// naming the host even though it is not the last chunk of the target's
+// authority.
+//
+// A trailing token that resolves to empty contributes nothing, so the one
+// before it closes the host; and a literal made only of the separators that may
+// trail a hostname pins nothing, since "evil.com." is the same host as
+// "evil.com" with the DNS root spelled out. Judging each token by its position
+// alone let "https://$1$2" with an empty $2 treat $1 as an interior label, and
+// the request named the host outright.
+func Test_Redirect_CaptureClosingTheHost(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		pattern string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"empty trailing capture", "/a/*x*", "https://$1$2", "/a/evil.comx", ""},
+		{"empty trailing capture after a dot", "/a/*x*", "https://$1.$2", "/a/evil.comx", ""},
+
+		// An empty trailing capture is fine where the author's own text still
+		// closes the host.
+		{"author text closes the host", "/a/*x*", "https://$1.assets.example.com$2", "/a/tenantx", "https://tenant.assets.example.com"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{
+				Rules:      map[string]string{tc.pattern: tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_TenthCaptureInAuthority pins that the guard judges what the
+// Replacer will actually splice in.
+//
+// strings.Replacer matches its patterns in the order they were given, so "$10"
+// is consumed as "$1" followed by a literal "0". Resolving the token by index
+// instead checked the tenth capture while the first was the one reaching the
+// host, and a rule with ten or more wildcards was an open redirect straight
+// past the guard.
+func Test_Redirect_TenthCaptureInAuthority(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules:      map[string]string{"/t/*/*/*/*/*/*/*/*/*/*": "https://$10.cdn.example.com/"},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet,
+		"/t/evil.com/x/b/c/d/e/f/g/h/i/tenant", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+
+	require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+	require.Empty(t, resp.Header.Get("Location"))
+}
+
+// Test_Redirect_ExtraSlashesBeforeTheCapture covers targets that open their
+// authority with more than two slashes.
+//
+// The URL parser's special-authority-ignore-slashes state skips the whole run
+// before it reads the host, so "///evil.com" is evil.com. Stopping the authority
+// span at the first of those slashes instead made such a target look like it had
+// an empty authority: no chunks for the guard to walk, and still "absolute"
+// enough that the same-origin fallback was skipped too.
+func Test_Redirect_ExtraSlashesBeforeTheCapture(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"three slashes", "///$1", "/go/evil.com", ""},
+		{"four slashes", "////$1", "/go/evil.com", ""},
+		{"slash then backslash", `//\$1`, "/go/evil.com", ""},
+		{"scheme with three slashes", "https:///$1", "/go/evil.com", ""},
+		{"scheme then backslash", `https://\$1`, "/go/evil.com", ""},
+
+		// A host the author wrote after the run is still their choice, and the
+		// capture only reaches the path.
+		{"fixed host after the run", "///static/$1", "/go/x", "///static/x"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{
+				Rules:      map[string]string{"/go/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_OverlappingRulesAreDeterministic pins that two patterns matching
+// the same path resolve the same way on every run.
+//
+// The rules used to be held in a map and walked in its randomized order, so the
+// winner changed run to run — and once a rule could be refused and fall through
+// to the next, so did whether there was a redirect at all.
+func Test_Redirect_OverlappingRulesAreDeterministic(t *testing.T) {
+	t.Parallel()
+
+	build := func() *fiber.App {
+		app := fiber.New()
+		app.Use(New(Config{
+			Rules: map[string]string{
+				"/cdn/*":  "/first/$1",
+				"/cdn/*x": "/second/$1",
+			},
+			StatusCode: fiber.StatusFound,
+		}))
+		app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+		return app
+	}
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/cdn/ax", http.NoBody)
+	require.NoError(t, err)
+	resp, err := build().Test(req)
+	require.NoError(t, err)
+	first := resp.Header.Get("Location")
+	require.NotEmpty(t, first)
+
+	// Rebuilding the middleware re-walks the rules map, which is where the
+	// randomization came from.
+	for range 20 {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/cdn/ax", http.NoBody)
+		require.NoError(t, err)
+		resp, err := build().Test(req)
+		require.NoError(t, err)
+		require.Equal(t, first, resp.Header.Get("Location"))
+	}
+}
+
+// Test_Redirect_PortDoesNotPinTheHost covers a capture followed only by a port.
+//
+// A port closes nothing: "evil.com:8080" is still evil.com. Counting the
+// literal ":8080" as author-written host text left the capture beside it judged
+// as a harmless interior label, and the request named the host outright.
+func Test_Redirect_PortDoesNotPinTheHost(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		pattern string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"literal port after a capture", "/p/*", "https://$1:8080", "/p/evil.com", ""},
+		{"protocol relative with a port", "/p/*", "//$1:8080", "/p/evil.com", ""},
+		{"captured host and port", "/p/*/*", "https://$1:$2", "/p/evil.com/443", ""},
+
+		// A host the author actually wrote still pins, port or no port.
+		{"port after author host text", "/p/*", "https://$1.cdn.example.com:8080", "/p/images", "https://images.cdn.example.com:8080"},
+		{"captured port only", "/p/*", "https://cdn.example.com:$1", "/p/8080", "https://cdn.example.com:8080"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{
+				Rules:      map[string]string{tc.pattern: tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_MoreSpecificRuleWins pins that a rule pinning more of the path
+// is evaluated before one that pins less.
+//
+// Ordering the rules made evaluation deterministic, but plain lexicographic
+// order sorts "/*" ahead of "/old/*", so the catch-all would shadow the
+// specific rule on every request instead of half the time.
+func Test_Redirect_MoreSpecificRuleWins(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			"/*":     "/home",
+			"/old/*": "/new/$1",
+		},
+		StatusCode: fiber.StatusFound,
+	}))
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/old/thing", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, "/new/thing", resp.Header.Get("Location"))
+
+	// The catch-all still covers everything the specific rule does not.
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/other", http.NoBody)
+	require.NoError(t, err)
+	resp, err = app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, "/home", resp.Header.Get("Location"))
+}
+
+// Test_TargetLetsRequestPickHost pins which target shapes hand the destination
+// to the request. "https:$1" is the awkward one: it names no authority for the
+// chunk check to guard and no origin for keepSameOrigin to hold it to, yet a
+// captured "//evil.com" still composes "https://evil.com".
+//
+// The shapes that pin only a port, a trailing dot or userinfo belong here too.
+// authorityHolds refuses every value for them, so before they were listed the
+// rule compiled, matched each request, was refused, and fell through — while
+// warning that values opening a path or query were honored, when none were.
+func Test_TargetLetsRequestPickHost(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		target string
+		want   bool
+	}{
+		{"https://$1", true},
+		{"//$1", true},
+		{"https:$1", true},
+		// The parser's missing-solidus step gives every special scheme but file
+		// an authority, so a capture after the colon names the host with no
+		// slash of its own: "ws:evil.com" is ws://evil.com.
+		{"ws:$1", true},
+		{"wss:$1", true},
+		{"ftp:$1", true},
+		{"WS:$1", true},
+		{"FTP:$1", true},
+		// file has no missing-solidus reading, but a captured "//evil.com" opens
+		// an authority for it like any other scheme.
+		{"file:$1", true},
+		// Any scheme at all: "//" is what opens the authority, so which scheme
+		// it is does not enter into it.
+		{"mailto:$1", true},
+		{"myapp:$1", true},
+		{"custom:$1", true},
+		// Author text between the colon and the capture leaves no authority for
+		// the value to open, or one the author already filled in.
+		{"myapp:fixed/$1", false},
+		{"https:fixed/$1", false},
+		// Nothing beside the capture is host text: a port, a captured port, a
+		// second capture and a trailing dot all pin nothing, so the value names
+		// the host on its own.
+		{"https://$1:8080", true},
+		{"https://$1:8080/health", true},
+		{"https://$1:$2", true},
+		{"https://$1$2", true},
+		{"//$1.", true},
+		{"//.$1", true},
+		// Text before an "@" is a username, not a host.
+		{"https://example.com@$1", true},
+		{"https://user:pw@$1", true},
+		// A capture inside the brackets is refused whichever side the author
+		// wrote: a bracketed address runs most significant group first, so the
+		// ordinary "text after the capture pins it" reading is backwards there.
+		{"https://[$1]", true},
+		{"https://[$1]:8080/", true},
+		{"https://[$1::1]", true},
+		{"https://[2001:db8::$1]", true},
+		{"https://[2001:db8::$1]:8080", true},
+
+		// A scheme with no authority syntax has no host to hijack, so it is not
+		// refused — dropping it would kill a working rule and the warning would
+		// say something untrue about it.
+		{"mailto:$1@example.com", false},
+		{"myapp:$1@example.com", false},
+
+		{"https://$1.example.com", false},
+		{"https://cdn.example.com$1", false},
+		{"https://cdn.example.com/$1", false},
+		// The same rules spelled without the "//". A special scheme reaches the
+		// authority state either way, so the two spellings have to be read the
+		// same: the capture here is a label under the author's host, and it is
+		// authorityHolds that judges each value for it.
+		{"https:$1.example.com", false},
+		{"https:cdn.example.com$1", false},
+		{"https:cdn.$1.com", false},
+		{"ws:$1.example.com", false},
+		{"ftp:cdn.example.com$1", false},
+		{"HTTPS:$1.example.com", false},
+		// And where nothing but a port or a dot sits beside it, refused in
+		// either spelling.
+		{"https:$1:8080", true},
+		{"ws:$1.", true},
+		{"https:example.com@$1", true},
+		// The author's host text can sit either side of the capture, and a
+		// captured port leaves it theirs.
+		{"https://$1@example.com", false},
+		{"https://cdn.example.com:$1", false},
+		{"https://tenant-$1.example.com", false},
+		// A bracketed literal the author wrote in full still pins the host, so
+		// a captured port beside it is theirs to allow.
+		{"https://[::1]:$1", false},
+		{"https://[::1]:8080/$1", false},
+		{"https://[::]:$1", false},
+		{"https://[2001:db8::1]:$2/$1", false},
+		// A bracket in userinfo is an ordinary character, not a host delimiter,
+		// so it does not make the capture beside it interior to an address.
+		{"https://[$1]@example.com", false},
+		{"https://us[er@$1.example.com", false},
+		{"https://us[er@example.com:$1", false},
+		// Empty brackets pin no host, so the capture names it outright.
+		{"https://[]$1", true},
+		{"https://[:]:$1", true},
+		// Only an "@" outside the brackets ends the userinfo. One inside them
+		// is no delimiter to the URL parser either, so the brackets still hold
+		// the host and a capture among them still chooses the address.
+		{"https://[$1@::1]", true},
+		{"https://[2001:db8::$1@a]", true},
+		{"https://x@y@[$1::1]", true},
+		// Past the closing bracket the "@" does end the userinfo, so these name
+		// the host after it and the capture only reaches userinfo.
+		{"https://[$1]@x", false},
+		{"https://[$1::1]@a", false},
+		{"https://$1@[::1]", false},
+		// Whereas here the capture is the host.
+		{"https://[::1]@$1", true},
+		{"/$1", false},
+		{"$1", false},
+		{"https://cdn.example.com", false},
+		{"mailto:someone@example.com", false},
+	} {
+		require.Equal(t, tc.want, targetLetsRequestPickHost(tc.target, authorityChunks(tc.target)), "target %q", tc.target)
+	}
+}
+
+// Test_PinsHost pins the three things that are not author-written host text: a
+// port, the separators that may trail a hostname, and userinfo.
+func Test_PinsHost(t *testing.T) {
+	t.Parallel()
+
+	// wantClosed is the answer when a label separator, an "@" or the start of
+	// the authority stands between the capture and this literal.
+	for _, tc := range []struct {
+		literal string
+		want    bool
+	}{
+		{"cdn.example.com", true},
+		{"cdn.example.com:", true},
+		{"cdn.example.com:8080", true},
+		{".example.com", true},
+		{"@example.com", true},
+		{"user:pw@example.com", true},
+
+		// An IPv6 literal's own colons sit inside the brackets, so the port is
+		// what follows the closing one.
+		{"[::1]", true},
+		{"[::1]:", true},
+		{"[::1]:8080", true},
+		{"[2001:db8::1]", true},
+		// The unspecified address is still a complete one the author wrote.
+		{"[::]", true},
+		{"[::]:", true},
+		// An opener with no closer is a fragment of an address some capture
+		// split, so it pins nothing on its own — the mirror of "::1]" above.
+		{"[2001:db8::", false},
+		{"[::", false},
+		{"[abc", false},
+		{"[fe80", false},
+		// Decided by the fragment rule alone: with a dot of its own it is not
+		// dotless, and it holds no hex tail, so nothing else would refuse it.
+		{"[example.com", false},
+
+		{"", false},
+		{":8080", false},
+		{".", false},
+		{"..", false},
+		{"::", false},
+		// Everything through the last "@" is userinfo, so nothing is left.
+		{"example.com@", false},
+		{"user:pw@", false},
+		{"example.com@:8080", false},
+		// The brackets around an IPv6 literal are punctuation, so a target of
+		// "https://[$1]:8080" pins no more of the host than "https://$1:8080".
+		{"[", false},
+		{"]", false},
+		{"]:8080", false},
+		// Brackets holding no address pin nothing. Counting them bought a rule
+		// that matched every request and composed a location no client parses.
+		{"[]", false},
+		{"[:]", false},
+		{"[.]", false},
+		{"[[]", false},
+		// Holding a hex digit is not the same as being an address.
+		{"[zzz1]", false},
+		{"[evil.com1]", false},
+		{"[a b]", false},
+		// Brackets hold an IPv6 address only, so an IPv4 one is no host there
+		// however well it parses alone — but the IPv4-mapped IPv6 spelling is.
+		{"[127.0.0.1]", false},
+		{"[1.2.3.4]", false},
+		{"[::ffff:127.0.0.1]", true},
+		{"[0:0:0:0:0:0:0:1]", true},
+		// A zone ID is not accepted in a URL host, by this or by the parser.
+		{"[fe80::1%25eth0]", false},
+		// Whitespace is not host text: the parser deletes a tab outright and
+		// percent-encodes a space into a host that fails to parse.
+		{" ", false},
+		{"\t", false},
+		{"\n", false},
+		{" \t ", false},
+		// Nor is anything UTS #46 mapping deletes before a host is read, nor
+		// the code points it folds onto a plain ".", which pins nothing either.
+		{"\u00ad", false}, // soft hyphen
+		{"\ufeff", false}, // zero width no-break space
+		{"\u200b", false}, // zero width space
+		{"\u2060", false}, // word joiner
+		{"\ufe0f", false}, // variation selector
+		{"\u3002", false}, // ideographic full stop
+		{"\uff0e", false}, // fullwidth full stop
+		{"\uff61", false}, // halfwidth ideographic full stop
+		{"\u00ad\u200b", false},
+		// A control character is stripped from either end of the whole input
+		// before the parser reads anything, and is forbidden in a host in the
+		// middle, so it pins nothing wherever it sits.
+		{"\x00", false},
+		{"\x01", false},
+		{"\x1f", false},
+		{"\x7f", false},
+		// The parser percent-decodes a host before reading it, so an escape
+		// pins only what it stands for.
+		{"%2E", false},       // "."
+		{"%2e", false},       // same, lowercased
+		{"%C2%AD", false},    // soft hyphen
+		{"%E3%80%82", false}, // ideographic full stop
+		{"%EF%BB%BF", false}, // BOM
+		// "A" is host text, but alone it is a hex tail a capture can turn into
+		// a number by supplying "0x" — so it pins only where a label already
+		// separates it from whatever came before.
+		{"%41", false},
+		{"%41.example.com", true},
+		// A stray "%" is literal to the parser, not an error — though dotless,
+		// so nothing here pins on its own account.
+		{"100%", false},
+		{"a%zz", false},
+		// A host whose last label reads as a number is an IPv4 address, where
+		// the author's trailing text is the low octets and the request supplies
+		// the network. Only a complete address pins one.
+		{".1", false},
+		{".0", false},
+		{".0.0.1", false},
+		{".0x1", false},
+		// A hex tail is one a capture can open a number with, by supplying the
+		// "0x" — or finish a percent-escape it left dangling.
+		{"cafe", false},
+		{"beef", false},
+		{"e", false},
+		{"ad", false},
+		{"x", false},
+		{"xcafe", false},
+		// Invalid UTF-8 is not host text: the mapping turns it into U+FFFD,
+		// which no client accepts in a host.
+		{"\xff.example.com", false},
+		{"%FF.example.com", false},
+		{"\xed\xa0\x80.example.com", false},
+
+		// Nor does any other dotless tail: the head the capture supplies can
+		// simply end with a dot, leaving the author's text a bare final label —
+		// "https://$1xyz" reached evil.xyz from a captured "evil.".
+		{"cdn", false},
+		{"xyz", false},
+		{"tenant-", false},
+		{"com", false},
+		// A trailing dot is not a label separator against what precedes it, and
+		// the trim takes it off, so these are dotless too.
+		{"xyz.", false},
+		{"com.", false},
+		// A leading "." closes the label, so an all-hex suffix is a suffix —
+		// ".de" pins Germany the way ".example.com" pins that domain.
+		{".de", true},
+		{".be", true},
+		{".cc", true},
+		{".ad", true},
+		{".cafe", true},
+		{".e", true},
+		// Even a whole address: open on the left the capture reaches its first
+		// octet, which is the network.
+		{"127.0.0.1", false},
+		{"10.0.0.1", false},
+		// A name is still a name, whatever letters it is made of.
+		{"abc.def", true},
+		{".example.com", true},
+		{"example1.com", true},
+		// An internationalized label is host text, in either spelling.
+		{"\u4f8b\u3048.jp", true},
+		{"xn--r8jz45g.jp", true},
+		// A closer with no opener is the tail of an address a capture split,
+		// and an IPv6 tail is the low bits, not the network it routes to.
+		{"::1]", false},
+		{":db8::1]", false},
+	} {
+		require.Equal(t, tc.want, pinsHost(tc.literal, true), "literal %q", tc.literal)
+	}
+
+	// The closed-on-the-left branch: a dotless tail the capture cannot reach
+	// pins the host, which is what keeps "https://[$1]@x" and
+	// "https://cdn$1.example.com" compiling.
+	for _, tc := range []struct {
+		literal string
+		want    bool
+	}{
+		{"cdn", true},
+		{"xyz", true},
+		{"cafe", true},
+		{"x", true},
+		{"tenant-", true},
+		{"example.com", true},
+		{"xyz.", true},
+		{"127.0.0.1", true}, // the author wrote the whole address
+		{"10.0.0.1", true},
+
+		// A bare number is an address rather than a name, and the parser takes
+		// the abbreviated spellings too: "1" is 0.0.0.1 and "0x1" the same, so
+		// the author who wrote one pinned the whole host.
+		{"1", true},
+		{"0x1", true},
+
+		{"", false},
+		{".", false},
+		{"[example.com", false},
+		// Closed on the left the dotless rule no longer stands in front of the
+		// decode, map and trim steps, so this is where each answers for itself:
+		// a code point the mapping deletes, ones the trim drops, and delimiters
+		// that only appear once the escape is decoded.
+		{"\u00ad", false},
+		{"\u200b", false},
+		{"\u3002example.com", true}, // folds to ".example.com"
+		{"\x7f", false},
+		{" ", false},
+		{"[", false},
+		{":", false},
+		{"%7F", false},
+		{"%2E", false},
+		{"%3A", false},
+		{"%5B", false},
+		// The trim has to run on the front too: keeping the space leaves a
+		// last label of " 1", which reads as no number, and the address check
+		// never runs on what is really the address 1.
+		{" 1", true},
+		{"%201", true},
+		{"%3A0x", true}, // "0x" is a number too, and it is zero
+	} {
+		require.Equal(t, tc.want, pinsHost(tc.literal, false), "literal %q closed on the left", tc.literal)
+	}
+}
+
+func Test_AuthoritySpan(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		in         string
+		start, end int
+	}{
+		{"https://cdn.example.com/$1", 8, 23},
+		{"https://$1.example.com", 8, 22},
+		{"//cdn.example.com/a", 2, 17},
+		{"//cdn.example.com", 2, 17},
+		{"https://cdn.example.com", 8, 23},
+		{"https://cdn.example.com?q=1", 8, 23},
+		{`https://cdn.example.com\x`, 8, 23},
+		// No authority: a path-only target, or a scheme with no "//".
+		{"/$1", 0, 0},
+		{"$1", 0, 0},
+		{"mailto:someone@example.com", 0, 0},
+		{"", 0, 0},
+	} {
+		start, end := authoritySpan(tc.in)
+		require.Equal(t, tc.start, start, "start for %q", tc.in)
+		require.Equal(t, tc.end, end, "end for %q", tc.in)
+	}
+}
+
+func Test_AsBrowserReads(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ in, want string }{
+		{" //evil.com", "//evil.com"},
+		{"/\t/evil.com", "//evil.com"},
+		{"/\r\n/evil.com", "//evil.com"},
+		{"\t\t//evil.com", "//evil.com"},
+		{"/a/b  ", "/a/b"},
+		{"/ /evil.com", "/ /evil.com"}, // an interior space survives
+		{"/clean/path", "/clean/path"},
+		{"", ""},
+		{" \t ", ""},
+	} {
+		require.Equal(t, tc.want, urlnorm.AsBrowserReads(tc.in), "input %q", tc.in)
+	}
+}
+
+func Test_Redirect_SameOriginTargets_QueryPreserved(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules:      map[string]string{"/api/*": "/$1"},
+		StatusCode: fiber.StatusFound,
+	}))
+
+	// The query is appended after the location is made same-origin, so it
+	// survives the collapse untouched.
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/api//evil.com?a=1&b=2", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, "/evil.com?a=1&b=2", resp.Header.Get("Location"))
+}
+
+func Test_SchemeEnd(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		in   string
+		want int
+	}{
+		{"https://evil.com", 5},
+		{"javascript:x", 10},
+		{"a:", 1},
+		{"h+t-t.p1://x", 8},
+		{"", -1},
+		{":", -1},          // a scheme cannot be empty
+		{"1http://x", -1},  // nor start with a digit
+		{"/https://x", -1}, // already rooted, so not a scheme
+		{"//evil.com", -1},
+		{"google.com", -1}, // no colon at all
+		{"/a/b?x=1:2", -1}, // the colon is past the path separator
+	} {
+		require.Equal(t, tc.want, schemeEnd(tc.in), "input %q", tc.in)
+	}
+}
+
 func Test_Next(t *testing.T) {
 	// Case 1 : Next function always returns true
 	app := *fiber.New()
 	app.Use(New(Config{
-		Next: func(fiber.Ctx) bool {
-			return true
-		},
+		Next: func(fiber.Ctx) bool {
+			return true
+		},
+		Rules: map[string]string{
+			"/default": "google.com",
+		},
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	// Case 2 : Next function always returns false
+	app = *fiber.New()
+	app.Use(New(Config{
+		Next: func(fiber.Ctx) bool {
+			return false
+		},
+		Rules: map[string]string{
+			"/default": "google.com",
+		},
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err = app.Test(req)
+	require.NoError(t, err)
+
+	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
+	require.Equal(t, "google.com", resp.Header.Get("Location"))
+}
+
+func Test_NoRules(t *testing.T) {
+	// Case 1: No rules with default route defined
+	app := *fiber.New()
+
+	app.Use(New(Config{
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	// Case 2: No rules and no default route defined
+	app = *fiber.New()
+
+	app.Use(New(Config{
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err = app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusNotFound, resp.StatusCode)
+}
+
+func Test_DefaultConfig(t *testing.T) {
+	// Case 1: Default config and no default route
+	app := *fiber.New()
+
+	app.Use(New())
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusNotFound, resp.StatusCode)
+
+	// Case 2: Default config and default route
+	app = *fiber.New()
+
+	app.Use(New())
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err = app.Test(req)
+
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+}
+
+func Test_RegexRules(t *testing.T) {
+	// Case 1: Rules regex is empty
+	app := *fiber.New()
+	app.Use(New(Config{
+		Rules:      map[string]string{},
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+	// Case 2: Rules regex map contains valid regex and well-formed replacement URLs
+	app = *fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			"/default": "google.com",
+		},
+		StatusCode: fiber.StatusMovedPermanently,
+	}))
+
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	require.NoError(t, err)
+	resp, err = app.Test(req)
+
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
+	require.Equal(t, "google.com", resp.Header.Get("Location"))
+
+	// Case 3: Test invalid regex throws panic
+	app = *fiber.New()
+	require.Panics(t, func() {
+		app.Use(New(Config{
+			Rules: map[string]string{
+				"(": "google.com",
+			},
+			StatusCode: fiber.StatusMovedPermanently,
+		}))
+	})
+}
+
+func requireNoAuthorityChunks(t *testing.T, target, msg string) {
+	t.Helper()
+	require.Nil(t, authorityChunks(target), msg)
+}
+
+// Test_Redirect_TargetIsReadAsTheClientWillRead pins that the guard judges the
+// target the URL parser will see, not the bytes as configured.
+//
+// The parser deletes every tab, LF and CR before parsing. Reading the target
+// as written scored one of them as author-written host text that then vanished
+// on the way out, so "https://\t$1" passed as a target naming its own host and
+// a captured "/evil.com" composed "https:///evil.com" — evil.com to a browser,
+// with no startup warning. A tab also defeated the leading-slash skip in
+// authoritySpan, leaving the authority of "https://\t/[$1::1]" unguarded
+// entirely, which reached "[beef::1]" and "[::ffff:127.0.0.1]".
+func Test_Redirect_TargetIsReadAsTheClientWillRead(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name    string
+		target  string
+		request string
+	}{
+		{"tab before the host", "https://\t$1", "/r/%2Fevil.com"},
+		{"newline before the host", "https://\n$1", "/r/%2Fevil.com"},
+		{"carriage return before the host", "https://\r$1", "/r/%2Fevil.com"},
+		{"protocol relative", "//\t$1", "/r/%2Fevil.com"},
+		{"tab defeating the slash skip", "https://\t/$1", "/r/evil.com"},
+		{"tab hiding a bracketed capture", "https://\t/[$1::1]", "/r/beef"},
+		{"tab before a bracketed capture", "https://\t[2001:db8::$1]", "/r/8080"},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+			app.Get("/r/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_TargetWhitespaceLeavesWorkingRulesAlone is the other half: the
+// normalization above must not disturb a target that never had any.
+func Test_Redirect_TargetWhitespaceLeavesWorkingRulesAlone(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		target, request, want string
+	}{
+		{"https://cdn.example.com/$1", "/r/a", "https://cdn.example.com/a"},
+		{"https://$1.example.com/", "/r/tenant", "https://tenant.example.com/"},
+		{"https://[::1]:$1/health", "/r/8080", "https://[::1]:8080/health"},
+		{"/new/$1", "/r/a", "/new/a"},
+	} {
+		t.Run(tc.target, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_HostTextTheParserDeletes pins that a target cannot be made to
+// look host-pinned with characters a URL parser drops before it reads the host.
+//
+// UTS #46 mapping runs on a domain before anything looks at it: it deletes some
+// 270 code points outright and folds three more onto a plain ".". Judging the
+// literal on its bytes let an invisible one stand in for a host — so
+// "https://$1\u00ad" compiled with no warning, and a captured "evil.com"
+// composed "https://evil.com\u00ad", which a browser resolves to evil.com.
+func Test_Redirect_HostTextTheParserDeletes(t *testing.T) {
+	t.Parallel()
+
+	for _, suffix := range []string{"\u00ad", "\ufeff", "\u200b", "\u2060", "\ufe0f", "\u3002", "\uff0e", "\uff61"} {
+		t.Run(strconv.QuoteToASCII(suffix), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": "https://$1" + suffix}}))
+			app.Get("/r/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/evil.com", http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_InternationalizedHostsStillPin is the other half: mapping the
+// literal must not cost a rule whose host is written in a non-ASCII script.
+func Test_Redirect_InternationalizedHostsStillPin(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ target, want string }{
+		{"https://$1.\u4f8b\u3048.jp/", "https://t.\u4f8b\u3048.jp/"},
+		{"https://$1.xn--r8jz45g.jp/", "https://t.xn--r8jz45g.jp/"},
+		{"https://$1.example.com/", "https://t.example.com/"},
+	} {
+		t.Run(tc.target, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/t", http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_ControlCharacterPinsNoHost pins the other half of what a client
+// removes before reading a host.
+//
+// The parser strips a leading or trailing run of controls and spaces from the
+// whole input before parsing, and urlnorm.AsBrowserReads does the same to the composed
+// location. So a control character in the target pinned a host that was gone by
+// the time the client saw it: with an empty second capture the rule below
+// composed "https://evil.com\x01" and shipped "https://evil.com".
+func Test_Redirect_ControlCharacterPinsNoHost(t *testing.T) {
+	t.Parallel()
+
+	for _, sep := range []string{"\x00", "\x01", "\x1f", "\x7f"} {
+		t.Run(strconv.QuoteToASCII(sep), func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*x*": "https://$1" + sep + "$2"}}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/evil.comx", http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_PercentEscapePinsOnlyWhatItDecodesTo covers the escaped
+// spelling of the same idea: a URL parser percent-decodes a host before it maps
+// or reads it, so "%2E" is the "." this guard already knows pins nothing, and
+// "%C2%AD" is a soft hyphen the mapping deletes. Judging the escape as written
+// let three ordinary characters stand in for a host.
+func Test_Redirect_PercentEscapePinsOnlyWhatItDecodesTo(t *testing.T) {
+	t.Parallel()
+
+	for _, suffix := range []string{"%2E", "%2e", "%C2%AD", "%E3%80%82", "%EF%BB%BF"} {
+		t.Run(suffix, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": "https://$1" + suffix}}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/evil.com", http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+
+	// An escape that decodes to real host text still pins one.
+	app := fiber.New()
+	app.Use(New(Config{Rules: map[string]string{"/r/*": "https://$1%41.example.com"}}))
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/t", http.NoBody)
+	require.NoError(t, err)
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, "https://t%41.example.com", resp.Header.Get("Location"))
+}
+
+// Test_Redirect_NumericSuffixPinsNoHost covers the IPv4 reading of the same
+// inversion that makes a capture inside an IPv6 literal unjudgeable.
+//
+// A host whose last label reads as a number is parsed as an IPv4 address, so
+// the author's trailing text is the low octets and the capture supplies the
+// network. "https://$1.1" looks like a pinned suffix and composed
+// "https://127.0.0.1" from a captured "127.0.0" — loopback, and 169.254.169.254
+// or a private range just as easily. The IPv4 parser reads hex too, so
+// "https://$1.0x1" did the same.
+func Test_Redirect_NumericSuffixPinsNoHost(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ target, request string }{
+		{"https://$1.1", "/r/127.0.0"},
+		{"https://$1.0x1", "/r/127.0.0"},
+		{"https://$1.0.0.1", "/r/127"},
+		{"https://$1.0", "/r/127.0.0"},
+	} {
+		t.Run(tc.target, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_CompleteAddressStillPins is the other half: an address the
+// author wrote in full is theirs, so a capture beside it is only a port or a
+// path.
+func Test_Redirect_CompleteAddressStillPins(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ target, request, want string }{
+		{"https://127.0.0.1:$1", "/r/8080", "https://127.0.0.1:8080"},
+		{"https://10.0.0.1/$1", "/r/a", "https://10.0.0.1/a"},
+		{"https://$1.example.com", "/r/tenant", "https://tenant.example.com"},
+		{"https://$1.abc.def", "/r/a", "https://a.abc.def"},
+	} {
+		t.Run(tc.target, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_DotlessTailPinsNoHost covers a literal with no dot of its own:
+// it sits inside a label the capture opens on the left, so what the author
+// wrote is only that label's tail and the request decides what the label is.
+//
+// Two tails let the request take the whole label. A tail of hex digits becomes
+// a number once the value supplies "0x" — "https://$1cafe" reached
+// 0.0.202.254, and "https://$1x" turned a captured "127.0.0" into 127.0.0.0 —
+// and the same tails finish a percent-escape the value left open, so
+// "https://$1E" composed "https://evil.com%2E" from "evil.com%2", whose
+// trailing dot pins nothing. That second shape is pinned by the "E" row of
+// Test_PinsHost rather than here, since net/http will not build a request
+// carrying the dangling escape it needs.
+func Test_Redirect_DotlessTailPinsNoHost(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ rule, target, request string }{
+		{"/r/*", "https://$1x", "/r/127.0.0"},
+		{"/r/*", "https://$1x", "/r/10.0.0"},
+		{"/r/*", "https://$1cafe", "/r/0x"},
+		{"/r/*", "https://$1beef", "/r/0x"},
+		// The head can simply end with a dot, which pins nothing at all: the
+		// author's text becomes a bare final label of the request's choosing.
+		{"/r/*", "https://$1xyz", "/r/evil."},
+		{"/r/*", "https://$1com", "/r/evil."},
+		{"/r/*", "https://$1io", "/r/evil."},
+		// The literal sits between two captures, the one place a literal is
+		// open on the left without starting the authority.
+		{"/r/*/*", "https://$1xyz:$2", "/r/evil./8080"},
+		{"/r/*/*", "https://$1cafe:$2", "/r/0x/8080"},
+		// Its only dot is trailing, and a trailing dot separates nothing from
+		// what precedes it.
+		{"/r/*", "https://$1xyz.", "/r/evil."},
+		{"/r/*", "https://$1com.", "/r/evil."},
+		// The address rule only sees these once the port is cut off and the
+		// last label is taken after the trim; skipping either step let them
+		// compile and reach 8.0.0.1 from a captured "0".
+		{"/r/*", "https://$110.0.0.1:8080", "/r/0"},
+		{"/r/*", "https://$110.0.0.1.", "/r/0"},
+	} {
+		t.Run(tc.target+" "+tc.request, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{tc.rule: tc.target}}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must be refused at startup")
+			require.Empty(t, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_ClosedLabelStillPins is the other half: a literal a capture
+// cannot reach into still pins the host. An "@" starts the host, so the capture
+// before it is only userinfo; a dot of the literal's own separates the label;
+// and a tail holding a non-hex byte is one no prefix turns into a number.
+func Test_Redirect_ClosedLabelStillPins(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ target, request, want string }{
+		{"https://$1@example.com/", "/r/user", "https://user@example.com/"},
+		{"https://$1.example.com", "/r/tenant", "https://tenant.example.com"},
+		{"https://$1cdn.example.com", "/r/a", "https://acdn.example.com"},
+		{"https://$1.de", "/r/shop", "https://shop.de"},
+		{"https://$1.cafe", "/r/shop", "https://shop.cafe"},
+		{"https://$1xyz.example.com", "/r/a", "https://axyz.example.com"},
+	} {
+		t.Run(tc.target, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_CarriesQueryOntoTargetsOwnQuery pins how the request's query
+// string joins a target that already has one, or a fragment.
+//
+// Appending "?" + query was right only for a target holding neither. A target
+// with its own query got a second "?", which a URL parser reads as one query
+// string — "/new?from=old" plus "bar=2" became the single parameter
+// "from=old?bar=2" — and a target with a fragment got the query after the "#",
+// where it is read as part of the fragment and the request's query is lost.
+func Test_Redirect_CarriesQueryOntoTargetsOwnQuery(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct{ target, request, want string }{
+		{"/new?from=old", "/old?bar=2", "/new?from=old&bar=2"},
+		{"/new#frag", "/old?bar=2", "/new?bar=2#frag"},
+		{"/new?from=old#frag", "/old?bar=2", "/new?from=old&bar=2#frag"},
+		{"https://cdn.example.com/p?a=1", "/old?b=2", "https://cdn.example.com/p?a=1&b=2"},
+
+		// Unchanged where there was nothing to merge.
+		{"/new", "/old?bar=2", "/new?bar=2"},
+		{"/new?from=old", "/old", "/new?from=old"},
+		{"/new#frag", "/old", "/new#frag"},
+		{"/new", "/old", "/new"},
+	} {
+		t.Run(tc.target+" "+tc.request, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/old": tc.target}}))
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_NoSlashSpecialSchemeAuthorityIsGuarded pins that a target
+// naming its host without the "//" is held to the same rules as one that writes
+// them.
+//
+// A special scheme reaches the authority state either way — "https:host" and
+// "https://host" name the same host — but authoritySpan looked for the slashes,
+// so the no-slash spelling had no authority for the chunk checks to guard and
+// no value was ever refused. "https:cdn.example.com$1" composed
+// "https:cdn.example.com@evil.com", where everything before the "@" is userinfo
+// and evil.com is the host the client reaches.
+func Test_Redirect_NoSlashSpecialSchemeAuthorityIsGuarded(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name   string
+		target string
+		path   string
+		want   string
+	}{
+		{
+			name:   "an @ makes the author's host userinfo",
+			target: "https:cdn.example.com$1",
+			path:   "/r/@evil.com",
+			want:   "",
+		},
+		{
+			name:   "a leading dot extends the host into another domain",
+			target: "https:cdn.example.com$1",
+			path:   "/r/.evil.com",
+			want:   "",
+		},
+		{
+			name:   "ws is special too",
+			target: "ws:cdn.example.com$1",
+			path:   "/r/@evil.com",
+			want:   "",
+		},
+		{
+			name:   "ftp is special too",
+			target: "ftp:cdn.example.com$1",
+			path:   "/r/@evil.com",
+			want:   "",
+		},
+		{
+			// The scheme is case-insensitive, so the reading does not change.
+			name:   "the scheme's own case does not matter",
+			target: "HTTPS:cdn.example.com$1",
+			path:   "/r/@evil.com",
+			want:   "",
+		},
+		{
+			// A label under the author's host is what the rule is for.
+			name:   "an interior label still redirects",
+			target: "https:$1.example.com",
+			path:   "/r/tenant",
+			want:   "https:tenant.example.com",
+		},
+		{
+			name:   "a capture between two literals still redirects",
+			target: "https:cdn.$1.com",
+			path:   "/r/example",
+			want:   "https:cdn.example.com",
+		},
+		{
+			// The "/" ends the authority, so the capture is a path segment and
+			// an "@" in it reaches no host.
+			name:   "past the first slash the capture is a path",
+			target: "https:cdn.example.com/$1",
+			path:   "/r/@evil.com",
+			want:   "https:cdn.example.com/@evil.com",
+		},
+		{
+			// mailto is not special: with no "//" it has no authority at all,
+			// so the capture is an addressee and the author's host follows it.
+			name:   "a scheme that is not special has no implied authority",
+			target: "mailto:$1@example.com",
+			path:   "/r/user",
+			want:   "mailto:user@example.com",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}, StatusCode: fiber.StatusFound}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.path, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "a refused value falls through")
+			}
+		})
+	}
+}
+
+// Test_Redirect_RuleOrderIsBySpecificity pins the order overlapping rules are
+// tried in. A map range gave no order at all, so which rule won changed run to
+// run; ordering by the literal prefix alone fixed the "/*" versus "/old/*" case
+// but left two rules that pin the same prefix tied, and the lexicographic
+// fallback then put the broader one first — where it matches everything the
+// narrower one would, leaving that rule dead.
+func Test_Redirect_RuleOrderIsBySpecificity(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name  string
+		rules map[string]string
+		path  string
+		want  string
+	}{
+		{
+			// Same prefix, so only what each pins past the wildcard separates
+			// them.
+			name:  "a suffix past the wildcard is more specific",
+			rules: map[string]string{"/cdn/*": "/broad", "/cdn/*x": "/narrow"},
+			path:  "/cdn/foox",
+			want:  "/narrow",
+		},
+		{
+			name:  "and the broader rule still takes what the narrower does not",
+			rules: map[string]string{"/cdn/*": "/broad", "/cdn/*x": "/narrow"},
+			path:  "/cdn/foo",
+			want:  "/broad",
+		},
+		{
+			name:  "an extension is a suffix like any other",
+			rules: map[string]string{"/p/*": "/any", "/p/*.png": "/img"},
+			path:  "/p/q.png",
+			want:  "/img",
+		},
+		{
+			// The prefix comparison still decides first: an anchored prefix is
+			// the stronger claim, so the catch-all does not shadow this.
+			name:  "a longer prefix outranks a longer total",
+			rules: map[string]string{"/*": "/catchall", "/old/*": "/new"},
+			path:  "/old/z",
+			want:  "/new",
+		},
+		{
+			name:  "a deeper prefix wins too",
+			rules: map[string]string{"/a/*": "/one", "/a/b/*": "/two"},
+			path:  "/a/b/c",
+			want:  "/two",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{Rules: tc.rules, StatusCode: fiber.StatusFound}))
+			app.Use(func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.path, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_LiteralLengths pins how a rule's pinned length is measured, which is
+// what orders two rules that overlap.
+func Test_LiteralLengths(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		rule      string
+		prefixLen int
+		totalLen  int
+	}{
+		// No wildcard at all: the whole rule is pinned.
+		{rule: "/exact", prefixLen: 6, totalLen: 6},
+		{rule: "/", prefixLen: 1, totalLen: 1},
+		{rule: "", prefixLen: 0, totalLen: 0},
+		// The prefix stops at the first wildcard; the total counts what
+		// follows it too.
+		{rule: "/cdn/*", prefixLen: 5, totalLen: 5},
+		{rule: "/cdn/*x", prefixLen: 5, totalLen: 6},
+		{rule: "/p/*.png", prefixLen: 3, totalLen: 6},
+		{rule: "*", prefixLen: 0, totalLen: 0},
+		{rule: "/a/*/b/*", prefixLen: 3, totalLen: 6},
+
+		// A key is compiled as a regexp, so its metacharacters match something
+		// other than themselves and pin nothing. Counting them as path bytes put
+		// "/api/[a-z]+" ahead of "/api/users", shadowing the exact rule outright.
+		{rule: "/api/[a-z]+", prefixLen: 5, totalLen: 5},
+		{rule: "/api/users", prefixLen: 10, totalLen: 10},
+		{rule: "/(a|b)/x", prefixLen: 1, totalLen: 4},
+		// A group is an alternation too, so it pins what its widest branch pins.
+		{rule: "/api/[a-z](specific|x)", prefixLen: 5, totalLen: 6},
+		// The "?:" of a non-capturing group is syntax, not path.
+		{rule: "/p/(?:ab)", prefixLen: 3, totalLen: 5},
+		// A class escape matches any byte of its class, so it pins none of them
+		// and ends the prefix where it stands.
+		{rule: `/api/\d+`, prefixLen: 5, totalLen: 5},
+		{rule: `/api/\w`, prefixLen: 5, totalLen: 5},
+		// A quantifier's bounds are syntax, and one allowing none of what it
+		// follows takes that back: "/api/a{0,1}" matches "/api/" too.
+		{rule: "/api/a{0,1}", prefixLen: 5, totalLen: 5},
+		{rule: "/api/a{2,3}", prefixLen: 6, totalLen: 6},
+		{rule: "/api/a?b", prefixLen: 5, totalLen: 6},
+		{rule: "/api/(ab)?c", prefixLen: 5, totalLen: 6},
+		// An unclosed brace is an ordinary byte to the regexp parser.
+		{rule: "/api/a{", prefixLen: 6, totalLen: 6},
+		// "." matches any byte, so "/api/user." pins no more than "/api/user".
+		{rule: "/api/user.", prefixLen: 9, totalLen: 9},
+		// Escaped, it matches itself and pins the byte it stands for. Counted in
+		// what a path is pinned to, so the backslash adds nothing to either.
+		{rule: `/p/a\.png`, prefixLen: 8, totalLen: 8},
+		// A complete escape names one character however it is spelled, so it is
+		// as specific as writing that character: "/p/\x{61}" is "/p/a".
+		{rule: `/p/\x{61}`, prefixLen: 4, totalLen: 4},
+		{rule: `/p/\x61`, prefixLen: 4, totalLen: 4},
+		{rule: `/p/\141`, prefixLen: 4, totalLen: 4},
+		{rule: `/p/\t`, prefixLen: 4, totalLen: 4},
+		// An incomplete one names nothing, so it ends the prefix where it
+		// stands. Only the prefix is pinned here: such a rule does not compile,
+		// so nothing downstream of the sort ever sees it.
+		{rule: `/p/\x{61`, prefixLen: 3, totalLen: 5},
+		// An anchor asserts a position and consumes nothing, so it pins no path.
+		{rule: "/p/a$", prefixLen: 4, totalLen: 4},
+		{rule: "/p/[a-z]$", prefixLen: 3, totalLen: 3},
+		{rule: "^/p/a", prefixLen: 0, totalLen: 4},
+		// A class matches one byte whatever it lists, so listing more
+		// alternatives buys no specificity.
+		{rule: "/api/[abcdefghijklmnopqrstuvwxyz]", prefixLen: 5, totalLen: 5},
+		{rule: "/api/[ab]", prefixLen: 5, totalLen: 5},
+		{rule: "/api/[a-z]x", prefixLen: 5, totalLen: 6},
+		// An alternation is only as specific as its least specific branch.
+		{rule: "/very/specific|/x", prefixLen: 2, totalLen: 2},
+		// A "|" inside a group or a class separates no top-level branch.
+		{rule: "/p/[a|b]", prefixLen: 3, totalLen: 3},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.rule, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.prefixLen, literalPrefixLen(tc.rule), "literalPrefixLen")
+			require.Equal(t, tc.totalLen, literalLen(tc.rule), "literalLen")
+		})
+	}
+}
+
+// Test_Redirect_ComposedPort covers one port built from several captures. Each
+// is asked for digits, which is the same question asked of the composition, so
+// the rule holds — requiring every one to sit directly after the colon left it
+// dead for any input at all.
+func Test_Redirect_ComposedPort(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		request string
+		want    string
+	}{
+		{"both captures digits", "/r/80/80", "https://example.com:8080"},
+		{"uneven digits", "/r/8/443", "https://example.com:8443"},
+		{"second capture is not a port", "/r/80/x", ""},
+		{"first capture is not a port", "/r/x/80", ""},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New()
+			app.Use(New(Config{
+				Rules:      map[string]string{"/r/*/*": "https://example.com:$1$2"},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_ExactRuleBeatsPattern covers ordering between a rule written
+// with regexp syntax and an exact one it overlaps. The metacharacters pin no
+// path, so counting them as pinned text made the broad rule win every time.
+func Test_Redirect_ExactRuleBeatsPattern(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			"/api/[a-z]+": "/broad",
+			"/api/users":  "/exact",
+		},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	for _, tc := range []struct{ request, want string }{
+		{"/api/users", "/exact"},
+		{"/api/other", "/broad"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
+
+// Test_Redirect_ExactRuleBeatsDottedPattern is the same ordering question as
+// Test_Redirect_ExactRuleBeatsPattern for the one metacharacter that looks like
+// path text. A "." matches any byte, so it pins nothing and must not tie with
+// the literal it resembles and then win on the lexicographic fallback.
+func Test_Redirect_ExactRuleBeatsDottedPattern(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			"/api/user.": "/broad",
+			"/api/users": "/exact",
+		},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	for _, tc := range []struct{ request, want string }{
+		{"/api/users", "/exact"},
+		{"/api/userx", "/broad"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
+
+// Test_Redirect_NonSpecialSchemeAuthority covers targets under a scheme the
+// WHATWG URL Standard does not call special — a custom deep link.
+//
+// Two things differ there. A "\" is an ordinary authority byte rather than a
+// delimiter, so accepting one as opening the path let a value reach past the
+// author's host into a new one. And a scheme followed by an opaque path names
+// no host at all, so text after the capture only looked like it pinned one:
+// "myapp:$1@example.com" against "//evil.com/x" composed a host of evil.com.
+func Test_Redirect_NonSpecialSchemeAuthority(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		// The capture writes the "//" that opens an authority the target had none of.
+		{"capture opens an authority", "myapp:$1@example.com", "/p/%2F%2Fevil.com%2Fx", ""},
+		{"capture opens one with the target's slash", "myapp:$1/@evil.com", "/p/%2F", ""},
+		// Ordinary userinfo under the same shape still composes.
+		{"plain userinfo", "myapp:$1@example.com", "/p/user", "myapp:user@example.com"},
+		{"mailto", "mailto:$1@example.com", "/p/bob", "mailto:bob@example.com"},
+
+		// A backslash does not end a non-special authority, so it reaches the host.
+		{"backslash in a non-special authority", "myapp://example.com$1", "/p/%5C@evil.com", ""},
+		{"backslash written by the author", `myapp://example.com\$1`, "/p/evil.com", ""},
+		{"slash still opens the path", "myapp://example.com$1", "/p/%2Fok", "myapp://example.com/ok"},
+
+		// Under a special scheme the parser folds it, so it still opens the path.
+		{"backslash under a special scheme", "https://example.com$1", "/p/%5Cok", `https://example.com\ok`},
+		{"slash under a special scheme", "https://example.com$1", "/p/%2Fok", "https://example.com/ok"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/p/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_ThirdSlashUnderNonSpecialScheme covers a target whose authority
+// the author left empty by writing a third slash.
+//
+// Only a special scheme reaches "special authority ignore slashes" and skips
+// past it; under any other one that slash terminates an empty authority, so the
+// capture is path. Skipping it regardless read the capture as the host, and the
+// rule was dropped at startup for handing the host to the request.
+func Test_Redirect_ThirdSlashUnderNonSpecialScheme(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"empty authority leaves the capture in the path", "myapp:///$1", "/p/evil.com", "myapp:///evil.com"},
+		{"deeper path under an empty authority", "myapp:///x/$1", "/p/evil.com", "myapp:///x/evil.com"},
+
+		// A special scheme skips them, so the capture is the host and the rule
+		// still hands the destination away.
+		{"special scheme still skips them", "https:///$1", "/p/evil.com", ""},
+		{"two slashes still open an authority", "myapp://$1", "/p/evil.com", ""},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/p/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				require.Empty(t, resp.Header.Get("Location"))
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+
+			// The authority stayed empty, so nothing the value supplied is a host.
+			u, err := url.Parse(resp.Header.Get("Location"))
+			require.NoError(t, err)
+			require.Empty(t, u.Host)
+		})
+	}
+}
+
+// Test_Redirect_WiderClassDoesNotOutrank covers two rules that differ only in
+// how many alternatives their character class lists. A class matches one byte
+// either way, so the longer list pins no more path — counting its members made
+// the broader rule win every time and left the narrower one dead.
+func Test_Redirect_WiderClassDoesNotOutrank(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
 		Rules: map[string]string{
-			"/default": "google.com",
+			"/api/[abcdefghijklmnopqrstuvwxyz]": "/broad",
+			"/api/[ab]":                         "/narrow",
 		},
-		StatusCode: fiber.StatusMovedPermanently,
+		StatusCode: fiber.StatusFound,
 	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	app.Use(func(c fiber.Ctx) error {
-		return c.SendStatus(fiber.StatusOK)
-	})
-
-	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
-	require.NoError(t, err)
-	resp, err := app.Test(req)
-	require.NoError(t, err)
+	for _, tc := range []struct{ request, want string }{
+		// Both match, and they now tie on pinned length, so the deterministic
+		// key order decides rather than the length of the class.
+		{"/api/a", "/narrow"},
+		// Only the wider class matches this one.
+		{"/api/z", "/broad"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
 
-	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+// Test_Redirect_AlternationRankedByItsWidestBranch covers a rule that can match
+// by more than one branch. It is only as specific as the least specific of them,
+// so crediting everything before the "|" put it ahead of the exact rule it ties
+// with and shadowed that rule outright.
+func Test_Redirect_AlternationRankedByItsWidestBranch(t *testing.T) {
+	t.Parallel()
 
-	// Case 2 : Next function always returns false
-	app = *fiber.New()
+	app := fiber.New()
 	app.Use(New(Config{
-		Next: func(fiber.Ctx) bool {
-			return false
+		Rules: map[string]string{
+			"/very/specific|/x": "/alt",
+			"/x":                "/exact",
 		},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	for _, tc := range []struct{ request, want string }{
+		// Both match, and the exact rule wins: they pin the same one byte, and
+		// the alternation matches strictly more paths.
+		{"/x", "/exact"},
+		// The branch only the alternation matches still reaches it.
+		{"/very/specific", "/alt"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
+
+// Test_Redirect_GroupedAlternationRankedByItsWidestBranch covers an alternation
+// written inside a group, which is one just the same. Crediting it with the
+// literals of every branch made the rule that matches more paths sort as the
+// more specific one, so it answered every request they share.
+func Test_Redirect_GroupedAlternationRankedByItsWidestBranch(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
 		Rules: map[string]string{
-			"/default": "google.com",
+			"/p/[a-z](reports|x.*)": "/grouped",
+			"/p/[a-z]xy":            "/narrow",
 		},
-		StatusCode: fiber.StatusMovedPermanently,
+		StatusCode: fiber.StatusFound,
 	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
-	require.NoError(t, err)
-	resp, err = app.Test(req)
-	require.NoError(t, err)
+	for _, tc := range []struct{ request, want string }{
+		// Both match "/p/axy". The grouped rule pins only the one byte its "x.*"
+		// branch does, so the rule pinning "xy" answers it.
+		{"/p/axy", "/narrow"},
+		// What only the grouped rule matches still reaches it.
+		{"/p/areports", "/grouped"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
 
-	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
-	require.Equal(t, "google.com", resp.Header.Get("Location"))
+// Test_Redirect_OptionalQuantifierDoesNotOutrankExactRule covers "{0,1}", whose
+// bounds were counted as path bytes. That put the rule matching "/api/" as well
+// ahead of the exact "/api/a", which it then answered for.
+func Test_Redirect_OptionalQuantifierDoesNotOutrankExactRule(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			"/api/ab{0,1}": "/maybe",
+			"/api/ab":      "/exact",
+		},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	for _, tc := range []struct{ request, want string }{
+		{"/api/ab", "/exact"},
+		// What only the quantified rule matches still reaches it.
+		{"/api/a", "/maybe"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
 }
 
-func Test_NoRules(t *testing.T) {
-	// Case 1: No rules with default route defined
-	app := *fiber.New()
+// Test_Redirect_AnchorPinsNoPath covers an explicit "$" in a rule. It asserts a
+// position and consumes nothing, so counting it as a path byte put the broader
+// class rule ahead of the exact one on a path they both match.
+func Test_Redirect_AnchorPinsNoPath(t *testing.T) {
+	t.Parallel()
 
+	app := fiber.New()
 	app.Use(New(Config{
-		StatusCode: fiber.StatusMovedPermanently,
+		Rules: map[string]string{
+			"/p/[a-z]$": "/class",
+			"/p/[a]":    "/exact",
+		},
+		StatusCode: fiber.StatusFound,
 	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	app.Use(func(c fiber.Ctx) error {
-		return c.SendStatus(fiber.StatusOK)
-	})
+	for _, tc := range []struct{ request, want string }{
+		{"/p/a", "/exact"},
+		{"/p/b", "/class"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
 
-	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+// Test_Redirect_UserinfoDelimitersFollowTheScheme covers a capture in the
+// userinfo of a non-special target. A backslash ends the authority only under a
+// special scheme, so refusing one outright dropped a redirect whose host the
+// author had pinned — "myapp://user\name@example.com" still reaches example.com.
+func Test_Redirect_UserinfoDelimitersFollowTheScheme(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name   string
+		target string
+		want   string
+	}{
+		{name: "non-special takes the backslash as userinfo", target: "myapp://$1@example.com", want: `myapp://user\name@example.com`},
+		{name: "special folds it into a slash", target: "https://$1@example.com", want: ""},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{Rules: map[string]string{"/r/*": tc.target}, StatusCode: fiber.StatusFound}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/user%5Cname", http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
+}
+
+// Test_Redirect_FileAuthorityOpensOnBackslashes covers "file:/$1", which looks
+// like it names no authority. The parser folds a backslash into a slash on the
+// way to the file host, so a captured "\evil.com/share" composes a location
+// whose host is evil.com — on Windows, a UNC path to a server of its choosing.
+func Test_Redirect_FileAuthorityOpensOnBackslashes(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{UnescapePath: true})
+	app.Use(New(Config{Rules: map[string]string{"/r/*": "file:/$1"}, StatusCode: fiber.StatusFound}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/%5Cevil.com/share", http.NoBody)
 	require.NoError(t, err)
 	resp, err := app.Test(req)
 	require.NoError(t, err)
 	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.Empty(t, resp.Header.Get("Location"))
 
-	// Case 2: No rules and no default route defined
-	app = *fiber.New()
+	// A value that stays a path still redirects. So does a third slash, which
+	// closes the authority empty exactly as "file:///tmp" does.
+	for _, tc := range []struct{ request, want string }{
+		{"/r/tmp/report", "file:/tmp/report"},
+		{"/r/%5C%5Cevil.com/share", `file:/\\evil.com/share`},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+
+	// The span itself, which is what the runtime guard asks of the composition:
+	// two slashes in any spelling open the host, and a third closes it empty.
+	for _, target := range []string{`file:/\evil.com/share`, `file:\\evil.com/share`, `file:\/evil.com`, "file://evil.com"} {
+		start, end := authoritySpan(target)
+		require.Equal(t, "evil.com", target[start:end], target)
+	}
+	for _, target := range []string{`file:/\\evil.com`, "file:///tmp", `file:\\\evil.com`} {
+		start, end := authoritySpan(target)
+		require.Equal(t, start, end, target)
+	}
+}
+
+// Test_Redirect_AnchorsBindEveryBranch covers a rule holding a top-level "|".
+// Concatenating the anchors made "^/a|/b$", which anchors the start of one
+// branch and the end of the other, so a path only sharing an edge matched.
+func Test_Redirect_AnchorsBindEveryBranch(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{Rules: map[string]string{"/a|/b": "/moved"}, StatusCode: fiber.StatusFound}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	for _, tc := range []struct {
+		request string
+		want    int
+	}{
+		{"/a", fiber.StatusFound},
+		{"/b", fiber.StatusFound},
+		{"/a-extra", fiber.StatusOK},
+		{"/extra/b", fiber.StatusOK},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, tc.want, resp.StatusCode, tc.request)
+	}
+}
+
+// Test_Redirect_NestedAlternationLosesTheTieBreak covers two rules that tie on
+// both specificity measures. The wider one matches a path the other does not, so
+// key order deciding between them left the exact rule dead.
+func Test_Redirect_NestedAlternationLosesTheTieBreak(t *testing.T) {
+	t.Parallel()
 
+	app := fiber.New()
 	app.Use(New(Config{
-		StatusCode: fiber.StatusMovedPermanently,
+		Rules: map[string]string{
+			"/p/[a-z](x|y)": "/wide",
+			"/p/[a-z]x":     "/narrow",
+		},
+		StatusCode: fiber.StatusFound,
 	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
-	require.NoError(t, err)
-	resp, err = app.Test(req)
-	require.NoError(t, err)
-	require.Equal(t, fiber.StatusNotFound, resp.StatusCode)
+	for _, tc := range []struct{ request, want string }{
+		{"/p/ax", "/narrow"},
+		{"/p/ay", "/wide"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+
+	// A class counts its breadth here too, so the two differ by the group alone.
+	require.Equal(t, 52, patternWidth("/p/[a-z](x|y)"))
+	require.Equal(t, 26, patternWidth("/p/[a-z]x"))
+	require.Equal(t, 1, patternWidth("/p/[a]"))
+	require.Equal(t, 256, patternWidth("/p/."))
+	require.Equal(t, 2, patternWidth("/very/specific|/x"))
+	require.Equal(t, 4, patternWidth("(a|b)(c|d)"))
 }
 
-func Test_DefaultConfig(t *testing.T) {
-	// Case 1: Default config and no default route
-	app := *fiber.New()
+// Test_Redirect_HexEscapeOutranksAClass covers "\x{61}", which names the one
+// character "a". Reading every letter-led escape as a class scored it no higher
+// than "[a-z]", and the tie left key order to pick the broader rule.
+func Test_Redirect_HexEscapeOutranksAClass(t *testing.T) {
+	t.Parallel()
 
-	app.Use(New())
+	app := fiber.New()
+	app.Use(New(Config{
+		Rules: map[string]string{
+			`/p/\x{61}`: "/exact",
+			"/p/[a-z]":  "/class",
+		},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	for _, tc := range []struct{ request, want string }{
+		{"/p/a", "/exact"},
+		{"/p/b", "/class"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
+
+// Test_Redirect_CaptureEndsAuthorityPastADeletedByte covers a captured "\t/ok".
+// The parser deletes the tab, so the value ends the authority at the author's
+// host and the client reaches "/ok" — judging the tab as the first byte instead
+// read the value as extending the host, and the redirect was refused.
+func Test_Redirect_CaptureEndsAuthorityPastADeletedByte(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{UnescapePath: true})
+	app.Use(New(Config{
+		Rules:      map[string]string{"/r/*": "https://example.com$1"},
+		StatusCode: fiber.StatusFound,
+	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/%09%2Fok", http.NoBody)
 	require.NoError(t, err)
 	resp, err := app.Test(req)
-
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusNotFound, resp.StatusCode)
-
-	// Case 2: Default config and default route
-	app = *fiber.New()
+	require.Equal(t, fiber.StatusFound, resp.StatusCode)
 
-	app.Use(New())
-	app.Use(func(c fiber.Ctx) error {
-		return c.SendStatus(fiber.StatusOK)
-	})
+	// What the client reads is example.com, whatever bytes the parser drops on
+	// the way there.
+	location := resp.Header.Get("Location")
+	ref, err := url.Parse(strings.NewReplacer("\t", "", "\r", "", "\n", "").Replace(location))
+	require.NoError(t, err)
+	require.Equal(t, "example.com", ref.Host)
+	require.Equal(t, "/ok", ref.Path)
 
-	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	// A value that really does extend the host is still refused.
+	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/%09evil", http.NoBody)
 	require.NoError(t, err)
 	resp, err = app.Test(req)
-
 	require.NoError(t, err)
 	require.Equal(t, fiber.StatusOK, resp.StatusCode)
 }
 
-func Test_RegexRules(t *testing.T) {
-	// Case 1: Rules regex is empty
-	app := *fiber.New()
-	app.Use(New(Config{
-		Rules:      map[string]string{},
-		StatusCode: fiber.StatusMovedPermanently,
-	}))
+// Test_Redirect_BareFileSchemeIsAPath covers a "file:" target with no slashes,
+// which names no authority: the parser leaves "file state" for "path state"
+// unless one follows, so what stands there is path. Reading it as a host made a
+// value that is only a path name one, and the redirect was skipped at runtime.
+func Test_Redirect_BareFileSchemeIsAPath(t *testing.T) {
+	t.Parallel()
 
-	app.Use(func(c fiber.Ctx) error {
-		return c.SendStatus(fiber.StatusOK)
-	})
+	app := fiber.New()
+	app.Use(New(Config{Rules: map[string]string{"/r/*": "file:tmp$1"}, StatusCode: fiber.StatusFound}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
+	req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/report", http.NoBody)
 	require.NoError(t, err)
 	resp, err := app.Test(req)
-
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.Equal(t, fiber.StatusFound, resp.StatusCode)
+	require.Equal(t, "file:tmpreport", resp.Header.Get("Location"))
 
-	// Case 2: Rules regex map contains valid regex and well-formed replacement URLs
-	app = *fiber.New()
+	// A bare "file:" target holds no authority span, so it is opaque-path and the
+	// composed location is what gets checked for one.
+	start, end := authoritySpan("file:tmp/report")
+	require.Equal(t, 0, start)
+	require.Equal(t, 0, end)
+	start, end = authoritySpan("file://host/report")
+	require.NotEqual(t, start, end)
+}
+
+// Test_Redirect_AuthorPinnedShortIPv4 covers "127.1", which the URL parser reads
+// as 127.0.0.1. Judging it by net.ParseIP said the author had pinned no host and
+// dropped a rule whose host they had written in full.
+func Test_Redirect_AuthorPinnedShortIPv4(t *testing.T) {
+	t.Parallel()
+
+	for _, host := range []string{"127.1", "0x7f.1", "2130706433", "127.0.0.1"} {
+		app := fiber.New()
+		app.Use(New(Config{
+			Rules:      map[string]string{"/r/*": "https://" + host + ":$1"},
+			StatusCode: fiber.StatusFound,
+		}))
+		app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/r/8080", http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, host)
+		require.Equal(t, "https://"+host+":8080", resp.Header.Get("Location"), host)
+	}
+
+	// A host that is not an address still hands the host away when the capture
+	// closes it, so "https://$1" stays refused.
+	require.False(t, isIPv4Host("127.0.0.256"))
+	require.False(t, isIPv4Host("1.2.3.4.5"))
+	require.False(t, isIPv4Host("0x1g"))
+	require.True(t, isIPv4Host("127.0.0.1."))
+}
+
+// Test_Redirect_ClassEscapeDoesNotOutrankExactRule covers "\d", which matches any
+// digit. Reading it as the byte "d" escaped counted two path bytes that are not
+// there, putting the rule that matches every digit ahead of the exact one.
+func Test_Redirect_ClassEscapeDoesNotOutrankExactRule(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
 	app.Use(New(Config{
 		Rules: map[string]string{
-			"/default": "google.com",
+			`/api/\d+`: "/digits",
+			"/api/1":   "/one",
 		},
-		StatusCode: fiber.StatusMovedPermanently,
+		StatusCode: fiber.StatusFound,
 	}))
+	app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
 
-	app.Use(func(c fiber.Ctx) error {
-		return c.SendStatus(fiber.StatusOK)
-	})
+	for _, tc := range []struct{ request, want string }{
+		{"/api/1", "/one"},
+		{"/api/27", "/digits"},
+	} {
+		req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+		require.NoError(t, err)
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusFound, resp.StatusCode, tc.request)
+		require.Equal(t, tc.want, resp.Header.Get("Location"), tc.request)
+	}
+}
 
-	req, err = http.NewRequestWithContext(context.Background(), fiber.MethodGet, "/default", http.NoBody)
-	require.NoError(t, err)
-	resp, err = app.Test(req)
+// Test_Redirect_FileSchemeEmptyAuthority covers "file", which is special — it
+// folds backslashes — but reaches its host through "file slash state" rather
+// than the ignore-slashes one every other special scheme takes. So "file:///$1"
+// has the empty authority of a local path, and skipping that third slash read
+// the capture as the host and dropped the rule at startup.
+func Test_Redirect_FileSchemeEmptyAuthority(t *testing.T) {
+	t.Parallel()
 
-	require.NoError(t, err)
-	require.Equal(t, fiber.StatusMovedPermanently, resp.StatusCode)
-	require.Equal(t, "google.com", resp.Header.Get("Location"))
+	tests := []struct {
+		name    string
+		target  string
+		request string
+		want    string // "" means the rule must not fire
+	}{
+		{"local path composes", "file:///$1", "/p/tmp/report", "file:///tmp/report"},
+		{"deeper local path", "file:///var/$1", "/p/log", "file:///var/log"},
+		// Two slashes still open an authority, so the capture is the host there.
+		{"capture as the file host", "file://$1/x", "/p/evil.com", ""},
+	}
 
-	// Case 3: Test invalid regex throws panic
-	app = *fiber.New()
-	require.Panics(t, func() {
-		app.Use(New(Config{
-			Rules: map[string]string{
-				"(": "google.com",
-			},
-			StatusCode: fiber.StatusMovedPermanently,
-		}))
-	})
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := fiber.New(fiber.Config{UnescapePath: true})
+			app.Use(New(Config{
+				Rules:      map[string]string{"/p/*": tc.target},
+				StatusCode: fiber.StatusFound,
+			}))
+			app.Get("/*", func(c fiber.Ctx) error { return c.SendString("fell through") })
+
+			req, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, tc.request, http.NoBody)
+			require.NoError(t, err)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+
+			if tc.want == "" {
+				require.Equal(t, fiber.StatusOK, resp.StatusCode, "the rule must not fire")
+				return
+			}
+			require.Equal(t, fiber.StatusFound, resp.StatusCode)
+			require.Equal(t, tc.want, resp.Header.Get("Location"))
+		})
+	}
 }
diff --git a/redirect_test.go b/redirect_test.go
index b48466f2ddd..a9af9449eda 100644
--- a/redirect_test.go
+++ b/redirect_test.go
@@ -8,6 +8,7 @@ import (
 	"bytes"
 	"encoding/hex"
 	"encoding/json"
+	"fmt"
 	"io"
 	"mime/multipart"
 	"net/http"
@@ -139,6 +140,143 @@ func Test_Redirect_Route_WithQueries_SpecialChars(t *testing.T) {
 	require.Equal(t, url.Values{"q": []string{"a&b=c"}}, location.Query())
 }
 
+// go test -run Test_Redirect_Route_ParamCannotMoveTheQuery
+func Test_Redirect_Route_ParamCannotMoveTheQuery(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name  string
+		param string
+		want  string
+	}{
+		{
+			name:  "plain",
+			param: "fiber",
+			want:  "/user/fiber?q=1",
+		},
+		{
+			// A second "?" reads as one query string, so appending it folded
+			// q=1 into the earlier parameter's value instead of adding it.
+			name:  "param opens a query",
+			param: "a?b=2",
+			want:  "/user/a?b=2&q=1",
+		},
+		{
+			// Everything after "#" is a fragment, which the client never
+			// sends, so appending the query there dropped it outright.
+			name:  "param opens a fragment",
+			param: "a#b",
+			want:  "/user/a?q=1#b",
+		},
+		{
+			name:  "param opens both",
+			param: "a?b=2#c",
+			want:  "/user/a?b=2&q=1#c",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			app := New()
+			app.Get("/user/:name", func(c Ctx) error {
+				return c.JSON(c.Params("name"))
+			}).Name("user")
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+			err := c.Redirect().Route("user", RedirectConfig{
+				Params:  Map{"name": tc.param},
+				Queries: map[string]string{"q": "1"},
+			})
+			require.NoError(t, err)
+			require.Equal(t, tc.want, string(c.Response().Header.Peek(HeaderLocation)))
+		})
+	}
+}
+
+// go test -run Test_Redirect_Route_ParamCannotLeaveTheOrigin
+func Test_Redirect_Route_ParamCannotLeaveTheOrigin(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name  string
+		param string
+		want  string
+	}{
+		{
+			name:  "plain",
+			param: "docs/index.html",
+			want:  "/docs/index.html",
+		},
+		{
+			// "//evil.com" is a network-path reference: the browser reads
+			// evil.com as the host and never comes back to this origin.
+			name:  "leading slash",
+			param: "/evil.com",
+			want:  "/evil.com",
+		},
+		{
+			name:  "leading slash run",
+			param: "//evil.com",
+			want:  "/evil.com",
+		},
+		{
+			// The WHATWG URL parser folds a backslash to a slash here, so this
+			// reaches evil.com exactly as "//evil.com" does.
+			name:  "leading backslash",
+			param: `\evil.com`,
+			want:  "/evil.com",
+		},
+		{
+			name:  "mixed slash run",
+			param: `/\/evil.com`,
+			want:  "/evil.com",
+		},
+		{
+			// Tab, LF and CR are removed before the URL is parsed, so a leading
+			// one hides the slash run that follows it.
+			name:  "tab before the slash",
+			param: "\t/evil.com",
+			want:  "/evil.com",
+		},
+		{
+			// A scheme cannot start here — the route is rooted at "/" — so this
+			// stays the path segment the route asked for.
+			name:  "absolute URL is a path segment",
+			param: "https://evil.com",
+			want:  "/https://evil.com",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			app := New()
+			app.Get("/*", func(c Ctx) error {
+				return c.JSON(c.Params("*"))
+			}).Name("wildcard")
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+			err := c.Redirect().Route("wildcard", RedirectConfig{
+				Params: Map{"*": tc.param},
+			})
+			require.NoError(t, err)
+			require.Equal(t, tc.want, string(c.Response().Header.Peek(HeaderLocation)))
+
+			// The same question asked the other two ways. A caller who puts
+			// either answer in a Location header or an href reaches the same
+			// place, so all three have to agree.
+			fromRoute, err := app.GetRoute("wildcard").URL(Map{"*": tc.param})
+			require.NoError(t, err)
+			require.Equal(t, tc.want, fromRoute, "Route.URL")
+
+			fromCtx, err := c.GetRouteURL("wildcard", Map{"*": tc.param})
+			require.NoError(t, err)
+			require.Equal(t, tc.want, fromCtx, "GetRouteURL")
+		})
+	}
+}
+
 // go test -run Test_Redirect_Route_WithOptionalParams
 func Test_Redirect_Route_WithOptionalParams(t *testing.T) {
 	t.Parallel()
@@ -341,6 +479,137 @@ func Test_Redirect_Back_WithCrossOriginReferer(t *testing.T) {
 	require.Equal(t, "/", string(c.Response().Header.Peek(HeaderLocation)))
 }
 
+// go test -run Test_Redirect_Back_RejectsEmptyAuthorityReferer
+//
+// Test_Redirect_Back_RejectsEmptyAuthorityReferer covers a network-path
+// reference whose authority came out empty.
+//
+// "//?x", "//#f" and "//@" reach net/url with an empty Host and no scheme, so
+// the relative-path branch called them same-origin — a different question than
+// the one asked. They name no origin at all, and the Location they produced is
+// one no client can resolve: a browser fails to parse "//?x" against its base
+// rather than going anywhere. Fall back instead of emitting a dead redirect.
+func Test_Redirect_Back_RejectsEmptyAuthorityReferer(t *testing.T) {
+	t.Parallel()
+
+	for _, referer := range []string{"//?x", "//#f", "//@"} {
+		t.Run(referer, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			app.Get("/back", func(c Ctx) error { return c.Redirect().Back("/fallback") })
+
+			req := httptest.NewRequest(MethodGet, "/back", http.NoBody)
+			req.Host = "victim.test"
+			req.Header.Set(HeaderReferer, referer)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, "/fallback", resp.Header.Get(HeaderLocation))
+		})
+	}
+
+	// A reference that is only slashes normalizes to a plain absolute path and
+	// really is this origin, so it is still honored.
+	for _, referer := range []string{"//", "///"} {
+		t.Run(referer, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			app.Get("/back", func(c Ctx) error { return c.Redirect().Back("/fallback") })
+
+			req := httptest.NewRequest(MethodGet, "/back", http.NoBody)
+			req.Host = "victim.test"
+			req.Header.Set(HeaderReferer, referer)
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, "/", resp.Header.Get(HeaderLocation))
+		})
+	}
+}
+
+func Test_Redirect_Back_RejectsBrowserNormalizedReferer(t *testing.T) {
+	t.Parallel()
+
+	// Referer values that net/url reports as ordinary relative paths but that a
+	// browser resolves to another origin, because it folds backslashes onto
+	// forward slashes, drops ASCII tab/newline, and treats any leading run of
+	// slashes as the start of an authority.
+	crossOrigin := []string{
+		`/\evil.com`,
+		`/\/evil.com`,
+		`\\evil.com`,
+		`\/evil.com`,
+		"/\t/evil.com",
+		"\t//evil.com",
+		` //evil.com`,
+		`///evil.com`,
+		`/////evil.com`,
+		`https:///evil.com`,
+	}
+
+	app := New()
+	for _, referer := range crossOrigin {
+		t.Run(referer, func(t *testing.T) {
+			t.Parallel()
+
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			defer app.ReleaseCtx(c)
+
+			c.Request().Header.Set(HeaderReferer, referer)
+			c.Request().URI().SetHost("example.com")
+
+			require.NoError(t, c.Redirect().Back("/fallback"))
+			require.Equal(t, StatusSeeOther, c.Response().StatusCode())
+			require.Equal(t, "/fallback", string(c.Response().Header.Peek(HeaderLocation)))
+		})
+	}
+}
+
+// go test -run Test_Redirect_Back_NormalizesSameOriginReferer
+func Test_Redirect_Back_NormalizesSameOriginReferer(t *testing.T) {
+	t.Parallel()
+
+	// A same-origin referer is redirected to in its browser-normalized form, so
+	// a client that does not fold backslashes cannot resolve a different origin
+	// than the one that was validated.
+	tests := []struct {
+		referer  string
+		expected string
+	}{
+		{referer: `/back`, expected: `/back`},
+		{referer: `back`, expected: `back`},
+		{referer: `/a\b`, expected: `/a/b`},
+		{referer: `http://example.com\@evil.com`, expected: `http://example.com/@evil.com`},
+		{referer: "/back\t", expected: `/back`},
+
+		// The backslash fold belongs to the path; WHATWG treats "\\" as an
+		// ordinary character in the query and fragment, so rewriting it there
+		// would send the user back to a different query than they came from.
+		{referer: `/search?q=a\b`, expected: `/search?q=a\b`},
+		{referer: `/p?path=C:\Users\me`, expected: `/p?path=C:\Users\me`},
+		{referer: `/docs#a\b`, expected: `/docs#a\b`},
+		// Invalid UTF-8 must survive byte-for-byte rather than becoming U+FFFD.
+		{referer: "/back?x=caf\xe9\\y", expected: "/back?x=caf\xe9\\y"},
+	}
+
+	app := New()
+	for _, tc := range tests {
+		t.Run(tc.referer, func(t *testing.T) {
+			t.Parallel()
+
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			defer app.ReleaseCtx(c)
+
+			c.Request().Header.Set(HeaderReferer, tc.referer)
+			c.Request().URI().SetHost("example.com")
+
+			require.NoError(t, c.Redirect().Back("/fallback"))
+			require.Equal(t, StatusSeeOther, c.Response().StatusCode())
+			require.Equal(t, tc.expected, string(c.Response().Header.Peek(HeaderLocation)))
+		})
+	}
+}
+
 // go test -run Test_Redirect_Route_WithFlashMessages
 func Test_Redirect_Route_WithFlashMessages(t *testing.T) {
 	t.Parallel()
@@ -632,10 +901,37 @@ func Test_Redirect_parseAndClearFlashMessages_InvalidHex(t *testing.T) {
 	// Verify that no flash messages are processed (should be empty)
 	require.Empty(t, r.messages)
 
+	// The cookie is expired even though hex decoding failed. A value this
+	// application cannot decode is one it will never decode, so leaving it in
+	// place would mean re-running hex and msgp over attacker-controlled bytes
+	// on every subsequent request for as long as the browser kept sending it.
+	assertFlashCookieCleared(t, string(c.Response().Header.Peek(HeaderSetCookie)))
+
 	// Release redirect
 	ReleaseRedirect(r)
 }
 
+// Test_Redirect_release_ZeroesMessages asserts that a *Redirect handed back to
+// the pool does not carry the submitted form with it. WithInput copies the
+// whole request body into r.messages — a rejected login puts the password the
+// user just typed in there — and truncating to [:0] leaves those strings
+// reachable from the backing array for the life of the process.
+func Test_Redirect_release_ZeroesMessages(t *testing.T) {
+	t.Parallel()
+
+	r := AcquireRedirect()
+	r.With("password", "hunter2")
+	r.With("token", "s3cr3t")
+	require.Len(t, r.messages, 2)
+
+	full := r.messages[:cap(r.messages)]
+	r.release()
+
+	for i := range full {
+		require.Equal(t, redirectionMsg{}, full[i], "index %d survived release", i)
+	}
+}
+
 func Test_Redirect_Messages_ClearsFlashMessages(t *testing.T) {
 	t.Parallel()
 
@@ -1126,3 +1422,273 @@ func Benchmark_Redirect_OldInput(b *testing.B) {
 		Value: "tom",
 	}, input)
 }
+
+// go test -run Test_Redirect_FlashCookie_Attributes
+func Test_Redirect_FlashCookie_Attributes(t *testing.T) {
+	t.Parallel()
+
+	// The flash payload is hex-encoded, not encrypted, and WithInput copies the
+	// whole submitted form into it — including whatever the user typed into a
+	// password field. It is only ever read back on the server, so it must not be
+	// reachable from document.cookie, and must not travel in the clear when the
+	// request that produced it was served over TLS.
+	newApp := func() *App {
+		app := New(Config{
+			TrustProxy: true,
+			TrustProxyConfig: TrustProxyConfig{
+				Proxies: []string{"0.0.0.0"},
+			},
+		})
+		app.Post("/login", func(c Ctx) error {
+			return c.Redirect().With("error", "bad credentials").WithInput().To("/login")
+		})
+		return app
+	}
+
+	post := func(t *testing.T, app *App, scheme string) string {
+		t.Helper()
+
+		req := httptest.NewRequest(MethodPost, "/login", strings.NewReader("user=alice&password=hunter2"))
+		req.Header.Set(HeaderContentType, MIMEApplicationForm)
+		if scheme != "" {
+			req.Header.Set(HeaderXForwardedProto, scheme)
+		}
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+
+		for _, cookie := range resp.Header.Values(HeaderSetCookie) {
+			if strings.HasPrefix(cookie, FlashCookieName+"=") {
+				return cookie
+			}
+		}
+		t.Fatalf("no %s cookie in response", FlashCookieName)
+		return ""
+	}
+
+	t.Run("plain http", func(t *testing.T) {
+		t.Parallel()
+
+		cookie := post(t, newApp(), "")
+		require.Contains(t, cookie, "HttpOnly")
+		// Secure would make the browser drop the cookie on a plaintext request.
+		require.NotContains(t, cookie, "secure")
+	})
+
+	t.Run("forwarded https", func(t *testing.T) {
+		t.Parallel()
+
+		cookie := post(t, newApp(), "https")
+		require.Contains(t, cookie, "HttpOnly")
+		require.Contains(t, cookie, "secure")
+	})
+}
+
+// go test -run Test_Redirect_FlashMessages_NoCrossRequestLeak
+func Test_Redirect_FlashMessages_NoCrossRequestLeak(t *testing.T) {
+	t.Parallel()
+
+	// The two requests below are sequential regardless, which is what makes the
+	// second reuse the first's pooled ctx. Running the test alongside others
+	// does not weaken that: mutation-verified with both clears reverted, this
+	// still fails under the full package's parallel load.
+	app := New()
+
+	app.Get("/read", func(c Ctx) error {
+		var sb strings.Builder
+		for _, m := range c.Redirect().Messages() {
+			sb.WriteString("MSG:" + m.Key + "=" + m.Value + ";") //nolint:errcheck // strings.Builder writes never fail
+		}
+		for _, in := range c.Redirect().OldInputs() {
+			sb.WriteString("OLD:" + in.Key + "=" + in.Value + ";") //nolint:errcheck // strings.Builder writes never fail
+		}
+		return c.SendString(sb.String())
+	})
+	// Deliberately does not consume the flash messages, so they are still in
+	// the context's slice when it is released back to the pool.
+	app.Get("/ignore", func(c Ctx) error { return c.SendString("ok") })
+
+	victim := redirectionMsgs{
+		{key: "user", value: "alice", isOldInput: true},
+		{key: "password", value: "hunter2", isOldInput: true},
+		{key: "error", value: "bad credentials"},
+	}
+	raw, err := victim.MarshalMsg(nil)
+	require.NoError(t, err)
+
+	get := func(t *testing.T, path, flashCookie string) string {
+		t.Helper()
+
+		req := httptest.NewRequest(MethodGet, path, http.NoBody)
+		if flashCookie != "" {
+			req.Header.Set(HeaderCookie, FlashCookieName+"="+flashCookie)
+		}
+		resp, err := app.Test(req)
+		require.NoError(t, err)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		return string(body)
+	}
+
+	// One request carries real flash data and leaves it unread.
+	require.Equal(t, "ok", get(t, "/ignore", hex.EncodeToString(raw)))
+
+	// The next request asks for N messages encoded as empty msgp maps (0x9N
+	// fixarray of 0x80 fixmaps). Those decode to zero values; if the pooled
+	// slice were reused without being cleared, the fields absent from each map
+	// would come back holding the previous request's data instead.
+	for n := 1; n <= 4; n++ {
+		payload := fmt.Sprintf("9%d%s", n, strings.Repeat("80", n))
+
+		body := get(t, "/read", payload)
+		require.NotContains(t, body, "alice")
+		require.NotContains(t, body, "hunter2")
+		require.NotContains(t, body, "bad credentials")
+		require.Equal(t, strings.Repeat("MSG:=;", n), body)
+	}
+}
+
+// go test -run Test_Redirect_Back_IgnoresHeaderNameCase
+//
+// Ctx.Get compares the stored key byte for byte, so under
+// DisableHeaderNormalizing a "referer:" from a client behind an HTTP/2 or
+// HTTP/3 front end — where lower case is what the wire carries — read as no
+// referer at all, and Back went to the fallback instead of back.
+func Test_Redirect_Back_IgnoresHeaderNameCase(t *testing.T) {
+	t.Parallel()
+
+	for _, normalize := range []bool{true, false} {
+		t.Run(fmt.Sprintf("normalize=%v", normalize), func(t *testing.T) {
+			t.Parallel()
+
+			for _, sent := range []string{"Referer", "referer", "REFERER"} {
+				app := New(Config{DisableHeaderNormalizing: !normalize})
+				c := app.AcquireCtx(&fasthttp.RequestCtx{})
+				if !normalize {
+					c.Request().Header.DisableNormalizing()
+				}
+				c.Request().Header.Set(sent, "/previous")
+
+				require.NoError(t, c.Redirect().Back("/fallback"))
+				require.Equal(t, "/previous", string(c.Response().Header.Peek(HeaderLocation)),
+					"sent as %q", sent)
+				app.ReleaseCtx(c)
+			}
+		})
+	}
+}
+
+// go test -run Test_Redirect_Back_RejectsAnUnusableReferer
+//
+// Every referer that cannot be resolved back to this origin falls back rather
+// than being echoed into Location. These are the shapes that fail before the
+// same-origin comparison is even reached: one that normalizes away to nothing,
+// and one the URL parser refuses.
+func Test_Redirect_Back_RejectsAnUnusableReferer(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		referer string
+	}{
+		{name: "empty", referer: ""},
+		// Leading and trailing C0 controls and spaces are stripped before
+		// anything else, so these name no location at all.
+		{name: "only spaces", referer: " "},
+		{name: "only controls", referer: "\t\n "},
+		// url.Parse refuses these outright.
+		{name: "bad percent escape", referer: "%zz"},
+		{name: "control byte", referer: "http://a\x7fb"},
+		{name: "space in the scheme", referer: "ht tp://x"},
+		{name: "no scheme before the colon", referer: "://x"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			defer app.ReleaseCtx(c)
+
+			if tc.referer != "" {
+				c.Request().Header.Set(HeaderReferer, tc.referer)
+			}
+
+			require.NoError(t, c.Redirect().Back("/fallback"))
+			require.Equal(t, "/fallback", string(c.Response().Header.Peek(HeaderLocation)))
+		})
+	}
+
+	t.Run("no referer at all, with names left as sent", func(t *testing.T) {
+		t.Parallel()
+
+		// The walk that matches the name case-insensitively finds nothing here,
+		// which is the same answer as the byte-for-byte lookup.
+		app := New(Config{DisableHeaderNormalizing: true})
+		c := app.AcquireCtx(&fasthttp.RequestCtx{})
+		defer app.ReleaseCtx(c)
+
+		c.Request().Header.DisableNormalizing()
+		c.Request().Header.Set("X-Not-A-Referer", "/nope")
+
+		require.NoError(t, c.Redirect().Back("/fallback"))
+		require.Equal(t, "/fallback", string(c.Response().Header.Peek(HeaderLocation)))
+	})
+
+	t.Run("no referer and no fallback is an error", func(t *testing.T) {
+		t.Parallel()
+
+		app := New()
+		c := app.AcquireCtx(&fasthttp.RequestCtx{})
+		defer app.ReleaseCtx(c)
+
+		require.ErrorIs(t, c.Redirect().Back(), ErrRedirectBackNoFallback)
+	})
+}
+
+// Test_Redirect_parseAndClearFlashMessages_UndecodablePayload covers a cookie
+// that decodes as hex but is not what this application wrote.
+//
+// UnmarshalMsg re-slices to the length the payload declares before it decodes
+// any element, so a failure partway leaves the slice holding zero-valued
+// entries. Reading those back would hand the handler empty messages nobody set,
+// which is why the slice is dropped rather than kept at whatever length the
+// payload claimed.
+func Test_Redirect_parseAndClearFlashMessages_UndecodablePayload(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name    string
+		payload []byte
+	}{
+		// An array header claiming four elements, and then nothing.
+		{name: "truncated after the count", payload: []byte{0x94}},
+		// A byte message-pack never assigns.
+		{name: "never a valid type", payload: []byte{0xc1, 0xc1}},
+		// A long claimed length with no elements behind it, which is the shape
+		// that leaves the most zero-valued entries.
+		{name: "claims more than it carries", payload: []byte{0xdc, 0x01, 0x00}},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{}).(*DefaultCtx) //nolint:errcheck,forcetypeassert // not needed
+			defer app.ReleaseCtx(c)
+
+			r := AcquireRedirect()
+			r.c = c
+			defer ReleaseRedirect(r)
+
+			c.Request().Header.SetCookie(FlashCookieName, hex.EncodeToString(tc.payload))
+
+			r.parseAndClearFlashMessages()
+
+			require.Empty(t, r.messages)
+			require.Empty(t, c.flashMessages, "a payload that failed to decode leaves nothing behind")
+			assertFlashCookieCleared(t, c.GetRespHeader(HeaderSetCookie))
+		})
+	}
+}
diff --git a/router_test.go b/router_test.go
index 5f6479d0e4f..79a88266e97 100644
--- a/router_test.go
+++ b/router_test.go
@@ -13,6 +13,7 @@ import (
 	"io"
 	"net/http"
 	"net/http/httptest"
+	neturl "net/url"
 	"os"
 	"reflect"
 	"regexp"
@@ -4449,3 +4450,41 @@ func Test_Route_OptionalSlash_SingleCharSegment(t *testing.T) {
 		})
 	}
 }
+
+// Test_Route_URL_RefusesUnrepresentableRoute covers a route whose own path
+// starts more than one slash. No relative URL names it: two leading slashes open
+// an authority, so "//internal" resolves to the host "internal" rather than a
+// path here, and collapsing to one reaches a different route. Both silently
+// composed the wrong thing, one of them an open redirect, so it errors instead.
+func Test_Route_URL_RefusesUnrepresentableRoute(t *testing.T) {
+	t.Parallel()
+
+	app := New()
+	app.Get("//internal", func(c Ctx) error { return c.SendString("internal") }).Name("dbl")
+	app.Get("//*", func(c Ctx) error { return c.SendString("wild") }).Name("dblwild")
+	// The parser deletes the tab, so this path is read as "//internal" too. The
+	// byte is not there to be seen by the time anything acts on the composition.
+	app.Get("/\t/internal", func(c Ctx) error { return c.SendString("tabbed") }).Name("tab")
+	// A trailing space goes the same way: the parser strips a run of controls or
+	// spaces from either end, so this route is read as "/internal", which is a
+	// different one. Reachable as "/internal%20" under UnescapePath, but no URL
+	// composed here can name it.
+	app.Get("/internal ", func(c Ctx) error { return c.SendString("spaced") }).Name("space")
+	app.Get("/*", func(c Ctx) error { return c.SendString("ok") }).Name("wild")
+
+	for _, name := range []string{"dbl", "dblwild", "tab", "space"} {
+		url, err := app.GetRoute(name).URL(Map{"*": "evil.com"})
+		require.ErrorIs(t, err, ErrRouteNotRepresentable, name)
+		require.Empty(t, url, name)
+	}
+
+	// An ordinary route still composes, and a value cannot open an authority.
+	url, err := app.GetRoute("wild").URL(Map{"*": "/evil.com"})
+	require.NoError(t, err)
+	require.Equal(t, "/evil.com", url)
+
+	// What that composed reaches is this origin, not evil.com.
+	ref, err := neturl.Parse(url)
+	require.NoError(t, err)
+	require.Empty(t, ref.Host)
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path binder/form_test.go --path client/cookiejar_test.go --path client/response_test.go --path client/transport_test.go --path ctx_test.go --path extractors/extractors_test.go --path helpers_test.go --path internal/fieldname/fieldname_test.go --path internal/mediatype/mediatype_test.go --path internal/urlnorm/urlnorm_test.go --path listen_test.go --path middleware/adaptor/adaptor_test.go --path middleware/cache/cache_security_test.go --path middleware/cache/cache_test.go --path middleware/cache/coverage_test.go --path middleware/cache/keygen_test.go --path middleware/csrf/csrf_test.go --path middleware/logger/logger_test.go --path middleware/proxy/bench_test.go --path middleware/proxy/fuzz_test.go --path middleware/proxy/proxy_test.go --path middleware/proxy/security_test.go --path middleware/redirect/redirect_test.go --path redirect_test.go --path router_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./binder ./client ./ ./extractors ./internal/fieldname ./internal/mediatype ./internal/urlnorm ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/logger ./middleware/proxy ./middleware/redirect')"
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path binder/form_test.go --path client/cookiejar_test.go --path client/response_test.go --path client/transport_test.go --path ctx_test.go --path extractors/extractors_test.go --path helpers_test.go --path internal/fieldname/fieldname_test.go --path internal/mediatype/mediatype_test.go --path internal/urlnorm/urlnorm_test.go --path listen_test.go --path middleware/adaptor/adaptor_test.go --path middleware/cache/cache_security_test.go --path middleware/cache/cache_test.go --path middleware/cache/coverage_test.go --path middleware/cache/keygen_test.go --path middleware/csrf/csrf_test.go --path middleware/logger/logger_test.go --path middleware/proxy/bench_test.go --path middleware/proxy/fuzz_test.go --path middleware/proxy/proxy_test.go --path middleware/proxy/security_test.go --path middleware/redirect/redirect_test.go --path redirect_test.go --path router_test.go --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./binder ./client ./ ./extractors ./internal/fieldname ./internal/mediatype ./internal/urlnorm ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/logger ./middleware/proxy ./middleware/redirect')"
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
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./binder ./client ./ ./extractors ./internal/fieldname ./internal/mediatype ./internal/urlnorm ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/logger ./middleware/proxy ./middleware/redirect' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./binder ./client ./ ./extractors ./internal/fieldname ./internal/mediatype ./internal/urlnorm ./middleware/adaptor ./middleware/cache ./middleware/csrf ./middleware/logger ./middleware/proxy ./middleware/redirect' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
