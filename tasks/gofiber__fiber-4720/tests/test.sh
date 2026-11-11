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
for f in internal/wiretarget/wiretarget_test.go middleware/adaptor/adaptor_test.go middleware/adaptor/routed_test.go middleware/proxy/coverage_test.go middleware/proxy/security_test.go middleware/proxy/target_test.go middleware/rewrite/rewrite_test.go middleware/static/static_test.go; do if git cat-file -e 0923873f4a1bd7e5582ab0d6729cf04e683db2ae:"$f" 2>/dev/null; then git checkout 0923873f4a1bd7e5582ab0d6729cf04e683db2ae -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 0923873f4a1bd7e5582ab0d6729cf04e683db2ae "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/internal/wiretarget/wiretarget_test.go b/internal/wiretarget/wiretarget_test.go
new file mode 100644
index 00000000000..6a4f4deb875
--- /dev/null
+++ b/internal/wiretarget/wiretarget_test.go
@@ -0,0 +1,238 @@
+package wiretarget
+
+import (
+	"bufio"
+	"encoding/hex"
+	"strings"
+	"testing"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// answerFor hands app a request line exactly as written, which net/http's
+// request builders would reject or rewrite, and returns what Routed answered.
+func answerFor(t *testing.T, app *fiber.App, target string) string {
+	t.Helper()
+
+	var req fasthttp.Request
+	raw := fiber.MethodGet + " " + target + " HTTP/1.1\r\nHost: example.com\r\n\r\n"
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	var fctx fasthttp.RequestCtx
+	fctx.Init(&req, nil, nil)
+	app.Handler()(&fctx)
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
+	return string(fctx.Response.Body())
+}
+
+func echoRouted(c fiber.Ctx) error {
+	return c.SendString(Routed(c))
+}
+
+func Test_Routed(t *testing.T) {
+	t.Parallel()
+
+	t.Run("default", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Get("/*", echoRouted)
+		for target, want := range map[string]string{
+			"/":                       "/",
+			"/a%2Fb/%41?q=%2F&x=1":    "/a%2Fb/A?q=%2F&x=1",
+			"/a//b":                   "/a//b",
+			"/a/./b/../c":             "/a/c",
+			"/%2e%2e/a":               "/a",
+			"/a%2fb":                  "/a%2Fb",
+			"/%zz":                    "/%25zz",
+			"/a%zzb%2Fc%":             "/a%25zzb%2Fc%25",
+			"/trailing%2":             "/trailing%252",
+			"/%":                      "/%25",
+			"/a?":                     "/a",
+			"/a?%zz=%zz":              "/a?%zz=%zz",
+			"/caf%C3%A9?x=caf%C3%A9":  "/caf%C3%A9?x=caf%C3%A9",
+			"/a?x=1#frag":             "/a?x=1",
+			"/sp%20ace/%7Etilde?x=+y": "/sp%20ace/~tilde?x=+y",
+			"/UPPER/%5C?X=1":          "/UPPER/%5C?X=1",
+			// bytes a path may not carry raw are written as their escapes
+			"/a\\b":                 "/a%5Cb",
+			"/a|b{c}":               "/a%7Cb%7Bc%7D",
+			"/q\"^<>`[]":            "/q%22%5E%3C%3E%60%5B%5D",
+			"/\xc3\xbcber":          "/%C3%BCber",
+			"/sub!$&'()*+,;=:@~-._": "/sub!$&'()*+,;=:@~-._",
+		} {
+			require.Equal(t, want, answerFor(t, app, target), target)
+		}
+	})
+
+	t.Run("unescape path", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New(fiber.Config{UnescapePath: true})
+		app.Get("/*", echoRouted)
+		for target, want := range map[string]string{
+			"/a%2Fb/%41%20c?q=%2F": "/a/b/A%20c?q=%2F",
+			"/a%2F..%2Fb":          "/b",
+			"/a%2F%2Fb":            "/a//b",
+			"/caf%C3%A9":           "/caf%C3%A9",
+			"/%zz":                 "/%25zz",
+			"/%252e%252e/a":        "/%252e%252e/a",
+			"/a%3Fb%23c%25d":       "/a%3Fb%23c%25d",
+		} {
+			require.Equal(t, want, answerFor(t, app, target), target)
+		}
+	})
+
+	t.Run("query read by a handler", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use(func(c fiber.Ctx) error {
+			_ = c.Query("a")
+			return c.Next()
+		})
+		app.Get("/*", echoRouted)
+		// parsed arguments would be serialized again as "a=+b&c=%3Bd"
+		require.Equal(t, "/x?a=%20b&c=;d&sig=AbC%2F", answerFor(t, app, "/x?a=%20b&c=;d&sig=AbC%2F"))
+	})
+
+	t.Run("query arguments changed by a handler", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use(func(c fiber.Ctx) error {
+			c.Request().URI().QueryArgs().Set("k", "v")
+			return c.Next()
+		})
+		app.Get("/*", echoRouted)
+		require.Equal(t, "/a?x=1&k=v", answerFor(t, app, "/a?x=1"))
+	})
+
+	t.Run("path overridden by a handler", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use(func(c fiber.Ctx) error {
+			c.Path("/rewritten/%41")
+			return c.Next()
+		})
+		app.Get("/*", echoRouted)
+		require.Equal(t, "/rewritten/A?x=1", answerFor(t, app, "/original?x=1"))
+	})
+
+	t.Run("immutable", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New(fiber.Config{Immutable: true})
+		app.Get("/*", echoRouted)
+		require.Equal(t, "/a%2Fb/A?q=1", answerFor(t, app, "/a%2Fb/%41?q=1"))
+	})
+}
+
+func Test_SegmentsAsRouted(t *testing.T) {
+	t.Parallel()
+
+	for _, target := range []string{
+		"/", "/a/b", "/a/b?x=%2F&y=//", "/a%252Fb", "/%252E%252E/a", "/a/b/",
+		"/a;b/c", "/m;x=1;y=2", "/..x;y/a", "/a/.b;c", "/a%255C", "/a?q=\\&r=%5C",
+	} {
+		require.True(t, SegmentsAsRouted(target), target)
+	}
+	// "%2E" is an escape the router decodes, so one still in the routed path
+	// was forged and URL.Path would read "%2E%2E" as "..". A backslash is a
+	// separator to WHATWG URL parsers and IIS, and servlet containers resolve
+	// a dot segment once they strip its path parameters.
+	for _, target := range []string{
+		"//", "//admin", "/a//b", "/a/b//", "/public/..%2Fadmin", "/a%2fb", "/a%2Fb?x=1", "/%2E%2E/a",
+		"/admin\\secret", "/public/..\\admin", "/a%5Cb", "/public/..%5cadmin",
+		"/public/..;/admin", "/public/.;/admin", "/public/..;jsessionid=x/admin", "/a/..;", "/a/.;x",
+	} {
+		require.False(t, SegmentsAsRouted(target), target)
+	}
+}
+
+func Test_ParsesAsPath(t *testing.T) {
+	t.Parallel()
+
+	host := []byte("example.com")
+	for _, target := range []string{"/", "/a://b", "/a//b://c", "//evil.example/x", "//u:pw@evil.example/a:/b", "/x?u=http://y"} {
+		require.True(t, ParsesAsPath(target, host), target)
+	}
+	for _, target := range []string{"//u:pw@evil.example/a://b", "//evil.example/x?u=http://y", "//?x=1://"} {
+		require.False(t, ParsesAsPath(target, host), target)
+	}
+	// Without a Host header fasthttp reads any target that begins with "//"
+	// as an authority.
+	require.False(t, ParsesAsPath("//evil.example/x", nil))
+	require.True(t, ParsesAsPath("/x", nil))
+	require.True(t, ParsesAsPath("/a//b", nil))
+}
+
+// Test_Routed_RootsUnrootedPath pins that a path override without a leading
+// slash, as a rewrite of "/go/*" to "$1" produces, is handed on as a path
+// rather than as the absolute URL a request line would read it as.
+func Test_Routed_RootsUnrootedPath(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Get("/go/*", func(c fiber.Ctx) error {
+		c.Path(c.Params("*"))
+		return c.SendString(Routed(c))
+	})
+	require.Equal(t, "/http://u:pw@evil.example/x", answerFor(t, app, "/go/http://u:pw@evil.example/x"))
+	require.Equal(t, "/evil.example/x?q=1", answerFor(t, app, "/go/evil.example/x?q=1"))
+}
+
+func Test_HasForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	for _, target := range []string{"/public/%2e%2e/admin", "/%2E", "/a%41", "/%7e", "/x%5F?q=%41", "/a%25%41"} {
+		require.True(t, HasForgedEscape(target), target)
+	}
+	// every unreserved character, digits and "-" included
+	for _, c := range []byte("09azAZ-._~") {
+		target := "/x/%" + strings.ToUpper(hex.EncodeToString([]byte{c}))
+		require.True(t, HasForgedEscape(target), target)
+		require.True(t, HasForgedEscape(strings.ToLower(target)), target)
+	}
+	for _, target := range []string{"/", "/a/b", "/a%20b", "/a%2Fb", "/a%25b", "/%2541", "/a%3Fb", "/%", "/%2", "/%zz", "/a?q=%41", "/a%25/%2"} {
+		require.False(t, HasForgedEscape(target), target)
+	}
+}
+
+func Test_SegmentsAsRouted_ForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	require.False(t, SegmentsAsRouted("/public/%2e%2e/admin/secret"))
+	require.False(t, SegmentsAsRouted("/public/%70rivate"))
+	require.True(t, SegmentsAsRouted("/public/%2541/a%20b?x=%2e"))
+}
+
+func Test_SurvivesNormalization(t *testing.T) {
+	t.Parallel()
+
+	// An escape of a byte fasthttp escapes again when it writes the path
+	// comes out as it went in, whatever the case of its hex digits.
+	for _, target := range []string{
+		"/", "/a/b", "/a/b?q=%2F&x=//", "/a.b/c-d_e~f", "/a%20b", "/%25", "/caf%C3%A9",
+		"/a%7Cb%7bc", "/a%3Fb%23c", "/%21%27%28%29%2A",
+	} {
+		require.True(t, SurvivesNormalization(target), target)
+	}
+	// An escape of a byte it writes raw is decoded into that byte, as is a
+	// backslash Windows resolves dot segments around, an empty segment is
+	// merged and a "%" that begins no escape is written as "%25".
+	for _, target := range []string{
+		"/public/..%2Fadmin", "/a//b", "//x", "/..%3B/admin", "/a%40b", "/a%2Cb", "/%41", "/%2e%2e/x",
+		"/a%5Cb", "/a%", "/a%2", "/a%zz",
+	} {
+		require.False(t, SurvivesNormalization(target), target)
+	}
+}
+
+func Test_ParsesAsPath_Unrooted(t *testing.T) {
+	t.Parallel()
+
+	host := []byte("example.com")
+	for _, target := range []string{"", "http://u:pw@evil.example/x", "evil.example/x", "*"} {
+		require.False(t, ParsesAsPath(target, host), target)
+	}
+	require.True(t, ParsesAsPath("/http://u:pw@evil.example/x", host))
+	require.True(t, ParsesAsPath("/http://u:pw@evil.example/x", nil))
+}
diff --git a/middleware/adaptor/adaptor_test.go b/middleware/adaptor/adaptor_test.go
index 7918cb42655..6f93701ca06 100644
--- a/middleware/adaptor/adaptor_test.go
+++ b/middleware/adaptor/adaptor_test.go
@@ -1952,6 +1952,38 @@ func Benchmark_HTTPMiddleware(b *testing.B) {
 	}
 }
 
+// Benchmark_ConvertRequest measures building a net/http request from a routed
+// Fiber request whose request line is already the routed target, the common
+// case, where the line is not set and parsed a second time.
+func Benchmark_ConvertRequest(b *testing.B) {
+	app := fiber.New()
+	app.Get("/users/:id", func(c fiber.Ctx) error {
+		r, err := ConvertRequest(c, true)
+		if err != nil {
+			return err
+		}
+		if r.URL.Path != "/users/42" {
+			return fiber.ErrInternalServerError
+		}
+		return nil
+	})
+
+	handler := app.Handler()
+	ctx := &fasthttp.RequestCtx{}
+
+	b.ReportAllocs()
+
+	for b.Loop() {
+		ctx.Request.Reset()
+		ctx.Response.Reset()
+		ctx.Request.Header.SetMethod(fiber.MethodGet)
+		ctx.Request.SetRequestURI("/users/42?expand=1")
+		ctx.Request.Header.Set("Foo", "bar")
+
+		handler(ctx)
+	}
+}
+
 // Benchmark_FiberApp exercises the net/http -> Fiber direction the way a real
 // net/http server does: a fresh response writer per request, a routed app, a
 // remote address to resolve and a handful of request and response headers.
diff --git a/middleware/adaptor/routed_test.go b/middleware/adaptor/routed_test.go
new file mode 100644
index 00000000000..c75000f383e
--- /dev/null
+++ b/middleware/adaptor/routed_test.go
@@ -0,0 +1,640 @@
+package adaptor
+
+import (
+	"bufio"
+	"context"
+	"fmt"
+	"net/http"
+	"net/http/httptest"
+	"net/url"
+	"os"
+	"path/filepath"
+	"strings"
+	"testing"
+	"time"
+
+	"github.com/gofiber/fiber/v3"
+	recoverer "github.com/gofiber/fiber/v3/middleware/recover"
+	"github.com/stretchr/testify/assert"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// rawCtx hands app a request line exactly as written, which net/http's request
+// builders would reject or rewrite, and returns the served context.
+func rawCtx(t *testing.T, app *fiber.App, target string) *fasthttp.RequestCtx {
+	t.Helper()
+
+	var req fasthttp.Request
+	raw := fiber.MethodGet + " " + target + " HTTP/1.1\r\nHost: example.com\r\n\r\n"
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	fctx := new(fasthttp.RequestCtx)
+	fctx.Init(&req, nil, nil)
+	app.Handler()(fctx)
+	return fctx
+}
+
+func denyAll(c fiber.Ctx) error {
+	return c.SendStatus(fiber.StatusForbidden)
+}
+
+// describeURL is a net/http handler that answers with how it read the request.
+func describeURL(w http.ResponseWriter, r *http.Request) {
+	fmt.Fprint(w, r.URL.Path, "|", r.URL.RawPath, "|", r.RequestURI)
+}
+
+func Test_HTTPHandler_RoutedPath(t *testing.T) {
+	t.Parallel()
+
+	t.Run("default", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use("/admin", denyAll)
+		app.Use(HTTPHandler(http.HandlerFunc(describeURL)))
+
+		for target, want := range map[string]string{
+			"/plain/path":       "/plain/path||/plain/path",
+			"/public/%41?x=%2F": "/public/A||/public/A?x=%2F",
+			"/%zz":              "/%zz||/%25zz",
+			"/a%3Fb%23c":        "/a?b#c||/a%3Fb%23c",
+			"/sp%20ace/":        "/sp ace/||/sp%20ace/",
+		} {
+			fctx := rawCtx(t, app, target)
+			require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
+			require.Equal(t, want, string(fctx.Response.Body()), target)
+		}
+		// Routed under "/admin", the guard answers before the handler.
+		for _, target := range []string{"/admin/x", "/a/../admin/x", "/%2e%2e/admin/x", "/public/%2E./admin/x"} {
+			require.Equal(t, fiber.StatusForbidden, rawCtx(t, app, target).Response.StatusCode(), target)
+		}
+		// An empty segment or an escaped slash would be cleaned or decoded
+		// into a path the router never matched, so the handler never sees it.
+		for _, target := range []string{"//admin/x", "/public//x", "/x//", "/public/..%2Fadmin/x", "/public%2F..%2Fadmin", "/a%2fb"} {
+			require.Equal(t, fiber.StatusNotFound, rawCtx(t, app, target).Response.StatusCode(), target)
+		}
+	})
+
+	t.Run("unescape path", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New(fiber.Config{UnescapePath: true})
+		app.Use("/admin", denyAll)
+		app.Use(HTTPHandler(http.HandlerFunc(describeURL)))
+
+		fctx := rawCtx(t, app, "/public/a%2Fb/%41%20c?x=%2F")
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+		require.Equal(t, "/public/a/b/A c||/public/a/b/A%20c?x=%2F", string(fctx.Response.Body()))
+
+		// Decoded before matching, the escaped slash completed a dot segment
+		// the router resolved: the request was routed under "/admin".
+		for _, target := range []string{"/public/..%2Fadmin/x", "/public%2F..%2Fadmin/x"} {
+			require.Equal(t, fiber.StatusForbidden, rawCtx(t, app, target).Response.StatusCode(), target)
+		}
+		require.Equal(t, fiber.StatusNotFound, rawCtx(t, app, "/a%2F%2Fb").Response.StatusCode())
+	})
+}
+
+// Test_HTTPHandler_FileServerStaysInPlace serves a directory tree through
+// net/http's file server behind a Fiber guard on "/admin", and pins that no
+// spelling of the admin file's path reaches the file server unguarded.
+func Test_HTTPHandler_FileServerStaysInPlace(t *testing.T) {
+	t.Parallel()
+
+	root := t.TempDir()
+	require.NoError(t, os.MkdirAll(filepath.Join(root, "public"), 0o750))
+	require.NoError(t, os.MkdirAll(filepath.Join(root, "admin"), 0o750))
+	require.NoError(t, os.WriteFile(filepath.Join(root, "public", "ok.txt"), []byte("ok"), 0o600))
+	require.NoError(t, os.WriteFile(filepath.Join(root, "admin", "secret.txt"), []byte("secret"), 0o600))
+
+	app := fiber.New()
+	app.Use("/admin", denyAll)
+	app.Use(HTTPHandler(http.FileServer(http.Dir(root))))
+
+	fctx := rawCtx(t, app, "/public/ok.txt")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "ok", string(fctx.Response.Body()))
+
+	for target, want := range map[string]int{
+		"/admin/secret.txt":               fiber.StatusForbidden,
+		"/public/../admin/secret.txt":     fiber.StatusForbidden,
+		"/public/%2e%2e/admin/secret.txt": fiber.StatusForbidden,
+		// A stray "%" forges the escape the router would have decoded:
+		// routed as "/public/%2e%2e/admin/secret.txt" it is not handed on,
+		// and routed as "/public/%252e%252e/admin/secret.txt" it names a
+		// directory that does not exist. URL.Path never reads it as "..".
+		"/public/%%32e%%32e/admin/secret.txt": fiber.StatusNotFound,
+		"/public/..%2Fadmin/secret.txt":       fiber.StatusNotFound,
+		"/public%2F..%2Fadmin/secret.txt":     fiber.StatusNotFound,
+		"//admin/secret.txt":                  fiber.StatusNotFound,
+		// The ".." removes the empty segment before it (RFC 3986 Section
+		// 5.2.4), so this is routed as "/public/admin/secret.txt", a file
+		// that does not exist, and never as "/admin/secret.txt".
+		"/public//../admin/secret.txt": fiber.StatusNotFound,
+	} {
+		fctx := rawCtx(t, app, target)
+		require.Equal(t, want, fctx.Response.StatusCode(), target)
+		require.NotContains(t, string(fctx.Response.Body()), "secret", target)
+	}
+}
+
+// Test_HTTPHandler_RefusesBackslashAndDotParams pins that an adapted handler
+// is not handed a path that a handler passing the request on, such as
+// httputil.ReverseProxy, would forward to an upstream that reads it as another
+// path: one with a backslash, which WHATWG URL parsers and IIS read as a
+// separator, or with a dot segment carrying parameters, which servlet
+// containers resolve once they strip the parameters. A ";" anywhere else is
+// an ordinary path character and is handed on.
+func Test_HTTPHandler_RefusesBackslashAndDotParams(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(HTTPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		fmt.Fprint(w, r.URL.EscapedPath())
+	})))
+
+	for _, target := range []string{
+		"/admin\\secret", "/public/..\\admin", "/public/..%5Cadmin", "/public/..%5cadmin",
+		"/public/..;/admin", "/public/.;x/admin", "/public/..;jsessionid=1/admin",
+	} {
+		fctx := rawCtx(t, app, target)
+		require.Equal(t, fiber.StatusNotFound, fctx.Response.StatusCode(), target)
+		require.NotContains(t, string(fctx.Response.Body()), "admin", target)
+	}
+	for _, target := range []string{"/a;b/c", "/m;x=1;y=2", "/..x;y/a"} {
+		fctx := rawCtx(t, app, target)
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
+		require.Equal(t, target, string(fctx.Response.Body()), target)
+	}
+}
+
+func Test_HTTPHandler_RestoresRequestLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	var after string
+	app.Use(func(c fiber.Ctx) error {
+		err := c.Next()
+		after = c.OriginalURL()
+		return err
+	})
+	app.Use(HTTPHandler(http.HandlerFunc(describeURL)))
+
+	fctx := rawCtx(t, app, "/a/../public/%41?x=1")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "/public/A||/public/A?x=1", string(fctx.Response.Body()))
+	require.Equal(t, "/a/../public/%41?x=1", after)
+}
+
+// Test_HTTPHandler_FlushedHandlerKeepsRequestLine pins that a handler still
+// running after it flushed reads its URL undisturbed: the request line is not
+// put back under it. Run with -race, the restore would be reported.
+func Test_HTTPHandler_FlushedHandlerKeepsRequestLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	var after string
+	app.Use(func(c fiber.Ctx) error {
+		err := c.Next()
+		after = c.OriginalURL()
+		return err
+	})
+	app.Use(HTTPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		flusher, ok := w.(http.Flusher)
+		if !assert.True(t, ok, "w does not implement http.Flusher") {
+			return
+		}
+		flusher.Flush()
+		time.Sleep(20 * time.Millisecond)
+		fmt.Fprint(w, r.URL.Path, "|", r.RequestURI)
+	})))
+
+	fctx := rawCtx(t, app, "/a/../public/%41?x=1")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "/public/A|/public/A?x=1", string(fctx.Response.Body()))
+	require.Equal(t, "/public/A?x=1", after)
+}
+
+func Test_HTTPHandlerWithContext_RoutedPath(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use("/admin", denyAll)
+	app.Use(HTTPHandlerWithContext(http.HandlerFunc(describeURL)))
+
+	fctx := rawCtx(t, app, "/a/../public/%41?x=1")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "/public/A||/public/A?x=1", string(fctx.Response.Body()))
+	require.Equal(t, fiber.StatusForbidden, rawCtx(t, app, "/%2e%2e/admin/x").Response.StatusCode())
+	require.Equal(t, fiber.StatusNotFound, rawCtx(t, app, "/public/..%2Fadmin/x").Response.StatusCode())
+}
+
+// Test_HTTPMiddleware_SeesRoutedPath pins that a net/http guard on r.URL.Path
+// sees the path the router matched, and that an escaped slash is handed on
+// rather than decoded, so a Fiber route behind the middleware still gets it.
+func Test_HTTPMiddleware_SeesRoutedPath(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			if strings.HasPrefix(r.URL.Path, "/admin") {
+				w.WriteHeader(http.StatusForbidden)
+				return
+			}
+			r.Header.Set("X-Seen-Path", r.URL.Path)
+			r.Header.Set("X-Seen-Escaped", r.URL.EscapedPath())
+			next.ServeHTTP(w, r)
+		})
+	}))
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendString(c.Get("X-Seen-Path") + "|" + c.Get("X-Seen-Escaped") + "|" + c.Path() + "|" + c.OriginalURL())
+	})
+
+	for target, want := range map[string]string{
+		"/items/a%2Fb?x=1": "/items/a/b|/items/a%2Fb|/items/a%2Fb|/items/a%2Fb?x=1",
+		"/public/%41":      "/public/A|/public/A|/public/A|/public/A",
+		"//admin/x":        "//admin/x|//admin/x|//admin/x|//admin/x",
+	} {
+		fctx := rawCtx(t, app, target)
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
+		require.Equal(t, want, string(fctx.Response.Body()), target)
+	}
+	for _, target := range []string{"/admin/x", "/a/../admin/x", "/%2e%2e/admin/x"} {
+		require.Equal(t, fiber.StatusForbidden, rawCtx(t, app, target).Response.StatusCode(), target)
+	}
+}
+
+func Test_ConvertRequest_RoutedPath(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Get("/*", func(c fiber.Ctx) error {
+		r, err := ConvertRequest(c, true)
+		if err != nil {
+			return err
+		}
+		return c.SendString(r.URL.Path + "|" + r.URL.RawPath + "|" + r.RequestURI + "|" + c.OriginalURL())
+	})
+
+	fctx := rawCtx(t, app, "/a/../public/%41%2Fb?x=1")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "/public/A/b|/public/A%2Fb|/public/A%2Fb?x=1|/public/A%2Fb?x=1", string(fctx.Response.Body()))
+}
+
+// Test_FiberHandler_RoutesTheURL pins that a Fiber handler served from
+// net/http is routed on r.URL when it differs from r.RequestURI: after an
+// http.StripPrefix in front of it, and for a request built in code, which
+// has no RequestURI at all.
+func Test_FiberHandler_RoutesTheURL(t *testing.T) {
+	t.Parallel()
+
+	h := func(c fiber.Ctx) error {
+		return c.SendString(c.Path() + "|" + c.OriginalURL())
+	}
+
+	rec := httptest.NewRecorder()
+	http.StripPrefix("/app", FiberHandler(h)).ServeHTTP(rec, httptest.NewRequest(fiber.MethodGet, "/app/users/%41?x=1", http.NoBody))
+	require.Equal(t, http.StatusOK, rec.Code)
+	require.Equal(t, "/users/A|/users/%41?x=1", rec.Body.String())
+
+	built, err := http.NewRequestWithContext(context.Background(), fiber.MethodGet, "http://example.com/built/%41?x=1", http.NoBody)
+	require.NoError(t, err)
+	require.Empty(t, built.RequestURI)
+	rec = httptest.NewRecorder()
+	FiberHandler(h).ServeHTTP(rec, built)
+	require.Equal(t, http.StatusOK, rec.Code)
+	require.Equal(t, "/built/A|/built/%41?x=1", rec.Body.String())
+
+	// As served by net/http, the two agree and the request line is used as is.
+	rec = httptest.NewRecorder()
+	FiberHandler(h).ServeHTTP(rec, httptest.NewRequest(fiber.MethodGet, "/served/%41?x=1", http.NoBody))
+	require.Equal(t, "/served/A|/served/%41?x=1", rec.Body.String())
+}
+
+// Test_FiberHandler_ConnectAuthorityForm pins that a CONNECT request in the
+// authority form, which net/http keeps in r.URL.Host with an empty path, is
+// routed as that authority, as the parent server received it, and not as the
+// "/" that r.URL.RequestURI() reads for it. The router may root the
+// authority, so both spellings of c.Path() are accepted.
+func Test_FiberHandler_ConnectAuthorityForm(t *testing.T) {
+	t.Parallel()
+
+	h := func(c fiber.Ctx) error {
+		return c.SendString(c.Path() + "|" + c.Host())
+	}
+	routed := func(t *testing.T, rec *httptest.ResponseRecorder) (string, string) {
+		t.Helper()
+		require.Equal(t, http.StatusOK, rec.Code)
+		path, host, ok := strings.Cut(rec.Body.String(), "|")
+		require.True(t, ok, rec.Body.String())
+		return strings.TrimPrefix(path, "/"), host
+	}
+
+	rec := httptest.NewRecorder()
+	FiberHandler(h).ServeHTTP(rec, httptest.NewRequest(fiber.MethodConnect, "backend.internal:443", http.NoBody))
+	path, host := routed(t, rec)
+	require.Equal(t, "backend.internal:443", path)
+	require.Equal(t, "backend.internal:443", host)
+
+	// A rewrite of the authority is routed like one of the path.
+	retarget := func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			r.URL.Host = "other.internal:8443"
+			r.Host = r.URL.Host
+			next.ServeHTTP(w, r)
+		})
+	}
+	rec = httptest.NewRecorder()
+	retarget(FiberHandler(h)).ServeHTTP(rec, httptest.NewRequest(fiber.MethodConnect, "backend.internal:443", http.NoBody))
+	path, host = routed(t, rec)
+	require.Equal(t, "other.internal:8443", path)
+	require.Equal(t, "other.internal:8443", host)
+
+	// The net/rpc form, a CONNECT with a path, is routed by that path.
+	rec = httptest.NewRecorder()
+	FiberHandler(h).ServeHTTP(rec, httptest.NewRequest(fiber.MethodConnect, "/rpc", http.NoBody))
+	path, host = routed(t, rec)
+	require.Equal(t, "rpc", path)
+	require.Equal(t, "example.com", host)
+}
+
+// Test_requestTarget pins the request line requestTarget reads for each
+// shape net/http hands the adaptor: no URL, a URL with a path, and the
+// authority form of CONNECT, where the target is URL.Opaque, else the Host
+// header, else the URL's host, as net/http writes such a request.
+func Test_requestTarget(t *testing.T) {
+	t.Parallel()
+
+	connect := func(u *url.URL, host string) *http.Request {
+		return &http.Request{Method: http.MethodConnect, URL: u, Host: host}
+	}
+
+	require.Empty(t, requestTarget(&http.Request{Method: http.MethodGet}))
+	require.Equal(t, "/a/b?x=1", requestTarget(&http.Request{Method: http.MethodGet, URL: &url.URL{Path: "/a/b", RawQuery: "x=1"}}))
+	require.Equal(t, "/rpc", requestTarget(connect(&url.URL{Path: "/rpc"}, "backend.internal:443")))
+	require.Equal(t, "backend.internal:443", requestTarget(connect(&url.URL{Host: "backend.internal:443"}, "backend.internal:443")))
+	require.Equal(t, "other.internal:8443", requestTarget(connect(&url.URL{Host: "backend.internal:443"}, "other.internal:8443")))
+	require.Equal(t, "backend.internal:443", requestTarget(connect(&url.URL{Host: "backend.internal:443"}, "")))
+	require.Equal(t, "opaque.internal:443", requestTarget(connect(&url.URL{Opaque: "opaque.internal:443", Host: "backend.internal:443"}, "backend.internal:443")))
+}
+
+// Test_HTTPMiddleware_RejectsAuthorityTarget pins that a routed target
+// fasthttp would read as an authority, one that begins with "//" and holds
+// "://", is refused rather than set on the request, where the next parse
+// would take the host and credentials from it.
+func Test_HTTPMiddleware_RejectsAuthorityTarget(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(HTTPMiddleware(func(next http.Handler) http.Handler { return next }))
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendString(c.Hostname() + "|" + c.Path())
+	})
+
+	require.Equal(t, fiber.StatusBadRequest, rawCtx(t, app, "//u:pw@evil.example/a:/x/..//b").Response.StatusCode())
+
+	fctx := rawCtx(t, app, "//evil.example/a:/b")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "example.com|//evil.example/a:/b", string(fctx.Response.Body()))
+}
+
+func Test_ConvertRequest_RejectsAuthorityTarget(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Get("/*", func(c fiber.Ctx) error {
+		r, err := ConvertRequest(c, true)
+		if err != nil {
+			return err
+		}
+		return c.SendString(r.URL.Path + "|" + c.Hostname())
+	})
+
+	require.Equal(t, fiber.StatusBadRequest, rawCtx(t, app, "//u:pw@evil.example/a:/x/..//b").Response.StatusCode())
+
+	fctx := rawCtx(t, app, "//evil.example/a:/b")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "//evil.example/a:/b|example.com", string(fctx.Response.Body()))
+}
+
+// Test_HTTPHandler_PanicRestoresRequestLine pins that the original request
+// line is put back when the adapted handler panics, so the middleware that
+// recovers, and anything logging afterwards, sees the request as it arrived.
+func Test_HTTPHandler_PanicRestoresRequestLine(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	var after string
+	app.Use(func(c fiber.Ctx) error {
+		err := c.Next()
+		after = c.OriginalURL()
+		return err
+	})
+	app.Use(recoverer.New())
+	app.Use(HTTPHandler(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
+		panic("boom")
+	})))
+
+	fctx := rawCtx(t, app, "/a/../public/%41")
+	require.Equal(t, fiber.StatusInternalServerError, fctx.Response.StatusCode())
+	require.Equal(t, "/a/../public/%41", after)
+}
+
+// forgedEscapeOutcome checks a response to "/public/%%32e%%32e/admin/x", a
+// stray "%" forging the escape the router would have decoded. Which of two
+// outcomes it gets depends on how the router spells a stray "%". Kept as sent,
+// the path is routed as "/public/%2e%2e/admin/x" and refused, since URL.Path
+// would read the segment as "..". Written as "%25" where a decoded escape
+// would complete it, the path is routed as "/public/%252e%252e/admin/x", which
+// holds no forged escape and is handed on as the literal name want: the body
+// must then be exactly that, so it never holds a decoded "..".
+func forgedEscapeOutcome(t *testing.T, fctx *fasthttp.RequestCtx, want string) {
+	t.Helper()
+	switch fctx.Response.StatusCode() {
+	case fiber.StatusBadRequest:
+	case fiber.StatusOK:
+		require.Equal(t, want, string(fctx.Response.Body()))
+	default:
+		t.Fatalf("unexpected status %d", fctx.Response.StatusCode())
+	}
+}
+
+func Test_HTTPMiddleware_RejectsForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(HTTPMiddleware(func(next http.Handler) http.Handler { return next }))
+	app.Use(func(c fiber.Ctx) error {
+		return c.SendString(c.Path())
+	})
+	forgedEscapeOutcome(t, rawCtx(t, app, "/public/%%32e%%32e/admin/x"), "/public/%252e%252e/admin/x")
+}
+
+func Test_ConvertRequest_RejectsForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Get("/*", func(c fiber.Ctx) error {
+		r, err := ConvertRequest(c, true)
+		if err != nil {
+			return err
+		}
+		return c.SendString(r.URL.RawPath + "|" + r.URL.Path)
+	})
+	// net/http leaves RawPath empty when it is the escaped form of Path, as it
+	// is for "/public/%252e%252e/admin/x".
+	forgedEscapeOutcome(t, rawCtx(t, app, "/public/%%32e%%32e/admin/x"), "|/public/%2e%2e/admin/x")
+}
+
+// rawLine hands app a whole raw request, request line and headers, and returns
+// the served context.
+func rawLine(t *testing.T, app *fiber.App, raw string) *fasthttp.RequestCtx {
+	t.Helper()
+
+	var req fasthttp.Request
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	fctx := new(fasthttp.RequestCtx)
+	fctx.Init(&req, nil, nil)
+	app.Handler()(fctx)
+	return fctx
+}
+
+// Test_Adaptor_KeepsAbsoluteFormHost pins that an adapted net/http handler sees
+// the host Fiber saw. An absolute-form request line names its own host, which
+// RFC 9112 Section 3.2.2 has the server use over the Host header, and
+// c.Hostname() reports it; setting a routed target that is a path must not
+// make fasthttp take the host from the Host header again.
+func Test_Adaptor_KeepsAbsoluteFormHost(t *testing.T) {
+	t.Parallel()
+
+	const raw = "GET http://public.example/x?q=1 HTTP/1.1\r\nHost: admin.internal\r\n\r\n"
+	echoHost := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		fmt.Fprint(w, r.Host, "|", r.URL.Path)
+	})
+
+	t.Run("HTTPHandler", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use(func(c fiber.Ctx) error {
+			require.Equal(t, "public.example", c.Hostname())
+			return c.Next()
+		})
+		app.Get("/x", HTTPHandler(echoHost))
+		fctx := rawLine(t, app, raw)
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+		require.Equal(t, "public.example|/x", string(fctx.Response.Body()))
+	})
+
+	t.Run("ConvertRequest", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Get("/x", func(c fiber.Ctx) error {
+			r, err := ConvertRequest(c, true)
+			if err != nil {
+				return err
+			}
+			return c.SendString(r.Host + "|" + c.Hostname())
+		})
+		fctx := rawLine(t, app, raw)
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+		require.Equal(t, "public.example|public.example", string(fctx.Response.Body()))
+	})
+
+	t.Run("HTTPMiddleware", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		var seen string
+		app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+				seen = strings.Clone(r.Host) // r is only valid during the call
+				next.ServeHTTP(w, r)
+			})
+		}))
+		app.Get("/x", func(c fiber.Ctx) error {
+			return c.SendString(c.Hostname())
+		})
+		fctx := rawLine(t, app, raw)
+		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+		require.Equal(t, "public.example", seen)
+		require.Equal(t, "public.example", string(fctx.Response.Body()))
+	})
+}
+
+// Test_HTTPMiddleware_ForwardsQueryAsSent pins that a net/http middleware sees
+// the query the client sent although a Fiber handler before it read the
+// arguments, which fasthttp would otherwise serialize again ("%20" as "+",
+// ";" as "%3B") and so break a signed URL.
+func Test_HTTPMiddleware_ForwardsQueryAsSent(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(func(c fiber.Ctx) error {
+		_ = c.Query("a")
+		return c.Next()
+	})
+	var rawQuery string
+	app.Use(HTTPMiddleware(func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			rawQuery = strings.Clone(r.URL.RawQuery) // r is only valid during the call
+			next.ServeHTTP(w, r)
+		})
+	}))
+	app.Get("/x", func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusNoContent)
+	})
+
+	fctx := rawCtx(t, app, "/x?a=%20b&c=;d&sig=AbC%2F")
+	require.Equal(t, fiber.StatusNoContent, fctx.Response.StatusCode())
+	require.Equal(t, "a=%20b&c=;d&sig=AbC%2F", rawQuery)
+}
+
+// Test_FiberHandler_RoutesRawBytes pins that a Fiber handler served from
+// net/http routes the request line the client sent, as Fiber served directly
+// would: r.URL.RequestURI() escapes a raw byte of UTF-8 or a "|", so routing it
+// answered 404 for "/über" and handed parameters back escaped.
+func Test_FiberHandler_RoutesRawBytes(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Get("/über", func(c fiber.Ctx) error {
+		return c.SendString("static|" + c.Path())
+	})
+	app.Get("/p/:name", func(c fiber.Ctx) error {
+		return c.SendString(c.Params("name"))
+	})
+	h := FiberApp(app)
+
+	for target, want := range map[string]string{
+		"/über":   "static|/über",
+		"/p/a|b":  "a|b",
+		"/p/café": "café",
+		"/p/%41":  "A",
+	} {
+		rec := httptest.NewRecorder()
+		h.ServeHTTP(rec, httptest.NewRequest(fiber.MethodGet, target, http.NoBody))
+		require.Equal(t, http.StatusOK, rec.Code, target)
+		require.Equal(t, want, rec.Body.String(), target)
+	}
+}
+
+// Test_HTTPMiddleware_ServesEscapedSlash pins the documented way to serve a
+// name holding "%2F", which HTTPHandler answers with 404: a net/http handler
+// wrapped as a middleware that does not call next reads it, escaped slash
+// included, from URL.EscapedPath().
+func Test_HTTPMiddleware_ServesEscapedSlash(t *testing.T) {
+	t.Parallel()
+
+	repos := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		fmt.Fprint(w, r.URL.EscapedPath())
+	})
+	app := fiber.New()
+	app.Use("/repos", HTTPMiddleware(func(http.Handler) http.Handler { return repos }))
+	app.Get("/handler/*", HTTPHandler(repos))
+
+	fctx := rawCtx(t, app, "/repos/group%2Fproject")
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode())
+	require.Equal(t, "/repos/group%2Fproject", string(fctx.Response.Body()))
+
+	require.Equal(t, fiber.StatusNotFound, rawCtx(t, app, "/handler/group%2Fproject").Response.StatusCode())
+}
diff --git a/middleware/proxy/coverage_test.go b/middleware/proxy/coverage_test.go
index d85768da68b..f9b15f5ab2a 100644
--- a/middleware/proxy/coverage_test.go
+++ b/middleware/proxy/coverage_test.go
@@ -184,10 +184,10 @@ func Test_Coverage_ResolveRedirect_RejectsHostlessTarget(t *testing.T) {
 	require.ErrorIs(t, err, fasthttp.ErrorInvalidURI)
 }
 
-// Test_Coverage_JoinUpstreamPath_RejectsAuthorityInjection covers the
-// fallback branch that fires when a parsed request path contains its
-// own scheme or host. The path is treated as opaque so the upstream
-// host pinned by base cannot be replaced.
+// Test_Coverage_JoinUpstreamPath_RejectsAuthorityInjection covers a
+// request path that spells a scheme and host of its own. Parsed behind
+// the placeholder authority it is a path and nothing else, so the
+// upstream host pinned by base cannot be replaced.
 func Test_Coverage_JoinUpstreamPath_RejectsAuthorityInjection(t *testing.T) {
 	t.Parallel()
 	base, err := url.Parse("http://upstream.example")
@@ -198,6 +198,7 @@ func Test_Coverage_JoinUpstreamPath_RejectsAuthorityInjection(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, "http", parsed.Scheme)
 	require.Equal(t, "upstream.example", parsed.Host, "host must remain pinned")
+	require.Equal(t, "/foo://hijack.example/bar", parsed.Path)
 }
 
 // Test_Coverage_JoinUpstreamPath_FallbackPreservesBasePathPrefix is a
diff --git a/middleware/proxy/security_test.go b/middleware/proxy/security_test.go
index 509bd6ecbc2..233d7c305dd 100644
--- a/middleware/proxy/security_test.go
+++ b/middleware/proxy/security_test.go
@@ -368,9 +368,54 @@ func Test_Security_JoinUpstreamPath_BlocksNetworkPathInjection(t *testing.T) {
 	base, err := parseUpstream("http://upstream.example")
 	require.NoError(t, err)
 
-	out := joinUpstreamPath(base, "//attacker.example/path")
-	require.True(t, strings.HasPrefix(out, "http://upstream.example/"), "host must not change: %q", out)
-	require.NotContains(t, out, "//attacker.example/")
+	for _, target := range []string{
+		"//attacker.example/path",
+		"////attacker.example/path",
+		"/\\attacker.example",
+		"/?@evil.com",
+		"@evil.com",
+		"https://evil.com/path",
+	} {
+		out := joinUpstreamPath(base, target)
+		parsed, parseErr := url.Parse(out)
+		require.NoError(t, parseErr, target)
+		require.Equal(t, "http", parsed.Scheme, "scheme must not change for %q: %q", target, out)
+		require.Equal(t, "upstream.example", parsed.Host, "host must not change for %q: %q", target, out)
+	}
+
+	// The router keeps empty segments, so "//attacker.example/path" is not
+	// "/attacker.example/path" to it. Forwarding it collapsed would hand the
+	// upstream a path no middleware mounted on "/attacker.example" has seen.
+	parsed, err := url.Parse(joinUpstreamPath(base, "//attacker.example/path"))
+	require.NoError(t, err)
+	require.Equal(t, "//attacker.example/path", parsed.Path)
+
+	withPrefix, err := parseUpstream("http://upstream.example/api")
+	require.NoError(t, err)
+	parsed, err = url.Parse(joinUpstreamPath(withPrefix, "//attacker.example/path"))
+	require.NoError(t, err)
+	require.Equal(t, "upstream.example", parsed.Host)
+	require.Equal(t, "/api//attacker.example/path", parsed.Path)
+}
+
+// Test_Security_JoinUpstreamPath_MalformedFragmentFallsBack covers the
+// fallback for a target that is a fragment alone and does not parse: the
+// opaque path it becomes is rooted, and stays under the base's prefix.
+func Test_Security_JoinUpstreamPath_MalformedFragmentFallsBack(t *testing.T) {
+	t.Parallel()
+	base, err := parseUpstream("http://upstream.example")
+	require.NoError(t, err)
+	parsed, err := url.Parse(joinUpstreamPath(base, "#%zz"))
+	require.NoError(t, err)
+	require.Equal(t, "upstream.example", parsed.Host)
+	require.Equal(t, "/#%zz", parsed.Path)
+
+	withPrefix, err := parseUpstream("http://upstream.example/api")
+	require.NoError(t, err)
+	parsed, err = url.Parse(joinUpstreamPath(withPrefix, "#%zz"))
+	require.NoError(t, err)
+	require.Equal(t, "upstream.example", parsed.Host)
+	require.Equal(t, "/api/#%zz", parsed.Path)
 }
 
 // Test_Security_JoinUpstreamPath_PreservesBasePathPrefix ensures a path
diff --git a/middleware/proxy/target_test.go b/middleware/proxy/target_test.go
new file mode 100644
index 00000000000..92a7740e136
--- /dev/null
+++ b/middleware/proxy/target_test.go
@@ -0,0 +1,710 @@
+package proxy
+
+import (
+	"bufio"
+	"io"
+	"net"
+	"net/http"
+	"net/http/httptest"
+	"strconv"
+	"strings"
+	"sync/atomic"
+	"testing"
+	"time"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// rawRequest hands app a request line exactly as written, which net/http's
+// request builders would reject or rewrite, and returns the response.
+func rawRequest(t *testing.T, app *fiber.App, target, host string) *fasthttp.Response {
+	t.Helper()
+
+	var req fasthttp.Request
+	raw := fiber.MethodGet + " " + target + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n"
+	if host == "" {
+		// HTTP/1.0 needs no Host header.
+		raw = fiber.MethodGet + " " + target + " HTTP/1.0\r\n\r\n"
+	}
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	var fctx fasthttp.RequestCtx
+	fctx.Init(&req, nil, nil)
+	app.Handler()(&fctx)
+
+	resp := fasthttp.AcquireResponse()
+	fctx.Response.CopyTo(resp)
+	return resp
+}
+
+// echoTarget serves an upstream that answers every request with the target
+// it was handed, exactly as it arrived on the wire.
+func echoTarget(t *testing.T) string {
+	t.Helper()
+
+	target := fiber.New()
+	target.Use(func(c fiber.Ctx) error {
+		return c.SendString(c.OriginalURL())
+	})
+
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() {
+		ln.Close() //nolint:errcheck // It is fine to ignore the error here
+	})
+	startServer(target, ln)
+
+	return ln.Addr().String()
+}
+
+func readBody(t *testing.T, resp *http.Response) string {
+	t.Helper()
+	b, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.NoError(t, resp.Body.Close())
+	return string(b)
+}
+
+func forbid(c fiber.Ctx) error {
+	return c.SendStatus(fiber.StatusForbidden)
+}
+
+// go test -run Test_Proxy_Balancer_ForwardsRoutedPath
+func Test_Proxy_Balancer_ForwardsRoutedPath(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	// Every mount and every expectation is the same for both apps: what
+	// differs is which spellings the router resolves before matching.
+	t.Run("default", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use("/admin", forbid)
+		app.Use(Balancer(Config{Servers: []string{addr}}))
+
+		for target, want := range map[string]string{
+			"/public/%41?x=%2F&y=1": "/public/A?x=%2F&y=1",
+			"/public/%zz":           "/public/%25zz",
+			"/public/a%3Ab%20c":     "/public/a%3Ab%20c",
+		} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+			require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+		}
+		for _, target := range []string{"/admin/secret", "/public/../admin/secret", "/%2e%2e/admin/secret", "/public/%2E./admin/secret"} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusForbidden, resp.StatusCode(), target)
+		}
+		// Kept as routed, an escaped slash or an empty segment would be read
+		// as another path by an upstream that decodes or merges: refused.
+		for _, target := range []string{"/public/..%2Fadmin/secret", "/public%2F..%2Fadmin", "//admin/secret", "/public//x"} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), target)
+		}
+	})
+
+	t.Run("unescape path", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New(fiber.Config{UnescapePath: true})
+		app.Use("/admin", forbid)
+		app.Use(Balancer(Config{Servers: []string{addr}}))
+
+		for target, want := range map[string]string{
+			"/public/a%2Fb":         "/public/a/b",
+			"/public/%41%20b?x=%2F": "/public/A%20b?x=%2F",
+		} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+			require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+		}
+		for _, target := range []string{"/public/..%2Fadmin/secret", "/public%2F..%2Fadmin/secret", "/%2e%2e/admin/secret"} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusForbidden, resp.StatusCode(), target)
+		}
+		// The decoded path keeps an empty segment, which is refused.
+		require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, "//admin/secret", "example.com").StatusCode())
+	})
+}
+
+// go test -run Test_Proxy_Balancer_ModifyRequestCanRetarget
+func Test_Proxy_Balancer_ModifyRequestCanRetarget(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	app := fiber.New()
+	app.Use("/set-path", Balancer(Config{
+		Servers: []string{addr},
+		ModifyRequest: func(c fiber.Ctx) error {
+			c.Request().URI().SetPath("/other")
+			return nil
+		},
+	}))
+	app.Use("/set-uri", Balancer(Config{
+		Servers: []string{addr},
+		ModifyRequest: func(c fiber.Ctx) error {
+			c.Request().SetRequestURI("/other?y=2")
+			return nil
+		},
+	}))
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/set-path?x=1", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, "/other?x=1", readBody(t, resp))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/set-uri?x=1", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, "/other?y=2", readBody(t, resp))
+}
+
+// go test -run Test_Proxy_Balancer_RestoresRequestLine
+func Test_Proxy_Balancer_RestoresRequestLine(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	app := fiber.New()
+	app.Use(func(c fiber.Ctx) error {
+		err := c.Next()
+		require.Equal(t, "/public/%41?x=%2F", c.OriginalURL())
+		return err
+	})
+	app.Use(Balancer(Config{Servers: []string{addr}}))
+
+	resp := rawRequest(t, app, "/public/%41?x=%2F", "example.com")
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Equal(t, "/public/A?x=%2F", string(resp.Body()))
+}
+
+// go test -run Test_Proxy_Balancer_RejectsHostUserinfo
+func Test_Proxy_Balancer_RejectsHostUserinfo(t *testing.T) {
+	t.Parallel()
+
+	var hits atomic.Int32
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		hits.Add(1)
+		return c.SendString(c.Get(fiber.HeaderAuthorization))
+	})
+
+	app := fiber.New()
+	app.Use(Balancer(Config{Servers: []string{addr}}))
+
+	resp := rawRequest(t, app, "/", "svc:pw@"+addr)
+	require.Equal(t, fiber.StatusBadRequest, resp.StatusCode())
+	require.Equal(t, int32(0), hits.Load(), "the upstream must not see the request")
+
+	resp = rawRequest(t, app, "/", addr)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Empty(t, string(resp.Body()), "no Authorization header is forged")
+	require.Equal(t, int32(1), hits.Load())
+}
+
+// go test -run Test_Proxy_Balancer_RejectsNonOriginServer
+func Test_Proxy_Balancer_RejectsNonOriginServer(t *testing.T) {
+	t.Parallel()
+
+	for _, server := range []string{
+		"http://127.0.0.1:1/api",
+		"http://127.0.0.1:1/api/",
+		"127.0.0.1:1/api",
+		"http://svc:pw@127.0.0.1:1",
+		"http://127.0.0.1:1?x=1",
+		"http://127.0.0.1:1?",
+		"http://127.0.0.1:1#frag",
+	} {
+		require.PanicsWithError(t, ErrUpstreamNotOrigin.Error()+": "+strconv.Quote(server), func() {
+			Balancer(Config{Servers: []string{server}})
+		}, server)
+	}
+
+	require.NotPanics(t, func() {
+		Balancer(Config{Servers: []string{"http://127.0.0.1:1", "http://127.0.0.1:1/", "127.0.0.1:1", "https://[::1]:1"}})
+	})
+}
+
+// go test -run Test_Proxy_DomainForward_ForwardsRoutedPath
+func Test_Proxy_DomainForward_ForwardsRoutedPath(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	t.Run("upstream with a path prefix", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use("/admin", forbid)
+		app.Use(DomainForward("example.com", "http://"+addr+"/api/"))
+
+		for target, want := range map[string]string{
+			"/../internal":     "/api/internal",
+			"/%2e%2e/internal": "/api/internal",
+			"/x/%41?q=%2F&y=1": "/api/x/A?q=%2F&y=1",
+		} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+			require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+		}
+		resp := rawRequest(t, app, "/%2e%2e/admin/secret", "example.com")
+		require.Equal(t, fiber.StatusForbidden, resp.StatusCode())
+		for _, target := range []string{"//internal", "/..%2Finternal", "/public/..%2Fadmin/secret"} {
+			require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), target)
+		}
+	})
+
+	t.Run("plain upstream", func(t *testing.T) {
+		t.Parallel()
+		app := fiber.New()
+		app.Use("/admin", forbid)
+		app.Use(DomainForward("example.com", "http://"+addr))
+
+		for target, want := range map[string]string{
+			"/a/../public/%zz?x=1": "/public/%25zz?x=1",
+			"/public/a%3Ab":        "/public/a%3Ab",
+		} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+			require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+		}
+		resp := rawRequest(t, app, "/public/../admin/secret", "example.com")
+		require.Equal(t, fiber.StatusForbidden, resp.StatusCode())
+		for _, target := range []string{"//admin/secret", "/public/..%2Fadmin/secret"} {
+			require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), target)
+		}
+	})
+}
+
+// go test -run Test_Proxy_BalancerForward_ForwardsRoutedPath
+func Test_Proxy_BalancerForward_ForwardsRoutedPath(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	app := fiber.New()
+	app.Use("/admin", forbid)
+	app.Use(BalancerForward([]string{"http://" + addr + "/api/"}))
+
+	for target, want := range map[string]string{
+		"/../internal":  "/api/internal",
+		"/x/%41?q=%2F":  "/api/x/A?q=%2F",
+		"/public/a%3Ab": "/api/public/a%3Ab",
+	} {
+		resp := rawRequest(t, app, target, "example.com")
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+		require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+	}
+	resp := rawRequest(t, app, "/%2e%2e/admin/secret", "example.com")
+	require.Equal(t, fiber.StatusForbidden, resp.StatusCode())
+	for _, target := range []string{"//internal", "/public/..%2Fadmin/secret"} {
+		require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), target)
+	}
+}
+
+// Test_Proxy_RejectsEncodedSeparator pins that a routed path an upstream could
+// read as another path is refused by every forwarding handler rather than
+// forwarded: an upstream that decodes "%2F" into a separator or merges "//"
+// before it matches routes, as a net/http file server or a fasthttp server
+// does, would serve "/admin/secret.txt" for each refused target although no
+// middleware on "/admin" ran. An escape of another reserved character is
+// forwarded as sent.
+func Test_Proxy_RejectsEncodedSeparator(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	handlers := map[string]func() fiber.Handler{
+		"Balancer":        func() fiber.Handler { return Balancer(Config{Servers: []string{addr}}) },
+		"DomainForward":   func() fiber.Handler { return DomainForward("example.com", "http://"+addr) },
+		"BalancerForward": func() fiber.Handler { return BalancerForward([]string{"http://" + addr}) },
+	}
+	for name, handler := range handlers {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			app.Use("/admin", forbid)
+			app.Use(handler())
+
+			for _, target := range []string{
+				"/public/..%2Fadmin/secret.txt",
+				"/public/..%2fadmin/secret.txt",
+				"/admin%2Fsecret.txt",
+				"//admin/secret.txt",
+				// a separator to WHATWG URL parsers and IIS
+				"/admin\\secret.txt",
+				"/public/..\\admin/secret.txt",
+				"/public/..%5Cadmin/secret.txt",
+				"/public/..%5cadmin/secret.txt",
+				// a dot segment once a servlet container strips its parameters
+				"/public/..;/admin/secret.txt",
+				"/public/.;x/../..;jsessionid=1/admin/secret.txt",
+			} {
+				require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), target)
+			}
+
+			// A separator forged by a stray "%": routed as "..%2fadmin" when
+			// the router keeps the stray "%" as sent, and refused; routed as
+			// "..%252fadmin" when it writes the stray "%" as "%25", and
+			// forwarded as that literal name.
+			resp := rawRequest(t, app, "/public/..%%32fadmin/secret.txt", "example.com")
+			switch resp.StatusCode() {
+			case fiber.StatusBadRequest:
+			case fiber.StatusOK:
+				require.Equal(t, "/public/..%252fadmin/secret.txt", string(resp.Body()))
+			default:
+				t.Fatalf("unexpected status %d", resp.StatusCode())
+			}
+
+			resp = rawRequest(t, app, "/files/a%20b%3Fc?x=%2F", "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode())
+			require.Equal(t, "/files/a%20b%3Fc?x=%2F", string(resp.Body()))
+		})
+	}
+}
+
+// Test_Proxy_EscapesRawBytes pins that a byte a path may not carry raw (RFC
+// 3986 Section 3.3) reaches the upstream as its escape, as fasthttp's
+// normalizing writer sent it before the proxy forwarded the routed path: an
+// upstream such as Tomcat answers 400 to a raw "|" or "{", and a raw byte of
+// UTF-8 is not a valid request line. The sub-delims, ":" and "@" stay raw.
+func Test_Proxy_EscapesRawBytes(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	handlers := map[string]func() fiber.Handler{
+		"Balancer":        func() fiber.Handler { return Balancer(Config{Servers: []string{addr}}) },
+		"DomainForward":   func() fiber.Handler { return DomainForward("example.com", "http://"+addr) },
+		"BalancerForward": func() fiber.Handler { return BalancerForward([]string{"http://" + addr}) },
+	}
+	for name, handler := range handlers {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			app := fiber.New()
+			app.Use(handler())
+			for target, want := range map[string]string{
+				"/a|b{c}d":               "/a%7Cb%7Bc%7Dd",
+				"/q\"^<>`":               "/q%22%5E%3C%3E%60",
+				"/\xc3\xbcber?x=1":       "/%C3%BCber?x=1",
+				"/keep!$&'()*+,;=:@/end": "/keep!$&'()*+,;=:@/end",
+			} {
+				resp := rawRequest(t, app, target, "example.com")
+				require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+				require.Equal(t, want, string(resp.Body()), "upstream target for %q", target)
+			}
+		})
+	}
+}
+
+// go test -run Test_Proxy_Do_UserClientForwardsTargetAsGiven
+func Test_Proxy_Do_UserClientForwardsTargetAsGiven(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	// A client left with path normalization on would decode "%2F", merge
+	// "//" and resolve ".." on the way out, and the upstream would see
+	// "/a/b/d?q=%2F" for a target the handler never wrote.
+	target := "http://" + addr + "/a%2Fb//c/..%2Fd?q=%2F"
+	app := fiber.New()
+	app.Get("/", func(c fiber.Ctx) error {
+		return Do(c, target, &fasthttp.Client{})
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.Equal(t, "/a%2Fb//c/..%2Fd?q=%2F", readBody(t, resp))
+}
+
+// Test_Proxy_Balancer_RejectsAuthorityTarget pins that a routed target
+// fasthttp would read as an authority never reaches the upstream: one that
+// begins with "//" and holds "://", here built by ".." resolution so that the
+// raw request line never held it and the server never split it, or one that
+// arrives without a Host header. Set as the request URI, fasthttp would take
+// the upstream's Host and a Basic credential from it, over the ones the
+// application pinned.
+func Test_Proxy_Balancer_RejectsAuthorityTarget(t *testing.T) {
+	t.Parallel()
+
+	var hits atomic.Int32
+	target := fiber.New()
+	target.Use(func(c fiber.Ctx) error {
+		hits.Add(1)
+		return c.SendString(c.OriginalURL() + "|" + string(c.Request().Header.Host()) + "|" + c.Get(fiber.HeaderAuthorization))
+	})
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() {
+		ln.Close() //nolint:errcheck // It is fine to ignore the error here
+	})
+	startServer(target, ln)
+	addr := ln.Addr().String()
+
+	for _, unescape := range []bool{false, true} {
+		app := fiber.New(fiber.Config{UnescapePath: unescape})
+		app.Use(Balancer(Config{
+			Servers: []string{addr},
+			ModifyRequest: func(c fiber.Ctx) error {
+				c.Request().Header.SetHost("backend.internal")
+				c.Request().Header.Set(fiber.HeaderAuthorization, "Bearer pinned")
+				return nil
+			},
+		}))
+
+		before := hits.Load()
+		// Neither raw line holds "://": fasthttp's server would read one that
+		// did as the absolute form and split the host off before routing.
+		rejected := []string{
+			"//u:pw@evil.example/a:/x/..//b",
+			"//u:pw@evil.example/a:/x/%2E%2E//b",
+		}
+		if unescape {
+			rejected = append(rejected, "//u:pw@evil.example/a%3A%2F%2Fb")
+		}
+		for _, tgt := range rejected {
+			resp := rawRequest(t, app, tgt, "example.com")
+			require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), "UnescapePath=%v %s", unescape, tgt)
+		}
+		// Without a Host header fasthttp reads the authority out of any
+		// target that begins with "//"; the ".." keeps the server from
+		// reading it out of the raw line first.
+		resp := rawRequest(t, app, "/x/..//u:pw@evil.example/y", "")
+		require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), "UnescapePath=%v, no Host", unescape)
+		require.Equal(t, before, hits.Load(), "UnescapePath=%v: the upstream must not see the request", unescape)
+
+		// The same characters in a path with no empty segment are forwarded
+		// as the router matched them, under the identity the application
+		// pinned.
+		resp = rawRequest(t, app, "/u:pw@evil.example/a:/b", "example.com")
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), "UnescapePath=%v", unescape)
+		require.Equal(t, "/u:pw@evil.example/a:/b|backend.internal|Bearer pinned", string(resp.Body()), "UnescapePath=%v", unescape)
+	}
+}
+
+// echoIdentity starts an upstream that answers with the request line it
+// received, the Host it was addressed to and the Authorization it carried,
+// and returns its address.
+func echoIdentity(t *testing.T) string {
+	t.Helper()
+
+	target := fiber.New()
+	target.Use(func(c fiber.Ctx) error {
+		return c.SendString(c.OriginalURL() + "|" + string(c.Request().Header.Host()) + "|" + c.Get(fiber.HeaderAuthorization))
+	})
+
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() {
+		ln.Close() //nolint:errcheck // It is fine to ignore the error here
+	})
+	startServer(target, ln)
+
+	return ln.Addr().String()
+}
+
+// pinIdentity is a ModifyRequest that sets the Host and Authorization the
+// upstream must see whatever the request carried.
+func pinIdentity(c fiber.Ctx) error {
+	c.Request().Header.SetHost("backend.internal")
+	c.Request().Header.Set(fiber.HeaderAuthorization, "Bearer pinned")
+	return nil
+}
+
+// Test_Proxy_Balancer_RootsUnrootedPath pins that a path override without a
+// leading slash, as a rewrite of "/go/*" to "$1" produces, is handled as a
+// path and not as the absolute URL a request line reads it as, which would
+// have replaced the pinned Host and credential: rooted, it is forwarded under
+// the pinned identity, or refused when the rooted path holds an empty
+// segment, as "/http://u:pw@evil.example/x" does.
+func Test_Proxy_Balancer_RootsUnrootedPath(t *testing.T) {
+	t.Parallel()
+
+	addr := echoIdentity(t)
+	balancer := Balancer(Config{Servers: []string{addr}, ModifyRequest: pinIdentity})
+	app := fiber.New()
+	app.Get("/go/*", func(c fiber.Ctx) error {
+		c.Path(c.Params("*"))
+		return balancer(c)
+	})
+
+	resp := rawRequest(t, app, "/go/u:pw@evil.example/x", "example.com")
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Equal(t, "/u:pw@evil.example/x|backend.internal|Bearer pinned", string(resp.Body()))
+
+	require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, "/go/http://u:pw@evil.example/x", "example.com").StatusCode())
+}
+
+// Test_Proxy_Balancer_CustomClientKeepsTarget pins that a host client the
+// caller built is told to keep the request line as given: left normalizing it
+// would decode "%2F" into a separator and merge "//" on the way out, and the
+// upstream would see a path no middleware had matched.
+func Test_Proxy_Balancer_CustomClientKeepsTarget(t *testing.T) {
+	t.Parallel()
+
+	addr := echoTarget(t)
+	hc := &fasthttp.HostClient{Addr: addr, NoDefaultUserAgentHeader: true}
+	app := fiber.New()
+	app.Use("/admin", forbid)
+	app.Use(Balancer(Config{Client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{hc}, Timeout: time.Second}}))
+
+	require.True(t, hc.DisablePathNormalizing)
+	for _, target := range []string{"/public/a%3Ab", "/a%20b?q=%2F"} {
+		resp := rawRequest(t, app, target, "example.com")
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+		require.Equal(t, target, string(resp.Body()), target)
+	}
+	for _, target := range []string{"/public/..%2Fadmin/secret", "//admin/secret"} {
+		require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), target)
+	}
+}
+
+// opaqueClient is a BalancingClient the proxy cannot configure. It forwards
+// through a host client left normalizing, as a caller's own implementation
+// might.
+type opaqueClient struct {
+	hc *fasthttp.HostClient
+}
+
+func (o *opaqueClient) DoDeadline(req *fasthttp.Request, resp *fasthttp.Response, deadline time.Time) error {
+	return o.hc.DoDeadline(req, resp, deadline)
+}
+
+func (o *opaqueClient) PendingRequests() int {
+	return o.hc.PendingRequests()
+}
+
+// Test_Proxy_Balancer_OpaqueClientFailsClosed pins that behind a
+// BalancingClient the proxy cannot keep from normalizing, a target that
+// normalization would change is refused rather than sent as another path,
+// while one it leaves alone, including the escapes the proxy writes for raw
+// bytes, is forwarded.
+func Test_Proxy_Balancer_OpaqueClientFailsClosed(t *testing.T) {
+	t.Parallel()
+
+	addr := echoTarget(t)
+	app := fiber.New()
+	app.Use(Balancer(Config{Client: &fasthttp.LBClient{
+		Clients: []fasthttp.BalancingClient{&opaqueClient{hc: &fasthttp.HostClient{Addr: addr}}},
+		Timeout: time.Second,
+	}}))
+
+	// Normalization would decode "%2F", "%3B" and "%40" into the bytes they
+	// name and merge "//".
+	for _, target := range []string{"/public/..%2Fadmin/secret", "//admin/secret", "/public/..%3B/admin", "/a%40b"} {
+		resp := rawRequest(t, app, target, "example.com")
+		require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), target)
+	}
+	for target, want := range map[string]string{
+		"/plain/path?q=%2F": "/plain/path?q=%2F",
+		"/a%20b":            "/a%20b",
+		"/caf\xc3\xa9":      "/caf%C3%A9",
+		"/a|b%25":           "/a%7Cb%25",
+	} {
+		resp := rawRequest(t, app, target, "example.com")
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+		require.Equal(t, want, string(resp.Body()), target)
+	}
+}
+
+// requireForgedEscapeRefused checks a response to
+// "/static/%%370rivate/secret.txt", an escape of an unreserved character
+// forged by a stray "%", which must never reach the upstream as something it
+// would decode into the guarded name. What the router hands the proxy depends
+// on how it spells a stray "%": kept as sent, the request is routed as
+// "/static/%70rivate/secret.txt" and refused; written as "%25", it is routed
+// as "/static/%2570rivate/secret.txt", holds no escape of an unreserved
+// character, and is forwarded as that literal name, prefix included.
+func requireForgedEscapeRefused(t *testing.T, resp *fasthttp.Response, prefix string) {
+	t.Helper()
+	switch resp.StatusCode() {
+	case fiber.StatusBadRequest:
+	case fiber.StatusOK:
+		require.Equal(t, prefix+"/static/%2570rivate/secret.txt", string(resp.Body()))
+	default:
+		t.Fatalf("unexpected status %d", resp.StatusCode())
+	}
+}
+
+func Test_Proxy_Balancer_RejectsForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	addr := echoTarget(t)
+	app := fiber.New()
+	app.Use("/static/private", forbid)
+	app.Use(Balancer(Config{Servers: []string{addr}}))
+
+	requireForgedEscapeRefused(t, rawRequest(t, app, "/static/%%370rivate/secret.txt", "example.com"), "")
+}
+
+func Test_Proxy_DomainForward_RejectsForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	addr := echoTarget(t)
+	app := fiber.New()
+	app.Use("/static/private", forbid)
+	app.Use(DomainForward("example.com", "http://"+addr+"/api/"))
+
+	requireForgedEscapeRefused(t, rawRequest(t, app, "/static/%%370rivate/secret.txt", "example.com"), "/api")
+}
+
+func Test_Proxy_BalancerForward_RejectsForgedEscape(t *testing.T) {
+	t.Parallel()
+
+	addr := echoTarget(t)
+	app := fiber.New()
+	app.Use("/static/private", forbid)
+	app.Use(BalancerForward([]string{"http://" + addr}))
+
+	requireForgedEscapeRefused(t, rawRequest(t, app, "/static/%%370rivate/secret.txt", "example.com"), "")
+}
+
+// Test_Proxy_Balancer_AllowAmbiguousSlashes pins the opt-out: with
+// SecurityPolicy.AllowAmbiguousSlashes, Balancer forwards an escaped slash and
+// an empty segment as routed, for an upstream that keeps them, and still
+// refuses a forged escape, a backslash and a dot segment carrying parameters.
+func Test_Proxy_Balancer_AllowAmbiguousSlashes(t *testing.T) {
+	t.Parallel()
+	addr := echoTarget(t)
+
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	policy.AllowAmbiguousSlashes = true
+	app := fiber.New()
+	app.Use(Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy}))
+
+	for _, target := range []string{"/api/projects/group%2Fname", "/bucket/key//with/empty", "/a%2fb"} {
+		resp := rawRequest(t, app, target, "example.com")
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+		require.Equal(t, strings.ReplaceAll(target, "%2f", "%2F"), string(resp.Body()), target)
+	}
+	for _, target := range []string{"/x/%%370rivate", "/admin\\secret", "/a/..%5Cb", "/a/..;/b"} {
+		resp := rawRequest(t, app, target, "example.com")
+		if target == "/x/%%370rivate" && resp.StatusCode() == fiber.StatusOK {
+			// a router that writes the stray "%" as "%25" forwards the literal name
+			require.Equal(t, "/x/%2570rivate", string(resp.Body()))
+			continue
+		}
+		require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), target)
+	}
+}
+
+// Test_Proxy_Forward_AllowAmbiguousSlashes pins the same opt-out for
+// DomainForward and BalancerForward, which follow the global policy.
+func Test_Proxy_Forward_AllowAmbiguousSlashes(t *testing.T) {
+	// Not parallel: installs a global security policy.
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	policy.AllowAmbiguousSlashes = true
+	withSecurityPolicyForTest(t, policy)
+	addr := echoTarget(t)
+
+	handlers := map[string]fiber.Handler{
+		"DomainForward":   DomainForward("example.com", "http://"+addr),
+		"BalancerForward": BalancerForward([]string{"http://" + addr}),
+	}
+	for name, handler := range handlers {
+		app := fiber.New()
+		app.Use(handler)
+		for _, target := range []string{"/api/projects/group%2Fname", "/bucket/key//with/empty"} {
+			resp := rawRequest(t, app, target, "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode(), "%s %s", name, target)
+			require.Equal(t, target, string(resp.Body()), "%s %s", name, target)
+		}
+		for _, target := range []string{"/admin\\secret", "/a/..;/b"} {
+			require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), "%s %s", name, target)
+		}
+	}
+}
diff --git a/middleware/rewrite/rewrite_test.go b/middleware/rewrite/rewrite_test.go
index 7637a23d5e7..4d0e802ee31 100644
--- a/middleware/rewrite/rewrite_test.go
+++ b/middleware/rewrite/rewrite_test.go
@@ -1,10 +1,12 @@
 package rewrite
 
 import (
+	"bufio"
 	"context"
 	"fmt"
 	"io"
 	"net/http"
+	"strings"
 	"testing"
 
 	"github.com/gofiber/fiber/v3"
@@ -611,3 +613,69 @@ func Test_Rewrite_TwoDigitCaptures(t *testing.T) {
 	require.NoError(t, err)
 	require.Equal(t, "k j a", string(body))
 }
+
+// rewrittenRaw hands app a request line exactly as written and reports the
+// path the handler behind the rewrite saw.
+func rewrittenRaw(t *testing.T, app *fiber.App, target string) string {
+	t.Helper()
+
+	var req fasthttp.Request
+	raw := fiber.MethodGet + " " + target + " HTTP/1.1\r\nHost: example.com\r\n\r\n"
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+
+	var fctx fasthttp.RequestCtx
+	fctx.Init(&req, nil, nil)
+	app.Handler()(&fctx)
+	require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
+	return string(fctx.Response.Body())
+}
+
+// Test_Rewrite_UnescapePathDecodesOnce pins that a capture is not decoded a
+// second time when the rewritten path is set: with UnescapePath the router
+// decoded "/files/%252e%252e/secret" into "/files/%2e%2e/secret", and the
+// "%2e%2e" carried into "/public/$1" has to stay that name rather than
+// become ".." and resolve out of "/public/".
+func Test_Rewrite_UnescapePathDecodesOnce(t *testing.T) {
+	t.Parallel()
+
+	for _, unescape := range []bool{false, true} {
+		app := fiber.New(fiber.Config{UnescapePath: unescape})
+		app.Use(New(Config{
+			RuleList: []Rule{{From: "/files/*", To: "/public/$1"}},
+		}))
+		app.Use(func(c fiber.Ctx) error {
+			return c.SendString(c.Path())
+		})
+
+		for target, want := range map[string]string{
+			"/files/a/b":                "/public/a/b",
+			"/files/%252e%252e/secret":  "/public/%2e%2e/secret",
+			"/files/..%252Fsecret":      "/public/..%2Fsecret",
+			"/files/%41%20b":            "/public/A b",
+			"/files/a%3Fb%23c":          "/public/a?b#c",
+			"/files/caf%C3%A9":          "/public/café",
+			"/files/%2e%2e/secret":      "/secret",
+			"/files/%252e%252e/secret/": "/public/%2e%2e/secret/",
+		} {
+			if !unescape {
+				// Without UnescapePath the path keeps its escapes, and a capture
+				// is carried as is.
+				switch target {
+				case "/files/%41%20b":
+					want = "/public/A%20b"
+				case "/files/a%3Fb%23c":
+					want = "/public/a%3Fb%23c"
+				case "/files/caf%C3%A9":
+					want = "/public/caf%C3%A9"
+				case "/files/%252e%252e/secret":
+					want = "/public/%252e%252e/secret"
+				case "/files/..%252Fsecret":
+					want = "/public/..%252Fsecret"
+				case "/files/%252e%252e/secret/":
+					want = "/public/%252e%252e/secret/"
+				}
+			}
+			require.Equal(t, want, rewrittenRaw(t, app, target), "UnescapePath=%v %s", unescape, target)
+		}
+	}
+}
diff --git a/middleware/static/static_test.go b/middleware/static/static_test.go
index b365bf88d75..79eb79b6fd0 100644
--- a/middleware/static/static_test.go
+++ b/middleware/static/static_test.go
@@ -1314,12 +1314,11 @@ func Test_SanitizePath(t *testing.T) {
 		{name: "root", input: []byte("/"), expectPath: "/"},
 		{name: "decoded space", input: []byte("/foo bar/baz.txt"), expectPath: "/foo bar/baz.txt"},
 		{name: "plus literal", input: []byte("/foo+bar/baz.txt"), expectPath: "/foo+bar/baz.txt"},
-		{name: "dots in names", input: []byte("/.well-known/..x/y.../z."), expectPath: "/.well-known/..x/y.../z."},
+		{name: "dots in names", input: []byte("/.well-known/..x/y..z/a.b"), expectPath: "/.well-known/..x/y..z/a.b"},
 		// escapes the router left encoded stay encoded for consistent authorization
 		{name: "encoded space", input: []byte("/foo%20bar/baz.txt"), expectPath: "/foo%20bar/baz.txt"},
 		{name: "encoded reserved character", input: []byte("/photo%402x.png"), expectPath: "/photo%402x.png"},
 		{name: "lowercase hex digits", input: []byte("/a%7bb%7d.txt"), expectPath: "/a%7bb%7d.txt"},
-		{name: "encoded unreserved characters", input: []byte("/%70rivate/%7Efile.txt"), expectPath: "/private/~file.txt"},
 		{name: "encoded percent sign", input: []byte("/100%25.txt"), expectPath: "/100%25.txt"},
 		{name: "percent sign stays encoded", input: []byte("/%2570rivate/secret.txt"), expectPath: "/%2570rivate/secret.txt"},
 		{name: "double encoded traversal stays a name", input: []byte("/%252e%252e/bar.txt"), expectPath: "/%252e%252e/bar.txt"},
@@ -1387,6 +1386,11 @@ func Test_SanitizePath_Error(t *testing.T) {
 		{name: "malformed escape", input: []byte("/a%zzb.txt")},
 		{name: "truncated escape", input: []byte("/foo%2")},
 		{name: "trailing percent", input: []byte("/foo%")},
+		// the router decodes every escape of an unreserved character, so one that
+		// reaches here was forged from a stray '%' and must not be decoded again
+		{name: "forged unreserved escape", input: []byte("/%70rivate/secret.txt")},
+		{name: "forged unreserved tilde", input: []byte("/%7Efile.txt")},
+		{name: "forged dot escape", input: []byte("/%2egit/config")},
 		// a decoded slash, a backslash or a control character cannot be part of a name
 		{name: "null byte", input: []byte("/foo/bar.txt\x00")},
 		{name: "encoded null byte", input: []byte("/foo/bar.txt%00")},
@@ -1430,6 +1434,44 @@ func Test_HasUnsafeSegment(t *testing.T) {
 	}
 }
 
+func Test_HasTrailingDotOrSpaceSegment(t *testing.T) {
+	t.Parallel()
+
+	for input, want := range map[string]bool{
+		"/":              false,
+		"/foo/bar.txt":   false,
+		"/.well-known/x": false,
+		"/..x/y":         false,
+		"/a.b/c":         false,
+		"/foo/":          false,
+		"/foo./bar":      true,
+		"/foo /bar":      true,
+		"/foo.":          true,
+		"/foo ":          true,
+		"/foo./":         true,
+		"/foo/bar. ":     true,
+	} {
+		require.Equal(t, want, hasTrailingDotOrSpaceSegment([]byte(input)), "input=%q", input)
+	}
+}
+
+// Test_SanitizePath_TrailingDotOrSpace pins that a segment ending in a dot or
+// a space names an ordinary file everywhere except Windows, which strips both
+// when it opens a file and would turn "private." into the guarded "private".
+func Test_SanitizePath_TrailingDotOrSpace(t *testing.T) {
+	t.Parallel()
+
+	for _, input := range []string{"/private./secret.txt", "/private /secret.txt", "/y.../z.", "/foo. /"} {
+		got, err := sanitizePath([]byte(input), nil, true)
+		if runtime.GOOS == winOS {
+			require.ErrorIs(t, err, ErrInvalidPath, "input=%q", input)
+			continue
+		}
+		require.NoError(t, err, "input=%q", input)
+		require.Equal(t, input, string(got), "input=%q", input)
+	}
+}
+
 // Test_Static_ServesRoutedPath pins that the file server resolves the path
 // the router matched, so a guard on "/static/private" covers the spellings the
 // router normalizes, that what the router leaves encoded remains encoded, and
@@ -1577,6 +1619,105 @@ func Test_Static_RawBackslashIsNotASeparator(t *testing.T) {
 	}
 }
 
+// Test_Static_ForgedEscapeCannotBypassGuard pins that a stray "%" the router
+// keeps literally cannot line up with the following bytes into an escape the
+// file server decodes a second time, reaching a guarded file the router never
+// matched. "%%370rivate" and "%7%30rivate" both normalize to "%70rivate", which
+// the guard on "/static/private" does not cover, so the file server must not
+// decode either to "private". Under UnescapePath the router decodes nothing
+// past its single pass, so the same spellings stay literal too. httptest
+// rejects these spellings, so the request line is set by hand.
+func Test_Static_ForgedEscapeCannotBypassGuard(t *testing.T) {
+	t.Parallel()
+
+	root := t.TempDir()
+	require.NoError(t, os.Mkdir(filepath.Join(root, "private"), 0o750))
+	require.NoError(t, os.WriteFile(filepath.Join(root, "private", "secret.txt"), []byte("SECRET"), 0o600))
+
+	// app.Test writes the URL's opaque form verbatim
+	rawRequest := func(target string) *http.Request {
+		req := httptest.NewRequest(fiber.MethodGet, "/static/", http.NoBody)
+		req.URL.Opaque = target
+		return req
+	}
+	serve := func(app *fiber.App, target string) (int, string) {
+		resp, err := app.Test(rawRequest(target))
+		require.NoError(t, err, "app.Test(req)")
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		return resp.StatusCode, string(body)
+	}
+
+	// both spellings normalize to "/static/%70rivate/secret.txt"
+	forged := []string{
+		"/static/%%370rivate/secret.txt",
+		"/static/%7%30rivate/secret.txt",
+	}
+
+	for _, unescape := range []bool{false, true} {
+		for _, mount := range []string{"wildcard", "prefix"} {
+			app := fiber.New(fiber.Config{UnescapePath: unescape})
+			app.Use("/static/private", func(c fiber.Ctx) error {
+				return c.SendStatus(fiber.StatusForbidden)
+			})
+			if mount == "wildcard" {
+				app.Get("/static/*", New(root, Config{CacheDuration: -1}))
+			} else {
+				app.Use("/static", New(root, Config{CacheDuration: -1}))
+			}
+
+			// the spelling the router does match the guard on still returns 403
+			status, _ := serve(app, "/static/private/secret.txt")
+			require.Equal(t, fiber.StatusForbidden, status, "unescape=%v mount=%s", unescape, mount)
+
+			for _, target := range forged {
+				status, body := serve(app, target)
+				require.Equal(t, fiber.StatusNotFound, status, "unescape=%v mount=%s target=%s", unescape, mount, target)
+				require.NotContains(t, body, "SECRET", "unescape=%v mount=%s target=%s", unescape, mount, target)
+			}
+		}
+	}
+}
+
+// Test_Static_TrailingDotOrSpaceCannotBypassGuard pins that "private." and
+// "private " never open the guarded "private": Windows strips a trailing dot or
+// space from a path component, so the file server rejects such a segment there,
+// and everywhere else no such directory exists. Both answer 404 while the
+// spelling the guard covers stays 403.
+func Test_Static_TrailingDotOrSpaceCannotBypassGuard(t *testing.T) {
+	t.Parallel()
+
+	root := t.TempDir()
+	require.NoError(t, os.Mkdir(filepath.Join(root, "private"), 0o750))
+	require.NoError(t, os.WriteFile(filepath.Join(root, "private", "secret.txt"), []byte("SECRET"), 0o600))
+
+	for _, unescape := range []bool{false, true} {
+		app := fiber.New(fiber.Config{UnescapePath: unescape})
+		app.Use("/static/private", func(c fiber.Ctx) error {
+			return c.SendStatus(fiber.StatusForbidden)
+		})
+		app.Get("/static/*", New(root, Config{CacheDuration: -1}))
+
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/static/private/secret.txt", http.NoBody))
+		require.NoError(t, err)
+		require.Equal(t, fiber.StatusForbidden, resp.StatusCode, "unescape=%v", unescape)
+
+		for _, target := range []string{
+			"/static/private./secret.txt",
+			"/static/private.../secret.txt",
+			"/static/private%20/secret.txt",
+			"/static/private%20./secret.txt",
+		} {
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, target, http.NoBody))
+			require.NoError(t, err, "app.Test(req)")
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusNotFound, resp.StatusCode, "unescape=%v target=%s", unescape, target)
+			require.NotContains(t, string(body), "SECRET", "unescape=%v target=%s", unescape, target)
+		}
+	}
+}
+
 // Test_Static_MalformedEscapeIsNotAName pins that a file whose name holds a
 // percent sign has one spelling: "%zz" is not an escape, so the router keeps
 // it apart from "%25zz" and the file server does not open the file it would

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path internal/wiretarget/wiretarget_test.go --path middleware/adaptor/adaptor_test.go --path middleware/adaptor/routed_test.go --path middleware/proxy/coverage_test.go --path middleware/proxy/security_test.go --path middleware/proxy/target_test.go --path middleware/rewrite/rewrite_test.go --path middleware/static/static_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/wiretarget ./middleware/adaptor ./middleware/proxy ./middleware/rewrite ./middleware/static')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/wiretarget ./middleware/adaptor ./middleware/proxy ./middleware/rewrite ./middleware/static' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
