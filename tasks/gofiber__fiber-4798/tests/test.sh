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
for f in internal/ipv6host/ipv6host_test.go internal/origin/origin_test.go internal/schemehost/schemehost_test.go middleware/cors/cors_test.go middleware/csrf/csrf_test.go middleware/hostauthorization/hostauthorization_test.go; do if git cat-file -e 95d7398102ac5a6efa2113bfa15f6f11976bd81a:"$f" 2>/dev/null; then git checkout 95d7398102ac5a6efa2113bfa15f6f11976bd81a -- "$f"; else rm -f -- "$f"; fi; done || true
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
diff --git a/internal/ipv6host/ipv6host_test.go b/internal/ipv6host/ipv6host_test.go
new file mode 100644
index 00000000000..e12f184a8fb
--- /dev/null
+++ b/internal/ipv6host/ipv6host_test.go
@@ -0,0 +1,71 @@
+package ipv6host
+
+import (
+	"net/netip"
+	"strings"
+	"testing"
+
+	"github.com/stretchr/testify/require"
+)
+
+func Test_Canonical(t *testing.T) {
+	t.Parallel()
+	for _, tc := range []struct{ host, want string }{
+		{host: "[::1]", want: "[::1]"},
+		{host: "[0:0:0:0:0:0:0:1]:3000", want: "[::1]:3000"},
+		{host: "[2001:0DB8:0000::0001]", want: "[2001:db8::1]"},
+		{host: "[2001:db8:0:1:0:0:0:1]", want: "[2001:db8:0:1::1]"},
+		{host: "[2001:db8:0:0:1:0:0:1]", want: "[2001:db8::1:0:0:1]"},
+		{host: "[2001:db8::0:1]", want: "[2001:db8::1]"},
+		{host: "[1:0:2:3:4:5:6:7]", want: "[1:0:2:3:4:5:6:7]"},
+		{host: "[::ffff:127.0.0.1]", want: "[::ffff:7f00:1]"},
+		{host: "[::ffff:7f00:1]", want: "[::ffff:7f00:1]"},
+		{host: "[64:ff9b::192.0.2.33]", want: "[64:ff9b::c000:221]"},
+		{host: "[::1.2.3.4]", want: "[::102:304]"},
+		{host: "[fe80:0::1%25eth0]", want: "[fe80:0::1%25eth0]"},
+		{host: "[fe80::1%eth0]", want: "[fe80::1%eth0]"},
+		{host: "[allowed.com]", want: "[allowed.com]"},
+		{host: "[127.0.0.1]", want: "[127.0.0.1]"},
+		{host: "[0::1", want: "[0::1"},
+		{host: "example.com", want: "example.com"},
+		{host: "0:0::1", want: "0:0::1"},
+		{host: "", want: ""},
+	} {
+		t.Run(tc.host, func(t *testing.T) {
+			t.Parallel()
+			require.Equal(t, tc.want, Canonical(tc.host))
+		})
+	}
+}
+
+// AllocsPerRun panics under t.Parallel, so this test stays sequential.
+func Test_Canonical_Allocations(t *testing.T) {
+	for _, host := range []string{"[::1]:3000", "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]", "[::ffff:7f00:1]", "example.com"} {
+		t.Run(host, func(t *testing.T) {
+			require.Zero(t, testing.AllocsPerRun(100, func() { Canonical(host) }))
+		})
+	}
+}
+
+// Every spelling parses back to its address, and the canonical one is a fixed point.
+func FuzzString(f *testing.F) {
+	for _, seed := range []string{"::1", "0:0:0:0:0:0:0:1", "2001:DB8::1", "::ffff:127.0.0.1", "64:ff9b::1.2.3.4", "fe80::1%eth0", "1:0:2:3:4:5:6:7"} {
+		f.Add(seed)
+	}
+	f.Fuzz(func(t *testing.T, s string) {
+		t.Parallel()
+		addr, ok := Parse(s)
+		if !ok {
+			return
+		}
+		canonical := String(addr, s)
+		back, err := netip.ParseAddr(canonical)
+		require.NoError(t, err)
+		require.Equal(t, addr, back)
+		require.Equal(t, canonical, String(back, canonical))
+		require.Equal(t, strings.ToLower(canonical), canonical)
+		if !addr.Is4In6() {
+			require.Equal(t, addr.String(), canonical)
+		}
+	})
+}
diff --git a/internal/origin/origin_test.go b/internal/origin/origin_test.go
index 904ad4dad5d..a0a22a9ecc2 100644
--- a/internal/origin/origin_test.go
+++ b/internal/origin/origin_test.go
@@ -256,6 +256,10 @@ func Test_FromURL(t *testing.T) {
 		{raw: "HTTPS://Example.COM:8443/Path?q=1#frag", want: "https://example.com:8443"},
 		{raw: "https://user:pass@example.com/", want: "https://example.com"},
 		{raw: "http://[::1]:8080/x", want: "http://[::1]:8080"},
+		{raw: "http://[0:0:0:0:0:0:0:1]:8080/x", want: "http://[::1]:8080"},
+		{raw: "http://[2001:DB8:0:0:0:0:0:1]", want: "http://[2001:db8::1]"},
+		{raw: "http://[::ffff:127.0.0.1]", want: "http://[::ffff:7f00:1]"},
+		{raw: "http://[fe80:0::1%25eth0]", want: "http://[fe80:0::1%eth0]"},
 		// No validation: an empty host still serializes, and can match no AllowList entry.
 		{raw: "https:///path", want: "https://"},
 	}
@@ -274,7 +278,7 @@ func Test_FromURL(t *testing.T) {
 // way, so a Referer-derived origin compares equal to a configured one.
 func Test_FromURL_AgreesWithNormalize(t *testing.T) {
 	t.Parallel()
-	for _, raw := range []string{"https://example.com", "HTTP://EXAMPLE.COM/", "app://Example.com:3000"} {
+	for _, raw := range []string{"https://example.com", "HTTP://EXAMPLE.COM/", "app://Example.com:3000", "http://[0:0:0:0:0:0:0:1]:3000"} {
 		u, err := url.Parse(raw)
 		require.NoError(t, err)
 		normalized, ok := Normalize(raw, AnyScheme)
diff --git a/internal/schemehost/schemehost_test.go b/internal/schemehost/schemehost_test.go
index 69dbf1cd8cf..d70c261c585 100644
--- a/internal/schemehost/schemehost_test.go
+++ b/internal/schemehost/schemehost_test.go
@@ -5,6 +5,7 @@ import (
 	"strings"
 	"testing"
 
+	"github.com/gofiber/fiber/v3/internal/ipv6host"
 	utilsstrings "github.com/gofiber/utils/v2/strings"
 	"github.com/stretchr/testify/assert"
 )
@@ -24,7 +25,8 @@ func normalizeSchemeHost(scheme, host string) string {
 
 // refNormalizeSchemeHost is the original url.Parse-based implementation, kept as
 // a behavioral reference. The fast-path normalizeSchemeHost must produce
-// identical output for every input.
+// identical output for every input. The one addition is the IPv6 rewrite for
+// http and https, so every spelling of an address compares equal.
 func refNormalizeSchemeHost(scheme, host string) string {
 	host = utilsstrings.ToLower(host)
 
@@ -37,6 +39,7 @@ func refNormalizeSchemeHost(scheme, host string) string {
 	default:
 		return host
 	}
+	host = ipv6host.Canonical(host)
 
 	parsedHost, err := url.Parse(scheme + "://" + host)
 	if err != nil {
@@ -74,6 +77,7 @@ var corpus = []string{
 	"[fe80::1%eth0]", "[fe80::1%25eth0]:8080",
 	"example.com:99999", "example.com:0", "host:00080",
 	"\\example.com", "example.com\\", "[::1]extra", "[::1]x:80", "\x01",
+	"[0:0:0:0:0:0:0:1]", "[0:0:0:0:0:0:0:1]:8080", "[2001:DB8:0::1]:443", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]:80",
 }
 
 // Test_normalizeSchemeHost_matchesReference verifies the fast path produces the
@@ -154,6 +158,11 @@ func Test_Match(t *testing.T) {
 		{"https", "example.com:8080", "https", "example.com", false},
 		{"https", "[::1]", "https", "[::1]:443", true},
 		{"https", "[::1]:8080", "https", "[::1]", false},
+		{"http", "[::1]:3000", "http", "[0:0:0:0:0:0:0:1]:3000", true},
+		{"https", "[2001:db8::1]", "https", "[2001:0DB8:0:0:0:0:0:1]:443", true},
+		{"http", "[::ffff:127.0.0.1]", "http", "[::ffff:7f00:1]:80", true},
+		{"http", "[::1]:3000", "http", "[0:0:0:0:0:0:0:2]:3000", false},
+		{"http", "[fe80::1%25eth0]", "http", "[fe80:0::1%25eth0]", false},
 	}
 	for _, tc := range tests {
 		got := Match(tc.schemeA, tc.hostA, tc.schemeB, tc.hostB)
diff --git a/middleware/cors/cors_test.go b/middleware/cors/cors_test.go
index aeca58e2f2a..1d054578ed5 100644
--- a/middleware/cors/cors_test.go
+++ b/middleware/cors/cors_test.go
@@ -525,6 +525,8 @@ func Test_CORS_AllowOriginsAndAllowOriginsFunc_AllUseCases(t *testing.T) {
 		AllowOriginsFunc: func(origin string) bool { return strings.Contains(origin, "example-2") },
 	}
 
+	ipv6 := Config{AllowOrigins: []string{"http://[2001:db8:0:0:0:0:0:1]:3000", "http://[::ffff:127.0.0.1]"}}
+
 	testCases := []struct {
 		Name           string
 		RequestOrigin  string
@@ -552,6 +554,9 @@ func Test_CORS_AllowOriginsAndAllowOriginsFunc_AllUseCases(t *testing.T) {
 		{Name: "OriginsAndFunc/disallowed origin", Config: originsAndFunc, RequestOrigin: "http://google.com", ResponseOrigin: ""},
 		{Name: "OriginsAndFunc/allowed origin", Config: originsAndFunc, RequestOrigin: "http://example-1.com", ResponseOrigin: "http://example-1.com"},
 		{Name: "OriginsAndFunc/allowed origin by the func", Config: originsAndFunc, RequestOrigin: "http://example-2.com", ResponseOrigin: "http://example-2.com"},
+		{Name: "IPv6/entry spelled out", Config: ipv6, RequestOrigin: "http://[2001:db8::1]:3000", ResponseOrigin: "http://[2001:db8::1]:3000"},
+		{Name: "IPv6/ipv4-mapped entry", Config: ipv6, RequestOrigin: "http://[::ffff:7f00:1]", ResponseOrigin: "http://[::ffff:7f00:1]"},
+		{Name: "IPv6/other address", Config: ipv6, RequestOrigin: "http://[2001:db8::2]:3000", ResponseOrigin: ""},
 	}
 
 	for i := range testCases {
diff --git a/middleware/csrf/csrf_test.go b/middleware/csrf/csrf_test.go
index d8859b19e16..291c8a82913 100644
--- a/middleware/csrf/csrf_test.go
+++ b/middleware/csrf/csrf_test.go
@@ -715,6 +715,7 @@ func Test_CSRF_TrustedOrigins(t *testing.T) {
 			"https://safe.example.com",
 			"http://*.domain-1.com",
 			"https://*.domain-1.com",
+			"http://[2001:db8:0:0:0:0:0:1]:3000",
 		},
 	}, "https")
 
@@ -729,6 +730,10 @@ func Test_CSRF_TrustedOrigins(t *testing.T) {
 		{name: "Trusted Origin with mixed-case header", scheme: "http", host: "example.com", origin: "http://SAFE.Example.com", status: fiber.StatusOK},
 		{name: "Trusted Origin with mixed-case header (wildcard subdomain entry)", scheme: "http", host: "domain-1.com", origin: "http://SAFE.Domain-1.com", status: fiber.StatusOK},
 		{name: "Trusted Origin Invalid", scheme: "http", host: "domain-1.com", origin: "http://evildomain-1.com", status: fiber.StatusForbidden},
+		// A browser sends the IPv6 host in its compressed form, whatever the entry spells.
+		{name: "Trusted Origin ipv6 entry spelled out", scheme: "http", host: "example.com", origin: "http://[2001:db8::1]:3000", status: fiber.StatusOK},
+		{name: "Trusted Referer ipv6 entry spelled out", scheme: "https", host: "example.com", referer: "http://[2001:db8::1]:3000/a", headers: viaHTTPS, status: fiber.StatusOK},
+		{name: "same-origin ipv6 Host spelled out", scheme: "http", host: "[0:0:0:0:0:0:0:1]:3000", origin: "http://[::1]:3000", status: fiber.StatusOK},
 		{name: "Trusted Origin malformed subdomain", scheme: "http", host: "domain-1.com", origin: "http://evil.comdomain-1.com", status: fiber.StatusForbidden},
 		{name: "Trusted Referer", scheme: "https", host: "example.com", referer: "https://safe.example.com", headers: viaHTTPS, status: fiber.StatusOK},
 		// Accepted on the fold-based Match fast path, no trusted-origin fallback involved.
diff --git a/middleware/hostauthorization/hostauthorization_test.go b/middleware/hostauthorization/hostauthorization_test.go
index 2ab8ce23353..3b06e2d6dc6 100644
--- a/middleware/hostauthorization/hostauthorization_test.go
+++ b/middleware/hostauthorization/hostauthorization_test.go
@@ -2,12 +2,14 @@ package hostauthorization
 
 import (
 	"fmt"
+	"net/netip"
 	"strings"
 	"testing"
 	"unicode/utf8"
 
 	"github.com/gofiber/fiber/v3"
 	"github.com/gofiber/fiber/v3/internal/apptest"
+	"github.com/gofiber/utils/v2"
 	"github.com/stretchr/testify/require"
 )
 
@@ -36,9 +38,11 @@ func Test_ConfigDefault(t *testing.T) {
 func Test_ConfigPanics(t *testing.T) {
 	t.Parallel()
 	longHost, longLabel := strings.Repeat("a", 254), strings.Repeat("a", 64)+".example.com"
+	entry := func(h string) func() { return func() { New(Config{AllowedHosts: []string{h}}) } }
 	for _, tc := range []struct {
 		fn   func()
 		name string
+		msg  string
 	}{
 		{name: "no hosts or func", fn: func() { configDefault(Config{}) }},
 		{name: "empty slice", fn: func() { configDefault(Config{AllowedHosts: []string{}}) }},
@@ -46,15 +50,43 @@ func Test_ConfigPanics(t *testing.T) {
 		{name: "host exceeds RFC 1035 total length", fn: func() { New(Config{AllowedHosts: []string{longHost}}) }},
 		{name: "leading dot form", fn: func() { New(Config{AllowedHosts: []string{".myapp.com"}}) }},
 		{name: "label exceeds RFC 1035 length", fn: func() { New(Config{AllowedHosts: []string{longLabel}}) }},
+		{name: "wildcard of an ipv6 address", fn: entry("*.[::1]")},
+		{name: "wildcard of an ipv4-mapped address", fn: entry("*.[::ffff:1.2.3.4]")},
+		{name: "invalid ipv6", fn: entry("[2001:db8::g]")},
+		{
+			name: "zoned ipv6", fn: entry("[fe80::1%25eth0]"),
+			msg: "hostauthorization: invalid host [fe80::1%25eth0]: IPv6 zones and percent-encoding are not supported",
+		},
+		{name: "bracketed name with port", fn: entry("[allowed.com:443]")},
+		{name: "wildcard of an ipv4 address", fn: entry("*.127.0.0.1")},
+		{name: "wildcard of an ipv4 address with trailing dot", fn: entry("*.127.0.0.1.")},
+		{name: "wildcard of a bracketed ipv4 address", fn: entry("*.[1.2.3.4]")},
+		{name: "wildcard of a bracketed name", fn: entry("*.[allowed.com]")},
+		{name: "wildcard with a non-numeric port", fn: entry("*.a:b")},
+		{name: "bracketed name", fn: entry("[allowed.com]")},
+		{name: "bracketed name and port", fn: entry("[allowed.com]:443")},
+		{name: "bracketed ipv4", fn: entry("[127.0.0.1]")},
+		{name: "double brackets", fn: entry("[[::1]]")},
+		{name: "unbalanced bracket", fn: entry("[::1")},
+		{name: "ipv6 with port out of range", fn: entry("[::1]:65536")},
+		{name: "colons that are not ipv6", fn: entry("a:b:c")},
+		{name: "empty port", fn: entry("example.com:")},
+		{name: "non-numeric port", fn: entry("allowed.com:http"), msg: `hostauthorization: invalid host allowed.com:http: invalid port "http"`},
+		{name: "url", fn: entry("https://myapp.com"), msg: "hostauthorization: invalid host https://myapp.com: write host[:port], not a URL"},
+		{name: "url with port", fn: entry("http://localhost:3000")},
 	} {
 		t.Run(tc.name, func(t *testing.T) {
 			t.Parallel()
+			if tc.msg != "" {
+				require.PanicsWithValue(t, tc.msg, tc.fn)
+				return
+			}
 			require.Panics(t, tc.fn)
 		})
 	}
 }
 
-func Test_NormalizeHost(t *testing.T) {
+func Test_NormalizeEntry(t *testing.T) {
 	t.Parallel()
 	tests := []struct {
 		name     string
@@ -72,15 +104,22 @@ func Test_NormalizeHost(t *testing.T) {
 		{"ipv6 brackets", "[::1]", "::1"},
 		{"ipv6 bare", "::1", "::1"},
 		{"ipv6 with port", "[::1]:8080", "::1"},
+		{"ipv6 uncompressed", "[0:0:0:0:0:0:0:1]", "::1"},
+		{"ipv6 zero padded", "[2001:0db8:0000:0000:0000:0000:0000:0001]", "2001:db8::1"},
+		{"ipv6 zero padded with port", "[2001:0db8:0000:0000:0000:0000:0000:0001]:8080", "2001:db8::1"},
+		{"ipv6 uppercase hex", "[2001:DB8::1]", "2001:db8::1"},
+		{"ipv6 ipv4-mapped hex form", "[::ffff:7f00:1]", "127.0.0.1"},
 		{"empty", "", ""},
 		{"idn unicode → punycode", "münchen.example.com", "xn--mnchen-3ya.example.com"},
 		{"idn already punycode", "xn--mnchen-3ya.example.com", "xn--mnchen-3ya.example.com"},
+		{"idn with port", "münchen.example.com:8080", "xn--mnchen-3ya.example.com"},
 	}
 
 	for _, tt := range tests {
 		t.Run(tt.name, func(t *testing.T) {
 			t.Parallel()
-			require.Equal(t, tt.expected, normalizeHost(tt.input))
+			host, _ := normalizeEntry(tt.input, tt.input)
+			require.Equal(t, tt.expected, host)
 		})
 	}
 }
@@ -98,6 +137,21 @@ func Test_ParseNormalizedAuthority(t *testing.T) {
 		{name: "multiple trailing dots are rejected as malformed", input: "api.example.com...:443", expectOK: false},
 		{name: "ipv6 with port", input: "[::1]:443", expected: "::1", expectOK: true},
 		{name: "ipv6 without port", input: "[::1]", expected: "::1", expectOK: true},
+		{name: "ipv6 uncompressed", input: "[0:0:0:0:0:0:0:1]:443", expected: "::1", expectOK: true},
+		{name: "ipv6 zero padded", input: "[2001:0db8:0000:0000:0000:0000:0000:0001]", expected: "2001:db8::1", expectOK: true},
+		{name: "ipv6 ipv4-mapped hex form", input: "[::ffff:7f00:1]:8080", expected: "127.0.0.1", expectOK: true},
+		{name: "ipv6 uppercase hex", input: "[2001:DB8::1]", expected: "2001:db8::1", expectOK: true},
+		{name: "ipv6 nat64 dotted", input: "[64:ff9b::1.2.3.4]:443", expected: "64:ff9b::102:304", expectOK: true},
+		{name: "ipv6 ipv4-compatible dotted", input: "[::1.2.3.4]", expected: "::102:304", expectOK: true},
+		{name: "invalid ipv6", input: "[2001:db8::g]", expectOK: false},
+		{name: "zoned ipv6", input: "[::1%eth0]", expectOK: false},
+		{name: "zoned ipv6 percent-encoded", input: "[fe80::1%25eth0]", expectOK: false},
+		{name: "zoned ipv4-mapped", input: "[::ffff:127.0.0.1%25eth0]", expectOK: false},
+		{name: "trailing dot in brackets", input: "[::1.]", expectOK: false},
+		{name: "bracketed name", input: "[allowed.com]", expectOK: false},
+		{name: "bracketed name with port inside", input: "[allowed.com:443]", expectOK: false},
+		{name: "bracketed ipv4", input: "[127.0.0.1]", expectOK: false},
+		{name: "bracketed label and port", input: "[1:80]", expectOK: false},
 		{name: "empty port", input: "example.com:", expectOK: false},
 		{name: "signed port", input: "example.com:+80", expectOK: false},
 		{name: "port out of range", input: "example.com:65536", expectOK: false},
@@ -118,7 +172,6 @@ func Test_ParseNormalizedAuthority(t *testing.T) {
 		{name: "253 bytes", input: strings.Repeat("a.", 125) + "com", expected: strings.Repeat("a.", 125) + "com", expectOK: true},
 		{name: "253 bytes with trailing dot and port", input: strings.Repeat("a.", 125) + "com.:443", expected: strings.Repeat("a.", 125) + "com", expectOK: true},
 		{name: "254 bytes", input: strings.Repeat("a.", 125) + "coms", expectOK: false},
-		{name: "254 bytes in brackets", input: "[" + strings.Repeat("a.", 125) + "coms]", expectOK: false},
 	}
 
 	for _, tt := range tests {
@@ -131,21 +184,6 @@ func Test_ParseNormalizedAuthority(t *testing.T) {
 	}
 }
 
-// Not parallel: AllocsPerRun counts allocations process-wide and refuses to run
-// under a parallel test.
-func Test_ParseNormalizedAuthority_LongUnicodeHostNotConverted(t *testing.T) {
-	var label []byte
-	for r := rune(0x4E00); len(label) < 8000; r++ {
-		label = utf8.AppendRune(label, r)
-	}
-	host := string(label)
-
-	require.Zero(t, testing.AllocsPerRun(10, func() {
-		_, ok := parseNormalizedAuthority(host)
-		require.False(t, ok)
-	}))
-}
-
 func Test_IsValidHostSyntax(t *testing.T) {
 	t.Parallel()
 	tests := []struct {
@@ -157,11 +195,8 @@ func Test_IsValidHostSyntax(t *testing.T) {
 		{name: "single label", host: "localhost", valid: true},
 		{name: "multi label", host: "sub.api.example.com", valid: true},
 		{name: "ipv4 literal", host: "192.168.0.1", valid: true},
-		{name: "ipv6 literal", host: "::1", valid: true},
-		{name: "ipv6 full", host: "2001:db8::1", valid: true},
-		{name: "malformed ipv6", host: "::g", valid: false},
-		{name: "ipv4 mapped ipv6", host: "::ffff:192.0.2.1", valid: true},
-		{name: "zoned ipv6 rejected", host: "fe80::1%eth0", valid: false},
+		// IPv6 literals are validated by canonicalIPv6 and never reach here.
+		{name: "ipv6 literal rejected", host: "::1", valid: false},
 		{name: "digit label", host: "1.example.com", valid: true},
 		{name: "leading hyphen label", host: "-bad.example.com", valid: false},
 		{name: "trailing hyphen label", host: "bad-.example.com", valid: false},
@@ -220,7 +255,7 @@ func Test_MatchHost(t *testing.T) {
 		{name: "wildcard does not match bare domain", allowed: wildcard, host: "myapp.com", want: false},
 		{name: "wildcard does not match unrelated host", allowed: wildcard, host: "evil.com", want: false},
 
-		{name: "idn wildcard matches normalized unicode subdomain", allowed: idnWildcard, host: normalizeHost("api.münchen.example.com"), want: true},
+		{name: "idn wildcard matches normalized unicode subdomain", allowed: idnWildcard, host: normalizeName("api.münchen.example.com"), want: true},
 		{name: "idn wildcard matches punycode subdomain", allowed: idnWildcard, host: "api.xn--mnchen-3ya.example.com", want: true},
 		// The bare domain must NOT match a subdomain wildcard.
 		{name: "idn wildcard does not match bare domain", allowed: idnWildcard, host: "xn--mnchen-3ya.example.com", want: false},
@@ -265,6 +300,11 @@ func Test_HostAuthorization_Hosts(t *testing.T) {
 		example     = []string{"example.com"}
 		examplePort = []string{"example.com:8080"}
 		wildcard    = []string{"*.myapp.com"}
+		loopback4   = []string{"127.0.0.1"}
+		loopback6   = []string{"[::1]"}
+		docIPv6     = []string{"[2001:db8::1]"}
+		linkLocal   = []string{"[fe80::1]"}
+		ipWildcard  = []string{"*.2.3.4"}
 		dynamic     = func(host string) bool { return host == "dynamic.com" }
 	)
 
@@ -286,6 +326,31 @@ func Test_HostAuthorization_Hosts(t *testing.T) {
 		{name: "trailing dot", allowed: example, host: "example.com.", status: fiber.StatusOK},
 		{name: "exact ip", allowed: []string{"127.0.0.1"}, host: "127.0.0.1", status: fiber.StatusOK},
 		{name: "idn punycode request", allowed: []string{"münchen.example.com"}, host: "xn--mnchen-3ya.example.com", status: fiber.StatusOK},
+		{name: "idn entry with port", allowed: []string{"münchen.example.com:8080"}, host: "xn--mnchen-3ya.example.com", status: fiber.StatusOK},
+
+		// Every spelling of one IPv6 address names the same host (RFC 4291 Section 2.2).
+		{name: "ipv6 uncompressed", allowed: loopback6, host: "[0:0:0:0:0:0:0:1]:3000", status: fiber.StatusOK},
+		{name: "ipv6 zero padded", allowed: loopback6, host: "[0000:0000:0000:0000:0000:0000:0000:0001]", status: fiber.StatusOK},
+		{name: "ipv6 entry uncompressed", allowed: []string{"[2001:db8:0:0:0:0:0:1]"}, host: "[2001:db8::1]:8080", status: fiber.StatusOK},
+		{name: "ipv6 entry zero padded", allowed: []string{"[2001:0db8::0001]"}, host: "[2001:db8::1]", status: fiber.StatusOK},
+		{name: "ipv6 entry ipv4-mapped dotted", allowed: []string{"[::ffff:127.0.0.1]"}, host: "[::ffff:7f00:1]", status: fiber.StatusOK},
+		{name: "ipv6 other address", allowed: loopback6, host: "[0:0:0:0:0:0:0:2]", status: fiber.StatusForbidden},
+		{name: "ipv6 other address, same prefix", allowed: docIPv6, host: "[2001:db8::1:0]", status: fiber.StatusForbidden},
+		{name: "ipv4-mapped dotted", allowed: loopback4, host: "[::ffff:127.0.0.1]", status: fiber.StatusOK},
+		{name: "ipv4-mapped hex", allowed: loopback4, host: "[::ffff:7f00:1]:8080", status: fiber.StatusOK},
+		{name: "ipv4-mapped other address", allowed: loopback4, host: "[::ffff:127.0.0.2]", status: fiber.StatusForbidden},
+		// An embedded IPv4 spelling must not leave a dotted tail for a subdomain rule.
+		{name: "ipv4 wildcard skips nat64 literal", allowed: ipWildcard, host: "[64:ff9b::1.2.3.4]", status: fiber.StatusForbidden},
+		{name: "ipv4 wildcard skips ipv4-compatible literal", allowed: ipWildcard, host: "[::1.2.3.4]:443", status: fiber.StatusForbidden},
+		{name: "ipv4 wildcard matches ipv4-mapped literal", allowed: ipWildcard, host: "[::ffff:1.2.3.4]", status: fiber.StatusOK},
+
+		// Canonicalization must not drop a zone, and Unmap does for a mapped one.
+		{name: "ipv6 zoned", allowed: linkLocal, host: "[fe80::1%25eth0]", status: fiber.StatusForbidden},
+		{name: "ipv6 zoned uncompressed", allowed: linkLocal, host: "[FE80:0:0:0:0:0:0:1%25eth0]:80", status: fiber.StatusForbidden},
+		{name: "ipv4-mapped zoned", allowed: loopback4, host: "[::ffff:127.0.0.1%25eth0]", status: fiber.StatusForbidden},
+		{name: "ipv4-mapped hex zoned", allowed: loopback4, host: "[::ffff:7f00:1%25eth0]:8080", status: fiber.StatusForbidden},
+		// fasthttp skips its IPv6 check for a "%25" literal, so this reaches the middleware.
+		{name: "bracketed name with zone", allowed: []string{"allowed.com"}, host: "[allowed.com:443%25z]", status: fiber.StatusForbidden},
 
 		{name: "subdomain wildcard allowed", allowed: wildcard, host: "api.myapp.com", status: fiber.StatusOK},
 		{name: "subdomain wildcard bare domain rejected", allowed: wildcard, host: "myapp.com", status: fiber.StatusForbidden},
@@ -369,6 +434,10 @@ func Test_HostAuthorization_XForwardedHost(t *testing.T) {
 			name: "trust proxy, malformed forwarded authority rejected", trustProxy: true,
 			allowed: "allowed.com", host: "proxy.internal", forwarded: "allowed.com:443@attacker.example", status: fiber.StatusForbidden,
 		},
+		{"trust proxy, bracketed name with port rejected", "allowed.com", "proxy.internal", "[allowed.com:443]", fiber.StatusForbidden, true},
+		{"trust proxy, bracketed name rejected", "allowed.com", "proxy.internal", "[allowed.com]", fiber.StatusForbidden, true},
+		{"trust proxy, bracketed ipv4 rejected", "127.0.0.1", "proxy.internal", "[127.0.0.1]", fiber.StatusForbidden, true},
+		{"trust proxy, ipv4-compatible literal skips ipv4 wildcard", "*.2.3.4", "proxy.internal", "[::1.2.3.4]:443", fiber.StatusForbidden, true},
 		// X-Forwarded-Host should be ignored without TrustProxy.
 		{"no trust proxy, forwarded host ignored", "example.com", "example.com", "evil.com", fiber.StatusOK, false},
 	} {
@@ -412,6 +481,96 @@ func Test_AllowedHostsFuncFallback(t *testing.T) {
 	require.Equal(t, 1, called, "AllowedHostsFunc must be called when no static rule matches")
 }
 
+func Test_HostAuthorization_AllowedHostsFuncReceivesCanonicalIPv6(t *testing.T) {
+	t.Parallel()
+	for _, tc := range []struct {
+		host string
+		want string
+	}{
+		{host: "[0:0:0:0:0:0:0:1]:3000", want: "::1"},
+		{host: "[2001:0DB8::0001]", want: "2001:db8::1"},
+		{host: "[::ffff:7f00:1]", want: "127.0.0.1"},
+		{host: "[2001:db8::1]:8080", want: "2001:db8::1"},
+	} {
+		t.Run(tc.host, func(t *testing.T) {
+			t.Parallel()
+			var got string
+			app := hostAuthApp(Config{AllowedHostsFunc: func(host string) bool {
+				got = strings.Clone(host) // host is only valid during the call
+				return true
+			}})
+			apptest.Expect(t, app, apptest.Req(fiber.MethodGet, "/", apptest.WithHost(tc.host)), fiber.StatusOK)
+			require.Equal(t, tc.want, got)
+		})
+	}
+}
+
+// AllocsPerRun panics under t.Parallel, so this test stays sequential.
+func Test_ParseNormalizedAuthority_Allocations(t *testing.T) {
+	const fullLength = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
+	var longUnicode []byte
+	for r := rune(0x4E00); len(longUnicode) < 8000; r++ {
+		longUnicode = utf8.AppendRune(longUnicode, r)
+	}
+	// netip interns a zone, so each run needs a fresh one to show a copy.
+	zoned := make([]string, 101)
+	for i := range zoned {
+		zoned[i] = fmt.Sprintf("[fe80::1%%%d%s]:80", i, strings.Repeat("a", 200))
+	}
+	for _, tc := range []struct {
+		name        string
+		want        string
+		authorities []string
+		maxAllocs   float64
+		ok          bool
+	}{
+		{name: "canonical", authorities: []string{"[2001:db8::1]:8080"}, want: "2001:db8::1", ok: true},
+		{name: "canonical at full length", authorities: []string{"[" + fullLength + "]:80"}, want: fullLength, ok: true},
+		{name: "non-canonical", authorities: []string{"[0:0:0:0:0:0:0:1]:8080"}, want: "::1", ok: true, maxAllocs: 1},
+		{name: "ipv4-mapped", authorities: []string{"[::ffff:127.0.0.1]:8080"}, want: "127.0.0.1", ok: true, maxAllocs: 1},
+		{name: "zoned and refused", authorities: zoned},
+		{name: "long unicode host not converted", authorities: []string{string(longUnicode)}},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			var (
+				host string
+				ok   bool
+				n    int
+			)
+			allocs := testing.AllocsPerRun(100, func() {
+				host, ok = parseNormalizedAuthority(tc.authorities[n%len(tc.authorities)])
+				n++
+			})
+			require.Equal(t, tc.ok, ok)
+			require.Equal(t, tc.want, host)
+			require.LessOrEqual(t, allocs, tc.maxAllocs)
+		})
+	}
+}
+
+// AllocsPerRun panics under t.Parallel, so this test stays sequential.
+func Test_IsAllowed_Allocations(t *testing.T) {
+	parsed := parseAllowedHosts([]string{"[2001:db8::1]", "127.0.0.1"})
+	for _, tc := range []struct {
+		host string
+		want bool
+	}{
+		{host: "[2001:db8::1]:8080", want: true},
+		{host: "[2001:0db8:0:0:0:0:0:1]", want: true},
+		{host: "[::ffff:7f00:1]", want: true},
+		{host: "[::ffff:127.0.0.1]:80", want: true},
+		{host: "[::ffff:7f00:2]", want: false},
+		{host: "[0:0:0:0:0:0:0:2]", want: false},
+	} {
+		t.Run(tc.host, func(t *testing.T) {
+			var got bool
+			allocs := testing.AllocsPerRun(100, func() { got = isAllowed(tc.host, parsed, nil) })
+			require.Equal(t, tc.want, got)
+			require.Zero(t, allocs)
+		})
+	}
+}
+
 // --- Benchmarks ---
 
 func Benchmark_matchHost_ExactMatch(b *testing.B) {
@@ -488,14 +647,93 @@ func Benchmark_HostAuthorization_Mixed(b *testing.B) {
 	}
 }
 
-func FuzzNormalizeHost(f *testing.F) {
-	f.Add("example.com")
-	f.Add("example.com.")
-	f.Add("[::1]:8080")
-	f.Add("[::1]")
-	f.Add("*.myapp.com")
-	f.Add("192.168.1.1:443")
-	f.Add("münchen.example.com")
-	f.Add("")
-	f.Fuzz(func(_ *testing.T, input string) { _ = normalizeHost(input) })
+func Benchmark_HostAuthorization_IPv6ExactMatch(b *testing.B) {
+	app := hostAuthApp(Config{AllowedHosts: []string{"[2001:db8::1]"}})
+	req := apptest.Req(fiber.MethodGet, "/", apptest.WithHost("[2001:db8::1]:8080"))
+
+	b.ReportAllocs()
+	b.ResetTimer()
+	for i := 0; i < b.N; i++ {
+		resp, err := app.Test(req)
+		if err != nil {
+			b.Fatal(err)
+		}
+		resp.Body.Close() //nolint:errcheck // benchmark cleanup
+	}
+}
+
+func Benchmark_parseNormalizedAuthority_IPv6(b *testing.B) {
+	for _, bc := range []struct{ name, authority string }{
+		{name: "canonical", authority: "[2001:db8::1]:8080"},
+		{name: "non-canonical", authority: "[2001:0db8:0:0:0:0:0:1]:8080"},
+		{name: "ipv4-mapped", authority: "[::ffff:127.0.0.1]:8080"},
+	} {
+		b.Run(bc.name, func(b *testing.B) {
+			b.ReportAllocs()
+			for i := 0; i < b.N; i++ {
+				parseNormalizedAuthority(bc.authority)
+			}
+		})
+	}
+}
+
+// An entry is accepted or refused with a hostauthorization panic, never a runtime one.
+func Benchmark_isAllowed_IPv6(b *testing.B) {
+	parsed := parseAllowedHosts([]string{"[::1]", "[2001:db8::1]", "127.0.0.1"})
+	for _, bc := range []struct{ name, authority string }{
+		{name: "canonical", authority: "[2001:db8::1]:8080"},
+		{name: "non-canonical", authority: "[2001:0db8:0:0:0:0:0:1]:8080"},
+		{name: "ipv4-mapped", authority: "[::ffff:7f00:1]:8080"},
+		{name: "refused", authority: "[2001:db8::2]:8080"},
+	} {
+		b.Run(bc.name, func(b *testing.B) {
+			b.ReportAllocs()
+			for i := 0; i < b.N; i++ {
+				isAllowed(bc.authority, parsed, nil)
+			}
+		})
+	}
+}
+
+func FuzzParseAllowedHosts(f *testing.F) {
+	for _, seed := range []string{
+		"example.com", "example.com.", "[::1]:8080", "::1", "*.myapp.com", "192.168.1.1:443", "münchen.example.com", "",
+		"*.127.0.0.1", "[allowed.com]:443", "https://myapp.com", "[fe80::1%25eth0]", "a:b:c",
+	} {
+		f.Add(seed)
+	}
+	f.Fuzz(func(t *testing.T, entry string) {
+		t.Parallel()
+		defer func() {
+			if r := recover(); r != nil {
+				msg, ok := r.(string)
+				require.True(t, ok && strings.HasPrefix(msg, "hostauthorization: "), "unexpected panic: %v", r)
+			}
+		}()
+		parseAllowedHosts([]string{entry})
+	})
+}
+
+// A bracketed authority passes only as the canonical form of a zone-free IPv6 address.
+func FuzzParseNormalizedAuthority(f *testing.F) {
+	for _, seed := range []string{
+		"example.com:8080", "[::1]:8080", "[0:0:0:0:0:0:0:1]", "[2001:DB8:0:0:0:0:0:1]:443", "[::ffff:127.0.0.1]",
+		"[::ffff:7f00:1]:80", "[fe80::1%25eth0]", "[::ffff:127.0.0.1%25eth0]", "[allowed.com:443]", "[127.0.0.1]",
+	} {
+		f.Add(seed)
+	}
+	f.Fuzz(func(t *testing.T, authority string) {
+		t.Parallel()
+		host, ok := parseNormalizedAuthority(authority)
+		authority = utils.TrimSpace(authority)
+		end := strings.IndexByte(authority, ']')
+		if !ok || authority[0] != '[' || end < 0 {
+			return
+		}
+		addr, err := netip.ParseAddr(authority[1:end])
+		require.NoError(t, err)
+		require.True(t, addr.Is6(), "brackets must hold an IPv6 address")
+		require.Empty(t, addr.Zone())
+		require.Equal(t, addr.Unmap().String(), host)
+	})
 }

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path internal/ipv6host/ipv6host_test.go --path internal/origin/origin_test.go --path internal/schemehost/schemehost_test.go --path middleware/cors/cors_test.go --path middleware/csrf/csrf_test.go --path middleware/hostauthorization/hostauthorization_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/ipv6host ./internal/origin ./internal/schemehost ./middleware/cors ./middleware/csrf ./middleware/hostauthorization')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/ipv6host ./internal/origin ./internal/schemehost ./middleware/cors ./middleware/csrf ./middleware/hostauthorization' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
