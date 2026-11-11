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
for f in hugolib/rebuild_test.go hugolib/resource_chain_test.go modules/config_test.go resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go resources/resource_transformers/tocss/scss/client_test.go resources/resource_transformers/tocss/scss/scss_integration_test.go tpl/resources/resources_integration_test.go; do if git cat-file -e 471d0fb3ef05aeb5c2c522719c081514ae904366:"$f" 2>/dev/null; then git checkout 471d0fb3ef05aeb5c2c522719c081514ae904366 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 471d0fb3ef05aeb5c2c522719c081514ae904366 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/hugolib/rebuild_test.go b/hugolib/rebuild_test.go
index 4f0089239d3..27998388887 100644
--- a/hugolib/rebuild_test.go
+++ b/hugolib/rebuild_test.go
@@ -13,7 +13,6 @@ import (
 	"github.com/gohugoio/hugo/htesting"
 	"github.com/gohugoio/hugo/markup/asciidocext"
 	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/dartsass"
-	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/scss"
 )
 
 const rebuildFilesSimple = `
@@ -1813,10 +1812,6 @@ Home.
 		})
 	}
 
-	if scss.Supports() {
-		runTest("libsass")
-	}
-
 	if dartsass.Supports() {
 		runTest("dartsass")
 	}
diff --git a/hugolib/resource_chain_test.go b/hugolib/resource_chain_test.go
index b886d0258a5..85edff586a5 100644
--- a/hugolib/resource_chain_test.go
+++ b/hugolib/resource_chain_test.go
@@ -22,7 +22,7 @@ import (
 	"strings"
 	"testing"
 
-	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/scss"
+	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/dartsass"
 )
 
 func TestResourceChainBasic(t *testing.T) {
@@ -273,7 +273,7 @@ func TestResourceChains(t *testing.T) {
 		files     string
 		assert    func(b *IntegrationTestBuilder)
 	}{
-		{"tocss", func() bool { return scss.Supports() }, `
+		{"tocss", func() bool { return dartsass.Supports() }, `
 -- hugo.toml --
 baseURL = "http://example.com/"
 -- content/_index.md --
@@ -332,7 +332,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -351,10 +351,10 @@ T4: Content: {{ len $scssCustomTargetString.Content }}|RelPermalink: {{ $scssCus
 T5: Content: {{ $sass.Content }}|T5 RelPermalink: {{ $sass.RelPermalink }}|
 T6: {{ $bundle1.Permalink }}
 `, func(b *IntegrationTestBuilder) {
-			b.AssertFileContent("public/index.html", `T1: Len Content: 24|RelPermalink: /scss/styles2.css|Permalink: http://example.com/scss/styles2.css|MediaType: text/css`)
+			b.AssertFileContent("public/index.html", `T1: Len Content: 23|RelPermalink: /scss/styles2.css|Permalink: http://example.com/scss/styles2.css|MediaType: text/css`)
 			b.AssertFileContent("public/index.html", `T2: Content: body{color:#333}|RelPermalink: /scss/styles2.min.css`)
-			b.AssertFileContent("public/index.html", `T3: Content: 24|RelPermalink: /styles/main.css|MediaType: text/css`)
-			b.AssertFileContent("public/index.html", `T4: Content: 24|RelPermalink: /styles/main.css|MediaType: text/css`)
+			b.AssertFileContent("public/index.html", `T3: Content: 23|RelPermalink: /styles/main.css|MediaType: text/css`)
+			b.AssertFileContent("public/index.html", `T4: Content: 23|RelPermalink: /styles/main.css|MediaType: text/css`)
 			b.AssertFileContent("public/index.html", `T5: Content: .content-navigation {`)
 			b.AssertFileContent("public/index.html", `T5 RelPermalink: /sass/styles3.css|`)
 			b.AssertFileContent("public/index.html", `T6: http://example.com/styles/bundle1.css`)
@@ -426,7 +426,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -519,7 +519,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -598,7 +598,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -703,7 +703,7 @@ T3: Content: {{ $combinedJs.Content }}|{{ $combinedJs.RelPermalink }}
 		  color: $color;
 		}
 		-- assets/sass/styles3.sass --
-		$color: #333;
+		$color: #333
 		
 		.content-navigation
 		  border-color: $color
@@ -779,7 +779,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -851,7 +851,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -925,7 +925,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -1006,7 +1006,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -1077,7 +1077,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -1161,7 +1161,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -1242,7 +1242,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
@@ -1311,7 +1311,7 @@ body {
   color: $color;
 }
 -- assets/sass/styles3.sass --
-$color: #333;
+$color: #333
 
 .content-navigation
   border-color: $color
diff --git a/modules/config_test.go b/modules/config_test.go
index 67ea08b153e..21e819fa24e 100644
--- a/modules/config_test.go
+++ b/modules/config_test.go
@@ -19,7 +19,6 @@ import (
 	"path/filepath"
 	"testing"
 
-	"github.com/gohugoio/hugo/common/hugo"
 	"github.com/gohugoio/hugo/common/loggers"
 	"github.com/gohugoio/hugo/common/version"
 
@@ -91,9 +90,7 @@ languages="en"
 		c.Assert(v056.Compare(hv.Max), qt.Equals, 1)
 		c.Assert(hv.Extended, qt.Equals, true)
 
-		if hugo.IsExtended {
-			c.Assert(hv.IsValid(), qt.Equals, true)
-		}
+		c.Assert(hv.IsValid(), qt.Equals, true)
 
 		c.Assert(mcfg.Workspace, qt.Equals, hugoWorkFilename)
 
diff --git a/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go b/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
index 9fcd4ccb288..80d3817db1e 100644
--- a/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
+++ b/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
@@ -835,3 +835,43 @@ allowRead = [".", ".."]
 		b.AssertFileContent("public/index.html", "PWN-SECRET")
 	})
 }
+
+// Issue 15405.
+func TestLibSassRemoved(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+disableKinds = ['page','section','rss','sitemap','taxonomy','term']
+-- assets/scss/main.scss --
+body { color: red; }
+-- layouts/home.html --
+{{ $r := resources.Get "scss/main.scss" | css.Sass (dict "transpiler" "libsass") }}
+T1: {{ $r.Content }}
+`
+
+	_, err := hugolib.TestE(t, files)
+	qt.Assert(t, err, qt.ErrorMatches, `(?s).*the libsass transpiler was removed in Hugo v0.170.0.*`)
+}
+
+// Issue 15405.
+func TestDefaultTranspiler(t *testing.T) {
+	t.Parallel()
+	if !dartsass.Supports() {
+		t.Skip()
+	}
+
+	files := `
+-- hugo.toml --
+disableKinds = ['page','section','rss','sitemap','taxonomy','term']
+-- assets/scss/main.scss --
+@use "sass:math";
+body { width: math.div(10px, 2); }
+-- layouts/home.html --
+{{ $r := resources.Get "scss/main.scss" | css.Sass (dict "outputStyle" "compressed") }}
+T1: {{ $r.Content }}|{{ hugo.IsExtended }}
+`
+
+	b := hugolib.Test(t, files)
+	b.AssertFileContent("public/index.html", "T1: body{width:5px}|false")
+}
diff --git a/resources/resource_transformers/tocss/scss/client_test.go b/resources/resource_transformers/tocss/scss/client_test.go
deleted file mode 100644
index 9dddd386965..00000000000
--- a/resources/resource_transformers/tocss/scss/client_test.go
+++ /dev/null
@@ -1,49 +0,0 @@
-// Copyright 2020 The Hugo Authors. All rights reserved.
-//
-// Licensed under the Apache License, Version 2.0 (the "License");
-// you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// http://www.apache.org/licenses/LICENSE-2.0
-//
-// Unless required by applicable law or agreed to in writing, software
-// distributed under the License is distributed on an "AS IS" BASIS,
-// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-// See the License for the specific language governing permissions and
-// limitations under the License.
-
-package scss
-
-import (
-	"testing"
-
-	qt "github.com/frankban/quicktest"
-)
-
-func TestReplaceRegularCSSImports(t *testing.T) {
-	c := qt.New(t)
-
-	scssWithImport := `
-	
-@import "moo";
-@import "regular.css";
-@import "moo";
-@import "another.css";
-@import "foo.scss";
-
-/* foo */`
-
-	scssWithoutImport := `
-@import "moo";
-/* foo */`
-
-	res, replaced := replaceRegularImportsIn(scssWithImport)
-	c.Assert(replaced, qt.Equals, true)
-	c.Assert(res, qt.Equals, "\n\t\n@import \"moo\";\n/* HUGO_IMPORT_START regular.css HUGO_IMPORT_END */\n@import \"moo\";\n/* HUGO_IMPORT_START another.css HUGO_IMPORT_END */\n@import \"foo.scss\";\n\n/* foo */")
-
-	res2, replaced2 := replaceRegularImportsIn(scssWithoutImport)
-	c.Assert(replaced2, qt.Equals, false)
-	c.Assert(res2, qt.Equals, scssWithoutImport)
-
-	reverted := replaceRegularImportsOut(res)
-	c.Assert(reverted, qt.Equals, scssWithImport)
-}
diff --git a/resources/resource_transformers/tocss/scss/scss_integration_test.go b/resources/resource_transformers/tocss/scss/scss_integration_test.go
deleted file mode 100644
index ac55504df59..00000000000
--- a/resources/resource_transformers/tocss/scss/scss_integration_test.go
+++ /dev/null
@@ -1,518 +0,0 @@
-// Copyright 2024 The Hugo Authors. All rights reserved.
-//
-// Licensed under the Apache License, Version 2.0 (the "License");
-// you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// http://www.apache.org/licenses/LICENSE-2.0
-//
-// Unless required by applicable law or agreed to in writing, software
-// distributed under the License is distributed on an "AS IS" BASIS,
-// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-// See the License for the specific language governing permissions and
-// limitations under the License.
-
-package scss_test
-
-import (
-	"os"
-	"path/filepath"
-	"runtime"
-	"strings"
-	"testing"
-
-	qt "github.com/frankban/quicktest"
-
-	"github.com/gohugoio/hugo/common/herrors"
-	"github.com/gohugoio/hugo/htesting"
-	"github.com/gohugoio/hugo/hugolib"
-	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/scss"
-)
-
-func TestTransformIncludePaths(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-	c := qt.New(t)
-
-	files := `
--- assets/scss/main.scss --
-@import "moo";
--- node_modules/foo/_moo.scss --
-@import "sub/bar";
-$moolor: $barcolor;
-
-moo {
-  color: $moolor;
-}
--- node_modules/foo/sub/_bar.scss --
-$barcolor: #fff;
--- hugo.toml --
--- layouts/home.html --
-{{ $cssOpts := (dict "includePaths" (slice "node_modules/foo") ) }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts  | minify  }}
-T1: {{ $r.Content }}
-	`
-
-	b := hugolib.Test(c, files, hugolib.TestOptOsFs())
-
-	b.AssertFileContent("public/index.html", `T1: moo{color:#fff}`)
-}
-
-func TestTransformImportRegularCSS(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	c := qt.New(t)
-
-	files := `
--- assets/scss/_moo.scss --
-$moolor: #fff;
-
-moo {
-	color: $moolor;
-}
--- assets/scss/another.css --
-
--- assets/scss/main.scss --
-@import "moo";
-@import "regular.css";
-@import "moo";
-@import "another.css";
-
-/* foo */
--- assets/scss/regular.css --
-
--- hugo.toml --
--- layouts/home.html --
-{{ $r := resources.Get "scss/main.scss" |  toCSS }}
-T1: {{ $r.Content | safeHTML }}
-
-	`
-
-	b := hugolib.Test(c, files, hugolib.TestOptOsFs())
-
-	// LibSass does not support regular CSS imports. There
-	// is an open bug about it that probably will never be resolved.
-	// Hugo works around this by preserving them in place:
-	b.AssertFileContent("public/index.html", `
- T1: moo {
- color: #fff; }
-
-@import "regular.css";
-moo {
- color: #fff; }
-
-@import "another.css";
-/* foo */
-
-`)
-}
-
-func TestTransformThemeOverrides(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	c := qt.New(t)
-
-	files := `
--- assets/scss/components/_boo.scss --
-$boolor: green;
-
-boo {
-	color: $boolor;
-}
--- assets/scss/components/_moo.scss --
-$moolor: #ccc;
-
-moo {
-	color: $moolor;
-}
--- hugo.toml --
-theme = 'mytheme'
--- layouts/home.html --
-{{ $cssOpts := (dict "includePaths" (slice "node_modules/foo" ) ) }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts  | minify  }}
-T1: {{ $r.Content }}
--- themes/mytheme/assets/scss/components/_boo.scss --
-$boolor: orange;
-
-boo {
-	color: $boolor;
-}
--- themes/mytheme/assets/scss/components/_imports.scss --
-@import "moo";
-@import "_boo";
-@import "_zoo";
--- themes/mytheme/assets/scss/components/_moo.scss --
-$moolor: #fff;
-
-moo {
-	color: $moolor;
-}
--- themes/mytheme/assets/scss/components/_zoo.scss --
-$zoolor: pink;
-
-zoo {
-	color: $zoolor;
-}
--- themes/mytheme/assets/scss/main.scss --
-@import "components/imports";
-	`
-
-	b := hugolib.Test(c, files, hugolib.TestOptOsFs())
-
-	b.AssertFileContent("public/index.html", `T1: moo{color:#ccc}boo{color:green}zoo{color:pink}`)
-}
-
-func TestTransformErrors(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	c := qt.New(t)
-
-	const filesTemplate = `
--- hugo.toml --
-theme = 'mytheme'
--- assets/scss/components/_foo.scss --
-/* comment line 1 */
-$foocolor: #ccc;
-
-foo {
-	color: $foocolor;
-}
--- themes/mytheme/assets/scss/main.scss --
-/* comment line 1 */
-/* comment line 2 */
-@import "components/foo";
-/* comment line 4 */
-
-$maincolor: #eee;
-
-body {
-	color: $maincolor;
-}
-
--- layouts/home.html --
-{{ $cssOpts := dict }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts  | minify  }}
-T1: {{ $r.Content }}
-
-	`
-
-	c.Run("error in main", func(c *qt.C) {
-		b, err := hugolib.TestE(c, strings.Replace(filesTemplate, "$maincolor: #eee;", "$maincolor #eee;", 1), hugolib.TestOptOsFs())
-
-		b.Assert(err, qt.IsNotNil)
-		b.Assert(err.Error(), qt.Contains, filepath.FromSlash(`themes/mytheme/assets/scss/main.scss:6:1": expected ':' after $maincolor in assignment statement`))
-		ferrs := herrors.UnwrapFileErrors(err)
-		c.Assert(len(ferrs), qt.Equals, 2)
-		fe := ferrs[1]
-		b.Assert(fe.ErrorContext(), qt.IsNotNil)
-		b.Assert(fe.ErrorContext().Lines, qt.DeepEquals, []string{"/* comment line 4 */", "", "$maincolor #eee;", "", "body {"})
-		b.Assert(fe.ErrorContext().ChromaLexer, qt.Equals, "scss")
-	})
-
-	c.Run("error in import", func(c *qt.C) {
-		b, err := hugolib.TestE(c, strings.Replace(filesTemplate, "$foocolor: #ccc;", "$foocolor #ccc;", 1), hugolib.TestOptOsFs())
-
-		b.Assert(err, qt.IsNotNil)
-		b.Assert(err.Error(), qt.Contains, `assets/scss/components/_foo.scss:2:1": expected ':' after $foocolor in assignment statement`)
-		ferrs := herrors.UnwrapFileErrors(err)
-		c.Assert(len(ferrs), qt.Equals, 2)
-		fe := ferrs[1]
-		b.Assert(fe.ErrorContext(), qt.IsNotNil)
-		b.Assert(fe.ErrorContext().Lines, qt.DeepEquals, []string{"/* comment line 1 */", "$foocolor #ccc;", "", "foo {"})
-		b.Assert(fe.ErrorContext().ChromaLexer, qt.Equals, "scss")
-	})
-}
-
-func TestOptionVars(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	files := `
--- assets/scss/main.scss --
-@import "hugo:vars";
-
-body {
-	body {
-		background: url($image) no-repeat center/cover;
-		font-family: $font;
-	  }
-}
-
-p {
-	color: $color1;
-	font-size: var$font_size;
-}
-
-b {
-	color: $color2;
-}
--- layouts/home.html --
-{{ $image := "images/hero.jpg" }}
-{{ $font := "Hugo's New Roman" }}
-{{ $vars := dict "$color1" "blue" "$color2" "green" "font_size" "24px" "image" $image "font" $font }}
-{{ $cssOpts := (dict "transpiler" "libsass" "outputStyle" "compressed" "vars" $vars ) }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts }}
-T1: {{ $r.Content }}
-	`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
-
-	b.AssertFileContent("public/index.html", `T1: body body{background:url(images/hero.jpg) no-repeat center/cover;font-family:Hugo&#39;s New Roman}p{color:blue;font-size:var 24px}b{color:green}`)
-}
-
-// Note: This test is more or less duplicated in both of the SCSS packages (libsass and dartsass).
-func TestBootstrap(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-	if !htesting.IsCI() {
-		t.Skip("skip (slow) test in non-CI environment")
-	}
-
-	files := `
--- hugo.toml --
-disableKinds = ["term", "taxonomy", "section", "page"]
-[module]
-[[module.imports]]
-path="github.com/gohugoio/hugo-mod-bootstrap-scss/v5"
--- go.mod --
-module github.com/gohugoio/tests/testHugoModules
--- assets/scss/main.scss --
-@import "bootstrap/bootstrap";
--- layouts/home.html --
-{{ $cssOpts := (dict "transpiler" "libsass" ) }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts }}
-Styles: {{ $r.RelPermalink }}
-		`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
-
-	b.AssertFileContent("public/index.html", "Styles: /scss/main.css")
-}
-
-// Issue #1239.
-func TestRebuildAssetGetMatch(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	files := `
--- assets/scss/main.scss --
-b {
-	color: red;
-}
--- layouts/home.html --
-{{ $r := resources.GetMatch "scss/main.scss" |  toCSS  }}
-T1: {{ $r.Content }}
-	`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs(), hugolib.TestOptRunning())
-
-	b.AssertFileContent("public/index.html", `color: red`)
-
-	b.EditFiles("assets/scss/main.scss", `b { color: blue; }`).Build()
-
-	b.AssertFileContent("public/index.html", `color: blue`)
-}
-
-func TestRebuildAssetMatchIssue12456(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	files := `
--- hugo.toml --
-disableKinds = ["term", "taxonomy", "section", "page"]
-disableLiveReload = true
--- assets/a.scss --
-h1 {
-	color: red;
-}
--- assets/dir/b.scss --
-h2 {
-	color: blue;
-}
--- assets/dir/c.scss --
-h3 {
-	color: green;
-}
--- layouts/home.html --
-{{ $a := slice (resources.Get "a.scss") }}
-{{ $b := resources.Match "dir/*.scss" }}
-
-{{/* Add styles in a specific order. */}}
-{{ $styles := slice $a $b }}
-
-{{ $stylesheets := slice }}
-  {{ range $styles }}
-  {{ $stylesheets = $stylesheets | collections.Append . }}
-{{ end }}
-
-
-{{ range $stylesheets }}
-  {{ with . | css.Sass | fingerprint }}
-    <link as="style"  href="{{ .RelPermalink }}" rel="preload stylesheet">
-  {{ end }}
-{{ end }}
-	`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs(), hugolib.TestOptRunning())
-
-	b.AssertFileContent("public/index.html", `b.60a9f3bdc189ee8a857afd5b7e1b93ad1644de0873761a7c9bc84f781a821942.css`)
-
-	b.EditFiles("assets/dir/b.scss", `h2 { color: orange; }`).Build()
-
-	b.AssertFileContent("public/index.html", `b.46b2d77c7ffe37ee191678f72df991ecb1319f849957151654362f09b0ef467f.css`)
-}
-
-// Issue 12851
-func TestDirectoryIndexes(t *testing.T) {
-	t.Parallel()
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	files := `
--- hugo.toml --
-disableKinds = ['page','section','rss','sitemap','taxonomy','term']
-
-[[module.mounts]]
-source = 'assets'
-target = 'assets'
-[[module.mounts]]
-source = "miscellaneous/sass"
-target = "assets/sass"
--- layouts/home.html --
-{{ $opts := dict "transpiler" "libsass" "outputStyle" "compressed" }}
-{{ (resources.Get "sass/main.scss" | toCSS $opts).Content }}
--- assets/sass/main.scss --
-@import "foo1"; // directory with _index file from OS file system
-@import "bar1"; // directory with _index file from module mount
-@import "foo2"; // directory with index file from OS file system
-@import "bar2"; // directory with index file from module mount
--- assets/sass/foo1/_index.scss --
-.foo1 {color: red;}
--- miscellaneous/sass/bar1/_index.scss --
-.bar1 {color: blue;}
--- assets/sass/foo2/index.scss --
-.foo2 {color: red;}
--- miscellaneous/sass/bar2/index.scss --
-.bar2 {color: blue;}
-`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
-
-	b.AssertFileContent("public/index.html", ".foo1{color:red}.bar1{color:blue}.foo2{color:red}.bar2{color:blue}")
-}
-
-func TestLibsassDeprecatedIssue14261(t *testing.T) {
-	// This cannot be run in parallel because of global state in log deprecation handling.
-	if !scss.Supports() {
-		t.Skip()
-	}
-
-	files := `
--- assets/scss/main.scss --
-body {
-	background-color: #fff;
-}
--- hugo.toml --
--- layouts/home.html --
-{{ $cssOpts := (dict  "transpiler" "libsass") }}
-{{ $r := resources.Get "scss/main.scss" |  toCSS $cssOpts  }}
-{{ $r.RelPermalink }}
-	`
-
-	b := hugolib.Test(t, files, hugolib.TestOptOsFs(), hugolib.TestOptInfo())
-
-	b.AssertLogContains("deprecated: css.Sass: libsass was deprecated in Hugo v0.153.0")
-}
-
-// Imports not found in Hugo's file systems used to be resolved by the Sass compiler
-// itself, following symlinks and with no notion of the project boundary.
-func TestTransformImportOutsideProject(t *testing.T) {
-	if !scss.Supports() {
-		t.Skip()
-	}
-	c := qt.New(t)
-
-	base := t.TempDir()
-	secret := filepath.Join(base, "secret.scss")
-	c.Assert(os.WriteFile(secret, []byte(`.pwn { content: "PWN-SECRET"; }`), 0o644), qt.IsNil)
-
-	files := `
--- hugo.toml --
-disableKinds = ["taxonomy", "term", "rss", "sitemap", "robotsTXT", "section", "page"]
-theme = "mytheme"
-SECURITY
--- themes/mytheme/hugo.toml --
--- themes/mytheme/assets/css/main.scss --
-@import "IMPORT";
--- layouts/all.html --
-{{ $css := resources.Get "css/main.scss" | css.Sass (dict "transpiler" "libsass") }}
-RESULT:<pre>{{ $css.Content }}</pre>
-`
-
-	build := func(c *qt.C, name, imp, security string) (*hugolib.IntegrationTestBuilder, error) {
-		workingDir := filepath.Join(base, name)
-		if runtime.GOOS != "windows" {
-			linkDir := filepath.Join(workingDir, "themes", "mytheme", "assets", "css")
-			c.Assert(os.MkdirAll(linkDir, 0o755), qt.IsNil)
-			c.Assert(os.Symlink(secret, filepath.Join(linkDir, "link.scss")), qt.IsNil)
-		}
-		f := strings.ReplaceAll(files, "IMPORT", imp)
-		f = strings.ReplaceAll(f, "SECURITY", security)
-		return hugolib.NewIntegrationTestBuilder(
-			hugolib.IntegrationTestConfig{
-				T:           c,
-				TxtarString: f,
-				NeedsOsFS:   true,
-				WorkingDir:  workingDir,
-			},
-		).BuildE()
-	}
-
-	const outsideErr = `.*"[^"]*\.scss" resolves to "[^"]*secret.scss" outside the project.*allowRead.*`
-
-	c.Run("Relative import", func(c *qt.C) {
-		_, err := build(c, "relative", "../../../../../secret", "")
-		c.Assert(err, qt.ErrorMatches, outsideErr)
-	})
-
-	c.Run("Symlink in theme", func(c *qt.C) {
-		if runtime.GOOS == "windows" {
-			c.Skip("symlinks")
-		}
-		_, err := build(c, "symlink", "link", "")
-		c.Assert(err, qt.ErrorMatches, outsideErr)
-	})
-
-	c.Run("Absolute import", func(c *qt.C) {
-		_, err := build(c, "absolute", filepath.ToSlash(filepath.Join(base, "secret")), "")
-		c.Assert(err, qt.ErrorMatches, outsideErr)
-	})
-
-	c.Run("Relative import, target in allowRead", func(c *qt.C) {
-		b, err := build(c, "allowed", "../../../../../secret", `
-[security.node.permissions]
-allowRead = [".", ".."]
-`)
-		c.Assert(err, qt.IsNil)
-		b.AssertFileContent("public/index.html", "PWN-SECRET")
-	})
-}
diff --git a/tpl/resources/resources_integration_test.go b/tpl/resources/resources_integration_test.go
index 736aee337ae..f6c5e3b9a85 100644
--- a/tpl/resources/resources_integration_test.go
+++ b/tpl/resources/resources_integration_test.go
@@ -19,7 +19,6 @@ import (
 	qt "github.com/frankban/quicktest"
 	"github.com/gohugoio/hugo/hugolib"
 	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/dartsass"
-	"github.com/gohugoio/hugo/resources/resource_transformers/tocss/scss"
 )
 
 func TestCopy(t *testing.T) {
@@ -240,7 +239,7 @@ match /files/C*: 2|
 func TestDartSassVars(t *testing.T) {
 	t.Parallel()
 
-	if !scss.Supports() || !dartsass.Supports() {
+	if !dartsass.Supports() {
 		t.Skip()
 	}
 
@@ -253,20 +252,11 @@ disableKinds = ['page','section','rss','sitemap','taxonomy','term']
   {{ .Content }}
 {{ end }}
 
-{{ $opts := dict "transpiler" "libsass" "outputStyle" "compressed" "vars" (dict "color" "blue") }}
-{{ with resources.Get "libsass.scss" | css.Sass $opts }}
-  {{ .Content }}
-{{ end }}
 -- assets/dartsass.scss --
 @use "hugo:vars" as v;
 .dartsass {
   color: v.$color;
 }
--- assets/libsass.scss --
-@import "hugo:vars";
-.libsass {
-  color: $color;
-}
 `
 
 	b := hugolib.Test(t, files, hugolib.TestOptWarn())
@@ -274,7 +264,6 @@ disableKinds = ['page','section','rss','sitemap','taxonomy','term']
 	b.AssertFileContent(
 		"public/index.html",
 		".dartsass{color:red}",
-		".libsass{color:blue}",
 	)
 	b.AssertLogContains("! WARN  Dart Sass: hugo:vars")
 }

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path hugolib/rebuild_test.go --path hugolib/resource_chain_test.go --path modules/config_test.go --path resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go --path resources/resource_transformers/tocss/scss/client_test.go --path resources/resource_transformers/tocss/scss/scss_integration_test.go --path tpl/resources/resources_integration_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 270 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./hugolib ./modules ./resources/resource_transformers/tocss/dartsass ./resources/resource_transformers/tocss/scss ./tpl/resources')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./hugolib ./modules ./resources/resource_transformers/tocss/dartsass ./resources/resource_transformers/tocss/scss ./tpl/resources' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
