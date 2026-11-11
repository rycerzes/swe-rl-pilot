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
for f in common/hreflect/compare_test.go common/hreflect/convert_test.go tpl/collections/where_test.go tpl/compare/compare_integration_test.go tpl/compare/compare_test.go; do if git cat-file -e a374b865f7e99cccafcbe443dcdb47552b91af3c:"$f" 2>/dev/null; then git checkout a374b865f7e99cccafcbe443dcdb47552b91af3c -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - a374b865f7e99cccafcbe443dcdb47552b91af3c "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/common/hreflect/compare_test.go b/common/hreflect/compare_test.go
new file mode 100644
index 00000000000..f146e98713e
--- /dev/null
+++ b/common/hreflect/compare_test.go
@@ -0,0 +1,81 @@
+// Copyright 2026 The Hugo Authors. All rights reserved.
+//
+// Licensed under the Apache License, Version 2.0 (the "License");
+// you may not use this file except in compliance with the License.
+// You may obtain a copy of the License at
+// http://www.apache.org/licenses/LICENSE-2.0
+//
+// Unless required by applicable law or agreed to in writing, software
+// distributed under the License is distributed on an "AS IS" BASIS,
+// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
+// See the License for the specific language governing permissions and
+// limitations under the License.
+
+package hreflect
+
+import (
+	"math"
+	"reflect"
+	"testing"
+
+	qt "github.com/frankban/quicktest"
+)
+
+func TestCompareNumbers(t *testing.T) {
+	t.Parallel()
+	c := qt.New(t)
+
+	for _, test := range []struct {
+		a, b   any
+		expect int
+	}{
+		{1, 1, 0},
+		{1, 2, -1},
+		{int8(-1), int64(-2), 1},
+		{uint8(1), uint64(1), 0},
+		{uint64(math.MaxUint64), uint8(1), 1},
+		{-1, uint64(math.MaxUint64), -1},
+		{uint64(math.MaxUint64), -1, 1},
+		{int64(math.MaxInt64), uint64(math.MaxInt64), 0},
+		{int64(math.MaxInt64), uint64(1 << 63), -1},
+		{1, 1.0, 0},
+		{1.0, 1, 0},
+		{1, 1.5, -1},
+		{2, 1.5, 1},
+		{-1, -1.5, 1},
+		{-2, -1.5, -1},
+		{1.5, 1, 1},
+		{-1.5, -1, -1},
+		{int64(1<<53 + 1), float64(1 << 53), 1},
+		{float64(1 << 53), int64(1<<53 + 1), -1},
+		{int64(1 << 53), float64(1 << 53), 0},
+		{int64(math.MaxInt64), float64(1 << 63), -1},
+		{int64(math.MinInt64), float64(-(1 << 63)), 0},
+		{int64(math.MinInt64), -1e300, 1},
+		{uint64(math.MaxUint64), float64(1 << 64), -1},
+		{uint64(0), -0.5, 1},
+		{uint64(0), math.Copysign(0, -1), 0},
+		{uint64(1<<53 + 1), float64(1 << 53), 1},
+		{float32(1.5), 1.5, 0},
+		{float32(1.1), 1.1, 1},
+		{math.Inf(1), int64(math.MaxInt64), 1},
+		{math.Inf(-1), uint64(0), -1},
+	} {
+		got, ok := CompareNumbers(reflect.ValueOf(test.a), reflect.ValueOf(test.b))
+		c.Assert(ok, qt.IsTrue, qt.Commentf("%v vs %v", test.a, test.b))
+		c.Assert(got, qt.Equals, test.expect, qt.Commentf("%v vs %v", test.a, test.b))
+	}
+
+	for _, test := range [][2]any{
+		{math.NaN(), 1},
+		{1, math.NaN()},
+		{math.NaN(), math.NaN()},
+		{"1", 1},
+		{1, "1"},
+		{true, 1},
+		{nil, 1},
+	} {
+		_, ok := CompareNumbers(reflect.ValueOf(test[0]), reflect.ValueOf(test[1]))
+		c.Assert(ok, qt.IsFalse, qt.Commentf("%v vs %v", test[0], test[1]))
+	}
+}
diff --git a/common/hreflect/convert_test.go b/common/hreflect/convert_test.go
index 81bfc91f3c2..eaad789e129 100644
--- a/common/hreflect/convert_test.go
+++ b/common/hreflect/convert_test.go
@@ -194,18 +194,49 @@ func TestConvertIfPossible(t *testing.T) {
 			expected: float32(32767),
 		},
 		{
-			name:     "int64(math.MaxInt64) to float32",
-			value:    int64(math.MaxInt64),
-			typ:      float32(0),
+			name:  "int64(math.MaxInt64) to float32",
+			value: int64(math.MaxInt64),
+			typ:   float32(0),
+			ok:    false, // loss of precision
+		},
+		{
+			name:  "int64(math.MaxInt64) to float64",
+			value: int64(math.MaxInt64),
+			typ:   float64(0),
+			ok:    false, // loss of precision
+		},
+		{
+			name:     "int64(1<<53) to float64",
+			value:    int64(1 << 53),
+			typ:      float64(0),
 			ok:       true,
-			expected: float32(math.MaxInt64),
+			expected: float64(1 << 53),
 		},
 		{
-			name:     "int64(math.MaxInt64) to float64",
-			value:    int64(math.MaxInt64),
+			name:  "int64(1<<53+1) to float64",
+			value: int64(1<<53 + 1),
+			typ:   float64(0),
+			ok:    false, // loss of precision
+		},
+		{
+			name:     "int64(1<<60) to float64",
+			value:    int64(1 << 60),
+			typ:      float64(0),
+			ok:       true,
+			expected: float64(1 << 60),
+		},
+		{
+			name:     "int64(math.MinInt64) to float64",
+			value:    int64(math.MinInt64),
 			typ:      float64(0),
 			ok:       true,
-			expected: float64(math.MaxInt64),
+			expected: float64(math.MinInt64),
+		},
+		{
+			name:  "int64(1<<24+1) to float32",
+			value: int64(1<<24 + 1),
+			typ:   float32(0),
+			ok:    false, // loss of precision
 		},
 		// Int to uint.
 		{
@@ -257,13 +288,44 @@ func TestConvertIfPossible(t *testing.T) {
 			ok:       true,
 			expected: float64(math.MaxInt16),
 		},
+		{
+			name:     "uint64(1<<63) to float64",
+			value:    uint64(1 << 63),
+			typ:      float64(0),
+			ok:       true,
+			expected: float64(1 << 63),
+		},
+		{
+			name:  "uint64(math.MaxUint64) to float64",
+			value: uint64(math.MaxUint64),
+			typ:   float64(0),
+			ok:    false, // loss of precision
+		},
+		{
+			name:  "uint64(1<<24+1) to float32",
+			value: uint64(1<<24 + 1),
+			typ:   float32(0),
+			ok:    false, // loss of precision
+		},
 		// Float to float.
 		{
-			name:     "float64(3.14) to float32",
-			value:    float64(3.14),
+			name:  "float64(3.14) to float32",
+			value: float64(3.14),
+			typ:   float32(0),
+			ok:    false, // loss of precision
+		},
+		{
+			name:     "float64(0.5) to float32",
+			value:    float64(0.5),
 			typ:      float32(0),
 			ok:       true,
-			expected: float32(3.14),
+			expected: float32(0.5),
+		},
+		{
+			name:  "float64(math.MaxFloat64) to float32",
+			value: float64(math.MaxFloat64),
+			typ:   float32(0),
+			ok:    false, // overflow
 		},
 		{
 			name:     "float32(3.14) to float64",
@@ -298,20 +360,27 @@ func TestConvertIfPossibleMisc(t *testing.T) {
 		i64        = int64(i)
 		iv     any = i
 		ip         = &i
-		inil   any = (*int32)(nil)
 		shello     = s("hello")
 	)
 
-	convertOK := func(v any, typ any) any {
-		rv, ok := ConvertIfPossible(reflect.ValueOf(v), reflect.TypeOf(typ))
+	convertOK := func(v reflect.Value, typ any) any {
+		rv, ok := ConvertIfPossible(v, reflect.TypeOf(typ))
 		c.Assert(ok, qt.IsTrue)
 		return rv.Interface()
 	}
 
-	c.Assert(convertOK(shello, ""), qt.Equals, "hello")
-	c.Assert(convertOK(ip, int64(0)), qt.Equals, i64)
-	c.Assert(convertOK(iv, int64(0)), qt.Equals, i64)
-	c.Assert(convertOK(inil, int64(0)), qt.Equals, int64(0))
+	c.Assert(convertOK(reflect.ValueOf(shello), ""), qt.Equals, "hello")
+	c.Assert(convertOK(reflect.ValueOf(iv), int64(0)), qt.Equals, i64)
+
+	// Elements of a []any are of kind Interface.
+	c.Assert(convertOK(reflect.ValueOf([]any{iv}).Index(0), int64(0)), qt.Equals, i64)
+	c.Assert(convertOK(reflect.ValueOf([]any{nil}).Index(0), int64(0)), qt.Equals, int64(0))
+
+	// Pointers are not dereferenced.
+	_, ok := ConvertIfPossible(reflect.ValueOf(ip), reflect.TypeOf(int64(0)))
+	c.Assert(ok, qt.IsFalse)
+	_, ok = ConvertIfPossible(reflect.ValueOf((*int32)(nil)), reflect.TypeOf(int64(0)))
+	c.Assert(ok, qt.IsFalse)
 }
 
 func BenchmarkToInt64(b *testing.B) {
diff --git a/tpl/collections/where_test.go b/tpl/collections/where_test.go
index b4fd6e6a82f..c88a8061f6a 100644
--- a/tpl/collections/where_test.go
+++ b/tpl/collections/where_test.go
@@ -17,6 +17,7 @@ import (
 	"context"
 	"fmt"
 	"html/template"
+	"math"
 	"math/rand"
 	"reflect"
 	"strings"
@@ -697,6 +698,14 @@ func TestCheckCondition(t *testing.T) {
 		expect
 	}{
 		{reflect.ValueOf(123), reflect.ValueOf(123), "", expect{true, false}},
+		{reflect.ValueOf(int64(1<<53 + 1)), reflect.ValueOf(int(1<<53 + 1)), "", expect{true, false}},
+		{reflect.ValueOf(int64(1<<53 + 1)), reflect.ValueOf(int(1 << 53)), ">", expect{true, false}},
+		{reflect.ValueOf(uint64(1<<53 + 1)), reflect.ValueOf(uint8(1)), ">", expect{true, false}},
+		{reflect.ValueOf(int64(1<<53 + 1)), reflect.ValueOf(float64(1 << 53)), "", expect{false, false}},
+		{reflect.ValueOf(int64(1<<53 + 1)), reflect.ValueOf(float64(1 << 53)), ">", expect{true, false}},
+		{reflect.ValueOf(int64(1<<53 + 1)), reflect.ValueOf(uint64(1<<53 + 1)), "", expect{true, false}},
+		{reflect.ValueOf(-1), reflect.ValueOf(uint64(math.MaxUint64)), "<", expect{true, false}},
+		{reflect.ValueOf(uint64(math.MaxUint64)), reflect.ValueOf(uint8(1)), ">", expect{true, false}},
 		{reflect.ValueOf("foo"), reflect.ValueOf("foo"), "", expect{true, false}},
 		{
 			reflect.ValueOf(time.Date(2015, time.May, 26, 19, 18, 56, 12345, time.UTC)),
diff --git a/tpl/compare/compare_integration_test.go b/tpl/compare/compare_integration_test.go
new file mode 100644
index 00000000000..5f57171045c
--- /dev/null
+++ b/tpl/compare/compare_integration_test.go
@@ -0,0 +1,168 @@
+// Copyright 2026 The Hugo Authors. All rights reserved.
+//
+// Licensed under the Apache License, Version 2.0 (the "License");
+// you may not use this file except in compliance with the License.
+// You may obtain a copy of the License at
+// http://www.apache.org/licenses/LICENSE-2.0
+//
+// Unless required by applicable law or agreed to in writing, software
+// distributed under the License is distributed on an "AS IS" BASIS,
+// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
+// See the License for the specific language governing permissions and
+// limitations under the License.
+
+package compare_test
+
+import (
+	"testing"
+
+	"github.com/gohugoio/hugo/hugolib"
+	"github.com/gohugoio/hugo/tpl/compare"
+)
+
+// See issue 15322.
+func TestEqIntFloat(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+-- layouts/home.html --
+eq: {{ eq 1 1.0 }}|{{ eq 1.0 1 }}|{{ eq 1 1.5 }}|{{ eq 1 2 1.0 }}
+ne: {{ ne 1 1.0 }}|{{ ne 1 1.5 }}
+lt: {{ lt 1 1.0 }}|{{ lt 1 1.5 }}
+le: {{ le 1 1.0 }}|{{ le 1 0.5 }}
+gt: {{ gt 1 1.0 }}|{{ gt 1 0.5 }}
+ge: {{ ge 1 1.0 }}|{{ ge 1 1.5 }}
+`
+	b := hugolib.Test(t, files)
+
+	b.AssertFileContent(
+		"public/index.html",
+		"eq: true|true|false|true",
+		"ne: false|true",
+		"lt: false|true",
+		"le: true|false",
+		"gt: false|true",
+		"ge: true|false",
+	)
+}
+
+func BenchmarkCompare(b *testing.B) {
+	files := `
+-- hugo.toml --
+`
+	bb := hugolib.Test(b, files)
+
+	ns := bb.H.TemplateStore.GetTemplateFuncsNamespace("compare").(*compare.Namespace)
+
+	b.ResetTimer()
+
+	run := func(name string, fn func(v1, v2 any)) {
+		b.Run(name, func(b *testing.B) {
+			b.Run("mixed int and float", func(b *testing.B) {
+				for b.Loop() {
+					fn(42, 42.0)
+				}
+			})
+			b.Run("mixed float and int", func(b *testing.B) {
+				for b.Loop() {
+					fn(42.0, 42)
+				}
+			})
+			b.Run("mixed string and int", func(b *testing.B) {
+				for b.Loop() {
+					fn("42", 42)
+				}
+			})
+			b.Run("mixed string and float", func(b *testing.B) {
+				for b.Loop() {
+					fn("42", 42.0)
+				}
+			})
+			b.Run("mixed float and string", func(b *testing.B) {
+				for b.Loop() {
+					fn(42.0, "42")
+				}
+			})
+			// End of mixed type benchmark
+			// start of same type benchmark
+			b.Run("same int", func(b *testing.B) {
+				for b.Loop() {
+					fn(42, 42)
+				}
+			})
+			b.Run("same float", func(b *testing.B) {
+				for b.Loop() {
+					fn(42.0, 42.0)
+				}
+			})
+			b.Run("same string", func(b *testing.B) {
+				for b.Loop() {
+					fn("foo", "foo")
+				}
+			})
+			b.Run("same bool", func(b *testing.B) {
+				for b.Loop() {
+					fn(true, true)
+				}
+			})
+			b.Run("same nil", func(b *testing.B) {
+				for b.Loop() {
+					fn(nil, nil)
+				}
+			})
+			b.Run("same complex", func(b *testing.B) {
+				for b.Loop() {
+					fn(complex(1, 2), complex(1, 2))
+				}
+			})
+			// End of same type benchmark
+			// start of edge case benchmark
+			b.Run("empty slice", func(b *testing.B) {
+				for b.Loop() {
+					fn([]int{}, []int{})
+				}
+			})
+			b.Run("empty map", func(b *testing.B) {
+				for b.Loop() {
+					fn(map[string]int{}, map[string]int{})
+				}
+			})
+			// End of edge case benchmark
+			// start of nil benchmark
+			b.Run("nil and non-nil", func(b *testing.B) {
+				for b.Loop() {
+					fn(nil, 42)
+				}
+			})
+			b.Run("non-nil and nil", func(b *testing.B) {
+				for b.Loop() {
+					fn(42, nil)
+				}
+			})
+			// End of nil benchmark
+			// start of large number benchmark
+			b.Run("large numbers", func(b *testing.B) {
+				for b.Loop() {
+					fn(1e18, 1e18)
+				}
+			})
+			// End of large number benchmark
+			// start of small number benchmark
+			b.Run("small numbers", func(b *testing.B) {
+				for b.Loop() {
+					fn(1e-18, 1e-18)
+				}
+			})
+			// End of small number benchmark
+		})
+	}
+
+	run("Eq", func(v1, v2 any) {
+		ns.Eq(v1, v2)
+	})
+
+	run("Gt", func(v1, v2 any) {
+		ns.Gt(v1, v2)
+	})
+}
diff --git a/tpl/compare/compare_test.go b/tpl/compare/compare_test.go
index a94ac5db733..b5e276cf4b0 100644
--- a/tpl/compare/compare_test.go
+++ b/tpl/compare/compare_test.go
@@ -221,6 +221,23 @@ func doTestCompare(t *testing.T, tp tstCompareType, funcUnderTest func(a, b any)
 		{0.0, 1.23, -1},
 		{1.1, 1.1, 0},
 		{float32(1.0), float64(1.0), 0},
+		{1, 1.0, 0},
+		{1.0, 1, 0},
+		{0, 0.0, 0},
+		{-1, -1.0, 0},
+		{int64(3), float64(3), 0},
+		{uint(4), 4.0, 0},
+		{1, float32(1.0), 0},
+		{float32(1.0), 1, 0},
+		{1, 1.5, -1},
+		{1.5, 1, 1},
+		{2, 1.5, 1},
+		{int64(1<<53 + 1), float64(1 << 53), 1},
+		{float64(1 << 53), int64(1<<53 + 1), -1},
+		{int64(1<<53 + 1), uint64(1<<53 + 1), 0},
+		{-1, uint64(math.MaxUint64), -1},
+		{uint64(math.MaxUint64), -1, 1},
+		{uint64(math.MaxUint64), uint8(1), 1},
 		{1.23, 0.0, 1},
 		{"5", "5", 0},
 		{"8", "5", 1},
@@ -287,6 +304,7 @@ func TestEqualExtend(t *testing.T) {
 	c := qt.New(t)
 
 	ns := New(time.UTC, false)
+	one := 1
 
 	for _, test := range []struct {
 		first  any
@@ -296,6 +314,31 @@ func TestEqualExtend(t *testing.T) {
 		{1, []any{1, 2}, true},
 		{1, []any{2, 1}, true},
 		{1, []any{2, 3}, false},
+		{1, []any{2, 1.0}, true},
+		{1.0, []any{2, 1}, true},
+		{1, []any{1.5}, false},
+		{uint64(math.MaxUint64), []any{-1}, false},
+		{-1, []any{uint64(math.MaxUint64)}, false},
+		{float64(9007199254740992), []any{int64(9007199254740993)}, false},
+		{int64(9007199254740993), []any{float64(9007199254740992)}, false},
+		{float64(9007199254740992), []any{int64(9007199254740992)}, true},
+		{int64(9007199254740992), []any{float64(9007199254740992)}, true},
+		{float32(16777216), []any{int64(16777217)}, false},
+		{int64(16777217), []any{float32(16777216)}, false},
+		{float64(3.14), []any{float32(3.14)}, false},
+		{float32(3.14), []any{float64(3.14)}, false},
+		{float64(0.5), []any{float32(0.5)}, true},
+		{float32(0.5), []any{float64(0.5)}, true},
+		{stringType("a"), []any{"b", "a"}, true},
+		{[]int{1, 2}, []any{[]int{1, 2}}, true},
+		{[]int{1, 2}, []any{[]int{2, 1}}, false},
+		{map[string]any{"a": []int{1}}, []any{map[string]any{"a": []int{1}}}, true},
+		{struct{ V any }{[]int{1}}, []any{struct{ V any }{[]int{1}}}, true},
+		{&T{}, []any{&T{}}, true},
+		{T{}, []any{&T{}}, false},
+		{&T{}, []any{T{}}, false},
+		{1, []any{&one}, false},
+		{&one, []any{1}, false},
 		{tstEqerType1("a"), []any{tstEqerType1("a"), tstEqerType1("b")}, true},
 		{tstEqerType1("a"), []any{tstEqerType1("b"), tstEqerType1("a")}, true},
 		{tstEqerType1("a"), []any{tstEqerType1("b"), tstEqerType1("c")}, false},

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path common/hreflect/compare_test.go --path common/hreflect/convert_test.go --path tpl/collections/where_test.go --path tpl/compare/compare_integration_test.go --path tpl/compare/compare_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./common/hreflect ./tpl/collections ./tpl/compare')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./common/hreflect ./tpl/collections ./tpl/compare' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
