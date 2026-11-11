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
for f in internal/wiretarget/wiretarget_test.go middleware/adaptor/routed_test.go middleware/idempotency/idempotency_test.go middleware/idempotency/stub_test.go middleware/proxy/target_test.go; do if git cat-file -e 56f2c776809c6cbc08c2cc0ca1be890e257d1fe7:"$f" 2>/dev/null; then git checkout 56f2c776809c6cbc08c2cc0ca1be890e257d1fe7 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 56f2c776809c6cbc08c2cc0ca1be890e257d1fe7 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
index 6a4f4deb875..0115cb32de4 100644
--- a/internal/wiretarget/wiretarget_test.go
+++ b/internal/wiretarget/wiretarget_test.go
@@ -3,6 +3,7 @@ package wiretarget
 import (
 	"bufio"
 	"encoding/hex"
+	"slices"
 	"strings"
 	"testing"
 
@@ -78,6 +79,8 @@ func Test_Routed(t *testing.T) {
 			"/%zz":                 "/%25zz",
 			"/%252e%252e/a":        "/%252e%252e/a",
 			"/a%3Fb%23c%25d":       "/a%3Fb%23c%25d",
+			"/admin;x/secret":      "/admin%3Bx/secret",
+			"/admin%3Bx/b;c=d":     "/admin%3Bx/b%3Bc=d",
 		} {
 			require.Equal(t, want, answerFor(t, app, target), target)
 		}
@@ -128,22 +131,78 @@ func Test_Routed(t *testing.T) {
 func Test_SegmentsAsRouted(t *testing.T) {
 	t.Parallel()
 
-	for _, target := range []string{
-		"/", "/a/b", "/a/b?x=%2F&y=//", "/a%252Fb", "/%252E%252E/a", "/a/b/",
-		"/a;b/c", "/m;x=1;y=2", "/..x;y/a", "/a/.b;c", "/a%255C", "/a?q=\\&r=%5C",
-	} {
-		require.True(t, SegmentsAsRouted(target), target)
-	}
-	// "%2E" is an escape the router decodes, so one still in the routed path
-	// was forged and URL.Path would read "%2E%2E" as "..". A backslash is a
-	// separator to WHATWG URL parsers and IIS, and servlet containers resolve
-	// a dot segment once they strip its path parameters.
-	for _, target := range []string{
-		"//", "//admin", "/a//b", "/a/b//", "/public/..%2Fadmin", "/a%2fb", "/a%2Fb?x=1", "/%2E%2E/a",
-		"/admin\\secret", "/public/..\\admin", "/a%5Cb", "/public/..%5cadmin",
-		"/public/..;/admin", "/public/.;/admin", "/public/..;jsessionid=x/admin", "/a/..;", "/a/.;x",
+	const both = AllowSlashes | AllowParameters
+	all := []Allowance{0, AllowSlashes, AllowParameters, both}
+
+	for _, tc := range []struct {
+		name    string
+		targets []string
+		passes  []Allowance // the allowances under which every target is let through
+	}{
+		{
+			name: "plain",
+			targets: []string{
+				"/", "/a/b", "/a/b?x=%2F&y=//", "/a%252Fb", "/%252E%252E/a", "/a/b/", "/a%255C", "/a?q=\\&r=%5C",
+				// a ";" in the query is no path parameter, and an escape of a
+				// reserved character, "%" included, is no forged escape
+				"/a/b?x=1;y=2", "/a?;", "/public/%2541/a%20b?x=%2e",
+			},
+			passes: all,
+		},
+		{
+			// A servlet container strips the parameters from every segment, so
+			// "/admin;x/secret" is "/admin/secret" there.
+			name: "path parameter",
+			targets: []string{
+				"/a;b/c", "/m;x=1;y=2", "/..x;y/a", "/a/.b;c", "/admin;x/secret", "/admin;/secret",
+				"/a/b;jsessionid=1", "/a;x/b;y?q=1", "/a;", "/;jsessionid=1", "/a/;x", "/;x;y",
+			},
+			passes: []Allowance{AllowParameters, both},
+		},
+		{
+			// Stripped, a segment of parameters alone is an empty segment:
+			// "/;/admin/secret" is "//admin/secret", merged into "/admin/secret".
+			name:    "parameters alone before another segment",
+			targets: []string{"/;/admin/secret", "/;x/admin", "/a/;x/b", "/a/;/", "/;x;y/b", "/a/;jsessionid=1/b"},
+			passes:  []Allowance{both},
+		},
+		{
+			name:    "escaped slash and a parameter",
+			targets: []string{"/a%2Fb;c", "/group%2Fname;x", "/a%2F;x/b", "/a%2fb;c"},
+			passes:  []Allowance{both},
+		},
+		{
+			name:    "escaped slash or empty segment",
+			targets: []string{"//", "//admin", "/a//b", "/a/b//", "/public/..%2Fadmin", "/a%2fb", "/a%2Fb?x=1"},
+			passes:  []Allowance{AllowSlashes, both},
+		},
+		{
+			// "%2E" is an escape the router decodes, so one still in the routed
+			// path was forged and URL.Path would read "%2E%2E" as "..". A
+			// backslash is a separator to WHATWG URL parsers and IIS, and
+			// servlet containers resolve a dot segment once they strip its
+			// path parameters.
+			name: "never",
+			targets: []string{
+				"/%2E%2E/a", "/public/%2e%2e/admin", "/public/%70rivate",
+				"/admin\\secret", "/public/..\\admin", "/a%5Cb", "/public/..%5cadmin",
+				"/public/..;/admin", "/public/.;/admin", "/public/..;jsessionid=x/admin", "/a/..;", "/a/.;x",
+				"/..;/a", "/.;x/a", "/a;x/..;/b",
+				// behind an escaped slash, the dot segment is one to a reader
+				// that decodes it; the escaped slash alone is let through
+				"/a%2F..;/b", "/%2F..;/b", "/a%2F.;x/b", "/a%2f..;/b", "/a%2F..;",
+			},
+		},
 	} {
-		require.False(t, SegmentsAsRouted(target), target)
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			for _, allow := range all {
+				want := slices.Contains(tc.passes, allow)
+				for _, target := range tc.targets {
+					require.Equal(t, want, SegmentsAsRouted(target, allow), "%s allowing %d", target, allow)
+				}
+			}
+		})
 	}
 }
 
@@ -196,14 +255,6 @@ func Test_HasForgedEscape(t *testing.T) {
 	}
 }
 
-func Test_SegmentsAsRouted_ForgedEscape(t *testing.T) {
-	t.Parallel()
-
-	require.False(t, SegmentsAsRouted("/public/%2e%2e/admin/secret"))
-	require.False(t, SegmentsAsRouted("/public/%70rivate"))
-	require.True(t, SegmentsAsRouted("/public/%2541/a%20b?x=%2e"))
-}
-
 func Test_SurvivesNormalization(t *testing.T) {
 	t.Parallel()
 
diff --git a/middleware/adaptor/routed_test.go b/middleware/adaptor/routed_test.go
index c75000f383e..6ebdbc84111 100644
--- a/middleware/adaptor/routed_test.go
+++ b/middleware/adaptor/routed_test.go
@@ -141,9 +141,10 @@ func Test_HTTPHandler_FileServerStaysInPlace(t *testing.T) {
 // is not handed a path that a handler passing the request on, such as
 // httputil.ReverseProxy, would forward to an upstream that reads it as another
 // path: one with a backslash, which WHATWG URL parsers and IIS read as a
-// separator, or with a dot segment carrying parameters, which servlet
-// containers resolve once they strip the parameters. A ";" anywhere else is
-// an ordinary path character and is handed on.
+// separator, or with a segment that servlet containers resolve as a dot
+// segment or merge away as an empty one once they strip its parameters. A
+// ";" on a named segment, including the last one, is an ordinary path
+// character to net/http and is handed on.
 func Test_HTTPHandler_RefusesBackslashAndDotParams(t *testing.T) {
 	t.Parallel()
 
@@ -155,12 +156,13 @@ func Test_HTTPHandler_RefusesBackslashAndDotParams(t *testing.T) {
 	for _, target := range []string{
 		"/admin\\secret", "/public/..\\admin", "/public/..%5Cadmin", "/public/..%5cadmin",
 		"/public/..;/admin", "/public/.;x/admin", "/public/..;jsessionid=1/admin",
+		"/;x/admin", "/public/;/admin", "/public/;jsessionid=1/admin",
 	} {
 		fctx := rawCtx(t, app, target)
 		require.Equal(t, fiber.StatusNotFound, fctx.Response.StatusCode(), target)
 		require.NotContains(t, string(fctx.Response.Body()), "admin", target)
 	}
-	for _, target := range []string{"/a;b/c", "/m;x=1;y=2", "/..x;y/a"} {
+	for _, target := range []string{"/a;b/c", "/m;x=1;y=2", "/..x;y/a", "/app/;jsessionid=1"} {
 		fctx := rawCtx(t, app, target)
 		require.Equal(t, fiber.StatusOK, fctx.Response.StatusCode(), target)
 		require.Equal(t, target, string(fctx.Response.Body()), target)
diff --git a/middleware/idempotency/idempotency_test.go b/middleware/idempotency/idempotency_test.go
index 50eafeb255c..4cbedd1e537 100644
--- a/middleware/idempotency/idempotency_test.go
+++ b/middleware/idempotency/idempotency_test.go
@@ -184,6 +184,37 @@ func Benchmark_Idempotency(b *testing.B) {
 			h(c)
 		}
 	})
+
+	scoped := fiber.New()
+	scoped.Use(New(Config{
+		Lifetime: lifetime,
+		KeyScope: func(c fiber.Ctx) string { return c.Get("X-User") },
+	}))
+	scoped.Post("/", func(_ fiber.Ctx) error {
+		return nil
+	})
+	hs := scoped.Handler()
+
+	b.Run("scoped hit", func(b *testing.B) {
+		c := &fasthttp.RequestCtx{}
+		c.Request.Header.SetMethod(fiber.MethodPost)
+		c.Request.SetRequestURI("/")
+		c.Request.Header.Set("X-Idempotency-Key", "00000000-0000-0000-0000-000000000000")
+		c.Request.Header.Set("X-User", "alice")
+
+		b.ReportAllocs()
+		for b.Loop() {
+			hs(c)
+		}
+	})
+}
+
+// go test -v -run=^$ -bench=Benchmark_scopedKey -benchmem -count=4
+func Benchmark_scopedKey(b *testing.B) {
+	b.ReportAllocs()
+	for b.Loop() {
+		scopedKey("alice", validKey)
+	}
 }
 
 func Test_configDefault_defaults(t *testing.T) {
@@ -195,6 +226,7 @@ func Test_configDefault_defaults(t *testing.T) {
 	require.Equal(t, ConfigDefault.Lifetime, cfg.Lifetime)
 	require.Equal(t, ConfigDefault.KeyHeader, cfg.KeyHeader)
 	require.Nil(t, cfg.KeepResponseHeaders)
+	require.Nil(t, cfg.KeyScope)
 
 	app := fiber.New()
 
@@ -226,10 +258,12 @@ func Test_configDefault_override(t *testing.T) {
 		KeepResponseHeaders: []string{},
 		Lock:                l,
 		Storage:             s,
+		KeyScope:            func(fiber.Ctx) string { return "scope" },
 	})
 
 	require.Equal(t, 42*time.Second, cfg.Lifetime)
 	require.Equal(t, "Foo", cfg.KeyHeader)
+	require.NotNil(t, cfg.KeyScope)
 	require.Nil(t, cfg.KeepResponseHeaders)
 	require.Equal(t, l, cfg.Lock)
 	require.Equal(t, s, cfg.Storage)
@@ -395,13 +429,15 @@ func Test_New_StoreRetrieve_FilterHeadersCaseInsensitiveSnapshot(t *testing.T) {
 
 // Test_New_StoreRetrieve_HeadersWithCommas pins that a replayed response
 // carries each header value exactly as the handler set it, even when the app
-// enables EnableSplittingOnParsers, which only concerns request parsing.
+// enables EnableSplittingOnParsers, which only concerns request parsing. The
+// cookie is kept because the config names it.
 func Test_New_StoreRetrieve_HeadersWithCommas(t *testing.T) {
 	t.Parallel()
 	app := fiber.New(fiber.Config{EnableSplittingOnParsers: true})
 	app.Use(New(Config{
-		Storage: &stubStorage{},
-		Lock:    &stubLock{},
+		Storage:             &stubStorage{},
+		Lock:                &stubLock{},
+		KeepResponseHeaders: []string{fiber.HeaderContentDisposition, fiber.HeaderSetCookie},
 	}))
 
 	var count int
@@ -426,10 +462,276 @@ func Test_New_StoreRetrieve_HeadersWithCommas(t *testing.T) {
 	resp2, body2 := do(app, req2)
 	require.Equal(t, "resp1", body2)
 	require.Equal(t, 1, count)
+	require.NotEmpty(t, resp2.Header.Values(fiber.HeaderSetCookie))
 	require.Equal(t, resp.Header.Values(fiber.HeaderContentDisposition), resp2.Header.Values(fiber.HeaderContentDisposition))
 	require.Equal(t, resp.Header.Values(fiber.HeaderSetCookie), resp2.Header.Values(fiber.HeaderSetCookie))
 }
 
+// Test_New_DoesNotReplayCookies pins that a cookie is neither stored nor
+// replayed by default: the key alone identifies a request, so a replayed
+// Set-Cookie hands the session of whoever sent the key first to whoever sends
+// it next, on any route.
+func Test_New_DoesNotReplayCookies(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	s := &stubStorage{}
+	app.Use(New(Config{Storage: s, Lock: &stubLock{}}))
+
+	var count int
+	app.Post("/login", func(c fiber.Ctx) error {
+		count++
+		c.Cookie(&fiber.Cookie{Name: "sid", Value: "ALICE-SESSION"})
+		c.Set(fiber.HeaderSetCookie2, "sid=ALICE-SESSION; Version=1")
+		c.Set("X-Request", "alice")
+		return c.SendString("welcome alice")
+	})
+	app.Post("/other", func(c fiber.Ctx) error {
+		count++
+		return c.SendString("other")
+	})
+
+	post := func(route string) (*http.Response, string) {
+		req := httptest.NewRequest(http.MethodPost, route, http.NoBody)
+		req.Header.Set(ConfigDefault.KeyHeader, validKey)
+		return do(app, req)
+	}
+
+	// the client that caused the miss gets its cookies
+	resp, body := post("/login")
+	require.Equal(t, "welcome alice", body)
+	require.Equal(t, []string{"sid=ALICE-SESSION; path=/; SameSite=Lax"}, resp.Header.Values(fiber.HeaderSetCookie))
+	require.Equal(t, []string{"sid=ALICE-SESSION; Version=1"}, resp.Header.Values(fiber.HeaderSetCookie2))
+
+	// whoever sends the key next gets the rest of the response, and the
+	// handler is not run for them, on the route that stored it or another
+	for _, route := range []string{"/login", "/other"} {
+		resp, body = post(route)
+		require.Equal(t, "welcome alice", body, route)
+		require.Equal(t, "alice", resp.Header.Get("X-Request"), route)
+		require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie), route)
+		require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie2), route)
+	}
+	require.Equal(t, 1, count)
+
+	// and nothing in the storage holds them
+	for _, val := range s.data {
+		require.NotContains(t, string(val), "ALICE-SESSION")
+	}
+}
+
+// Test_New_KeepResponseHeaders_NamedCookies pins that naming a cookie header in
+// KeepResponseHeaders stores and replays it, matched case-insensitively, and
+// that naming one of the two leaves the other out.
+func Test_New_KeepResponseHeaders_NamedCookies(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	app.Use(New(Config{
+		Storage:             &stubStorage{},
+		Lock:                &stubLock{},
+		KeepResponseHeaders: []string{"set-cookie", "X-Request"},
+	}))
+
+	app.Post("/", func(c fiber.Ctx) error {
+		c.Cookie(&fiber.Cookie{Name: "sid", Value: "abc"})
+		c.Set(fiber.HeaderSetCookie2, "sid=abc; Version=1")
+		c.Set("X-Request", "first")
+		c.Set("X-Other", "dropped")
+		return c.SendString("ok")
+	})
+
+	post := func() *http.Response {
+		req := httptest.NewRequest(http.MethodPost, "/", http.NoBody)
+		req.Header.Set(ConfigDefault.KeyHeader, validKey)
+		resp, _ := do(app, req)
+		return resp
+	}
+	first, replayed := post(), post()
+	require.Equal(t, []string{"sid=abc; path=/; SameSite=Lax"}, first.Header.Values(fiber.HeaderSetCookie))
+	require.Equal(t, first.Header.Values(fiber.HeaderSetCookie), replayed.Header.Values(fiber.HeaderSetCookie))
+	require.Equal(t, "first", replayed.Header.Get("X-Request"))
+	require.Empty(t, replayed.Header.Values(fiber.HeaderSetCookie2))
+	require.Empty(t, replayed.Header.Values("X-Other"))
+}
+
+// Test_New_ReplayDropsStoredCookies pins that a cookie in an entry the storage
+// already holds, written by a version that kept every header or under a
+// configuration that named the cookie, is not replayed unless the
+// configuration names it now.
+func Test_New_ReplayDropsStoredCookies(t *testing.T) {
+	t.Parallel()
+
+	stored := func() *stubStorage {
+		res := response{
+			Headers: map[string][]string{
+				fiber.HeaderSetCookie:  {"sid=ALICE-SESSION; path=/"},
+				fiber.HeaderSetCookie2: {"sid=ALICE-SESSION; Version=1"},
+				"X-Request":            {"alice"},
+			},
+			Body:       []byte("welcome alice"),
+			StatusCode: fiber.StatusOK,
+		}
+		bs, err := res.MarshalMsg(nil)
+		require.NoError(t, err)
+		return &stubStorage{data: map[string][]byte{validKey: bs}}
+	}
+	replay := func(keep []string) *http.Response {
+		app := fiber.New()
+		app.Use(New(Config{Storage: stored(), Lock: &stubLock{}, KeepResponseHeaders: keep}))
+		app.Post("/", func(_ fiber.Ctx) error { return errors.New("the handler must not run") })
+
+		req := httptest.NewRequest(http.MethodPost, "/", http.NoBody)
+		req.Header.Set(ConfigDefault.KeyHeader, validKey)
+		resp, body := do(app, req)
+		require.Equal(t, "welcome alice", body)
+		require.Equal(t, "alice", resp.Header.Get("X-Request"))
+		return resp
+	}
+
+	resp := replay(nil)
+	require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie))
+	require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie2))
+
+	resp = replay([]string{"X-Request"})
+	require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie))
+	require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie2))
+
+	resp = replay([]string{"X-Request", fiber.HeaderSetCookie})
+	require.Equal(t, []string{"sid=ALICE-SESSION; path=/"}, resp.Header.Values(fiber.HeaderSetCookie))
+	require.Empty(t, resp.Header.Values(fiber.HeaderSetCookie2))
+}
+
+// Test_New_KeyScope pins that a key is stored, replayed and locked per scope: a
+// user who sends the key another user sent runs the handler for their own
+// request and gets their own response, cookie included, and the storage holds
+// neither the key nor the scope.
+func Test_New_KeyScope(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	s := &stubStorage{}
+	l := &stubLock{}
+	app.Use(New(Config{
+		Storage:             s,
+		Lock:                l,
+		KeepResponseHeaders: []string{fiber.HeaderSetCookie},
+		KeyScope:            func(c fiber.Ctx) string { return c.Get("X-User") },
+	}))
+
+	var count int
+	app.Post("/", func(c fiber.Ctx) error {
+		count++
+		c.Cookie(&fiber.Cookie{Name: "sid", Value: c.Get("X-User") + "-session"})
+		return c.SendString(fmt.Sprintf("%s:%d", c.Get("X-User"), count))
+	})
+
+	post := func(user string) (*http.Response, string) {
+		req := httptest.NewRequest(http.MethodPost, "/", http.NoBody)
+		req.Header.Set(ConfigDefault.KeyHeader, validKey)
+		if user != "" {
+			req.Header.Set("X-User", user)
+		}
+		return do(app, req)
+	}
+	requireReply := func(user, wantBody string, wantCalls int) {
+		t.Helper()
+		resp, body := post(user)
+		require.Equal(t, wantBody, body)
+		require.Equal(t, "sid="+user+"-session; path=/; SameSite=Lax", resp.Header.Get(fiber.HeaderSetCookie))
+		require.Equal(t, wantCalls, count)
+	}
+
+	requireReply("alice", "alice:1", 1)
+	requireReply("bob", "bob:2", 2) // the key is Alice's too, the response is not
+	requireReply("alice", "alice:1", 2)
+	requireReply("bob", "bob:2", 2)
+	requireReply("", ":3", 3) // a request without a user is a scope of its own
+	requireReply("", ":3", 3)
+
+	require.Equal(t, 3, s.setCount)
+	require.Len(t, s.data, 3)
+	// Each entry holds its own user's cookie and nobody else's, under the key
+	// the scope and the idempotency key digest to.
+	for _, user := range []string{"alice", "bob", ""} {
+		val := string(s.data[scopedKey(user, validKey)])
+		require.Contains(t, val, "sid="+user+"-session")
+		for _, other := range []string{"alice", "bob"} {
+			if other != user {
+				require.NotContains(t, val, other+"-session")
+			}
+		}
+	}
+	// A replay is answered before the lock, so only the three misses took it,
+	// under the same keys, and a key two users share makes neither wait for
+	// the other.
+	require.Len(t, l.locked, 3)
+	for _, key := range l.locked {
+		require.Contains(t, s.data, key)
+	}
+}
+
+// Test_New_KeyScope_NotConsulted pins that the scope is asked for only when a
+// request carries a valid key.
+func Test_New_KeyScope_NotConsulted(t *testing.T) {
+	t.Parallel()
+	app := fiber.New()
+	var asked int
+	app.Use(New(Config{
+		Storage:  &stubStorage{},
+		Lock:     &stubLock{},
+		KeyScope: func(fiber.Ctx) string { asked++; return "user" },
+	}))
+	app.Post("/", func(c fiber.Ctx) error { return c.SendString("ok") })
+
+	do(app, httptest.NewRequest(http.MethodPost, "/", http.NoBody))
+	require.Zero(t, asked, "no key")
+
+	req := httptest.NewRequest(http.MethodPost, "/", http.NoBody)
+	req.Header.Set(ConfigDefault.KeyHeader, "bad")
+	resp, _ := do(app, req)
+	require.Equal(t, fiber.StatusInternalServerError, resp.StatusCode)
+	require.Zero(t, asked, "invalid key")
+
+	req = httptest.NewRequest(http.MethodPost, "/", http.NoBody)
+	req.Header.Set(ConfigDefault.KeyHeader, validKey)
+	do(app, req)
+	require.Equal(t, 1, asked)
+}
+
+// Test_scopedKey pins that a scope and a key give one storage key, of one
+// length, that no other pair gives, however their bytes run together.
+func Test_scopedKey(t *testing.T) {
+	t.Parallel()
+
+	first := scopedKey("alice", validKey)
+	require.Equal(t, first, scopedKey("alice", validKey))
+	require.Len(t, scopedKey("", ""), 64)
+	require.Len(t, scopedKey(strings.Repeat("s", 1000), strings.Repeat("k", 1000)), 64)
+	require.NotEqual(t, validKey, scopedKey("", validKey))
+
+	seen := make(map[string][2]string)
+	for _, pair := range [][2]string{
+		{"", ""},
+		{"", "abc"},
+		{"a", "bc"},
+		{"ab", "c"},
+		{"abc", ""},
+		{"1", ":ab"},
+		{"1:a", "b"},
+		{"3", ":abc"},
+		{"3:abc", ""},
+		{"0", ":abc"},
+		{"10", ":"},
+		{"1", "0:"},
+		{"alice", validKey},
+		{"bob", validKey},
+		{"alice" + validKey[:1], validKey[1:]},
+	} {
+		key := scopedKey(pair[0], pair[1])
+		prev, dup := seen[key]
+		require.False(t, dup, "%q and %q share a key", pair, prev)
+		seen[key] = pair
+	}
+}
+
 func Test_New_Cache_WhenBodyTooLarge(t *testing.T) {
 	t.Parallel()
 	bodyLimit := 8
diff --git a/middleware/idempotency/stub_test.go b/middleware/idempotency/stub_test.go
index 0d9fc57a7e5..58821c6c454 100644
--- a/middleware/idempotency/stub_test.go
+++ b/middleware/idempotency/stub_test.go
@@ -10,9 +10,11 @@ type stubLock struct {
 	lockErr   error
 	unlockErr error
 	afterLock func()
+	locked    []string // the keys Lock was called with
 }
 
-func (s *stubLock) Lock(string) error {
+func (s *stubLock) Lock(key string) error {
+	s.locked = append(s.locked, key)
 	if s.afterLock != nil {
 		s.afterLock()
 	}
diff --git a/middleware/proxy/target_test.go b/middleware/proxy/target_test.go
index 92a7740e136..709f1e26242 100644
--- a/middleware/proxy/target_test.go
+++ b/middleware/proxy/target_test.go
@@ -6,6 +6,7 @@ import (
 	"net"
 	"net/http"
 	"net/http/httptest"
+	"slices"
 	"strconv"
 	"strings"
 	"sync/atomic"
@@ -39,6 +40,21 @@ func rawRequest(t *testing.T, app *fiber.App, target, host string) *fasthttp.Res
 	return resp
 }
 
+// listenUpstream serves upstream on a loopback port until the test ends and
+// returns its address.
+func listenUpstream(t *testing.T, upstream *fiber.App) string {
+	t.Helper()
+
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() {
+		ln.Close() //nolint:errcheck // It is fine to ignore the error here
+	})
+	startServer(upstream, ln)
+
+	return ln.Addr().String()
+}
+
 // echoTarget serves an upstream that answers every request with the target
 // it was handed, exactly as it arrived on the wire.
 func echoTarget(t *testing.T) string {
@@ -48,15 +64,13 @@ func echoTarget(t *testing.T) string {
 	target.Use(func(c fiber.Ctx) error {
 		return c.SendString(c.OriginalURL())
 	})
+	return listenUpstream(t, target)
+}
 
-	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
-	require.NoError(t, err)
-	t.Cleanup(func() {
-		ln.Close() //nolint:errcheck // It is fine to ignore the error here
-	})
-	startServer(target, ln)
-
-	return ln.Addr().String()
+// forwardingHandlers returns the helpers that forward the routed path: those
+// of realIPHandlers but Forward, which sends to the address it was given.
+func forwardingHandlers() []realIPHandler {
+	return slices.DeleteFunc(realIPHandlers(), func(h realIPHandler) bool { return h.name == "Forward" })
 }
 
 func readBody(t *testing.T, resp *http.Response) string {
@@ -307,17 +321,12 @@ func Test_Proxy_RejectsEncodedSeparator(t *testing.T) {
 	t.Parallel()
 	addr := echoTarget(t)
 
-	handlers := map[string]func() fiber.Handler{
-		"Balancer":        func() fiber.Handler { return Balancer(Config{Servers: []string{addr}}) },
-		"DomainForward":   func() fiber.Handler { return DomainForward("example.com", "http://"+addr) },
-		"BalancerForward": func() fiber.Handler { return BalancerForward([]string{"http://" + addr}) },
-	}
-	for name, handler := range handlers {
-		t.Run(name, func(t *testing.T) {
+	for _, h := range forwardingHandlers() {
+		t.Run(h.name, func(t *testing.T) {
 			t.Parallel()
 			app := fiber.New()
 			app.Use("/admin", forbid)
-			app.Use(handler())
+			app.Use(h.build(addr))
 
 			for _, target := range []string{
 				"/public/..%2Fadmin/secret.txt",
@@ -356,30 +365,99 @@ func Test_Proxy_RejectsEncodedSeparator(t *testing.T) {
 	}
 }
 
+// Test_Proxy_RejectsPathParameters pins that a path parameter, a ";" in any
+// segment, is refused by every forwarding handler by default. A servlet
+// container strips the parameters from every segment before it matches routes,
+// so "/admin;x/secret", "/admin;/secret" and "/;/admin/secret" are
+// "/admin/secret" there, although no middleware on "/admin" ran for them.
+func Test_Proxy_RejectsPathParameters(t *testing.T) {
+	t.Parallel()
+
+	for _, h := range forwardingHandlers() {
+		t.Run(h.name, func(t *testing.T) {
+			t.Parallel()
+			// an upstream that counts what it is handed and echoes it
+			var hits atomic.Int32
+			upstream := fiber.New()
+			upstream.Use(func(c fiber.Ctx) error {
+				hits.Add(1)
+				return c.SendString(c.OriginalURL())
+			})
+			addr := listenUpstream(t, upstream)
+			app := fiber.New()
+			app.Use("/admin", forbid)
+			app.Use(h.build(addr))
+
+			// the guard still answers for the path it is mounted on
+			require.Equal(t, fiber.StatusForbidden, rawRequest(t, app, "/admin/secret", "example.com").StatusCode())
+			resp := rawRequest(t, app, "/public/page?x=1", "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode())
+			require.Equal(t, "/public/page?x=1", string(resp.Body()))
+			require.Equal(t, int32(1), hits.Load())
+
+			for _, target := range []string{
+				"/admin;x/secret",
+				"/admin;/secret",
+				"/;/admin/secret",
+				"/;x/admin/secret",
+				"/public/;/admin/secret",
+				"/public/..;/admin/secret",
+				"/public/.;x/../..;jsessionid=1/admin/secret",
+				// a parameter on an ordinary segment, whether or not it is the last
+				"/public;x/page",
+				"/public/page;jsessionid=1",
+				"/public/page;jsessionid=1?x=1",
+			} {
+				refused := rawRequest(t, app, target, "example.com")
+				require.Equal(t, fiber.StatusBadRequest, refused.StatusCode(), "%s: %s", target, refused.Body())
+			}
+			require.Equal(t, int32(1), hits.Load(), "the upstream must not see a path parameter")
+
+			// A ";" in the query is no path parameter.
+			resp = rawRequest(t, app, "/public/page?a=1;b=2", "example.com")
+			require.Equal(t, fiber.StatusOK, resp.StatusCode())
+			require.Equal(t, "/public/page?a=1;b=2", string(resp.Body()))
+
+			// With UnescapePath the router takes a ";" for part of the name
+			// it matches, "admin;x", which is no path under "/admin". It is
+			// forwarded as an escape, so the upstream reads that name too.
+			unescaping := fiber.New(fiber.Config{UnescapePath: true})
+			unescaping.Use("/admin", forbid)
+			unescaping.Use(h.build(addr))
+			for target, want := range map[string]string{
+				"/admin;x/secret":   "/admin%3Bx/secret",
+				"/admin%3Bx/secret": "/admin%3Bx/secret",
+				"/admin;/secret":    "/admin%3B/secret",
+				"/;/admin/secret":   "/%3B/admin/secret",
+			} {
+				resp := rawRequest(t, unescaping, target, "example.com")
+				require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
+				require.Equal(t, want, string(resp.Body()), "path read by the upstream for %q", target)
+			}
+		})
+	}
+}
+
 // Test_Proxy_EscapesRawBytes pins that a byte a path may not carry raw (RFC
 // 3986 Section 3.3) reaches the upstream as its escape, as fasthttp's
 // normalizing writer sent it before the proxy forwarded the routed path: an
 // upstream such as Tomcat answers 400 to a raw "|" or "{", and a raw byte of
-// UTF-8 is not a valid request line. The sub-delims, ":" and "@" stay raw.
+// UTF-8 is not a valid request line. The sub-delims, ":" and "@" stay raw, but
+// for the ";" that begins a path parameter (see Test_Proxy_RejectsPathParameters).
 func Test_Proxy_EscapesRawBytes(t *testing.T) {
 	t.Parallel()
 	addr := echoTarget(t)
 
-	handlers := map[string]func() fiber.Handler{
-		"Balancer":        func() fiber.Handler { return Balancer(Config{Servers: []string{addr}}) },
-		"DomainForward":   func() fiber.Handler { return DomainForward("example.com", "http://"+addr) },
-		"BalancerForward": func() fiber.Handler { return BalancerForward([]string{"http://" + addr}) },
-	}
-	for name, handler := range handlers {
-		t.Run(name, func(t *testing.T) {
+	for _, h := range forwardingHandlers() {
+		t.Run(h.name, func(t *testing.T) {
 			t.Parallel()
 			app := fiber.New()
-			app.Use(handler())
+			app.Use(h.build(addr))
 			for target, want := range map[string]string{
-				"/a|b{c}d":               "/a%7Cb%7Bc%7Dd",
-				"/q\"^<>`":               "/q%22%5E%3C%3E%60",
-				"/\xc3\xbcber?x=1":       "/%C3%BCber?x=1",
-				"/keep!$&'()*+,;=:@/end": "/keep!$&'()*+,;=:@/end",
+				"/a|b{c}d":              "/a%7Cb%7Bc%7Dd",
+				"/q\"^<>`":              "/q%22%5E%3C%3E%60",
+				"/\xc3\xbcber?x=1":      "/%C3%BCber?x=1",
+				"/keep!$&'()*+,=:@/end": "/keep!$&'()*+,=:@/end",
 			} {
 				resp := rawRequest(t, app, target, "example.com")
 				require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
@@ -425,13 +503,7 @@ func Test_Proxy_Balancer_RejectsAuthorityTarget(t *testing.T) {
 		hits.Add(1)
 		return c.SendString(c.OriginalURL() + "|" + string(c.Request().Header.Host()) + "|" + c.Get(fiber.HeaderAuthorization))
 	})
-	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
-	require.NoError(t, err)
-	t.Cleanup(func() {
-		ln.Close() //nolint:errcheck // It is fine to ignore the error here
-	})
-	startServer(target, ln)
-	addr := ln.Addr().String()
+	addr := listenUpstream(t, target)
 
 	for _, unescape := range []bool{false, true} {
 		app := fiber.New(fiber.Config{UnescapePath: unescape})
@@ -484,15 +556,7 @@ func echoIdentity(t *testing.T) string {
 	target.Use(func(c fiber.Ctx) error {
 		return c.SendString(c.OriginalURL() + "|" + string(c.Request().Header.Host()) + "|" + c.Get(fiber.HeaderAuthorization))
 	})
-
-	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
-	require.NoError(t, err)
-	t.Cleanup(func() {
-		ln.Close() //nolint:errcheck // It is fine to ignore the error here
-	})
-	startServer(target, ln)
-
-	return ln.Addr().String()
+	return listenUpstream(t, target)
 }
 
 // pinIdentity is a ModifyRequest that sets the Host and Authorization the
@@ -651,60 +715,130 @@ func Test_Proxy_BalancerForward_RejectsForgedEscape(t *testing.T) {
 	requireForgedEscapeRefused(t, rawRequest(t, app, "/static/%%370rivate/secret.txt", "example.com"), "")
 }
 
-// Test_Proxy_Balancer_AllowAmbiguousSlashes pins the opt-out: with
-// SecurityPolicy.AllowAmbiguousSlashes, Balancer forwards an escaped slash and
-// an empty segment as routed, for an upstream that keeps them, and still
-// refuses a forged escape, a backslash and a dot segment carrying parameters.
-func Test_Proxy_Balancer_AllowAmbiguousSlashes(t *testing.T) {
-	t.Parallel()
-	addr := echoTarget(t)
+// allowanceCase is one opt-in of SecurityPolicy and what the forwarding
+// handlers do under it: forwarded maps a target to what the upstream reads,
+// refused lists the targets answered 400 Bad Request. A forged escape is
+// refused, or forwarded as a literal name, under every allowance (see
+// requireForgedEscapeRefused).
+type allowanceCase struct {
+	allow     func(*SecurityPolicy)
+	forwarded map[string]string
+	name      string
+	refused   []string
+}
 
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-	policy.AllowAmbiguousSlashes = true
-	app := fiber.New()
-	app.Use(Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy}))
+// allowanceCases lists the opt-ins and their combination.
+func allowanceCases() []allowanceCase {
+	return []allowanceCase{
+		{
+			// an upstream that keeps "%2F" and "//" as sent, such as one
+			// addressing GitLab-style ids or object keys
+			name:  "AllowAmbiguousSlashes",
+			allow: func(p *SecurityPolicy) { p.AllowAmbiguousSlashes = true },
+			forwarded: map[string]string{
+				"/api/projects/group%2Fname": "/api/projects/group%2Fname",
+				"/bucket/key//with/empty":    "/bucket/key//with/empty",
+				"/a%2fb":                     "/a%2Fb",
+			},
+			// a path parameter still needs AllowPathParameters
+			refused: []string{"/admin\\secret", "/a/..%5Cb", "/a/..;/b", "/cart;jsessionid=abc", "/admin;x/secret"},
+		},
+		{
+			// an upstream that relies on ";jsessionid"
+			name:  "AllowPathParameters",
+			allow: func(p *SecurityPolicy) { p.AllowPathParameters = true },
+			forwarded: map[string]string{
+				"/cart;jsessionid=abc":   "/cart;jsessionid=abc",
+				"/shop;x/cart;y=1?q=1":   "/shop;x/cart;y=1?q=1",
+				"/admin;x/secret":        "/admin;x/secret",
+				"/;jsessionid=abc":       "/;jsessionid=abc",
+				"/app/;jsessionid=abc":   "/app/;jsessionid=abc",
+				"/keep!$&'()*+,;=:@/end": "/keep!$&'()*+,;=:@/end",
+			},
+			// a dot segment with parameters, a backslash and an escaped slash
+			// stay refused, and a segment of parameters alone before another
+			// segment is an empty one
+			refused: []string{
+				"/public/..;/admin", "/public/.;x/admin", "/..;jsessionid=1/a", "/a;x/..;/b",
+				"/admin\\secret", "/a/..%5Cb", "/a/..%2Fb", "/a%2Fb;c",
+				"/;/admin/secret", "/;x/admin", "/public/;/admin", "/a/;x/b",
+			},
+		},
+		{
+			name: "both",
+			allow: func(p *SecurityPolicy) {
+				p.AllowAmbiguousSlashes = true
+				p.AllowPathParameters = true
+			},
+			forwarded: map[string]string{
+				"/;/admin/secret":  "/;/admin/secret",
+				"/public/;x/admin": "/public/;x/admin",
+				"/a%2Fb;c":         "/a%2Fb;c",
+				"/group%2Fname;x":  "/group%2Fname;x",
+			},
+			// a dot segment carrying parameters is refused behind an escaped
+			// slash as behind a raw one
+			refused: []string{"/public/..;/admin", "/;/..;/admin", "/a%2F..;/b", "/%2F..;/b", "/a%2F.;x/b", "/admin\\secret"},
+		},
+	}
+}
+
+// check sends every target of the case to app, a Fiber app with a forwarding
+// handler built under the case's policy, and asserts the answers.
+func (tc allowanceCase) check(t *testing.T, app *fiber.App, label string) {
+	t.Helper()
 
-	for _, target := range []string{"/api/projects/group%2Fname", "/bucket/key//with/empty", "/a%2fb"} {
+	for target, want := range tc.forwarded {
 		resp := rawRequest(t, app, target, "example.com")
-		require.Equal(t, fiber.StatusOK, resp.StatusCode(), target)
-		require.Equal(t, strings.ReplaceAll(target, "%2f", "%2F"), string(resp.Body()), target)
+		require.Equal(t, fiber.StatusOK, resp.StatusCode(), "%s %s", label, target)
+		require.Equal(t, want, string(resp.Body()), "%s %s", label, target)
 	}
-	for _, target := range []string{"/x/%%370rivate", "/admin\\secret", "/a/..%5Cb", "/a/..;/b"} {
-		resp := rawRequest(t, app, target, "example.com")
-		if target == "/x/%%370rivate" && resp.StatusCode() == fiber.StatusOK {
-			// a router that writes the stray "%" as "%25" forwards the literal name
-			require.Equal(t, "/x/%2570rivate", string(resp.Body()))
-			continue
-		}
-		require.Equal(t, fiber.StatusBadRequest, resp.StatusCode(), target)
+	for _, target := range tc.refused {
+		require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), "%s %s", label, target)
 	}
+	requireForgedEscapeRefused(t, rawRequest(t, app, "/static/%%370rivate/secret.txt", "example.com"), "")
 }
 
-// Test_Proxy_Forward_AllowAmbiguousSlashes pins the same opt-out for
-// DomainForward and BalancerForward, which follow the global policy.
-func Test_Proxy_Forward_AllowAmbiguousSlashes(t *testing.T) {
-	// Not parallel: installs a global security policy.
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-	policy.AllowAmbiguousSlashes = true
-	withSecurityPolicyForTest(t, policy)
+// Test_Proxy_Balancer_Allowances pins each opt-in of SecurityPolicy on
+// Balancer, which reads it from Config.SecurityPolicy.
+func Test_Proxy_Balancer_Allowances(t *testing.T) {
+	t.Parallel()
 	addr := echoTarget(t)
 
-	handlers := map[string]fiber.Handler{
-		"DomainForward":   DomainForward("example.com", "http://"+addr),
-		"BalancerForward": BalancerForward([]string{"http://" + addr}),
+	for _, tc := range allowanceCases() {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+			policy := DefaultSecurityPolicy()
+			policy.AllowPrivateIPs = true
+			tc.allow(&policy)
+			app := fiber.New()
+			app.Use(Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy}))
+			tc.check(t, app, "Balancer")
+		})
 	}
-	for name, handler := range handlers {
-		app := fiber.New()
-		app.Use(handler)
-		for _, target := range []string{"/api/projects/group%2Fname", "/bucket/key//with/empty"} {
-			resp := rawRequest(t, app, target, "example.com")
-			require.Equal(t, fiber.StatusOK, resp.StatusCode(), "%s %s", name, target)
-			require.Equal(t, target, string(resp.Body()), "%s %s", name, target)
-		}
-		for _, target := range []string{"/admin\\secret", "/a/..;/b"} {
-			require.Equal(t, fiber.StatusBadRequest, rawRequest(t, app, target, "example.com").StatusCode(), "%s %s", name, target)
-		}
+}
+
+// Test_Proxy_Forward_Allowances pins the same opt-ins on DomainForward and
+// BalancerForward, which read the policy installed with WithSecurityPolicy.
+func Test_Proxy_Forward_Allowances(t *testing.T) {
+	// Not parallel: installs the global policy, which every other test in
+	// the package reads.
+	addr := echoTarget(t)
+
+	for _, tc := range allowanceCases() {
+		t.Run(tc.name, func(t *testing.T) {
+			policy := DefaultSecurityPolicy()
+			policy.AllowPrivateIPs = true
+			tc.allow(&policy)
+			withSecurityPolicyForTest(t, policy)
+			for _, h := range forwardingHandlers() {
+				if h.name == "Balancer" {
+					continue // reads Config.SecurityPolicy, not the installed policy
+				}
+				app := fiber.New()
+				app.Use(h.build(addr))
+				tc.check(t, app, h.name)
+			}
+		})
 	}
 }

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path internal/wiretarget/wiretarget_test.go --path middleware/adaptor/routed_test.go --path middleware/idempotency/idempotency_test.go --path middleware/idempotency/stub_test.go --path middleware/proxy/target_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/wiretarget ./middleware/adaptor ./middleware/idempotency ./middleware/proxy')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./internal/wiretarget ./middleware/adaptor ./middleware/idempotency ./middleware/proxy' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
