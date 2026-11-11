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
for f in ctx_helpers_test.go ctx_test.go internal/cookie/samesite_test.go internal/etag/etag_test.go internal/fieldname/fieldname_test.go middleware/cors/cors_test.go middleware/etag/etag_test.go middleware/logger/logger_test.go middleware/timeout/timeout_test.go; do if git cat-file -e a9981a7db37dca1a3310fd7c924eb60262f31df8:"$f" 2>/dev/null; then git checkout a9981a7db37dca1a3310fd7c924eb60262f31df8 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - a9981a7db37dca1a3310fd7c924eb60262f31df8 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/ctx_helpers_test.go b/ctx_helpers_test.go
new file mode 100644
index 00000000000..0865b09be09
--- /dev/null
+++ b/ctx_helpers_test.go
@@ -0,0 +1,1540 @@
+// ⚡️ Fiber is an Express inspired web framework written in Go with ☕️
+// 🤖 GitHub Repository: https://github.com/gofiber/fiber
+// 📌 API Documentation: https://docs.gofiber.io
+
+package fiber
+
+import (
+	"bytes"
+	"compress/gzip"
+	"io"
+	"net"
+	"net/http"
+	"net/http/httptest"
+	"strconv"
+	"strings"
+	"testing"
+	"time"
+
+	"github.com/gofiber/utils/v2"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// Splitting a handler into func(fiber.Req) and func(fiber.Res) and passing the
+// same Ctx to both is the reason the split exists, so Ctx has to satisfy each.
+// A name carried by Req and Res under different signatures breaks that on
+// assignment, which no test of the concrete types would catch.
+var (
+	_ Req = (*DefaultCtx)(nil)
+	_ Res = (*DefaultCtx)(nil)
+	_ Req = Ctx(nil)
+	_ Res = Ctx(nil)
+)
+
+func Test_Req_RequestHelpersOnReq(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetRequestURI("/path/here?q=1")
+	fctx.Request.Header.SetMethod(MethodPost)
+	fctx.Request.Header.SetHost("example.com")
+	fctx.Request.Header.SetUserAgent("fiber-test")
+	fctx.Request.Header.SetReferer("https://referer.example")
+	fctx.Request.Header.Set(HeaderAcceptLanguage, "en-US, de")
+	fctx.Request.Header.Set(HeaderAcceptEncoding, "gzip, br")
+	fctx.Request.Header.Set(HeaderAccept, MIMEApplicationJSON)
+	fctx.Request.Header.SetContentType(MIMEApplicationJSON + "; charset=utf-8")
+	fctx.Request.SetBody([]byte(`{"a":1}`))
+
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	r := c.Req()
+
+	require.Equal(t, "http://example.com/path/here?q=1", r.FullURL())
+	require.Equal(t, "fiber-test", r.UserAgent())
+	require.Equal(t, "https://referer.example", r.Referer())
+	require.Equal(t, "en-US, de", r.AcceptLanguage())
+	require.Equal(t, "gzip, br", r.AcceptEncoding())
+	require.True(t, r.HasHeader(HeaderUserAgent))
+	require.False(t, r.HasHeader("X-Absent"))
+	require.Equal(t, MIMEApplicationJSON, r.MediaType()) //nolint:testifylint // this is comparing content-type strings, not JSON content
+	require.Equal(t, "utf-8", r.Charset())
+	require.True(t, r.IsJSON())
+	require.False(t, r.IsForm())
+	require.False(t, r.IsMultipart())
+	require.True(t, r.AcceptsJSON())
+	require.False(t, r.AcceptsHTML())
+	require.False(t, r.AcceptsXML())
+	require.False(t, r.AcceptsEventStream())
+
+	require.Equal(t, "/path/here", r.Path())
+	require.False(t, r.Secure())
+	require.False(t, r.XHR())
+	require.True(t, r.HasBody())
+	require.False(t, r.IsWebSocket())
+	require.False(t, r.IsPreflight())
+
+	require.Equal(t, r.FullURL(), c.FullURL())
+	require.Equal(t, r.UserAgent(), c.UserAgent())
+	require.Equal(t, r.MediaType(), c.MediaType())
+	require.Equal(t, r.Path(), c.Path())
+	require.Equal(t, r.HasBody(), c.HasBody())
+	require.Equal(t, r.IsPreflight(), c.IsPreflight())
+}
+
+func Test_Req_PathOverride(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetRequestURI("/original")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, "/original", c.Req().Path())
+	require.Equal(t, "/rewritten", c.Req().Path("/rewritten"))
+	require.Equal(t, "/rewritten", c.Path())
+	require.Equal(t, "/rewritten", string(c.Request().URI().Path()))
+}
+
+func Test_Req_GetAll(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.Add("X-Test", "first")
+	fctx.Request.Header.Add("X-Test", "second")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, []string{"first", "second"}, c.Req().GetAll("X-Test"))
+	require.Equal(t, []string{"first", "second"}, c.Req().GetAll("x-test"))
+	require.Equal(t, "first", c.Req().Get("X-Test"))
+	require.Nil(t, c.Req().GetAll("X-Absent"))
+}
+
+func Test_Req_ContentLength(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var length int
+	app.Post("/", func(c Ctx) error {
+		length = c.Req().ContentLength()
+		return nil
+	})
+
+	_, err := app.Test(httptest.NewRequest(MethodPost, "/", strings.NewReader("0123456789")))
+	require.NoError(t, err)
+	require.Equal(t, 10, length)
+
+	chunked := &fasthttp.RequestCtx{}
+	chunked.Request.Header.SetContentLength(-1)
+	cc := app.AcquireCtx(chunked)
+	t.Cleanup(func() { app.ReleaseCtx(cc) })
+
+	require.Equal(t, -1, cc.Req().ContentLength(), "chunked bodies report an unknown length")
+	require.True(t, cc.Req().HasBody(), "an unknown length still means there is a body")
+
+	var bodyless int
+	app.Get("/", func(c Ctx) error {
+		bodyless = c.Req().ContentLength()
+		return nil
+	})
+	_, err = app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, -2, bodyless)
+}
+
+func Test_Req_GetAll_AbsentSlottedHeaders(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var got map[string][]string
+	var has map[string]bool
+	app.Get("/", func(c Ctx) error {
+		got = map[string][]string{}
+		has = map[string]bool{}
+		for _, key := range []string{HeaderContentLength, HeaderTrailer, "X-Absent"} {
+			got[key] = c.Req().GetAll(key)
+			has[key] = c.Req().HasHeader(key)
+		}
+		return nil
+	})
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+
+	for key, lines := range got {
+		require.Nil(t, lines, key)
+		require.False(t, has[key], key)
+		require.Equal(t, has[key], len(lines) > 0, "GetAll and HasHeader must agree on %s", key)
+	}
+}
+
+func Test_Req_ContentType(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetContentType(MIMEApplicationJSON + "; charset=utf-8")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, MIMEApplicationJSONCharsetUTF8, c.Req().ContentType())                      //nolint:testifylint // this is comparing content-type headers, not JSON content
+	require.Equal(t, MIMEApplicationJSON, c.Req().MediaType(), "MediaType drops the parameters") //nolint:testifylint // same
+	require.Equal(t, "utf-8", c.Req().Charset())
+
+	require.NoError(t, c.SendString("hi"))
+	c.Type("html")
+	require.Equal(t, c.Req().ContentType(), c.ContentType())
+	require.Equal(t, MIMETextHTMLCharsetUTF8, c.Res().ContentType())
+}
+
+func Test_Req_BodyStream(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	buffered := &fasthttp.RequestCtx{}
+	buffered.Request.SetBody([]byte("buffered"))
+	bc := app.AcquireCtx(buffered)
+	t.Cleanup(func() { app.ReleaseCtx(bc) })
+	require.Nil(t, bc.Req().BodyStream(), "a buffered body is not a stream")
+
+	streamed := &fasthttp.RequestCtx{}
+	streamed.Request.SetBodyStream(strings.NewReader("streamed"), 8)
+	sc := app.AcquireCtx(streamed)
+	t.Cleanup(func() { app.ReleaseCtx(sc) })
+
+	stream := sc.Req().BodyStream()
+	require.NotNil(t, stream)
+	body, err := io.ReadAll(stream)
+	require.NoError(t, err)
+	require.Equal(t, "streamed", string(body))
+}
+
+func Test_Req_URI(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetRequestURI("/search?q=fiber#frag")
+	fctx.Request.Header.SetHost("example.com")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	uri := c.Req().URI()
+	require.NotNil(t, uri)
+	require.Equal(t, "/search", string(uri.Path()))
+	require.Equal(t, "q=fiber", string(uri.QueryString()))
+	require.Equal(t, "frag", string(uri.Hash()))
+	require.Equal(t, "example.com", string(uri.Host()))
+}
+
+func Test_Req_Origin(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.Set(HeaderOrigin, "https://example.com")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+	require.Equal(t, "https://example.com", c.Req().Origin())
+
+	bare := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(bare) })
+	require.Empty(t, bare.Req().Origin())
+}
+
+func Test_Req_Authorization(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	tests := []struct {
+		name        string
+		header      string
+		scheme      string
+		credentials string
+		bearer      string
+	}{
+		{name: "absent"},
+		{name: "bearer", header: "Bearer abc123", scheme: "Bearer", credentials: "abc123", bearer: "abc123"},
+		{name: "bearer lowercase scheme", header: "bearer abc123", scheme: "bearer", credentials: "abc123", bearer: "abc123"},
+		{name: "basic", header: "Basic dXNlcjpwYXNz", scheme: "Basic", credentials: "dXNlcjpwYXNz"},
+		{name: "auth-param list", header: `Digest username="u", realm="r"`, scheme: "Digest", credentials: `username="u", realm="r"`},
+		{name: "extra whitespace", header: "  Bearer   abc123  ", scheme: "Bearer", credentials: "abc123", bearer: "abc123"},
+		{name: "tab separator", header: "Bearer\tabc123", scheme: "Bearer", credentials: "abc123", bearer: "abc123"},
+		{name: "scheme only", header: "Negotiate", scheme: "Negotiate"},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			fctx := &fasthttp.RequestCtx{}
+			if tc.header != "" {
+				fctx.Request.Header.Set(HeaderAuthorization, tc.header)
+			}
+			c := app.AcquireCtx(fctx)
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			scheme, credentials := c.Req().Authorization()
+			require.Equal(t, tc.scheme, scheme)
+			require.Equal(t, tc.credentials, credentials)
+			require.Equal(t, tc.bearer, c.Req().Bearer())
+		})
+	}
+}
+
+func Test_Req_IsSafe_IsIdempotent(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	tests := []struct {
+		method     string
+		safe       bool
+		idempotent bool
+	}{
+		{method: MethodGet, safe: true, idempotent: true},
+		{method: MethodHead, safe: true, idempotent: true},
+		{method: MethodOptions, safe: true, idempotent: true},
+		{method: MethodTrace, safe: true, idempotent: true},
+		{method: MethodPut, safe: false, idempotent: true},
+		{method: MethodDelete, safe: false, idempotent: true},
+		{method: MethodPost, safe: false, idempotent: false},
+		{method: MethodPatch, safe: false, idempotent: false},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.method, func(t *testing.T) {
+			t.Parallel()
+
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Request.Header.SetMethod(tc.method)
+			c := app.AcquireCtx(fctx)
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			require.Equal(t, tc.safe, c.Req().IsSafe())
+			require.Equal(t, tc.idempotent, c.Req().IsIdempotent())
+		})
+	}
+}
+
+func Test_Req_CookieNames_AllCookies(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetCookie("session", "abc")
+	fctx.Request.Header.SetCookie("theme", "dark")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.ElementsMatch(t, []string{"session", "theme"}, c.Req().CookieNames())
+	require.Equal(t, map[string]string{"session": "abc", "theme": "dark"}, c.Req().AllCookies())
+
+	shadowed := &fasthttp.RequestCtx{}
+	shadowed.Request.Header.Set(HeaderCookie, "a=first; a=second")
+	sc := app.AcquireCtx(shadowed)
+	t.Cleanup(func() { app.ReleaseCtx(sc) })
+
+	require.Equal(t, "first", sc.Req().Cookies("a"))
+	require.Equal(t, "first", sc.Req().AllCookies()["a"])
+	require.Equal(t, []string{"a", "a"}, sc.Req().CookieNames(), "the repetition itself stays visible")
+
+	bare := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(bare) })
+	require.Empty(t, bare.Req().CookieNames())
+	require.Empty(t, bare.Req().AllCookies())
+}
+
+func Test_Req_IfNoneMatch(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	tests := []struct {
+		name   string
+		header string
+		want   []string
+	}{
+		{name: "absent"},
+		{name: "single", header: `"abc"`, want: []string{`"abc"`}},
+		{name: "list", header: `"a", W/"b"`, want: []string{`"a"`, `W/"b"`}},
+		{name: "wildcard", header: "*", want: []string{"*"}},
+		{name: "comma inside tag", header: `"v1,v2"`, want: []string{`"v1,v2"`}},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			fctx := &fasthttp.RequestCtx{}
+			if tc.header != "" {
+				fctx.Request.Header.Set(HeaderIfNoneMatch, tc.header)
+			}
+			c := app.AcquireCtx(fctx)
+			t.Cleanup(func() { app.ReleaseCtx(c) })
+
+			require.Equal(t, tc.want, c.Req().IfNoneMatch())
+		})
+	}
+}
+
+func Test_Req_IfNoneMatch_MultipleFieldLines(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.Add(HeaderIfNoneMatch, `"a"`)
+	fctx.Request.Header.Add(HeaderIfNoneMatch, `"b"`)
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, []string{`"a"`, `"b"`}, c.Req().IfNoneMatch())
+}
+
+func Test_Req_IfModifiedSince(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	bare := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(bare) })
+	_, err := bare.Req().IfModifiedSince()
+	require.ErrorIs(t, err, ErrHeaderNotFound)
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.Set(HeaderIfModifiedSince, "Wed, 21 Oct 2015 07:28:00 GMT")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	got, err := c.Req().IfModifiedSince()
+	require.NoError(t, err)
+	require.True(t, got.Equal(time.Date(2015, time.October, 21, 7, 28, 0, 0, time.UTC)))
+
+	malformed := &fasthttp.RequestCtx{}
+	malformed.Request.Header.Set(HeaderIfModifiedSince, "not a date")
+	mc := app.AcquireCtx(malformed)
+	t.Cleanup(func() { app.ReleaseCtx(mc) })
+
+	_, err = mc.Req().IfModifiedSince()
+	require.Error(t, err)
+	require.NotErrorIs(t, err, ErrHeaderNotFound, "a malformed date is not an absent header")
+}
+
+func Test_Res_StatusCode(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, StatusOK, c.Res().StatusCode(), "an untouched response reports 200")
+	c.Status(StatusTeapot)
+	require.Equal(t, StatusTeapot, c.Res().StatusCode())
+	require.Equal(t, c.Response().StatusCode(), c.Res().StatusCode())
+}
+
+func Test_Res_Body_ResetBody_Written(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Empty(t, c.Res().Body())
+	require.False(t, c.Res().Written())
+
+	c.Status(StatusCreated)
+	require.False(t, c.Res().Written())
+
+	require.NoError(t, c.SendString("hello"))
+	require.Equal(t, "hello", string(c.Res().Body()))
+	require.True(t, c.Res().Written())
+
+	c.Res().ResetBody()
+	require.Empty(t, c.Res().Body())
+	require.False(t, c.Res().Written())
+	require.Equal(t, StatusCreated, c.Res().StatusCode(), "ResetBody keeps the status")
+}
+
+func Test_Res_Written_BodyStream(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.NoError(t, c.SendStream(strings.NewReader("streamed"), 8))
+	require.True(t, c.Res().Written())
+	require.True(t, c.Response().IsBodyStream())
+}
+
+func Test_Res_Del(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Set("X-Custom", "value")
+	require.Equal(t, "value", c.Res().Get("X-Custom"))
+	c.Res().Del("x-custom")
+	require.Empty(t, c.Res().Get("X-Custom"))
+
+	require.NotPanics(t, func() { c.Res().Del("X-Absent") })
+
+	c.Res().Add("X-Multi", "a")
+	c.Res().Add("X-Multi", "b")
+	require.Len(t, c.Response().Header.PeekAll("X-Multi"), 2)
+	c.Res().Del("X-Multi")
+	require.Empty(t, c.Response().Header.PeekAll("X-Multi"))
+
+	c.Cookie(&Cookie{Name: "a", Value: "1"})
+	require.NotEmpty(t, c.Res().GetCookies())
+	c.Res().Del(HeaderSetCookie)
+	require.Empty(t, c.Res().GetCookies())
+}
+
+func Test_Res_Add(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Res().Add(HeaderWWWAuthenticate, `Basic realm="one"`)
+	c.Res().Add(HeaderWWWAuthenticate, `Bearer realm="two"`)
+
+	lines := c.Response().Header.PeekAll(HeaderWWWAuthenticate)
+	require.Len(t, lines, 2, "Add keeps challenges on separate field lines")
+	require.Equal(t, `Basic realm="one"`, string(lines[0]))
+	require.Equal(t, `Bearer realm="two"`, string(lines[1]))
+
+	c.Append("X-Folded", "a")
+	c.Append("X-Folded", "b")
+	require.Len(t, c.Response().Header.PeekAll("X-Folded"), 1)
+	require.Equal(t, "a, b", c.Res().Get("X-Folded"))
+}
+
+func Test_Res_ContentType_ContentLength(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, MIMETextPlainCharsetUTF8, c.Res().ContentType(), "an untouched response reports fasthttp's default")
+
+	require.NoError(t, c.JSON(Map{"a": 1}))
+	require.Equal(t, MIMEApplicationJSONCharsetUTF8, c.Res().ContentType()) //nolint:testifylint // this is comparing content-type headers, not JSON content
+
+	c.Type("html")
+	require.Equal(t, MIMETextHTMLCharsetUTF8, c.Res().ContentType(), "ContentType reads back what Type set")
+
+	require.NotEmpty(t, c.Res().Body())
+	require.Equal(t, 0, c.Res().ContentLength())
+
+	c.Set(HeaderContentLength, "42")
+	require.Equal(t, 42, c.Res().ContentLength())
+}
+
+func Test_Res_GetCookie_Cookies(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	_, ok := c.Res().GetCookie("absent")
+	require.False(t, ok)
+	require.Empty(t, c.Res().GetCookies())
+
+	expires := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
+	c.Cookie(&Cookie{
+		Name:     "session",
+		Value:    "abc",
+		Path:     "/scoped",
+		Domain:   "example.com",
+		MaxAge:   60,
+		Expires:  expires,
+		Secure:   true,
+		HTTPOnly: true,
+		SameSite: CookieSameSiteStrictMode,
+	})
+
+	got, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	require.Equal(t, "session", got.Name)
+	require.Equal(t, "abc", got.Value)
+	require.Equal(t, "/scoped", got.Path)
+	require.Equal(t, "example.com", got.Domain)
+	require.Equal(t, 60, got.MaxAge)
+	require.True(t, got.Secure)
+	require.True(t, got.HTTPOnly)
+	require.Equal(t, CookieSameSiteStrictMode, got.SameSite)
+	require.False(t, got.SessionOnly)
+
+	c.Cookie(&Cookie{Name: "flash", Value: "x", SessionOnly: true})
+	flash, ok := c.Res().GetCookie("flash")
+	require.True(t, ok)
+	require.True(t, flash.SessionOnly)
+	require.Zero(t, flash.MaxAge)
+	require.True(t, flash.Expires.IsZero())
+
+	cookies := c.Res().GetCookies()
+	require.Len(t, cookies, 2)
+	names := make([]string, 0, len(cookies))
+	for _, cookie := range cookies {
+		names = append(names, cookie.Name)
+	}
+	require.ElementsMatch(t, []string{"session", "flash"}, names)
+
+	got.Value = "tampered"
+	again, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	require.Equal(t, "abc", again.Value)
+}
+
+func Test_Res_Cookies_RepeatedNames(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Cookie(&Cookie{Name: "sid", Value: "app", Path: "/app"})
+	c.Res().Add(HeaderSetCookie, "sid=admin; path=/admin")
+	c.Cookie(&Cookie{Name: "other", Value: "z"})
+
+	cookies := c.Res().GetCookies()
+	require.Len(t, cookies, 3)
+
+	type pair struct{ value, path string }
+	got := make([]pair, 0, len(cookies))
+	for _, cookie := range cookies {
+		got = append(got, pair{cookie.Value, cookie.Path})
+	}
+	require.ElementsMatch(t, []pair{{"app", "/app"}, {"admin", "/admin"}, {"z", "/"}}, got)
+
+	first, ok := c.Res().GetCookie("sid")
+	require.True(t, ok)
+	require.Equal(t, "app", first.Value)
+
+	over := New()
+	over.Get("/", func(c Ctx) error {
+		c.Cookie(&Cookie{Name: "sid", Value: "app", Path: "/app"})
+		c.Res().Add(HeaderSetCookie, "sid=admin; path=/admin")
+		c.Cookie(&Cookie{Name: "other", Value: "z"})
+		return nil
+	})
+	resp, err := over.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Len(t, resp.Header.Values(HeaderSetCookie), 3)
+}
+
+func Test_Res_GetCookie_Deletion(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Cookie(&Cookie{Name: "session", Value: "v", MaxAge: -1})
+	require.Contains(t, string(c.Response().Header.Peek(HeaderSetCookie)), "max-age=0")
+
+	got, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	require.False(t, got.SessionOnly, "an explicit max-age=0 is a deletion, not a session cookie")
+	require.Negative(t, got.MaxAge)
+
+	got.Domain = "example.com"
+	c.Cookie(got)
+	require.Contains(t, string(c.Response().Header.Peek(HeaderSetCookie)), "max-age=0")
+
+	rewritten, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	require.False(t, rewritten.SessionOnly)
+	require.Equal(t, "example.com", rewritten.Domain)
+}
+
+func Test_Res_Body_DoesNotDrainStream(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.NoError(t, c.SendStream(strings.NewReader("streamed"), 8))
+	require.True(t, c.Res().Written())
+	require.Nil(t, c.Res().Body(), "a streamed body is not materialized")
+	require.True(t, c.Response().IsBodyStream(), "and it is still a stream afterwards")
+}
+
+func Test_Res_Add_SpecialHeaders(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Set(HeaderContentType, MIMEApplicationJSON)
+	c.Res().Add(HeaderContentType, MIMETextPlain)
+	require.Equal(t, MIMETextPlain, c.Res().ContentType(), "Content-Type is replaced, not appended")
+	require.Len(t, c.Response().Header.PeekAll(HeaderContentType), 1)
+
+	c.Res().Add(HeaderLink, "</a>; rel=preload")
+	c.Res().Add(HeaderLink, "</b>; rel=preload")
+	require.Len(t, c.Response().Header.PeekAll(HeaderLink), 2)
+}
+
+func Test_Res_GetCookie_RoundTrip(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Cookie(&Cookie{Name: "session", Value: "plain", Path: "/app", HTTPOnly: true, SameSite: CookieSameSiteLaxMode})
+
+	cookie, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	cookie.Value = "encrypted"
+	c.Cookie(cookie)
+
+	rewritten, ok := c.Res().GetCookie("session")
+	require.True(t, ok)
+	require.Equal(t, "encrypted", rewritten.Value)
+	require.Equal(t, "/app", rewritten.Path, "the other attributes survive the round trip")
+	require.True(t, rewritten.HTTPOnly)
+	require.Equal(t, CookieSameSiteLaxMode, rewritten.SameSite)
+	require.Len(t, c.Res().GetCookies(), 1, "rewriting replaces the cookie rather than adding one")
+}
+
+func Test_Res_NoContent(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.NoError(t, c.JSON(Map{"a": 1}))
+	require.NotEmpty(t, c.Res().Body())
+
+	require.NoError(t, c.Res().NoContent())
+	require.Equal(t, StatusNoContent, c.Res().StatusCode())
+	require.Empty(t, c.Res().Body())
+	require.False(t, c.Res().Written())
+	require.NotEqual(t, MIMEApplicationJSONCharsetUTF8, c.Res().ContentType(),
+		"the handler's Content-Type is gone; Test_Res_NoContent_OverHTTP pins that none is sent")
+}
+
+func Test_Res_NoContent_OverHTTP(t *testing.T) {
+	t.Parallel()
+	app := New()
+	app.Delete("/item", func(c Ctx) error {
+		return c.Res().NoContent()
+	})
+
+	resp, err := app.Test(httptest.NewRequest(MethodDelete, "/item", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, StatusNoContent, resp.StatusCode)
+	require.Empty(t, resp.Header.Get(HeaderContentType))
+
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Empty(t, body)
+}
+
+func Test_Res_NoContent_DiffersFromSendStatus(t *testing.T) {
+	t.Parallel()
+	app := New()
+	app.Get("/sendstatus", func(c Ctx) error {
+		c.Type("json")
+		return c.SendStatus(StatusNoContent)
+	})
+	app.Get("/nocontent", func(c Ctx) error {
+		c.Type("json")
+		return c.Res().NoContent()
+	})
+
+	sent, err := app.Test(httptest.NewRequest(MethodGet, "/sendstatus", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, StatusNoContent, sent.StatusCode)
+	require.NotEmpty(t, sent.Header.Get(HeaderContentType))
+
+	none, err := app.Test(httptest.NewRequest(MethodGet, "/nocontent", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, StatusNoContent, none.StatusCode)
+	require.Empty(t, none.Header.Get(HeaderContentType))
+}
+
+func Test_Ctx_BodyContentLengthCookiesPreferRequest(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetBody([]byte("request body"))
+	fctx.Request.Header.SetContentLength(len("request body"))
+	fctx.Request.Header.SetCookie("who", "client")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.NoError(t, c.SendString("response body"))
+	c.Cookie(&Cookie{Name: "who", Value: "server"})
+
+	require.Equal(t, "request body", string(c.Body()))
+	require.Equal(t, "request body", string(c.Req().Body()))
+	require.Equal(t, "response body", string(c.Res().Body()))
+
+	require.Equal(t, len("request body"), c.ContentLength())
+	require.Equal(t, len("request body"), c.Req().ContentLength())
+
+	require.Equal(t, "client", c.Cookies("who"))
+	require.Equal(t, "client", c.Req().Cookies("who"))
+	require.Equal(t, "fallback", c.Cookies("absent", "fallback"))
+
+	serverCookies := c.Res().GetCookies()
+	require.Len(t, serverCookies, 1)
+	require.Equal(t, "server", serverCookies[0].Value)
+
+	require.Equal(t, c.Req().ContentType(), c.ContentType())
+}
+
+func Test_Ctx_ID_StartTime_Elapsed(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var (
+		id      uint64
+		stable  bool
+		start   time.Time
+		elapsed time.Duration
+	)
+	app.Get("/", func(c Ctx) error {
+		id = c.ID()
+		stable = c.ID() == id
+		start = c.StartTime()
+		elapsed = c.Elapsed()
+		return nil
+	})
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+
+	require.NotZero(t, id)
+	require.True(t, stable, "ID is stable within a request")
+	require.False(t, start.IsZero())
+	require.GreaterOrEqual(t, elapsed, time.Duration(0))
+	require.Less(t, elapsed, time.Minute, "Elapsed measures from StartTime, not from the epoch")
+}
+
+func Test_Ctx_LocalAddr_RemoteAddr(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var local, remote net.Addr
+	app.Get("/", func(c Ctx) error {
+		local = c.LocalAddr()
+		remote = c.RemoteAddr()
+		return nil
+	})
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+
+	require.NotNil(t, local)
+	require.NotNil(t, remote)
+	require.NotEmpty(t, remote.Network())
+}
+
+func Test_Ctx_Hijack(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.False(t, c.Hijacked())
+	c.Hijack(func(net.Conn) {})
+	require.True(t, c.Hijacked())
+}
+
+func Test_Ctx_RouteName(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var mwName, handlerName string
+	app.Use(func(c Ctx) error {
+		mwName = c.RouteName()
+		return c.Next()
+	})
+	app.Get("/home", func(c Ctx) error {
+		handlerName = c.RouteName()
+		return nil
+	}).Name("home")
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/home", http.NoBody))
+	require.NoError(t, err)
+
+	require.Equal(t, "home", handlerName)
+	require.Empty(t, mwName, "middleware reports its own unnamed route, not the endpoint's")
+}
+
+func Test_Ctx_RouteName_Unmatched(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.NotPanics(t, func() { require.Empty(t, c.RouteName()) })
+}
+
+func Test_Ctx_IsFinal(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	var (
+		inGlobalMW bool
+		inRouteMW  bool
+		inHandler  bool
+	)
+	app.Use(func(c Ctx) error {
+		inGlobalMW = c.IsFinal()
+		return c.Next()
+	})
+	app.Get("/chain", func(c Ctx) error {
+		inRouteMW = c.IsFinal()
+		return c.Next()
+	}, func(c Ctx) error {
+		inHandler = c.IsFinal()
+		return nil
+	})
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/chain", http.NoBody))
+	require.NoError(t, err)
+
+	require.False(t, inGlobalMW)
+	require.False(t, inRouteMW, "a route handler with another after it is not final")
+	require.True(t, inHandler)
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+	require.False(t, c.IsFinal())
+	require.False(t, c.IsMiddleware())
+}
+
+func Test_Ctx_IsFinal_ScopedToTheRoute(t *testing.T) {
+	t.Parallel()
+
+	terminal := New()
+	var inUse bool
+	terminal.Use(func(c Ctx) error {
+		inUse = c.IsFinal()
+		return c.SendString("done")
+	})
+	_, err := terminal.Test(httptest.NewRequest(MethodGet, "/anything", http.NoBody))
+	require.NoError(t, err)
+	require.False(t, inUse, "a Use route is middleware by registration, whatever its position")
+
+	overlapping := New()
+	var inSpecific, inCatchAll bool
+	overlapping.Get("/specific", func(c Ctx) error {
+		inSpecific = c.IsFinal()
+		return c.Next()
+	})
+	overlapping.Get("/*", func(_ Ctx) error {
+		inCatchAll = true
+		return nil
+	})
+	_, err = overlapping.Test(httptest.NewRequest(MethodGet, "/specific", http.NoBody))
+	require.NoError(t, err)
+	require.True(t, inSpecific, "it is the last handler of its own route")
+	require.True(t, inCatchAll, "but another route still matched after it")
+}
+
+func Test_Ctx_MountPath(t *testing.T) {
+	t.Parallel()
+
+	micro := New()
+	var mounted, mountedPath string
+	micro.Get("/doe", func(c Ctx) error {
+		mounted = c.MountPath()
+		mountedPath = strings.Clone(c.Path())
+		return nil
+	})
+
+	app := New()
+	var top string
+	app.Get("/top", func(c Ctx) error {
+		top = c.MountPath()
+		return nil
+	})
+	app.Use("/john", micro)
+
+	_, err := app.Test(httptest.NewRequest(MethodGet, "/john/doe", http.NoBody))
+	require.NoError(t, err)
+	_, err = app.Test(httptest.NewRequest(MethodGet, "/top", http.NoBody))
+	require.NoError(t, err)
+
+	var standalone string
+	micro.Get("/solo", func(c Ctx) error {
+		standalone = c.MountPath()
+		return nil
+	})
+	_, err = micro.Test(httptest.NewRequest(MethodGet, "/solo", http.NoBody))
+	require.NoError(t, err)
+	require.Empty(t, standalone)
+	require.Equal(t, "/john", micro.MountPath(), "App.MountPath still reports the mount")
+
+	require.Equal(t, "/john", mounted)
+	require.Equal(t, "/john/doe", mountedPath,
+		"Fiber bakes the prefix into the cloned route, so Path is not relative to the mount")
+	require.True(t, strings.HasPrefix(mountedPath, mounted), "the served path lives under MountPath")
+	require.Empty(t, top, "the top-level app is not mounted under anything")
+}
+
+func Test_Ctx_Error(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	err := c.Error(StatusTeapot)
+	var fiberErr *Error
+	require.ErrorAs(t, err, &fiberErr)
+	require.Equal(t, StatusTeapot, fiberErr.Code)
+	require.Equal(t, utils.StatusMessage(StatusTeapot), fiberErr.Message)
+
+	err = c.Error(StatusBadRequest, "id must be numeric")
+	require.ErrorAs(t, err, &fiberErr)
+	require.Equal(t, StatusBadRequest, fiberErr.Code)
+	require.Equal(t, "id must be numeric", fiberErr.Message)
+
+	require.Equal(t, StatusOK, c.Res().StatusCode(), "Error builds an error, it does not write the response")
+	require.False(t, c.Res().Written())
+}
+
+func Test_Ctx_Error_ReachesErrorHandler(t *testing.T) {
+	t.Parallel()
+	app := New()
+	app.Get("/", func(c Ctx) error {
+		return c.Error(StatusBadRequest, "id must be numeric")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, StatusBadRequest, resp.StatusCode)
+
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "id must be numeric", string(body))
+}
+
+func Test_Req_HeaderFieldWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("origin", "https://example.com")
+	fctx.Request.Header.Set("authorization", "Bearer abc123")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, "https://example.com", c.Get(HeaderOrigin))
+	require.Equal(t, "https://example.com", c.Req().Origin())
+
+	scheme, credentials := c.Req().Authorization()
+	require.Equal(t, "Bearer", scheme)
+	require.Equal(t, "abc123", credentials)
+	require.Equal(t, "abc123", c.Req().Bearer())
+}
+
+func Test_Req_ConditionalHeadersWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("if-none-match", `"a", W/"b"`)
+	fctx.Request.Header.Set("if-modified-since", "Wed, 21 Oct 2015 07:28:00 GMT")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, []string{`"a"`, `W/"b"`}, c.Req().IfNoneMatch())
+
+	since, err := c.Req().IfModifiedSince()
+	require.NoError(t, err)
+	require.True(t, since.Equal(time.Date(2015, time.October, 21, 7, 28, 0, 0, time.UTC)))
+}
+
+func Test_Req_IsPreflightWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.SetMethod(MethodOptions)
+	fctx.Request.Header.Set("origin", "https://example.com")
+	fctx.Request.Header.Set("access-control-request-method", MethodGet)
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.True(t, c.Req().IsPreflight())
+}
+
+func Test_Res_Del_CaseInsensitive(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Response.Header.DisableNormalizing()
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Response().Header.Set("x-token", "secret")
+	require.Equal(t, "secret", string(c.Response().Header.Peek("x-token")))
+
+	c.Res().Del(HeaderXRequestID)
+	c.Res().Del("X-Token")
+	require.Empty(t, string(c.Response().Header.Peek("x-token")), "a differently cased field is still removed")
+}
+
+func Test_Res_Cookies_UnparsableEntry(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Cookie(&Cookie{Name: "good", Value: "1"})
+	c.Res().Add(HeaderSetCookie, "")
+
+	cookies := c.Res().GetCookies()
+	require.Len(t, cookies, 1, "the unparsable entry is skipped")
+	require.Equal(t, "good", cookies[0].Name)
+
+	_, ok := c.Res().GetCookie("")
+	require.False(t, ok, "GetCookie reports failure rather than a half-parsed cookie")
+
+	good, ok := c.Res().GetCookie("good")
+	require.True(t, ok)
+	require.Equal(t, "1", good.Value)
+}
+
+func Test_Res_GetCookie_NoAttributes(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Res().Add(HeaderSetCookie, "plain=value")
+
+	got, ok := c.Res().GetCookie("plain")
+	require.True(t, ok)
+	require.Equal(t, "value", got.Value)
+	require.Empty(t, got.Path)
+	require.Zero(t, got.MaxAge)
+	require.True(t, got.SessionOnly, "no Max-Age and no Expires is a session cookie")
+}
+
+func Test_Ctx_MountPath_NoApp(t *testing.T) {
+	t.Parallel()
+
+	var c DefaultCtx
+	require.NotPanics(t, func() { require.Empty(t, c.MountPath()) })
+}
+
+func Test_Req_HasHeaderWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("x-test", "yes")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.True(t, c.Req().HasHeader("X-Test"))
+	require.Equal(t, []string{"yes"}, c.Req().GetAll("X-Test"))
+	require.True(t, c.Req().HasHeader("x-test"))
+	require.False(t, c.Req().HasHeader("X-Absent"))
+}
+
+func Test_Res_SendStatus_DropsDeclaredContentLength(t *testing.T) {
+	t.Parallel()
+	app := New()
+	for _, status := range []int{StatusNoContent, StatusResetContent, StatusNotModified} {
+		app.Get("/set"+strconv.Itoa(status), func(c Ctx) error {
+			c.Set(HeaderContentLength, "42")
+			return c.SendStatus(status)
+		})
+		app.Get("/bare"+strconv.Itoa(status), func(c Ctx) error {
+			return c.SendStatus(status)
+		})
+	}
+	app.Get("/nocontent", func(c Ctx) error {
+		c.Set(HeaderContentLength, "42")
+		return c.Res().NoContent()
+	})
+
+	get := func(path string) []string {
+		resp, err := app.Test(httptest.NewRequest(MethodGet, path, http.NoBody))
+		require.NoError(t, err)
+
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.Empty(t, body, path)
+		require.NotContains(t, resp.Header.Values(HeaderContentLength), "42", path)
+		return resp.Header.Values(HeaderContentLength)
+	}
+
+	for _, status := range []int{StatusNoContent, StatusResetContent, StatusNotModified} {
+		require.Equal(t, get("/bare"+strconv.Itoa(status)), get("/set"+strconv.Itoa(status)), status)
+	}
+
+	require.Empty(t, get("/nocontent"))
+	require.Equal(t, []string{"0"}, get("/bare205"))
+}
+
+func Test_Req_AcceptsWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("accept", "application/json")
+	fctx.Request.Header.Set("accept-charset", "utf-8")
+	fctx.Request.Header.Set("accept-encoding", "gzip")
+	fctx.Request.Header.Set("accept-language", "en-GB")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	r := c.Req()
+	require.Equal(t, "gzip", r.AcceptEncoding())
+	require.Equal(t, "en-GB", r.AcceptLanguage())
+
+	require.Equal(t, "application/json", r.Accepts("application/json", "text/html"))
+	require.Empty(t, r.Accepts("text/html"))
+	require.Equal(t, "utf-8", r.AcceptsCharsets("utf-8", "iso-8859-1"))
+	require.Empty(t, r.AcceptsCharsets("iso-8859-1"))
+	require.Equal(t, "gzip", r.AcceptsEncodings("gzip", "br"))
+	require.Empty(t, r.AcceptsEncodings("br"))
+	require.Equal(t, "en-GB", r.AcceptsLanguages("en-GB", "de"))
+	require.Empty(t, r.AcceptsLanguages("de"))
+}
+
+func Test_Req_FreshWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	newCtx := func(t *testing.T, set func(h *fasthttp.RequestHeader)) Ctx {
+		t.Helper()
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Request.Header.DisableNormalizing()
+		fctx.Request.Header.SetMethod(MethodGet)
+		set(&fctx.Request.Header)
+		c := app.AcquireCtx(fctx)
+		t.Cleanup(func() { app.ReleaseCtx(c) })
+		return c
+	}
+
+	c := newCtx(t, func(h *fasthttp.RequestHeader) {
+		h.Set("if-none-match", `"abc"`)
+	})
+	c.Res().Set(HeaderETag, `"abc"`)
+	require.True(t, c.Req().Fresh())
+	require.Equal(t, []string{`"abc"`}, c.Req().IfNoneMatch())
+
+	noCache := newCtx(t, func(h *fasthttp.RequestHeader) {
+		h.Set("if-none-match", `"abc"`)
+		h.Set("cache-control", "no-cache")
+	})
+	noCache.Res().Set(HeaderETag, `"abc"`)
+	require.False(t, noCache.Req().Fresh())
+
+	since := newCtx(t, func(h *fasthttp.RequestHeader) {
+		h.Set("if-modified-since", "Wed, 21 Oct 2015 07:28:00 GMT")
+	})
+	since.Res().Set(HeaderLastModified, "Tue, 20 Oct 2015 07:28:00 GMT")
+	require.True(t, since.Req().Fresh())
+}
+
+func Test_Req_HeaderFieldSkipsEmptyFirstLine(t *testing.T) {
+	t.Parallel()
+	app := New()
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.Add("X-Thing", "")
+	fctx.Request.Header.Add("X-Thing", "v2")
+	fctx.Request.Header.Add(HeaderAuthorization, "")
+	fctx.Request.Header.Add(HeaderAuthorization, "Bearer tok")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.True(t, c.Req().HasHeader("X-Thing"))
+	require.Equal(t, []string{"v2"}, c.Req().GetAll("X-Thing"))
+	require.Equal(t, "v2", c.Req().Get("X-Thing"))
+	require.Equal(t, "tok", c.Req().Bearer())
+}
+
+func Test_Req_GetWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("x-api-key", "k1")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.True(t, c.Req().HasHeader("X-Api-Key"))
+	require.Equal(t, "k1", c.Req().Get("X-Api-Key"))
+	require.Equal(t, "k1", GetReqHeader[string](c, "X-Api-Key"))
+}
+
+func Test_Req_BodyContentEncodingWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	var buf bytes.Buffer
+	zw := gzip.NewWriter(&buf)
+	_, err := zw.Write([]byte("hello world"))
+	require.NoError(t, err)
+	require.NoError(t, zw.Close())
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.SetMethod(MethodPost)
+	fctx.Request.Header.Set("content-encoding", "gzip")
+	fctx.Request.SetBody(buf.Bytes())
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.Equal(t, []byte("hello world"), c.Req().Body())
+}
+
+func Test_Req_UpgradePredicatesWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("connection", "Upgrade")
+	fctx.Request.Header.Set("upgrade", "websocket")
+	fctx.Request.Header.Set("x-requested-with", "XMLHttpRequest")
+	fctx.Request.Header.Set("range", "bytes=0-5")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	require.True(t, c.Req().IsWebSocket())
+	require.True(t, c.Req().XHR())
+
+	rg, err := c.Req().Range(100)
+	require.NoError(t, err)
+	require.Equal(t, "bytes", rg.Type)
+	require.Equal(t, []RangeSet{{Start: 0, End: 5}}, rg.Ranges)
+}
+
+func Test_Res_FormatWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Request.Header.Set("accept", "text/html")
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	err := c.Res().Format(
+		ResFmt{MediaType: "application/json", Handler: func(cc Ctx) error { return cc.SendString("json") }},
+		ResFmt{MediaType: "text/html", Handler: func(cc Ctx) error { return cc.SendString("html") }},
+	)
+	require.NoError(t, err)
+	require.Equal(t, "html", string(c.Response().Body()))
+}
+
+func Test_Res_DelKeyCaseWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := New(Config{DisableHeaderNormalizing: true})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Response.Header.DisableNormalizing()
+	c := app.AcquireCtx(fctx)
+	t.Cleanup(func() { app.ReleaseCtx(c) })
+
+	c.Res().Set("X-Token", "secret")
+	c.Res().Del("x-token")
+	require.Empty(t, string(c.Response().Header.Peek("X-Token")))
+}
+
+func Test_Req_Res_AccessorsImmutable(t *testing.T) {
+	t.Parallel()
+
+	scrubHeader := func(field string) func(c Ctx) {
+		return func(c Ctx) {
+			raw := c.Request().Header.Peek(field)
+			for i := range raw {
+				raw[i] = 'X'
+			}
+		}
+	}
+
+	tests := []struct {
+		setup func(c Ctx)
+		read  func(c Ctx) string
+		scrub func(c Ctx)
+		name  string
+		want  string
+		// alwaysCopies marks an accessor that builds its own string whatever
+		// Immutable says, so the buffer it was read from cannot be observed.
+		alwaysCopies bool
+	}{
+		{
+			name:  "UserAgent",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderUserAgent, "agent-one") },
+			read:  func(c Ctx) string { return c.UserAgent() },
+			scrub: scrubHeader(HeaderUserAgent),
+			want:  "agent-one",
+		},
+		{
+			name:  "Referer",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderReferer, "https://ref.example/a") },
+			read:  func(c Ctx) string { return c.Referer() },
+			scrub: scrubHeader(HeaderReferer),
+			want:  "https://ref.example/a",
+		},
+		{
+			name:  "Origin",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderOrigin, "https://origin.example") },
+			read:  func(c Ctx) string { return c.Origin() },
+			scrub: scrubHeader(HeaderOrigin),
+			want:  "https://origin.example",
+		},
+		{
+			name:  "AcceptLanguage",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderAcceptLanguage, "en-GB,en;q=0.8") },
+			read:  func(c Ctx) string { return c.AcceptLanguage() },
+			scrub: scrubHeader(HeaderAcceptLanguage),
+			want:  "en-GB,en;q=0.8",
+		},
+		{
+			name:  "AcceptEncoding",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderAcceptEncoding, "gzip, br") },
+			read:  func(c Ctx) string { return c.AcceptEncoding() },
+			scrub: scrubHeader(HeaderAcceptEncoding),
+			want:  "gzip, br",
+		},
+		{
+			name:  "ContentType",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderContentType, "text/plain; charset=iso-8859-1") },
+			read:  func(c Ctx) string { return c.ContentType() },
+			scrub: scrubHeader(HeaderContentType),
+			want:  "text/plain; charset=iso-8859-1",
+		},
+		{
+			name:  "MediaType",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderContentType, "text/plain; charset=iso-8859-1") },
+			read:  func(c Ctx) string { return c.MediaType() },
+			scrub: scrubHeader(HeaderContentType),
+			want:  "text/plain",
+		},
+		{
+			name:  "Charset",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderContentType, "text/plain; charset=iso-8859-1") },
+			read:  func(c Ctx) string { return c.Charset() },
+			scrub: scrubHeader(HeaderContentType),
+			want:  "iso-8859-1",
+		},
+		{
+			name:  "Bearer",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderAuthorization, "Bearer tok-123") },
+			read:  func(c Ctx) string { return c.Bearer() },
+			scrub: scrubHeader(HeaderAuthorization),
+			want:  "tok-123",
+		},
+		{
+			name:  "Authorization",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderAuthorization, "Basic Y3JlZA==") },
+			read: func(c Ctx) string {
+				_, credentials := c.Authorization()
+				return credentials
+			},
+			scrub: scrubHeader(HeaderAuthorization),
+			want:  "Y3JlZA==",
+		},
+		{
+			name:  "GetAll",
+			setup: func(c Ctx) { c.Request().Header.Set("X-Multi", "one") },
+			read:  func(c Ctx) string { return strings.Join(c.GetAll("X-Multi"), "|") },
+			scrub: scrubHeader("X-Multi"),
+			want:  "one",
+		},
+		{
+			name:  "IfNoneMatch",
+			setup: func(c Ctx) { c.Request().Header.Set(HeaderIfNoneMatch, `"v1", "v2"`) },
+			read:  func(c Ctx) string { return c.IfNoneMatch()[0] },
+			scrub: scrubHeader(HeaderIfNoneMatch),
+			want:  `"v1"`,
+		},
+		{
+			name:         "AllCookies",
+			setup:        func(c Ctx) { c.Request().Header.Set(HeaderCookie, "sid=abc") },
+			read:         func(c Ctx) string { return c.AllCookies()["sid"] },
+			scrub:        scrubHeader(HeaderCookie),
+			want:         "abc",
+			alwaysCopies: true,
+		},
+		{
+			name:  "Res.ContentType",
+			setup: func(c Ctx) { c.Response().Header.Set(HeaderContentType, "application/xml") },
+			read:  func(c Ctx) string { return c.Res().ContentType() },
+			scrub: func(c Ctx) {
+				raw := c.Response().Header.Peek(HeaderContentType)
+				for i := range raw {
+					raw[i] = 'X'
+				}
+			},
+			want: "application/xml",
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := New(Config{Immutable: true})
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			tc.setup(c)
+
+			got := tc.read(c)
+			require.Equal(t, tc.want, got)
+
+			tc.scrub(c)
+			require.Equal(t, tc.want, got, "Immutable must hand back a copy, not a view of the header buffer")
+		})
+
+		if tc.alwaysCopies {
+			continue
+		}
+
+		t.Run(tc.name+"/scrubReachesTheBuffer", func(t *testing.T) {
+			t.Parallel()
+
+			app := New()
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+			tc.setup(c)
+
+			got := tc.read(c)
+			require.Equal(t, tc.want, got)
+
+			tc.scrub(c)
+			require.NotEqual(t, tc.want, got, "without Immutable the value views the header buffer, so this guards the test above against a scrub that reaches nothing")
+		})
+	}
+}
diff --git a/ctx_test.go b/ctx_test.go
index 0c051bf091d..8be594ea703 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -34,6 +34,7 @@ import (
 
 	"github.com/fxamacker/cbor/v2"
 	"github.com/gofiber/utils/v2"
+	utilsstrings "github.com/gofiber/utils/v2/strings"
 	"github.com/shamaton/msgpack/v3"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/bytebufferpool"
@@ -9828,6 +9829,157 @@ func Benchmark_Ctx_XHR(b *testing.B) {
 	require.True(b, equal)
 }
 
+// headerReadBenchCtx builds the request a browser sends, eight field lines, for
+// the header reads below. Names are stored the way the peer spelled them, so the
+// non-normalizing case exercises the case-insensitive walk rather than a store
+// fasthttp has already canonicalized.
+//
+//nolint:revive // flag-parameter: this selects which header store shape is measured
+func headerReadBenchCtx(b *testing.B, disableNormalizing bool) Ctx {
+	b.Helper()
+
+	app := New(Config{DisableHeaderNormalizing: disableNormalizing})
+	c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+	fields := [][2]string{
+		{HeaderUserAgent, "Mozilla/5.0"},
+		{HeaderAccept, "text/html,application/xhtml+xml"},
+		{HeaderAcceptLanguage, "en-US,en;q=0.9"},
+		{HeaderAcceptEncoding, "gzip, deflate, br"},
+		{HeaderConnection, "keep-alive"},
+		{HeaderCacheControl, "max-age=0"},
+		{"Sec-Fetch-Site", "same-origin"},
+		{HeaderXRequestID, "3f0c1a"},
+	}
+	if disableNormalizing {
+		c.Request().Header.DisableNormalizing()
+		for _, f := range fields {
+			c.Request().Header.Set(utilsstrings.ToLower(f[0]), f[1])
+		}
+		return c
+	}
+
+	for _, f := range fields {
+		c.Request().Header.Set(f[0], f[1])
+	}
+	return c
+}
+
+func benchHeaderReadModes(b *testing.B, f func(b *testing.B, c Ctx)) {
+	b.Helper()
+
+	b.Run("Normalizing", func(b *testing.B) {
+		c := headerReadBenchCtx(b, false)
+		b.ReportAllocs()
+		f(b, c)
+	})
+	b.Run("WithoutNormalizing", func(b *testing.B) {
+		c := headerReadBenchCtx(b, true)
+		b.ReportAllocs()
+		f(b, c)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_Get_Header -benchmem -count=4
+func Benchmark_Ctx_Get_Header(b *testing.B) {
+	benchHeaderReadModes(b, func(b *testing.B, c Ctx) {
+		b.Helper()
+		var v string
+		for b.Loop() {
+			v = c.Get(HeaderXRequestID)
+		}
+		require.Equal(b, "3f0c1a", v)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_Get_HeaderAbsent -benchmem -count=4
+func Benchmark_Ctx_Get_HeaderAbsent(b *testing.B) {
+	benchHeaderReadModes(b, func(b *testing.B, c Ctx) {
+		b.Helper()
+		var v string
+		for b.Loop() {
+			v = c.Get("X-Not-Sent")
+		}
+		require.Empty(b, v)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_HasHeader -benchmem -count=4
+func Benchmark_Ctx_HasHeader(b *testing.B) {
+	benchHeaderReadModes(b, func(b *testing.B, c Ctx) {
+		b.Helper()
+		var ok bool
+		for b.Loop() {
+			ok = c.HasHeader(HeaderXRequestID)
+		}
+		require.True(b, ok)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_HasHeaderAbsent -benchmem -count=4
+func Benchmark_Ctx_HasHeaderAbsent(b *testing.B) {
+	benchHeaderReadModes(b, func(b *testing.B, c Ctx) {
+		b.Helper()
+		var ok bool
+		for b.Loop() {
+			ok = c.HasHeader("X-Not-Sent")
+		}
+		require.False(b, ok)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_GetReqHeader -benchmem -count=4
+func Benchmark_Ctx_GetReqHeader(b *testing.B) {
+	benchHeaderReadModes(b, func(b *testing.B, c Ctx) {
+		b.Helper()
+		var v string
+		for b.Loop() {
+			v = GetReqHeader[string](c, HeaderXRequestID)
+		}
+		require.Equal(b, "3f0c1a", v)
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_Ctx_IsWebSocket -benchmem -count=4
+//
+// Covered under both settings because the two paths differ in kind, not degree:
+// the canonical one peeks, while the case-insensitive one walks the store and
+// collects the field lines, which allocates.
+func Benchmark_Ctx_IsWebSocket(b *testing.B) {
+	for _, tc := range []struct {
+		name               string
+		disableNormalizing bool
+		handshake          bool
+	}{
+		{"Normalizing/handshake", false, true},
+		{"Normalizing/no-upgrade", false, false},
+		{"WithoutNormalizing/handshake", true, true},
+		{"WithoutNormalizing/no-upgrade", true, false},
+	} {
+		b.Run(tc.name, func(b *testing.B) {
+			app := New(Config{DisableHeaderNormalizing: tc.disableNormalizing})
+			c := app.AcquireCtx(&fasthttp.RequestCtx{})
+
+			connection, upgrade := HeaderConnection, HeaderUpgrade
+			if tc.disableNormalizing {
+				c.Request().Header.DisableNormalizing()
+				connection, upgrade = utilsstrings.ToLower(connection), utilsstrings.ToLower(upgrade)
+			}
+			c.Request().Header.Set(connection, "upgrade")
+			if tc.handshake {
+				c.Request().Header.Set(upgrade, "websocket")
+			}
+
+			b.ReportAllocs()
+			var got bool
+			for b.Loop() {
+				got = c.IsWebSocket()
+			}
+			require.Equal(b, tc.handshake, got)
+		})
+	}
+}
+
 // go test -v  -run=^$ -bench=Benchmark_Ctx_SendString_B -benchmem -count=4
 func Benchmark_Ctx_SendString_B(b *testing.B) {
 	app := New()
diff --git a/internal/cookie/samesite_test.go b/internal/cookie/samesite_test.go
index 73d28b08294..e44fa78016e 100644
--- a/internal/cookie/samesite_test.go
+++ b/internal/cookie/samesite_test.go
@@ -77,3 +77,35 @@ func Test_ParseSameSite(t *testing.T) {
 		})
 	}
 }
+
+func Test_FormatSameSite(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name string
+		want string
+		mode fasthttp.CookieSameSite
+	}{
+		{name: "disabled", mode: fasthttp.CookieSameSiteDisabled, want: SameSiteDisabled},
+		{name: "lax", mode: fasthttp.CookieSameSiteLaxMode, want: SameSiteLax},
+		{name: "strict", mode: fasthttp.CookieSameSiteStrictMode, want: SameSiteStrict},
+		{name: "none", mode: fasthttp.CookieSameSiteNoneMode, want: SameSiteNone},
+		{name: "fasthttp default has no Fiber name", mode: fasthttp.CookieSameSiteDefaultMode, want: ""},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			got := FormatSameSite(tc.mode)
+			require.Equal(t, tc.want, got)
+
+			if got == "" {
+				return
+			}
+			parsed, ok := ParseSameSite(got)
+			require.True(t, ok)
+			require.Equal(t, tc.mode, parsed.FastHTTPMode)
+		})
+	}
+}
diff --git a/internal/etag/etag_test.go b/internal/etag/etag_test.go
index 0c6a47837af..8889f4868ef 100644
--- a/internal/etag/etag_test.go
+++ b/internal/etag/etag_test.go
@@ -107,3 +107,78 @@ func Test_AnyMatch(t *testing.T) {
 		})
 	}
 }
+
+func Test_Split(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		name   string
+		header string
+		want   []string
+	}{
+		{name: "empty", header: ""},
+		{name: "whitespace only", header: "   "},
+		{name: "single", header: `"abc"`, want: []string{`"abc"`}},
+		{name: "list", header: `"a", "b"`, want: []string{`"a"`, `"b"`}},
+		{name: "weak", header: `W/"a", "b"`, want: []string{`W/"a"`, `"b"`}},
+		{name: "wildcard", header: "*", want: []string{"*"}},
+		{name: "comma inside tag", header: `"v1,v2"`, want: []string{`"v1,v2"`}},
+		{name: "comma inside and after", header: `"v1,v2", "v3"`, want: []string{`"v1,v2"`, `"v3"`}},
+		{name: "untrimmed", header: `  "a" ,  "b"  `, want: []string{`"a"`, `"b"`}},
+		{name: "unquoted", header: `abc`, want: []string{"abc"}},
+		{name: "trailing comma", header: `"a",`, want: []string{`"a"`}},
+		{name: "trailing comma and space", header: `"a", `, want: []string{`"a"`}},
+		{name: "leading comma", header: `,"a"`, want: []string{`"a"`}},
+		{name: "doubled comma", header: `"a",,"b"`, want: []string{`"a"`, `"b"`}},
+		{name: "only commas", header: `,,`},
+		{name: "only a comma", header: `,`},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, Split(tc.header))
+		})
+	}
+}
+
+func Test_AnyMatch_IgnoresEmptyElements(t *testing.T) {
+	t.Parallel()
+
+	require.True(t, AnyMatch(`"a",`, `"a"`))
+	require.True(t, AnyMatch(`,"a"`, `"a"`))
+	require.True(t, AnyMatch(`"a",,"b"`, `"b"`))
+	require.False(t, AnyMatch(`,,`, `"a"`))
+	require.False(t, AnyMatch(`"a",`, ""))
+	require.False(t, AnyMatch(`,`, ""))
+}
+
+func Benchmark_AnyMatch(b *testing.B) {
+	benchmarks := []struct {
+		name   string
+		header string
+		etag   string
+	}{
+		{name: "hit", header: `"abc123"`, etag: `"abc123"`},
+		{name: "miss", header: `"abc123"`, etag: `"xyz789"`},
+		{name: "list_miss", header: `"a", "b", "c", "d", "e"`, etag: `"z"`},
+		{name: "weak", header: `W/"abcdefghijklmnop"`, etag: `W/"abcdefghijklmnop"`},
+		{name: "empty", header: "", etag: `"a"`},
+	}
+
+	for _, bm := range benchmarks {
+		b.Run(bm.name, func(b *testing.B) {
+			b.ReportAllocs()
+			for b.Loop() {
+				_ = AnyMatch(bm.header, bm.etag)
+			}
+		})
+	}
+}
+
+func Benchmark_Split(b *testing.B) {
+	b.ReportAllocs()
+	for b.Loop() {
+		_ = Split(`"a", "b", "c"`)
+	}
+}
diff --git a/internal/fieldname/fieldname_test.go b/internal/fieldname/fieldname_test.go
index e4b42861c98..7864d82f27d 100644
--- a/internal/fieldname/fieldname_test.go
+++ b/internal/fieldname/fieldname_test.go
@@ -4,6 +4,7 @@ import (
 	"bufio"
 	"bytes"
 	"testing"
+	"time"
 
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
@@ -112,3 +113,56 @@ func Test_First_EmptyLineDoesNotHideTheValue(t *testing.T) {
 		})
 	}
 }
+
+func Test_Del_TerminatesOnSynthesizedContentType(t *testing.T) {
+	t.Parallel()
+
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		h := &fasthttp.ResponseHeader{}
+		Del(h, fasthttp.HeaderContentType, false)
+	}()
+
+	select {
+	case <-done:
+	case <-time.After(5 * time.Second):
+		t.Fatal("Del did not return: ResponseHeader.All reports a default Content-Type once the slot is empty")
+	}
+}
+
+func Test_Del_TerminatesOnNonCanonicalNameInNormalizingStore(t *testing.T) {
+	t.Parallel()
+
+	done := make(chan struct{})
+	go func() {
+		defer close(done)
+		h := &fasthttp.ResponseHeader{}
+		h.SetNoDefaultContentType(true)
+		h.SetCanonical([]byte("x-session-id"), []byte("v"))
+		Del(h, "X-Session-Id", false)
+	}()
+
+	select {
+	case <-done:
+	case <-time.After(5 * time.Second):
+		t.Fatal("Del did not return: the store normalizes the key it is given, so it never matches the stored spelling")
+	}
+}
+
+func Test_Del_RemovesEverySpelling(t *testing.T) {
+	t.Parallel()
+
+	h := &fasthttp.ResponseHeader{}
+	h.SetNoDefaultContentType(true)
+	h.DisableNormalizing()
+	h.Add("x-trace", "a")
+	h.Add("X-Trace", "b")
+	h.Add("X-TRACE", "c")
+	h.Add("X-Keep", "k")
+
+	Del(h, "X-Trace", false)
+
+	require.Empty(t, Lines(h, "X-Trace", false))
+	require.Equal(t, "k", string(First(h, "X-Keep", false)))
+}
diff --git a/middleware/cors/cors_test.go b/middleware/cors/cors_test.go
index 6dd396dbf0c..81a703f95d2 100644
--- a/middleware/cors/cors_test.go
+++ b/middleware/cors/cors_test.go
@@ -1,6 +1,7 @@
 package cors
 
 import (
+	"bufio"
 	"bytes"
 	"net/http"
 	"net/http/httptest"
@@ -1872,3 +1873,98 @@ func Test_CORS_Security_NoOriginReflectionForDisallowed(t *testing.T) {
 	require.Empty(t, got)
 	require.NotEqual(t, "https://attacker.example.net", got)
 }
+
+func Test_CORS_OriginWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{AllowOrigins: []string{"http://example.com"}}))
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendString("ok")
+	})
+
+	do := func(header string) *fasthttp.RequestCtx {
+		raw := "GET / HTTP/1.1\r\nHost: example.com\r\n" + header + "\r\n\r\n"
+
+		req := fasthttp.AcquireRequest()
+		defer fasthttp.ReleaseRequest(req)
+		req.Header.DisableNormalizing()
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+		fctx := &fasthttp.RequestCtx{}
+		fctx.Init(req, nil, nil)
+		app.Handler()(fctx)
+		return fctx
+	}
+
+	lower := do("origin: http://example.com")
+	require.Equal(t, "http://example.com", string(lower.Response.Header.Peek(fiber.HeaderAccessControlAllowOrigin)))
+
+	canonical := do("Origin: http://example.com")
+	require.Equal(t, "http://example.com", string(canonical.Response.Header.Peek(fiber.HeaderAccessControlAllowOrigin)))
+
+	other := do("origin: http://evil.example")
+	require.Empty(t, string(other.Response.Header.Peek(fiber.HeaderAccessControlAllowOrigin)))
+}
+
+func Test_CORS_PreflightWithoutHeaderNormalizing(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New(Config{
+		AllowOrigins: []string{"http://example.com"},
+		AllowMethods: []string{fiber.MethodGet, fiber.MethodPut},
+	}))
+	app.Put("/", func(c fiber.Ctx) error {
+		return c.SendString("ok")
+	})
+
+	raw := "OPTIONS / HTTP/1.1\r\nHost: example.com\r\n" +
+		"origin: http://example.com\r\n" +
+		"access-control-request-method: PUT\r\n" +
+		"access-control-request-headers: X-Custom\r\n\r\n"
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
+	require.Equal(t, fiber.StatusNoContent, fctx.Response.StatusCode())
+	require.Equal(t, "http://example.com", string(fctx.Response.Header.Peek(fiber.HeaderAccessControlAllowOrigin)))
+	require.Contains(t, string(fctx.Response.Header.Peek(fiber.HeaderAccessControlAllowMethods)), fiber.MethodPut)
+	require.Equal(t, "X-Custom", string(fctx.Response.Header.Peek(fiber.HeaderAccessControlAllowHeaders)))
+}
+
+func Test_CORS_PreflightSplitRequestHeaders(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		AllowOrigins: []string{"http://example.com"},
+		AllowMethods: []string{fiber.MethodGet, fiber.MethodPut},
+	}))
+	app.Put("/", func(c fiber.Ctx) error {
+		return c.SendString("ok")
+	})
+
+	raw := "OPTIONS / HTTP/1.1\r\nHost: example.com\r\n" +
+		"Origin: http://example.com\r\n" +
+		"Access-Control-Request-Method: PUT\r\n" +
+		"Access-Control-Request-Headers: X-One\r\n" +
+		"Access-Control-Request-Headers: X-Two\r\n\r\n"
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Init(req, nil, nil)
+	app.Handler()(fctx)
+
+	require.Equal(t, fiber.StatusNoContent, fctx.Response.StatusCode())
+	require.Equal(t, "X-One, X-Two", string(fctx.Response.Header.Peek(fiber.HeaderAccessControlAllowHeaders)))
+}
diff --git a/middleware/etag/etag_test.go b/middleware/etag/etag_test.go
index bc1f3c62341..35be3134bb0 100644
--- a/middleware/etag/etag_test.go
+++ b/middleware/etag/etag_test.go
@@ -9,6 +9,7 @@ import (
 	"testing"
 
 	"github.com/gofiber/fiber/v3"
+	"github.com/gofiber/utils/v2"
 	"github.com/stretchr/testify/require"
 	"github.com/valyala/fasthttp"
 )
@@ -379,3 +380,80 @@ func Test_ETag_WeakComparison(t *testing.T) {
 		})
 	}
 }
+
+func Test_ETag_SplitIfNoneMatch(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	app.Use(New())
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendString("Hello, World!")
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	generated := resp.Header.Get(fiber.HeaderETag)
+	require.NotEmpty(t, generated)
+
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Add(fiber.HeaderIfNoneMatch, `"other"`)
+	req.Header.Add(fiber.HeaderIfNoneMatch, generated)
+	resp, err = app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusNotModified, resp.StatusCode)
+}
+
+func Test_ETag_HandlerETagSpellingsWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+
+	for _, spelling := range []string{"ETag", "Etag", "etag", "ETAG", "eTaG"} {
+		t.Run(spelling, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+			app.Use(New())
+			app.Get("/", func(c fiber.Ctx) error {
+				c.Response().Header.Set(spelling, `"upstream"`)
+				return c.SendString("Hello, World!")
+			})
+
+			fctx := &fasthttp.RequestCtx{}
+			fctx.Request.SetRequestURI("/")
+			fctx.Request.Header.SetMethod(fiber.MethodGet)
+			fctx.Request.Header.DisableNormalizing()
+			fctx.Response.Header.DisableNormalizing()
+			app.Handler()(fctx)
+
+			var lines []string
+			for k, v := range fctx.Response.Header.All() {
+				if utils.EqualFold(string(k), fiber.HeaderETag) {
+					lines = append(lines, string(v))
+				}
+			}
+			require.Equal(t, []string{`"upstream"`}, lines)
+		})
+	}
+}
+
+func Test_ETag_HandlerETagWithoutNormalizing(t *testing.T) {
+	t.Parallel()
+	app := fiber.New(fiber.Config{DisableHeaderNormalizing: true})
+	app.Use(New())
+	app.Get("/", func(c fiber.Ctx) error {
+		c.Set("ETag", `"custom"`)
+		return c.SendString("Hello, World!")
+	})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetRequestURI("/")
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	fctx.Request.Header.DisableNormalizing()
+	fctx.Response.Header.DisableNormalizing()
+	app.Handler()(fctx)
+
+	var lines []string
+	for k, v := range fctx.Response.Header.All() {
+		if utils.EqualFold(string(k), fiber.HeaderETag) {
+			lines = append(lines, string(v))
+		}
+	}
+	require.Equal(t, []string{`"custom"`}, lines)
+}
diff --git a/middleware/logger/logger_test.go b/middleware/logger/logger_test.go
index 23df07fc9ff..4314da91ba4 100644
--- a/middleware/logger/logger_test.go
+++ b/middleware/logger/logger_test.go
@@ -2231,3 +2231,42 @@ func Test_TagIPs_PropagatesWriteErrors(t *testing.T) {
 		require.Equal(t, len("1.1.1.1,"), n)
 	})
 }
+
+func Test_Logger_ResBody_DoesNotDrainStream(t *testing.T) {
+	t.Parallel()
+
+	var logged bytes.Buffer
+	app := fiber.New()
+	app.Use(New(Config{
+		Format: "[${resBody}]",
+		Stream: &logged,
+	}))
+	app.Get("/events", func(c fiber.Ctx) error {
+		return c.SendStreamWriter(func(w *bufio.Writer) {
+			w.WriteString("data: one\n\n") //nolint:errcheck // nothing to do with a stream-writer error here
+			w.Flush()                      //nolint:errcheck // same
+		})
+	})
+
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.SetRequestURI("/events")
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	app.Handler()(fctx)
+
+	require.True(t, fctx.Response.IsBodyStream(), "logging must leave a streamed response streamed")
+	require.Equal(t, "[]", logged.String(), "and it logs nothing rather than the buffered stream")
+
+	logged.Reset()
+	buffered := fiber.New()
+	buffered.Use(New(Config{Format: "[${resBody}]", Stream: &logged}))
+	buffered.Get("/", func(c fiber.Ctx) error {
+		return c.SendString("hello")
+	})
+
+	bctx := &fasthttp.RequestCtx{}
+	bctx.Request.SetRequestURI("/")
+	bctx.Request.Header.SetMethod(fiber.MethodGet)
+	buffered.Handler()(bctx)
+
+	require.Equal(t, "[hello]", logged.String())
+}
diff --git a/middleware/timeout/timeout_test.go b/middleware/timeout/timeout_test.go
index 0730950e29a..8d2117b645c 100644
--- a/middleware/timeout/timeout_test.go
+++ b/middleware/timeout/timeout_test.go
@@ -7,6 +7,7 @@ import (
 	"io"
 	"net/http"
 	"net/http/httptest"
+	"strings"
 	"sync/atomic"
 	"testing"
 	"time"
@@ -654,3 +655,76 @@ func TestTimeout_AbandonWithoutReclaimNotPooled(t *testing.T) {
 	app.ReleaseCtx(ctx)
 	require.True(t, ctx.IsAbandoned(), "abandoned, un-armed context must not be auto-reclaimed")
 }
+
+type neverReturningReader struct{}
+
+func (neverReturningReader) Read(_ []byte) (int, error) { select {} }
+
+// Test_Timeout_ResponseUnwritten covers the OnTimeout fallback's decision on its
+// own. Driving it through a served request would mean reading the response while
+// the timed-out handler still writes to it, which is a race this middleware has
+// either way: the handler is abandoned by design and keeps running.
+func Test_Timeout_ResponseUnwritten(t *testing.T) {
+	t.Parallel()
+
+	tests := []struct {
+		setup func(resp *fasthttp.Response)
+		name  string
+		want  bool
+	}{
+		{
+			name:  "nothing written",
+			setup: func(_ *fasthttp.Response) {},
+			want:  true,
+		},
+		{
+			name:  "stream with a payload",
+			setup: func(resp *fasthttp.Response) { resp.SetBodyStream(strings.NewReader("streamed"), -1) },
+			want:  true,
+		},
+		{
+			name:  "stream that yields nothing",
+			setup: func(resp *fasthttp.Response) { resp.SetBodyStream(strings.NewReader(""), -1) },
+			want:  true,
+		},
+		{
+			name:  "reader that never returns",
+			setup: func(resp *fasthttp.Response) { resp.SetBodyStream(neverReturningReader{}, -1) },
+			want:  true,
+		},
+		{
+			name:  "buffered body the handler already wrote",
+			setup: func(resp *fasthttp.Response) { resp.SetBodyString("handler-body") },
+			want:  false,
+		},
+	}
+
+	for _, tc := range tests {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			resp := &fasthttp.Response{}
+			tc.setup(resp)
+			require.Equal(t, tc.want, timeoutResponseUnwritten(resp))
+		})
+	}
+}
+
+func Test_Timeout_OnTimeout_ResetsBodyStream(t *testing.T) {
+	t.Parallel()
+
+	resp := &fasthttp.Response{}
+	resp.SetBodyStream(neverReturningReader{}, -1)
+
+	require.True(t, timeoutResponseUnwritten(resp))
+
+	// What handleTimeout does once the check passes. ResetBody closes the stream
+	// instead of draining it, so this returns rather than blocking on the reader.
+	resp.ResetBody()
+	resp.SetStatusCode(fiber.StatusRequestTimeout)
+	resp.SetBodyString(fiber.ErrRequestTimeout.Message)
+
+	require.False(t, resp.IsBodyStream())
+	require.Equal(t, fiber.StatusRequestTimeout, resp.StatusCode())
+	require.Equal(t, fiber.ErrRequestTimeout.Message, string(resp.Body()))
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path ctx_helpers_test.go --path ctx_test.go --path internal/cookie/samesite_test.go --path internal/etag/etag_test.go --path internal/fieldname/fieldname_test.go --path middleware/cors/cors_test.go --path middleware/etag/etag_test.go --path middleware/logger/logger_test.go --path middleware/timeout/timeout_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/cookie ./internal/etag ./internal/fieldname ./middleware/cors ./middleware/etag ./middleware/logger ./middleware/timeout')"
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path ctx_helpers_test.go --path ctx_test.go --path internal/cookie/samesite_test.go --path internal/etag/etag_test.go --path internal/fieldname/fieldname_test.go --path middleware/cors/cors_test.go --path middleware/etag/etag_test.go --path middleware/logger/logger_test.go --path middleware/timeout/timeout_test.go --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/cookie ./internal/etag ./internal/fieldname ./middleware/cors ./middleware/etag ./middleware/logger ./middleware/timeout')"
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
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/cookie ./internal/etag ./internal/fieldname ./middleware/cors ./middleware/etag ./middleware/logger ./middleware/timeout' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./ ./internal/cookie ./internal/etag ./internal/fieldname ./middleware/cors ./middleware/etag ./middleware/logger ./middleware/timeout' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
