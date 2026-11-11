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
for f in middleware/limiter/limiter_test.go middleware/proxy/bench_test.go middleware/proxy/coverage_test.go middleware/proxy/fuzz_test.go middleware/proxy/lookupcache_test.go middleware/proxy/proxy_test.go middleware/proxy/security_rebinding_test.go middleware/proxy/security_test.go; do if git cat-file -e 45156761f9c6c998eb85c4079b12a7875cc7009d:"$f" 2>/dev/null; then git checkout 45156761f9c6c998eb85c4079b12a7875cc7009d -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 45156761f9c6c998eb85c4079b12a7875cc7009d "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/middleware/limiter/limiter_test.go b/middleware/limiter/limiter_test.go
index 3e6a3882286..294c4f932a3 100644
--- a/middleware/limiter/limiter_test.go
+++ b/middleware/limiter/limiter_test.go
@@ -8,6 +8,7 @@ import (
 	"math"
 	"net/http"
 	"net/http/httptest"
+	"runtime"
 	"strconv"
 	"strings"
 	"sync"
@@ -1354,28 +1355,91 @@ func Test_Limiter_Bug_NewErrorf_SkipSuccessfulRequests(t *testing.T) {
 	}
 }
 
-func Test_Limiter_NilConfigUsesDefaults(t *testing.T) {
+// A Config given straight to a strategy, or none, gets the defaults New would give it.
+func Test_Limiter_RawConfigUsesDefaults(t *testing.T) {
 	t.Parallel()
 
+	tests := []struct {
+		cfg   *Config
+		name  string
+		limit int
+	}{
+		{name: "nil", cfg: nil, limit: defaultLimiterMax},
+		{name: "ConfigDefault", cfg: &ConfigDefault, limit: defaultLimiterMax},
+		{name: "zero value", cfg: &Config{}, limit: defaultLimiterMax},
+		{name: "only Max", cfg: &Config{Max: 2}, limit: 2},
+		{name: "MaxFunc wins over Max", cfg: &Config{Max: 9, MaxFunc: func(fiber.Ctx) int { return 3 }}, limit: 3},
+		{name: "only ExpirationFunc", cfg: &Config{ExpirationFunc: func(fiber.Ctx) time.Duration { return time.Hour }}, limit: defaultLimiterMax},
+	}
+
 	for _, strategy := range windowStrategies {
-		t.Run(strategy.name, func(t *testing.T) {
-			t.Parallel()
+		for _, tc := range tests {
+			t.Run(strategy.name+"/"+tc.name, func(t *testing.T) {
+				t.Parallel()
 
-			app := fiber.New()
-			app.Use(strategy.handler.New(nil))
-			app.Get("/", func(c fiber.Ctx) error {
-				return c.SendStatus(fiber.StatusOK)
-			})
+				app := fiber.New()
+				app.Use(strategy.handler.New(tc.cfg))
+				app.Get("/", func(c fiber.Ctx) error {
+					return c.SendStatus(fiber.StatusOK)
+				})
+
+				for i := range tc.limit {
+					resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+					require.NoError(t, err)
+					require.Equal(t, fiber.StatusOK, resp.StatusCode, "request %d", i+1)
+					require.Equal(t, strconv.Itoa(tc.limit), resp.Header.Get(xRateLimitLimit), "request %d", i+1)
+				}
 
-			for range defaultLimiterMax {
 				resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
 				require.NoError(t, err)
-				require.Equal(t, fiber.StatusOK, resp.StatusCode)
-			}
+				require.Equal(t, fiber.StatusTooManyRequests, resp.StatusCode)
+			})
+		}
+	}
+}
 
-			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
-			require.NoError(t, err)
-			require.Equal(t, fiber.StatusTooManyRequests, resp.StatusCode)
+// A strategy given no Config uses the exported ConfigDefault as the application left it.
+//
+// Intentionally not parallel: it replaces ConfigDefault, and Go pauses parallel
+// tests while a sequential one runs.
+func Test_Limiter_NilConfigKeepsCustomizedDefault(t *testing.T) {
+	prev := ConfigDefault
+	t.Cleanup(func() { ConfigDefault = prev })
+	ConfigDefault.DisableHeaders = true
+
+	for _, strategy := range windowStrategies {
+		app := fiber.New()
+		app.Use(strategy.handler.New(nil))
+		app.Get("/", func(c fiber.Ctx) error {
+			return c.SendStatus(fiber.StatusOK)
+		})
+
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+		require.NoError(t, err, strategy.name)
+		require.Equal(t, fiber.StatusOK, resp.StatusCode, strategy.name)
+		require.Empty(t, resp.Header.Get(xRateLimitLimit), strategy.name)
+	}
+}
+
+// A strategy leaves the Config it is given alone: ConfigDefault is shared.
+func Test_Limiter_RawConfigIsNotModified(t *testing.T) {
+	t.Parallel()
+
+	for _, strategy := range windowStrategies {
+		t.Run(strategy.name, func(t *testing.T) {
+			t.Parallel()
+
+			for _, cfg := range []*Config{{Max: 2}, &ConfigDefault} {
+				before := *cfg
+				strategy.handler.New(cfg)
+
+				require.Nil(t, cfg.MaxFunc)
+				require.Nil(t, cfg.ExpirationFunc)
+				require.Equal(t, before.Max, cfg.Max)
+				require.Equal(t, before.Expiration, cfg.Expiration)
+				require.Equal(t, before.KeyGenerator == nil, cfg.KeyGenerator == nil)
+				require.Equal(t, before.LimitReached == nil, cfg.LimitReached == nil)
+			}
 		})
 	}
 }
@@ -1734,40 +1798,286 @@ func Test_Limiter_Sliding_MixedWindowsDoNotInflateThePreviousWindow(t *testing.T
 	require.Equal(t, "2", resp.Header.Get(xRateLimitRemaining))
 }
 
-// A handler overwriting the memory behind the key (c.Get does not copy) must not misdirect the credit.
+// limiterStores are the built-in store, which copies keys, and a Storage that keeps the string it is given.
+var limiterStores = []struct {
+	storage func() fiber.Storage
+	name    string
+}{
+	{name: "builtin", storage: func() fiber.Storage { return nil }},
+	{name: "keeps_key", storage: func() fiber.Storage { return newFakeLimiterStorage() }},
+}
+
+// keyOverwritingApp serves a handler that overwrites the memory behind the key (c.Get does not copy).
+func keyOverwritingApp(cfg *Config) *fiber.App {
+	cfg.Expiration = time.Minute
+	cfg.KeyGenerator = func(c fiber.Ctx) string { return c.Get("X-Client") }
+
+	app := fiber.New()
+	app.Use(New(*cfg))
+	app.Get("/", func(c fiber.Ctx) error {
+		// Same length, so fasthttp overwrites the key's bytes in place.
+		c.Request().Header.Set("X-Client", "BBBB")
+		return c.SendStatus(fiber.StatusOK)
+	})
+	return app
+}
+
+// sendAsClient sends a request under the key keyOverwritingApp's handler overwrites.
+func sendAsClient(t *testing.T, app *fiber.App) *http.Response {
+	t.Helper()
+
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Set("X-Client", "AAAA")
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	return resp
+}
+
+// A handler overwriting the memory behind the key must not misdirect the credit.
 func Test_Limiter_KeyOverwrittenByHandler(t *testing.T) {
 	t.Parallel()
 
 	for _, strategy := range windowStrategies {
-		t.Run(strategy.name, func(t *testing.T) {
-			t.Parallel()
+		for _, store := range limiterStores {
+			t.Run(strategy.name+"/"+store.name, func(t *testing.T) {
+				t.Parallel()
 
-			app := fiber.New()
-			app.Use(New(Config{
-				Max:                    1,
-				Expiration:             time.Minute,
-				SkipSuccessfulRequests: true,
-				LimiterMiddleware:      strategy.handler,
-				Storage:                newFakeLimiterStorage(),
-				KeyGenerator:           func(c fiber.Ctx) string { return c.Get("X-Client") },
-			}))
-			app.Get("/", func(c fiber.Ctx) error {
-				// Same length, so fasthttp overwrites the key's bytes in place.
-				c.Request().Header.Set("X-Client", "BBBB")
-				return c.SendStatus(fiber.StatusOK)
+				app := keyOverwritingApp(&Config{
+					Max:                    1,
+					SkipSuccessfulRequests: true,
+					LimiterMiddleware:      strategy.handler,
+					Storage:                store.storage(),
+				})
+				for i := range 3 {
+					require.Equal(t, fiber.StatusOK, sendAsClient(t, app).StatusCode, "request %d", i+1)
+				}
 			})
+		}
+	}
+}
 
-			for i := range 3 {
-				req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
-				req.Header.Set("X-Client", "AAAA")
-				resp, err := app.Test(req)
-				require.NoError(t, err)
+// A Storage that keeps the key it is given must not be handed memory the request owns, even when
+// nothing reads the entry again: the next request rewrites that memory and the client finds nothing.
+func Test_Limiter_KeyOverwrittenByHandler_NothingRereads(t *testing.T) {
+	t.Parallel()
+
+	for _, strategy := range windowStrategies {
+		for _, store := range limiterStores {
+			t.Run(strategy.name+"/"+store.name, func(t *testing.T) {
+				t.Parallel()
+
+				// The key aliases request memory, as c.Get does; the handler rewrites it, as the next request would.
+				first, second := []byte("AAAA"), []byte("AAAA")
+				current := first
+				app := fiber.New()
+				app.Use(New(Config{
+					Max:               1,
+					Expiration:        time.Minute,
+					DisableHeaders:    true,
+					KeyGenerator:      func(fiber.Ctx) string { return utils.UnsafeString(current) },
+					LimiterMiddleware: strategy.handler,
+					Storage:           store.storage(),
+				}))
+				app.Get("/", func(c fiber.Ctx) error {
+					copy(current, "BBBB")
+					return c.SendStatus(fiber.StatusOK)
+				})
+
+				status := func() int {
+					resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+					require.NoError(t, err)
+					require.NoError(t, resp.Body.Close())
+					return resp.StatusCode
+				}
+				require.Equal(t, fiber.StatusOK, status(), "first request")
+				current = second
+				require.Equal(t, fiber.StatusTooManyRequests, status(), "the same client, again")
+			})
+		}
+	}
+}
+
+// A handler overwriting the key must not misdirect the sliding window's header refresh.
+func Test_Limiter_KeyOverwrittenByHandler_Headers(t *testing.T) {
+	t.Parallel()
+
+	for _, store := range limiterStores {
+		t.Run(store.name, func(t *testing.T) {
+			t.Parallel()
+
+			app := keyOverwritingApp(&Config{Max: 5, LimiterMiddleware: SlidingWindow{}, Storage: store.storage()})
+			for i, remaining := range []string{"4", "3", "2"} {
+				resp := sendAsClient(t, app)
 				require.Equal(t, fiber.StatusOK, resp.StatusCode, "request %d", i+1)
+				require.Equal(t, remaining, resp.Header.Get(xRateLimitRemaining), "request %d", i+1)
+			}
+		})
+	}
+}
+
+// rejectingHandler returns a handler and context for a limiter whose Max requests are used up.
+func rejectingHandler(tb testing.TB, cfg *Config, expiration time.Duration) (fasthttp.RequestHandler, *fasthttp.RequestCtx) {
+	tb.Helper()
+
+	cfg.Max = 1
+	cfg.Expiration = expiration
+	cfg.KeyGenerator = func(fiber.Ctx) string { return testLimiterClientKey }
+
+	app := fiber.New()
+	app.Use(New(*cfg))
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	h := app.Handler()
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	fctx.Request.SetRequestURI("/")
+
+	h(fctx)
+	return h, fctx
+}
+
+// A rejected request never reaches the handler, so it skips the key copy made for the read after it.
+//
+// Intentionally not parallel: testing.AllocsPerRun panics when called from a parallel test.
+func Test_Limiter_RejectDoesNotCopyKey(t *testing.T) {
+	rejectAllocs := func(t *testing.T, cfg Config) float64 {
+		t.Helper()
+
+		// A Retry-After under 100 formats without allocating.
+		h, fctx := rejectingHandler(t, &cfg, time.Minute)
+		h(fctx)
+		require.Equal(t, fiber.StatusTooManyRequests, fctx.Response.StatusCode())
+
+		// The fewest of many single runs, not an average: under -race sync.Pool drops a quarter of
+		// what it is handed at random, so an average varies from one run to the next.
+		fewest := math.MaxFloat64
+		for range 200 {
+			fewest = min(fewest, testing.AllocsPerRun(1, func() { h(fctx) }))
+		}
+		return fewest
+	}
+
+	for _, strategy := range windowStrategies {
+		t.Run(strategy.name, func(t *testing.T) {
+			bare := rejectAllocs(t, Config{LimiterMiddleware: strategy.handler, DisableHeaders: true})
+			// SkipSuccessfulRequests refunds every hit here, so nothing would be rejected.
+			rereading := rejectAllocs(t, Config{LimiterMiddleware: strategy.handler, DisableHeaders: true, SkipFailedRequests: true})
+			require.InDelta(t, bare, rereading, 0, "the Skip options must not add to a rejected request")
+
+			// Sliding also re-reads the entry for the headers.
+			if strategy.name == "sliding" {
+				headers := rejectAllocs(t, Config{LimiterMiddleware: strategy.handler})
+				require.InDelta(t, bare, headers, 0, "the header refresh must not add to a rejected request")
 			}
 		})
 	}
 }
 
+// admittedHandler returns a handler and context for a limiter that admits every request, with the
+// headers off and, unless cfg has its own, the key testLimiterClientKey.
+func admittedHandler(tb testing.TB, cfg *Config) (fasthttp.RequestHandler, *fasthttp.RequestCtx) {
+	tb.Helper()
+
+	cfg.Max = math.MaxInt32
+	cfg.Expiration = time.Minute
+	cfg.DisableHeaders = true
+	if cfg.KeyGenerator == nil {
+		cfg.KeyGenerator = func(fiber.Ctx) string { return testLimiterClientKey }
+	}
+
+	app := fiber.New()
+	app.Use(New(*cfg))
+	app.Get("/", func(c fiber.Ctx) error {
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	h := app.Handler()
+	fctx := &fasthttp.RequestCtx{}
+	fctx.Request.Header.SetMethod(fiber.MethodGet)
+	fctx.Request.SetRequestURI("/")
+
+	h(fctx)
+	require.Equal(tb, fiber.StatusOK, fctx.Response.StatusCode())
+	return h, fctx
+}
+
+// The built-in store copies the keys it keeps, so an admitted request copies the key only for the re-read.
+//
+// Intentionally not parallel: testing.AllocsPerRun panics when called from a parallel test.
+func Test_Limiter_AdmitCopiesKeyOnlyForReread(t *testing.T) {
+	admitAllocs := func(t *testing.T, cfg Config) float64 {
+		t.Helper()
+
+		h, fctx := admittedHandler(t, &cfg)
+
+		fewest := math.MaxFloat64
+		for range 200 {
+			fewest = min(fewest, testing.AllocsPerRun(1, func() { h(fctx) }))
+		}
+		return fewest
+	}
+
+	for _, strategy := range windowStrategies {
+		t.Run(strategy.name, func(t *testing.T) {
+			bare := admitAllocs(t, Config{LimiterMiddleware: strategy.handler})
+			// A 200 is not a failed request, so SkipFailedRequests adds the copy and no second read.
+			rereading := admitAllocs(t, Config{LimiterMiddleware: strategy.handler, SkipFailedRequests: true})
+			require.InDelta(t, bare+1, rereading, 0, "only the re-read may copy the key")
+		})
+	}
+}
+
+// With the built-in store an admitted request allocates the key once, in the store, and once more when
+// the limiter reads the entry again after the handler. A copy made before that, as a Storage that may
+// keep the key needs, would be one more on every request.
+//
+// Intentionally not parallel: it counts the allocations of the whole process.
+func Test_Limiter_AdmitKeyCopiesWithBuiltInStore(t *testing.T) {
+	const shortLen, longLen = 8, 160 // a longer key than 192 bytes is hashed before it reaches the store
+
+	// The bytes an admitted request allocates: the fewest of many single runs, as in the tests above.
+	admitBytes := func(t *testing.T, cfg Config, keyLen int) float64 {
+		t.Helper()
+
+		key := strings.Repeat("k", keyLen)
+		cfg.KeyGenerator = func(fiber.Ctx) string { return key }
+		h, fctx := admittedHandler(t, &cfg)
+
+		fewest := math.MaxFloat64
+		var before, after runtime.MemStats
+		for range 400 {
+			runtime.ReadMemStats(&before)
+			h(fctx)
+			runtime.ReadMemStats(&after)
+			fewest = min(fewest, float64(after.TotalAlloc-before.TotalAlloc))
+		}
+		return fewest
+	}
+
+	for _, strategy := range windowStrategies {
+		for _, tc := range []struct {
+			name   string
+			cfg    Config
+			copies float64
+		}{
+			{name: "admit", cfg: Config{}, copies: 1},
+			// A 200 is not a failed request, so SkipFailedRequests adds the re-read.
+			{name: "re-read", cfg: Config{SkipFailedRequests: true}, copies: 2},
+		} {
+			t.Run(strategy.name+"/"+tc.name, func(t *testing.T) {
+				cfg := tc.cfg
+				cfg.LimiterMiddleware = strategy.handler
+
+				// What a request allocates grows with the key by one key length per copy of it.
+				copies := (admitBytes(t, cfg, longLen) - admitBytes(t, cfg, shortLen)) / (longLen - shortLen)
+				require.Less(t, copies, tc.copies+0.5, "%.2f copies of the key per request", copies)
+			})
+		}
+	}
+}
+
 func Test_Limiter_DisableValueRedaction_ShowsBoundedKey(t *testing.T) {
 	t.Parallel()
 
@@ -2029,6 +2339,33 @@ func Benchmark_Limiter_Admit(b *testing.B) {
 	}
 }
 
+// Benchmark_Limiter_Reject measures requests the limit rejects: the handler never runs.
+//
+// go test -v -run=^$ -bench=Benchmark_Limiter_Reject -benchmem -count=4
+func Benchmark_Limiter_Reject(b *testing.B) {
+	benchmarks := []struct {
+		name string
+		cfg  Config
+	}{
+		{name: "fixed", cfg: Config{LimiterMiddleware: FixedWindow{}}},
+		{name: "fixed_skip_failed", cfg: Config{LimiterMiddleware: FixedWindow{}, SkipFailedRequests: true}},
+		{name: "sliding", cfg: Config{LimiterMiddleware: SlidingWindow{}}},
+		{name: "sliding_disable_headers", cfg: Config{LimiterMiddleware: SlidingWindow{}, DisableHeaders: true}},
+	}
+
+	for _, bm := range benchmarks {
+		b.Run(bm.name, func(b *testing.B) {
+			h, fctx := rejectingHandler(b, &bm.cfg, time.Hour)
+
+			b.ReportAllocs()
+
+			for b.Loop() {
+				h(fctx)
+			}
+		})
+	}
+}
+
 // go test -run Test_Sliding_Window -race -v
 func Test_Sliding_Window(t *testing.T) {
 	t.Parallel()
diff --git a/middleware/proxy/bench_test.go b/middleware/proxy/bench_test.go
index f72deda4e0a..ca2fe58ee94 100644
--- a/middleware/proxy/bench_test.go
+++ b/middleware/proxy/bench_test.go
@@ -8,15 +8,13 @@ import (
 	"net/url"
 	"sync"
 	"testing"
+	"time"
 
 	"github.com/gofiber/fiber/v3"
 	"github.com/valyala/fasthttp"
 )
 
-// These benchmarks are the baseline that the PR description's
-// performance table compares against. Each one targets a specific hot
-// path identified during the perf survey so subsequent changes can
-// produce a benchstat-grade before/after.
+// These benchmarks are the performance baseline: each targets a hot path.
 //
 // All benchmarks call b.ReportAllocs() so allocation regressions are
 // caught even when ns/op is noise. They use the testing.B.Loop form
@@ -69,7 +67,7 @@ func BenchmarkValidateUpstream_IPLiteral(b *testing.B) {
 	const addr = "http://203.0.113.5:8080/api/v1/widgets"
 	b.ReportAllocs()
 	for b.Loop() {
-		if _, err := validateUpstream(addr, policy); err != nil {
+		if _, err := validateUpstream(addr, policy, nil); err != nil {
 			b.Fatal(err)
 		}
 	}
@@ -90,16 +88,14 @@ func BenchmarkResolveRedirect_HTTPSDowngradeBlocked(b *testing.B) {
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
 	location := []byte("http://example.com/landing")
-	// Anchor: assert once that we're actually measuring the blocked
-	// downgrade path. Without this, a regression that started allowing
-	// the redirect would leave the benchmark green while measuring a
-	// different path.
-	if _, err := resolveRedirect("https://example.com/", location, policy); !errors.Is(err, ErrRedirectDowngrade) {
-		b.Fatalf("expected ErrRedirectDowngrade, got %v", err)
-	}
 	b.ReportAllocs()
+	var err error
 	for b.Loop() {
-		_, _ = resolveRedirect("https://example.com/", location, policy) //nolint:errcheck // bench
+		_, err = resolveRedirect("https://example.com/", location, policy, nil)
+	}
+	// Anchor: the loop must have measured the blocked downgrade path.
+	if !errors.Is(err, ErrRedirectDowngrade) {
+		b.Fatalf("expected ErrRedirectDowngrade, got %v", err)
 	}
 }
 
@@ -109,7 +105,7 @@ func BenchmarkResolveRedirect_AllowedAcrossOrigin(b *testing.B) {
 	location := []byte("https://other.example/landing")
 	b.ReportAllocs()
 	for b.Loop() {
-		if _, err := resolveRedirect("https://example.com/", location, policy); err != nil {
+		if _, err := resolveRedirect("https://example.com/", location, policy, nil); err != nil {
 			b.Fatal(err)
 		}
 	}
@@ -194,9 +190,7 @@ func BenchmarkIsBlockedIP_PublicV4(b *testing.B) {
 
 // BenchmarkFollowRedirects_NoRedirect isolates the followRedirects entry
 // cost — initial URL handling, request setup, and one cli.Do call that
-// returns 204 (no Location). The bench measures the work that P6
-// targets: the validateUpstream call that used to run on the initial
-// URL inside followRedirects.
+// returns 204 (no Location). The URL arrives validated, so no validateUpstream is measured.
 func BenchmarkFollowRedirects_NoRedirect(b *testing.B) {
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
@@ -222,7 +216,7 @@ func BenchmarkFollowRedirects_NoRedirect(b *testing.B) {
 		req.Reset()
 		req.SetRequestURI(initialURL.String())
 		req.Header.SetMethod(fasthttp.MethodGet)
-		if err := followRedirects(cli, req, resp, 3, initialURL, policy, true); err != nil {
+		if err := followRedirects(cli, req, resp, 3, initialURL, policy); err != nil {
 			b.Fatal(err)
 		}
 	}
@@ -233,25 +227,9 @@ func BenchmarkFollowRedirects_NoRedirect(b *testing.B) {
 // closure executes from its first statement through the call into
 // doActionWithPolicy. The action callback short-circuits so the
 // downstream action work (cli.Do) is not measured — this isolates the
-// constructor-vs-per-request split that P2 targets.
+// per-request work from the one-time construction work.
 func BenchmarkDomainForward_HostMatchPath(b *testing.B) {
-	// Construction-time validation requires a passing upstream.
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-	prev := WithSecurityPolicy(policy)
-	b.Cleanup(func() { WithSecurityPolicy(prev) })
-
-	// Stash & restore the global proxy client so the benchmark uses a
-	// no-op transport instead of dialing.
-	noopClient := &fasthttp.Client{
-		Transport: noopRoundTripper{},
-	}
-	prevClient := client.Swap(noopClient)
-	b.Cleanup(func() {
-		if prevClient != nil {
-			client.Store(prevClient)
-		}
-	})
+	benchNoopUpstream(b)
 
 	app := fiber.New()
 	app.Use(DomainForward("api.example", "http://203.0.113.5:8080"))
@@ -274,6 +252,68 @@ func BenchmarkDomainForward_HostMatchPath(b *testing.B) {
 	}
 }
 
+// benchNoopUpstream points the runtime helpers at an upstream that answers 204 without dialing.
+func benchNoopUpstream(b *testing.B) {
+	b.Helper()
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	withSecurityPolicyForTest(b, policy)
+
+	restoreGlobalProxyClient(b)
+	sharedClient.Store(&fasthttp.Client{Transport: noopRoundTripper{}})
+}
+
+// benchProxyPath sends a GET through app per iteration on a bare fasthttp context; the upstream must answer 204.
+func benchProxyPath(b *testing.B, app *fiber.App, host, target string) {
+	b.Helper()
+	var req fasthttp.Request
+	req.SetRequestURI(target)
+	req.Header.SetHost(host)
+	handler := app.Handler()
+	remote := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 9), Port: 40000}
+
+	var fctx fasthttp.RequestCtx
+	b.ReportAllocs()
+	for b.Loop() {
+		fctx.Init(&req, remote, nil)
+		handler(&fctx)
+		if got := fctx.Response.StatusCode(); got != fasthttp.StatusNoContent {
+			b.Fatalf("status = %d, want %d", got, fasthttp.StatusNoContent)
+		}
+	}
+}
+
+// BenchmarkBalancer_ProxyPath measures a request through Balancer to an upstream that never dials.
+func BenchmarkBalancer_ProxyPath(b *testing.B) {
+	lbc := &fasthttp.LBClient{
+		Timeout: time.Second,
+		Clients: []fasthttp.BalancingClient{
+			&fasthttp.HostClient{Addr: "203.0.113.5:8080", Transport: noopRoundTripper{}},
+		},
+	}
+	app := fiber.New()
+	app.Use(Balancer(Config{Client: lbc}))
+	benchProxyPath(b, app, "api.example", "/v1/widgets?q=1")
+}
+
+// BenchmarkForward_ProxyPath measures a request through Forward.
+func BenchmarkForward_ProxyPath(b *testing.B) {
+	benchNoopUpstream(b)
+
+	app := fiber.New()
+	app.Use(Forward("http://203.0.113.5:8080/v1/widgets"))
+	benchProxyPath(b, app, "api.example", "/anything")
+}
+
+// BenchmarkBalancerForward_ProxyPath measures a request through BalancerForward.
+func BenchmarkBalancerForward_ProxyPath(b *testing.B) {
+	benchNoopUpstream(b)
+
+	app := fiber.New()
+	app.Use(BalancerForward([]string{"http://203.0.113.5:8080", "http://203.0.113.6:8080"}))
+	benchProxyPath(b, app, "api.example", "/v1/widgets?q=1")
+}
+
 func BenchmarkURLRoundrobinGet(b *testing.B) {
 	pool := []*url.URL{
 		{Scheme: schemeHTTP, Host: "a.example"},
diff --git a/middleware/proxy/coverage_test.go b/middleware/proxy/coverage_test.go
index bd10aedde60..2f7ba18ad54 100644
--- a/middleware/proxy/coverage_test.go
+++ b/middleware/proxy/coverage_test.go
@@ -33,7 +33,7 @@ func (stubConn) SetWriteDeadline(time.Time) error { return nil }
 // fast path that skips DNS entirely.
 func Test_Coverage_ResolveAndValidateHost_IPLiteralOK(t *testing.T) {
 	t.Parallel()
-	ips, err := resolveAndValidateHost("8.8.8.8")
+	ips, err := resolveAndValidateHost("8.8.8.8", time.Time{})
 	require.NoError(t, err)
 	require.Len(t, ips, 1)
 	require.True(t, ips[0].Equal(net.ParseIP("8.8.8.8")))
@@ -43,7 +43,7 @@ func Test_Coverage_ResolveAndValidateHost_IPLiteralOK(t *testing.T) {
 // post-resolution loop that rejects a blocked IP literal.
 func Test_Coverage_ResolveAndValidateHost_BlocksIPLiteral(t *testing.T) {
 	t.Parallel()
-	_, err := resolveAndValidateHost("127.0.0.1")
+	_, err := resolveAndValidateHost("127.0.0.1", time.Time{})
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
@@ -52,7 +52,7 @@ func Test_Coverage_ResolveAndValidateHost_BlocksIPLiteral(t *testing.T) {
 // never resolves and therefore never depends on outbound DNS.
 func Test_Coverage_ResolveAndValidateHost_LookupFails(t *testing.T) {
 	t.Parallel()
-	_, err := resolveAndValidateHost("definitely-not-a-real-host.invalid")
+	_, err := resolveAndValidateHost("definitely-not-a-real-host.invalid", time.Time{})
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
@@ -61,38 +61,33 @@ func Test_Coverage_ResolveAndValidateHost_LookupFails(t *testing.T) {
 func Test_Coverage_DialValidatedIPs_SuccessOnIPv4(t *testing.T) {
 	t.Parallel()
 	called := atomic.Bool{}
-	conn, err := dialValidatedIPs(
-		[]net.IP{net.ParseIP("203.0.113.1")},
-		"example.test", "80", false,
-		func(network, addr string) (net.Conn, error) {
-			called.Store(true)
-			require.Equal(t, "tcp", network)
-			require.Equal(t, "203.0.113.1:80", addr)
-			return stubConn{addr: addr}, nil
-		},
-	)
+	guard := dialGuard{dial: func(network, addr string) (net.Conn, error) {
+		called.Store(true)
+		require.Equal(t, "tcp", network)
+		require.Equal(t, "203.0.113.1:80", addr)
+		return stubConn{addr: addr}, nil
+	}}
+	conn, err := guard.dialValidatedIPs([]net.IP{net.ParseIP("203.0.113.1")}, "example.test", "80")
 	require.NoError(t, err)
 	require.NotNil(t, conn)
 	require.True(t, called.Load())
 }
 
-// Test_Coverage_DialValidatedIPs_SkipsV6_WhenNoDualStack covers the
-// IPv4-only branch: an IPv6 candidate is skipped before any dial is
-// attempted, leaving the loop with no candidates and producing the
-// "no usable address" sentinel error.
+// Test_Coverage_DialValidatedIPs_SkipsV6_WhenNoDualStack covers the IPv4-only branch: an IPv6
+// candidate is skipped before any dial, and the error does not match ErrUpstreamHostBlocked, since
+// nothing was blocked.
 func Test_Coverage_DialValidatedIPs_SkipsV6_WhenNoDualStack(t *testing.T) {
 	t.Parallel()
 	called := atomic.Bool{}
-	_, err := dialValidatedIPs(
-		[]net.IP{net.ParseIP("2606:4700:4700::1111")},
-		"example.test", "80", false,
-		func(string, string) (net.Conn, error) {
-			called.Store(true)
-			return nil, errors.New("should not dial")
-		},
-	)
-	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
-	require.Contains(t, err.Error(), "no usable address")
+	guard := dialGuard{dial: func(string, string) (net.Conn, error) {
+		called.Store(true)
+		return nil, errors.New("should not dial")
+	}}
+	_, err := guard.dialValidatedIPs([]net.IP{net.ParseIP("2606:4700:4700::1111")}, "example.test", "80")
+	require.ErrorIs(t, err, errIPv6Only)
+	require.NotErrorIs(t, err, ErrUpstreamHostBlocked)
+	require.NotErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	require.ErrorContains(t, err, "example.test has only IPv6 addresses, and DialDualStack is off")
 	require.False(t, called.Load(), "IPv6 candidate must be skipped without dialing")
 }
 
@@ -103,14 +98,11 @@ func Test_Coverage_DialValidatedIPs_FallsBackOnError(t *testing.T) {
 	t.Parallel()
 	sentinel := errors.New("dial-refused")
 	var attempts atomic.Int32
-	_, err := dialValidatedIPs(
-		[]net.IP{net.ParseIP("203.0.113.1"), net.ParseIP("203.0.113.2")},
-		"example.test", "80", false,
-		func(string, string) (net.Conn, error) {
-			attempts.Add(1)
-			return nil, sentinel
-		},
-	)
+	guard := dialGuard{dial: func(string, string) (net.Conn, error) {
+		attempts.Add(1)
+		return nil, sentinel
+	}}
+	_, err := guard.dialValidatedIPs([]net.IP{net.ParseIP("203.0.113.1"), net.ParseIP("203.0.113.2")}, "example.test", "80")
 	require.ErrorIs(t, err, sentinel)
 	require.Equal(t, int32(2), attempts.Load())
 }
@@ -121,37 +113,34 @@ func Test_Coverage_DialValidatedIPs_FallsBackOnError(t *testing.T) {
 func Test_Coverage_DialValidatedIPs_DualStackTriesV6(t *testing.T) {
 	t.Parallel()
 	var addr string
-	_, err := dialValidatedIPs(
-		[]net.IP{net.ParseIP("2606:4700:4700::1111")},
-		"example.test", "443", true,
-		func(_, a string) (net.Conn, error) {
-			addr = a
-			return stubConn{addr: a}, nil
-		},
-	)
+	guard := dialGuard{dualStack: true, dial: func(_, a string) (net.Conn, error) {
+		addr = a
+		return stubConn{addr: a}, nil
+	}}
+	_, err := guard.dialValidatedIPs([]net.IP{net.ParseIP("2606:4700:4700::1111")}, "example.test", "443")
 	require.NoError(t, err)
 	require.Equal(t, "[2606:4700:4700::1111]:443", addr)
 }
 
-// Test_Coverage_NewSSRFDialer_RejectsLoopbackHostname drives the
+// Test_Coverage_DialChecked_RejectsLoopbackHostname drives the
 // SplitHostPort → resolveAndValidateHost → blocked-IP rejection branch.
-func Test_Coverage_NewSSRFDialer_RejectsLoopbackHostname(t *testing.T) {
+func Test_Coverage_DialChecked_RejectsLoopbackHostname(t *testing.T) {
 	t.Parallel()
-	dial := newSSRFDialer(false)
+	dial := newDialGuard(false).dialChecked
 	_, err := dial("localhost:65535")
 	require.Error(t, err)
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
-// Test_Coverage_NewSSRFDialer_PassesGuardThenDials covers the post-guard
-// dial dispatch (the final return inside newSSRFDialer). TEST-NET-1
+// Test_Coverage_DialChecked_PassesGuardThenDials covers the post-guard
+// dial dispatch (the final return inside dialGuard.dialChecked). TEST-NET-1
 // (192.0.2.0/24, RFC 5737) is reserved for documentation and not in the
 // blocked ranges, so it survives the SSRF check; the dial itself fails
 // fast because the kernel has no route. We only assert that an error
 // surfaced — the *type* of error depends on the host's networking stack.
-func Test_Coverage_NewSSRFDialer_PassesGuardThenDials(t *testing.T) {
+func Test_Coverage_DialChecked_PassesGuardThenDials(t *testing.T) {
 	t.Parallel()
-	dial := newSSRFDialer(true) // dualStack so the dial loop is reached
+	dial := newDialGuard(true).dialChecked // dualStack so the dial loop is reached
 	_, err := dial("192.0.2.1:1")
 	require.Error(t, err)
 }
@@ -165,7 +154,7 @@ func Test_Coverage_NewSSRFDialer_PassesGuardThenDials(t *testing.T) {
 // could disagree with the second lookup in restricted CI.
 func Test_Coverage_ValidateHostForSSRF_PublicHostname(t *testing.T) {
 	t.Parallel()
-	err := validateHostForSSRF("one.one.one.one")
+	err := validateHostForSSRF("one.one.one.one", nil)
 	if _, ok := errors.AsType[*net.DNSError](err); ok {
 		t.Skipf("offline DNS, skipping: %v", err)
 	}
@@ -179,7 +168,7 @@ func Test_Coverage_ResolveRedirect_RejectsHostlessTarget(t *testing.T) {
 	t.Parallel()
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	_, err := resolveRedirect("https://example.com", []byte("http://"), policy)
+	_, err := resolveRedirect("https://example.com", []byte("http://"), policy, nil)
 	require.ErrorIs(t, err, fasthttp.ErrorInvalidURI)
 }
 
@@ -241,13 +230,20 @@ func Test_Coverage_ConfigDefault_PanicsOnEmptyServersAndNoClient(t *testing.T) {
 	})
 }
 
-// Test_Coverage_ConfigDefault_NoArgsReturnsDefault covers the
-// variadic-empty branch where configDefault is called with no args.
-func Test_Coverage_ConfigDefault_NoArgsReturnsDefault(t *testing.T) {
+// Test_Coverage_ConfigDefault_FillsDefaults checks the defaults for a Config with Servers or a Client.
+func Test_Coverage_ConfigDefault_FillsDefaults(t *testing.T) {
 	t.Parallel()
-	cfg := configDefault()
-	require.Equal(t, ConfigDefault.Timeout, cfg.Timeout)
-	require.Equal(t, ConfigDefault.MaxConnsPerHost, cfg.MaxConnsPerHost)
+	for name, in := range map[string]Config{
+		"servers": {Servers: []string{"http://upstream.example"}},
+		"client":  {Client: &fasthttp.LBClient{}},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+			cfg := configDefault(in)
+			require.Equal(t, ConfigDefault.Timeout, cfg.Timeout)
+			require.Equal(t, ConfigDefault.MaxConnsPerHost, cfg.MaxConnsPerHost)
+		})
+	}
 }
 
 // Test_Coverage_DialValidatedIPs_SkipsV6ThenDialsV4 verifies the
@@ -256,14 +252,11 @@ func Test_Coverage_ConfigDefault_NoArgsReturnsDefault(t *testing.T) {
 func Test_Coverage_DialValidatedIPs_SkipsV6ThenDialsV4(t *testing.T) {
 	t.Parallel()
 	var dialed string
-	conn, err := dialValidatedIPs(
-		[]net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("203.0.113.5")},
-		"example.test", "443", false,
-		func(_, addr string) (net.Conn, error) {
-			dialed = addr
-			return stubConn{addr: addr}, nil
-		},
-	)
+	guard := dialGuard{dial: func(_, addr string) (net.Conn, error) {
+		dialed = addr
+		return stubConn{addr: addr}, nil
+	}}
+	conn, err := guard.dialValidatedIPs([]net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("203.0.113.5")}, "example.test", "443")
 	require.NoError(t, err)
 	require.NotNil(t, conn)
 	require.Equal(t, "203.0.113.5:443", dialed)
@@ -302,3 +295,17 @@ func Test_Coverage_DomainForward_HostMismatch_DoesNotProxy(t *testing.T) {
 	// a 5xx from dialing 127.0.0.1:1.
 	require.NotEqual(t, fiber.StatusInternalServerError, resp.StatusCode)
 }
+
+// Test_Coverage_CanFastJoinPath_RepeatedSeparator covers a second '?' or '#' left to the url.Parse path.
+func Test_Coverage_CanFastJoinPath_RepeatedSeparator(t *testing.T) {
+	t.Parallel()
+
+	for _, target := range []string{"/a?b?c", "/a?b#c", "/a#b?c", "/a#b#c"} {
+		require.False(t, canFastJoinPath(target), target)
+	}
+	require.True(t, canFastJoinPath("/a?b"))
+
+	base := mustParseTestURL(t, "http://upstream.example")
+	require.Equal(t, "http://upstream.example/a?b?c", joinUpstreamPath(base, "/a?b?c"))
+	require.Equal(t, "http://upstream.example/a?b#c", joinUpstreamPath(base, "/a?b#c"))
+}
diff --git a/middleware/proxy/fuzz_test.go b/middleware/proxy/fuzz_test.go
index 8a28780a46d..cb9c9385c6e 100644
--- a/middleware/proxy/fuzz_test.go
+++ b/middleware/proxy/fuzz_test.go
@@ -44,7 +44,7 @@ func FuzzValidateUpstream(f *testing.F) {
 	policy.AllowPrivateIPs = true // focus on scheme/host parsing, not SSRF here
 
 	f.Fuzz(func(t *testing.T, raw string) {
-		u, err := validateUpstream(raw, policy)
+		u, err := validateUpstream(raw, policy, nil)
 		if err != nil {
 			return
 		}
@@ -118,7 +118,7 @@ func FuzzJoinUpstreamPath(f *testing.F) {
 	})
 }
 
-// FuzzConnectionListedHeaders ensures the RFC 7230 Connection-header
+// FuzzConnectionListedHeaders ensures the RFC 9110 §7.6.1 Connection-header
 // parser tolerates pathological inputs (excess whitespace, embedded
 // commas, control bytes) without panicking, on the request's walk and the
 // response's alike, and that no listing takes X-Real-IP with it.
@@ -155,6 +155,6 @@ func FuzzConnectionListedHeaders(f *testing.F) {
 		res.Header.Set(fiber.HeaderConnection, v)
 		res.Header.Set("X-Foo", "1")
 		res.Header.Set("X-Bar", "2")
-		delConnectionListedHeaders(&res.Header, res.Header.PeekAll(fiber.HeaderConnection), true)
+		delConnectionListedHeaders(&res.Header, res.Header.PeekAll(fiber.HeaderConnection))
 	})
 }
diff --git a/middleware/proxy/lookupcache_test.go b/middleware/proxy/lookupcache_test.go
new file mode 100644
index 00000000000..969846b7d78
--- /dev/null
+++ b/middleware/proxy/lookupcache_test.go
@@ -0,0 +1,204 @@
+package proxy
+
+import (
+	"net"
+	"net/http"
+	"net/http/httptest"
+	"sync/atomic"
+	"testing"
+	"time"
+
+	"github.com/gofiber/fiber/v3"
+	"github.com/stretchr/testify/require"
+	"github.com/valyala/fasthttp"
+)
+
+// Test_LookupCache pins when an answer is served again: for the same host from
+// the same resolver until the TTL ends, and until another host takes its slot.
+func Test_LookupCache(t *testing.T) {
+	t.Parallel()
+
+	now := time.Unix(1000, 0)
+	cache := newLookupCache(1, time.Second, func() time.Time { return now }) // one slot: every host collides
+	first, second := &net.Resolver{}, &net.Resolver{}
+	addrs := []net.IPAddr{{IP: net.ParseIP("198.51.100.7")}}
+
+	_, ok := cache.get("a.test", first)
+	require.False(t, ok, "nothing is remembered yet")
+
+	cache.put("a.test", first, addrs)
+	got, ok := cache.get("a.test", first)
+	require.True(t, ok)
+	require.Equal(t, addrs, got)
+
+	_, ok = cache.get("a.test", second)
+	require.False(t, ok, "another resolver's answer is not this one's")
+	_, ok = cache.get("b.test", first)
+	require.False(t, ok, "another host that maps to the same slot")
+
+	now = now.Add(time.Second - time.Nanosecond)
+	_, ok = cache.get("a.test", first)
+	require.True(t, ok, "just before the TTL ends")
+	now = now.Add(time.Nanosecond)
+	_, ok = cache.get("a.test", first)
+	require.False(t, ok, "when the TTL ends")
+
+	cache.put("a.test", first, addrs)
+	cache.put("b.test", first, addrs)
+	_, ok = cache.get("a.test", first)
+	require.False(t, ok, "replaced by a host that shares its slot")
+}
+
+// Test_Security_ValidateHostForSSRF_RemembersTheLookup pins what the cache is for and where it stops:
+// the up-front check looks a name up once, the dial guard every time, and a refused answer stays refused.
+func Test_Security_ValidateHostForSSRF_RemembersTheLookup(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide DNS resolver.
+	public := net.IPv4(198, 51, 100, 1)
+	dnsAddr, aQueries := startRebindingDNS(t, public, public)
+	withRebindingResolver(t, dnsAddr)
+
+	for range 3 {
+		require.NoError(t, validateHostForSSRF("remembered.test", upfrontLookups))
+	}
+	require.Equal(t, int64(1), aQueries.Load(), "the up-front check looks the name up once")
+
+	for range 2 {
+		_, err := resolveAndValidateHost("remembered.test", time.Time{})
+		require.NoError(t, err)
+	}
+	require.Equal(t, int64(3), aQueries.Load(), "the dial guard looks it up every time")
+
+	private := net.IPv4(10, 0, 0, 1)
+	dnsAddr, aQueries = startRebindingDNS(t, private, private)
+	withRebindingResolver(t, dnsAddr)
+
+	for range 3 {
+		require.ErrorIs(t, validateHostForSSRF("internal.test", upfrontLookups), ErrUpstreamHostBlocked)
+	}
+	require.Equal(t, int64(1), aQueries.Load(), "a refused answer is held, and refused, each time")
+}
+
+// Test_Security_LookupHost_RemembersASmallAnswerOnly pins that an answer with more addresses than
+// lookupCacheMaxAddrs is judged and forgotten, so a name's owner cannot make every slot large.
+func Test_Security_LookupHost_RemembersASmallAnswerOnly(t *testing.T) {
+	t.Parallel()
+
+	for name, tc := range map[string]struct {
+		addrs      int
+		remembered bool
+	}{
+		"at the cap":   {addrs: lookupCacheMaxAddrs, remembered: true},
+		"over the cap": {addrs: lookupCacheMaxAddrs + 1},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			resolver := resolverFor(startManyAnswersDNS(t, tc.addrs))
+			cache := newLookupCache(16, time.Minute, time.Now)
+
+			addrs, err := lookupHost(resolver, "big.test", cache, time.Time{})
+			require.NoError(t, err)
+			require.Len(t, addrs, tc.addrs, "the caller gets the whole answer either way")
+
+			_, remembered := cache.get("big.test", resolver)
+			require.Equal(t, tc.remembered, remembered)
+		})
+	}
+}
+
+// Test_Security_LookupHost_EndsAtTheDeadline pins that the lookup of a dial gives up with the time the
+// request left it, not at the lookup limit.
+func Test_Security_LookupHost_EndsAtTheDeadline(t *testing.T) {
+	t.Parallel()
+
+	_, err := lookupHost(net.DefaultResolver, "deadline.test", nil, time.Now().Add(-time.Second))
+	require.ErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	var dnsErr *net.DNSError
+	require.ErrorAs(t, err, &dnsErr)
+	require.True(t, dnsErr.IsTimeout, "%v", err)
+}
+
+// Test_Security_LookupsFor pins which clients the up-front check may serve from the cache: only the
+// shared client, whose dials are checked again where they are made.
+func Test_Security_LookupsFor(t *testing.T) {
+	// Intentionally not parallel: it reads and replaces the process-wide client.
+	restoreGlobalProxyClient(t)
+
+	shared := &fasthttp.Client{}
+	WithClient(shared)
+	require.Same(t, upfrontLookups, lookupsFor(shared))
+	require.Nil(t, lookupsFor(&fasthttp.Client{}), "a client passed per call may have dialed before the guard reached it")
+
+	dialsByItself := &fasthttp.Client{Transport: noopRoundTripper{}}
+	WithClient(dialsByItself)
+	require.Nil(t, lookupsFor(dialsByItself), "a client with a Transport is not covered by the dial guard")
+}
+
+// Test_Security_Do_UnguardedClientIsJudgedByAFreshLookup pins that a client the dial guard cannot
+// cover never sees the cache: a name rebound within the cache's lifetime is judged by its new answer.
+func Test_Security_Do_UnguardedClientIsJudgedByAFreshLookup(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide DNS resolver and security policy.
+	policy := DefaultSecurityPolicy() // AllowPrivateIPs == false
+	withSecurityPolicyForTest(t, policy)
+
+	// The first A answer for a name is public; every one after is internal.
+	dnsAddr, _ := startRebindingDNS(t, net.IPv4(198, 51, 100, 1), net.IPv4(10, 0, 0, 1))
+	withRebindingResolver(t, dnsAddr)
+
+	// What the cache does: the second judgment is the first answer, remembered.
+	_, err := validateUpstream("http://cached.test/", policy, upfrontLookups)
+	require.NoError(t, err)
+	_, err = validateUpstream("http://cached.test/", policy, upfrontLookups)
+	require.NoError(t, err)
+	_, err = validateUpstream("http://cached.test/", policy, nil)
+	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+
+	// The client below dials by itself: only the up-front check stands between it and the internal answer.
+	var served atomic.Int32
+	client := &fasthttp.Client{Transport: roundTripperFunc(func(_ *fasthttp.Request, resp *fasthttp.Response) error {
+		served.Add(1)
+		resp.SetStatusCode(fiber.StatusNoContent)
+		return nil
+	})}
+	app := fiber.New()
+	app.Get("/", func(c fiber.Ctx) error { return Do(c, "http://fresh.test/", client) })
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusNoContent, resp.StatusCode)
+	require.NoError(t, resp.Body.Close())
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusInternalServerError, resp.StatusCode, "the rebound answer is judged")
+	require.NoError(t, resp.Body.Close())
+	require.Equal(t, int32(1), served.Load(), "and the second request never reaches the transport")
+}
+
+// Test_Security_FollowRedirects_UnguardedClientHopsAreJudgedByFreshLookups pins that the hops of a
+// redirect an unguarded client follows never see the cache: a name rebound between hops is caught.
+func Test_Security_FollowRedirects_UnguardedClientHopsAreJudgedByFreshLookups(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide DNS resolver.
+	// The first A answer for a name is public; every one after is internal.
+	dnsAddr, _ := startRebindingDNS(t, net.IPv4(198, 51, 100, 1), net.IPv4(10, 0, 0, 1))
+	withRebindingResolver(t, dnsAddr)
+
+	var hops []string
+	client, _ := newCountingRedirectClient(map[string]redirectStep{
+		"http://start.example/": {status: fasthttp.StatusFound, location: "http://rebind.test/a"},
+		"http://rebind.test/a":  {status: fasthttp.StatusFound, location: "http://rebind.test/b"},
+	})
+	client.onRequest = func(req *fasthttp.Request) { hops = append(hops, req.URI().String()) }
+
+	req := fasthttp.AcquireRequest()
+	resp := fasthttp.AcquireResponse()
+	t.Cleanup(func() {
+		fasthttp.ReleaseRequest(req)
+		fasthttp.ReleaseResponse(resp)
+	})
+	req.SetRequestURI("http://start.example/")
+
+	err := followRedirects(client.client, req, resp, 5, mustParseTestURL(t, "http://start.example/"), DefaultSecurityPolicy())
+	require.ErrorIs(t, err, ErrUpstreamHostBlocked, "the second hop to the rebound name is judged by its new answer")
+	require.Equal(t, []string{"http://start.example/", "http://rebind.test/a"}, hops, "and never sent")
+}
diff --git a/middleware/proxy/proxy_test.go b/middleware/proxy/proxy_test.go
index 0e05f90deef..dc50521699f 100644
--- a/middleware/proxy/proxy_test.go
+++ b/middleware/proxy/proxy_test.go
@@ -8,7 +8,10 @@ import (
 	"net/http"
 	"net/http/httptest"
 	"os"
+	"strconv"
 	"strings"
+	"sync"
+	"sync/atomic"
 	"testing"
 	"time"
 
@@ -101,18 +104,48 @@ func createRedirectServer(t *testing.T) string {
 	return addr
 }
 
-func restoreGlobalProxyClient(t *testing.T) {
-	t.Helper()
+func restoreGlobalProxyClient(tb testing.TB) {
+	tb.Helper()
 
-	prev := client.Load()
-	t.Cleanup(func() {
+	prev := sharedClient.Load()
+	tb.Cleanup(func() {
 		WithClient(prev)
 	})
 }
 
 // go test -run Test_Proxy_DefaultClient_MaxConnsPerHost
 func Test_Proxy_DefaultClient_MaxConnsPerHost(t *testing.T) {
-	require.Equal(t, defaultMaxConnsPerHost, client.Load().MaxConnsPerHost)
+	t.Parallel()
+	require.Equal(t, defaultMaxConnsPerHost, sharedClient.Load().MaxConnsPerHost)
+}
+
+// Test_Proxy_Balancer_LeavesConfiguredClientAlone pins that Balancer does not write to a host client
+// that already has DisablePathNormalizing: another goroutine may be reading it (run under -race).
+func Test_Proxy_Balancer_LeavesConfiguredClientAlone(t *testing.T) {
+	t.Parallel()
+
+	hc := &fasthttp.HostClient{Addr: "127.0.0.1:1", DisablePathNormalizing: true}
+	var reads atomic.Int64
+	var stop atomic.Bool
+	var wg sync.WaitGroup
+	wg.Go(func() {
+		for !stop.Load() {
+			if hc.DisablePathNormalizing {
+				reads.Add(1)
+			}
+		}
+	})
+	t.Cleanup(func() {
+		stop.Store(true)
+		wg.Wait()
+	})
+	readsMoreThan := func(n int64) func() bool { return func() bool { return reads.Load() > n } }
+
+	require.Eventually(t, readsMoreThan(0), 5*time.Second, time.Millisecond, "the reader is running before the build")
+
+	Balancer(Config{Client: &fasthttp.LBClient{Clients: []fasthttp.BalancingClient{hc}}})
+
+	require.Eventually(t, readsMoreThan(reads.Load()+1000), 5*time.Second, time.Millisecond, "and is still reading after it")
 }
 
 // go test -run Test_Proxy_ConfigDefault_MaxConnsPerHost
@@ -208,6 +241,8 @@ func Test_Proxy(t *testing.T) {
 }
 
 // go test -run Test_Proxy_Balancer_WithTlsConfig
+//
+// The balancer does not speak TLS itself, but the request must still reach the upstream as https.
 func Test_Proxy_Balancer_WithTlsConfig(t *testing.T) {
 	t.Parallel()
 
@@ -219,33 +254,113 @@ func Test_Proxy_Balancer_WithTlsConfig(t *testing.T) {
 
 	ln = tls.NewListener(ln, serverTLSConf)
 
-	app := fiber.New()
-
-	app.Get("/tlsbalancer", func(c fiber.Ctx) error {
+	upstream := fiber.New()
+	upstream.Get("/tlsbalancer", func(c fiber.Ctx) error {
 		return c.SendString("tls balancer")
 	})
+	startServer(upstream, ln)
 
-	addr := ln.Addr().String()
-	clientTLSConf := &tls.Config{InsecureSkipVerify: true}
-
+	app := fiber.New()
 	// disable certificate verification in Balancer
 	app.Use(Balancer(Config{
-		Servers:   []string{addr},
-		TLSConfig: clientTLSConf,
+		Servers:   []string{"https://" + ln.Addr().String()},
+		TLSConfig: &tls.Config{InsecureSkipVerify: true},
 	}))
 
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/tlsbalancer", http.NoBody), fiber.TestConfig{
+		Timeout:       5 * time.Second,
+		FailOnTimeout: true,
+	})
+	require.NoError(t, err)
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.NoError(t, resp.Body.Close())
+	require.Equal(t, fiber.StatusOK, resp.StatusCode, string(body))
+	require.Equal(t, "tls balancer", string(body))
+}
+
+// go test -run Test_Proxy_Balancer_PlainUpstreamBehindTLS
+//
+// The other way round: the balancer sits behind a TLS listener and its upstream is plain HTTP.
+func Test_Proxy_Balancer_PlainUpstreamBehindTLS(t *testing.T) {
+	t.Parallel()
+
+	_, upstreamAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		return c.SendString("plain upstream")
+	})
+
+	gatewayTLSConf, _, err := tlstest.GetTLSConfigs()
+	require.NoError(t, err)
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	ln = tls.NewListener(ln, gatewayTLSConf)
+	gatewayAddr := ln.Addr().String()
+
+	app := fiber.New()
+	app.Use(Balancer(Config{Servers: []string{"http://" + upstreamAddr}}))
 	startServer(app, ln)
 
 	client := clientpkg.New()
-	client.SetTLSConfig(clientTLSConf)
+	client.SetTimeout(5 * time.Second)
+	client.TLSConfig().InsecureSkipVerify = true
 
-	resp, err := client.Get("https://" + addr + "/tlsbalancer")
+	resp, err := client.Get("https://" + gatewayAddr)
 	require.NoError(t, err)
-	require.Equal(t, fiber.StatusOK, resp.StatusCode())
-	require.Equal(t, "tls balancer", string(resp.Body()))
+	require.Equal(t, fiber.StatusOK, resp.StatusCode(), string(resp.Body()))
+	require.Equal(t, "plain upstream", string(resp.Body()))
 	resp.Close()
 }
 
+// go test -run Test_Proxy_Balancer_MixedSchemes
+//
+// Each upstream of a mixed list is reached with its own scheme, whichever one the request arrived on.
+func Test_Proxy_Balancer_MixedSchemes(t *testing.T) {
+	t.Parallel()
+
+	_, plainAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		return c.SendString("plain")
+	})
+	serverTLSConf, _, err := tlstest.GetTLSConfigs()
+	require.NoError(t, err)
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	ln = tls.NewListener(ln, serverTLSConf)
+	secure := fiber.New()
+	secure.Get("/", func(c fiber.Ctx) error { return c.SendString("secure") })
+	startServer(secure, ln)
+
+	app := fiber.New()
+	app.Use(Balancer(Config{
+		Servers:   []string{"http://" + plainAddr, "https://" + ln.Addr().String()},
+		TLSConfig: &tls.Config{InsecureSkipVerify: true},
+	}))
+
+	seen := map[string]int{}
+	for range 6 {
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody), fiber.TestConfig{
+			Timeout:       5 * time.Second,
+			FailOnTimeout: true,
+		})
+		require.NoError(t, err)
+		body, err := io.ReadAll(resp.Body)
+		require.NoError(t, err)
+		require.NoError(t, resp.Body.Close())
+		require.Equal(t, fiber.StatusOK, resp.StatusCode, string(body))
+		seen[string(body)]++
+	}
+	require.Equal(t, map[string]int{"plain": 3, "secure": 3}, seen)
+}
+
+// go test -run Test_Proxy_Balancer_EmptyClientPanicsAtStartup
+func Test_Proxy_Balancer_EmptyClientPanicsAtStartup(t *testing.T) {
+	t.Parallel()
+
+	// fasthttp would panic on the first request, and nothing above the handler recovers it.
+	require.PanicsWithValue(t, "Client.Clients cannot be empty", func() {
+		Balancer(Config{Client: &fasthttp.LBClient{}})
+	})
+}
+
 // go test -run Test_Proxy_Balancer_IPv6_Upstream
 func Test_Proxy_Balancer_IPv6_Upstream(t *testing.T) {
 	t.Parallel()
@@ -362,6 +477,96 @@ func Test_Proxy_Forward_WithTlsConfig_To_Http(t *testing.T) {
 	resp.Close()
 }
 
+// Test_Proxy_DoRedirects_AppliesSchemePerHopBehindTLS pins that every hop is sent with the scheme of
+// its own URL: a copied hop would keep the TLS mark of the gateway's request and speak TLS to plain HTTP.
+func Test_Proxy_DoRedirects_AppliesSchemePerHopBehindTLS(t *testing.T) {
+	t.Parallel()
+
+	_, finalAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		return c.SendString("final")
+	})
+	_, redirectAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		c.Location("http://" + finalAddr + "/")
+		return c.Status(fiber.StatusFound).SendString("redirect")
+	})
+
+	gatewayTLSConf, _, err := tlstest.GetTLSConfigs()
+	require.NoError(t, err)
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	ln = tls.NewListener(ln, gatewayTLSConf)
+	gatewayAddr := ln.Addr().String()
+
+	app := fiber.New()
+	app.Get("/", func(c fiber.Ctx) error {
+		return DoRedirects(c, "http://"+redirectAddr+"/", 3)
+	})
+	startServer(app, ln)
+
+	client := clientpkg.New()
+	client.SetTimeout(5 * time.Second)
+	client.TLSConfig().InsecureSkipVerify = true
+
+	resp, err := client.Get("https://" + gatewayAddr)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode())
+	require.Equal(t, "final", string(resp.Body()))
+	resp.Close()
+}
+
+// Test_Proxy_DoRedirects_StreamedRequestBody pins that a method-keeping redirect of a streamed
+// request (StreamRequestBody) is followed when the first hop left the whole body in memory.
+func Test_Proxy_DoRedirects_StreamedRequestBody(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range []struct {
+		name       string
+		body       string
+		wantBody   string
+		wantStatus int
+		wantFinals int32
+	}{
+		{name: "empty", wantStatus: fiber.StatusOK, wantBody: "POST:0", wantFinals: 1},
+		{name: "small", body: "payload", wantStatus: fiber.StatusOK, wantBody: "POST:7", wantFinals: 1},
+		{name: "more than is read ahead", body: strings.Repeat("a", 8*1024+1), wantStatus: fiber.StatusInternalServerError, wantBody: fasthttp.ErrRedirectBodyStream.Error()},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var finals atomic.Int32 // requests that reached the target of the redirect
+			upstream := fiber.New()
+			ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+			require.NoError(t, err)
+			addr := ln.Addr().String()
+			upstream.Post("/start", func(c fiber.Ctx) error {
+				return c.Redirect().Status(fiber.StatusTemporaryRedirect).To("http://" + addr + "/final")
+			})
+			upstream.Post("/final", func(c fiber.Ctx) error {
+				finals.Add(1)
+				return c.SendString(c.Method() + ":" + strconv.Itoa(len(c.Body())))
+			})
+			startServer(upstream, ln)
+
+			app := fiber.New(fiber.Config{StreamRequestBody: true})
+			app.Post("/", func(c fiber.Ctx) error {
+				return DoRedirects(c, "http://"+addr+"/start", 3)
+			})
+
+			req := httptest.NewRequest(fiber.MethodPost, "/", strings.NewReader(tc.body))
+			req.Header.Set(fiber.HeaderContentLength, strconv.Itoa(len(tc.body)))
+			resp, err := app.Test(req, fiber.TestConfig{Timeout: 5 * time.Second, FailOnTimeout: true})
+			require.NoError(t, err)
+			defer func() { require.NoError(t, resp.Body.Close()) }()
+
+			body, err := io.ReadAll(resp.Body)
+			require.NoError(t, err)
+			require.Equal(t, tc.wantStatus, resp.StatusCode)
+			require.Equal(t, tc.wantBody, string(body))
+			require.Equal(t, tc.wantFinals, finals.Load(), "requests that reached the target of the redirect")
+		})
+	}
+}
+
 // go test -run Test_Proxy_Forward
 func Test_Proxy_Forward(t *testing.T) {
 	t.Parallel()
@@ -696,6 +901,7 @@ func Test_Proxy_Do_ConnectionCannotRemoveRealIP(t *testing.T) {
 
 // go test -run Test_Proxy_Forward_WithClient_TLSConfig
 func Test_Proxy_Forward_WithClient_TLSConfig(t *testing.T) {
+	// Intentionally not parallel: WithClient replaces the process-wide shared client.
 	restoreGlobalProxyClient(t)
 
 	serverTLSConf, _, err := tlstest.GetTLSConfigs()
@@ -935,15 +1141,8 @@ func Test_Proxy_Do_WithRedirect(t *testing.T) {
 }
 
 // go test -race -run Test_Proxy_DoRedirects_RestoreOriginalURL
-// Test_Proxy_DoRedirects_AliasedAddr regression-tests P3+P6: the addr
-// string is derived from c.OriginalURL() and therefore aliases the
-// fasthttp request's internal requestURI buffer. After P6, the *url.URL
-// returned by validateUpstream is passed into followRedirects, which
-// reads u.Host on the cross-host strip check and u.String() to feed
-// SetRequestURI. If u's field slices were ever aliased back to the
-// request buffer, SetRequestURI's overwrite would corrupt them mid-loop
-// and the redirect target would be garbled. P3 fixes this by cloning
-// addr once at the parse boundary inside doActionWithPolicy.
+// Test_Proxy_DoRedirects_AliasedAddr covers an addr that aliases the request buffer (c.OriginalURL()):
+// doActionWithPolicy clones it once, or SetRequestURI would corrupt a *url.URL still pointing into it.
 func Test_Proxy_DoRedirects_AliasedAddr(t *testing.T) {
 	t.Parallel()
 
@@ -1037,6 +1236,7 @@ func Test_Proxy_DoTimeout_RestoreOriginalURL(t *testing.T) {
 
 // go test -race -run Test_Proxy_DoTimeout_Timeout
 func Test_Proxy_DoTimeout_Timeout(t *testing.T) {
+	// Intentionally not parallel: it measures a timeout, so it must not compete for CPU.
 	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
 		time.Sleep(time.Second * 5)
 		return c.SendString("proxied")
@@ -1084,6 +1284,7 @@ func Test_Proxy_DoDeadline_RestoreOriginalURL(t *testing.T) {
 
 // go test -race -run Test_Proxy_DoDeadline_PastDeadline
 func Test_Proxy_DoDeadline_PastDeadline(t *testing.T) {
+	// Intentionally not parallel: it measures a deadline, so it must not compete for CPU.
 	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
 		time.Sleep(time.Second * 5)
 		return c.SendString("proxied")
@@ -1131,6 +1332,7 @@ func Test_Proxy_Do_HTTP_Prefix_URL(t *testing.T) {
 
 // go test -race -run Test_Proxy_Forward_Global_Client
 func Test_Proxy_Forward_Global_Client(t *testing.T) {
+	// Intentionally not parallel: WithClient replaces the process-wide shared client.
 	restoreGlobalProxyClient(t)
 	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
 	require.NoError(t, err)
@@ -1139,7 +1341,7 @@ func Test_Proxy_Forward_Global_Client(t *testing.T) {
 		DisablePathNormalizing:   true,
 		MaxConnsPerHost:          123,
 	})
-	loadedClient := client.Load()
+	loadedClient := sharedClient.Load()
 	require.NotNil(t, loadedClient)
 	require.Equal(t, 123, loadedClient.MaxConnsPerHost)
 
@@ -1764,9 +1966,8 @@ func matchingFieldLines(c fiber.Ctx, names ...string) []string {
 	return found
 }
 
-// Test_Proxy_HopByHopHeadersStrippedWhateverTheirCase checks that the RFC 7230
-// Section 6.1 strip holds for a peer that spells the names in lower case, which
-// is what HTTP/2 and HTTP/3 require on the wire.
+// Test_Proxy_HopByHopHeadersStrippedWhateverTheirCase checks that the RFC 9110 §7.6.1 strip holds
+// for names in lower case, as HTTP/2 and HTTP/3 require on the wire.
 //
 // Del matches the stored key byte for byte, so under DisableHeaderNormalizing
 // it removed nothing: the hop-by-hop headers reached the upstream, and so did a
@@ -2016,3 +2217,164 @@ func Test_Proxy_HostWithoutPort(t *testing.T) {
 		require.Equal(t, tc.out, hostWithoutPort(tc.in), "in=%q", tc.in)
 	}
 }
+
+// go test -run Test_Proxy_Balancer_NoArgsPanicsAtStartup
+func Test_Proxy_Balancer_NoArgsPanicsAtStartup(t *testing.T) {
+	t.Parallel()
+
+	// No default upstream exists, so Balancer() stops at startup, as Balancer(Config{}) does.
+	require.PanicsWithValue(t, "Servers cannot be empty", func() { Balancer() })
+}
+
+// go test -run Test_Proxy_NewHostClient
+func Test_Proxy_NewHostClient(t *testing.T) {
+	t.Parallel()
+
+	cfg := Config{
+		MaxConnsPerHost:     7,
+		ReadBufferSize:      2048,
+		WriteBufferSize:     3072,
+		MaxResponseBodySize: 4096,
+		DialDualStack:       true,
+	}
+	strict := DefaultSecurityPolicy()
+	relaxed := DefaultSecurityPolicy()
+	relaxed.AllowPrivateIPs = true
+
+	t.Run("carries the config", func(t *testing.T) {
+		t.Parallel()
+
+		hc := newHostClient(mustParseTestURL(t, "http://upstream.example:8080"), &cfg, strict)
+		require.Equal(t, "upstream.example:8080", hc.Addr)
+		require.False(t, hc.IsTLS)
+		require.Equal(t, 7, hc.MaxConns)
+		require.Equal(t, 2048, hc.ReadBufferSize)
+		require.Equal(t, 3072, hc.WriteBufferSize)
+		require.Equal(t, 4096, hc.MaxResponseBodySize)
+		require.True(t, hc.DialDualStack)
+		require.True(t, hc.DisablePathNormalizing)
+		require.True(t, hc.NoDefaultUserAgentHeader)
+	})
+
+	t.Run("https gets TLS with a floor", func(t *testing.T) {
+		t.Parallel()
+
+		hc := newHostClient(mustParseTestURL(t, "https://upstream.example"), &cfg, strict)
+		require.True(t, hc.IsTLS)
+		require.NotNil(t, hc.TLSConfig)
+		require.Equal(t, uint16(tls.VersionTLS12), hc.TLSConfig.MinVersion)
+	})
+
+	t.Run("guards the dial unless private IPs are allowed", func(t *testing.T) {
+		t.Parallel()
+
+		guarded := newHostClient(mustParseTestURL(t, "http://upstream.example"), &cfg, strict)
+		require.NotNil(t, guarded.Dial)
+		_, err := guarded.Dial("127.0.0.1:80")
+		require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+
+		open := newHostClient(mustParseTestURL(t, "http://upstream.example"), &cfg, relaxed)
+		require.Nil(t, open.Dial)
+		require.Nil(t, open.DialTimeout)
+	})
+
+	// fasthttp hands the timeout a request leaves for the connect only to a DialTimeout.
+	t.Run("guards the dial timeout too", func(t *testing.T) {
+		t.Parallel()
+
+		guarded := newHostClient(mustParseTestURL(t, "http://upstream.example"), &cfg, strict)
+		require.NotNil(t, guarded.DialTimeout)
+		for _, timeout := range []time.Duration{0, time.Second} {
+			_, err := guarded.DialTimeout("127.0.0.1:80", timeout)
+			require.ErrorIs(t, err, ErrUpstreamHostBlocked, "timeout %v", timeout)
+		}
+	})
+
+	// Only fasthttp's own dialer adds the port, and the guard's does not.
+	t.Run("adds the port its scheme defaults to", func(t *testing.T) {
+		t.Parallel()
+
+		for raw, want := range map[string]string{
+			"http://upstream.example":           "upstream.example:80",
+			"https://upstream.example":          "upstream.example:443",
+			"http://upstream.example:8080":      "upstream.example:8080",
+			"https://upstream.example:8443":     "upstream.example:8443",
+			"http://[2001:db8::1]":              "[2001:db8::1]:80",
+			"https://[2001:db8::1]":             "[2001:db8::1]:443",
+			"http://[2001:db8::1]:8080":         "[2001:db8::1]:8080",
+			"http://203.0.113.5":                "203.0.113.5:80",
+			"https://upstream.example:443":      "upstream.example:443",
+			"http://upstream.example:80":        "upstream.example:80",
+			"https://[2001:db8::1]:8443":        "[2001:db8::1]:8443",
+			"http://upstream.example.:8080":     "upstream.example.:8080",
+			"http://xn--bcher-kva.example/":     "xn--bcher-kva.example:80",
+			"https://xn--bcher-kva.example:444": "xn--bcher-kva.example:444",
+		} {
+			hc := newHostClient(mustParseTestURL(t, raw), &cfg, strict)
+			require.Equal(t, want, hc.Addr, raw)
+		}
+	})
+}
+
+// go test -run Test_Proxy_Balancer_MaxResponseBodySize
+func Test_Proxy_Balancer_MaxResponseBodySize(t *testing.T) {
+	t.Parallel()
+
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		return c.SendString(strings.Repeat("x", 64))
+	})
+
+	for name, tc := range map[string]struct {
+		limit   int
+		wantErr bool
+	}{
+		"over the limit":   {limit: 16, wantErr: true},
+		"within the limit": {limit: 128},
+		"unbounded":        {limit: 0},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			var handled error
+			app := fiber.New(fiber.Config{ErrorHandler: func(c fiber.Ctx, err error) error {
+				handled = err
+				return c.SendStatus(fiber.StatusBadGateway)
+			}})
+			app.Use(Balancer(Config{Servers: []string{addr}, MaxResponseBodySize: tc.limit}))
+
+			resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+			require.NoError(t, err)
+			if tc.wantErr {
+				require.ErrorIs(t, handled, fasthttp.ErrBodyTooLarge)
+				require.Equal(t, fiber.StatusBadGateway, resp.StatusCode)
+				return
+			}
+			require.NoError(t, handled)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+		})
+	}
+}
+
+// go test -run Test_Proxy_Balancer_WriteBufferSize
+//
+// Headers larger than WriteBufferSize must still arrive whole.
+func Test_Proxy_Balancer_WriteBufferSize(t *testing.T) {
+	t.Parallel()
+
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		return c.SendString(strconv.Itoa(len(c.Get(fiber.HeaderCookie))))
+	})
+
+	app := fiber.New()
+	app.Use(Balancer(Config{Servers: []string{addr}, WriteBufferSize: 256}))
+
+	cookie := "session=" + strings.Repeat("a", 2000)
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Set(fiber.HeaderCookie, cookie)
+
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, strconv.Itoa(len(cookie)), string(body))
+}
diff --git a/middleware/proxy/security_rebinding_test.go b/middleware/proxy/security_rebinding_test.go
index 0969e2d3661..39626d4162c 100644
--- a/middleware/proxy/security_rebinding_test.go
+++ b/middleware/proxy/security_rebinding_test.go
@@ -126,6 +126,58 @@ func buildDNSResponse(id uint16, q *dnsmessage.Question, ip net.IP) ([]byte, err
 	return out, nil
 }
 
+// startManyAnswersDNS starts a loopback UDP DNS server that answers every A query with n distinct
+// public addresses and every AAAA query with an empty NODATA response. It returns its "host:port".
+func startManyAnswersDNS(t *testing.T, n int) string {
+	t.Helper()
+
+	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() { pc.Close() }) //nolint:errcheck // best-effort close in cleanup
+
+	go func() {
+		buf := make([]byte, 512)
+		for {
+			size, addr, rerr := pc.ReadFrom(buf)
+			if rerr != nil {
+				return // listener closed
+			}
+			var p dnsmessage.Parser
+			hdr, perr := p.Start(buf[:size])
+			if perr != nil {
+				continue
+			}
+			q, perr := p.Question()
+			if perr != nil {
+				continue
+			}
+
+			b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: hdr.ID, Response: true, Authoritative: true})
+			b.EnableCompression()
+			if b.StartQuestions() != nil || b.Question(q) != nil || b.StartAnswers() != nil {
+				continue
+			}
+			if q.Type == dnsmessage.TypeA {
+				for i := range n {
+					rerr := b.AResource(dnsmessage.ResourceHeader{
+						Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET,
+					}, dnsmessage.AResource{A: [4]byte{198, 51, 100, byte(i + 1)}})
+					if rerr != nil {
+						break
+					}
+				}
+			}
+			resp, ferr := b.Finish()
+			if ferr != nil {
+				continue
+			}
+			pc.WriteTo(resp, addr) //nolint:errcheck // best-effort UDP reply
+		}
+	}()
+
+	return pc.LocalAddr().String()
+}
+
 // withRebindingResolver points the proxy's SSRF-validation resolver at the
 // fake DNS server at dnsAddr for the duration of t, restoring the previous
 // resolver via t.Cleanup. It swaps the package's atomic dnsResolver seam
@@ -134,14 +186,61 @@ func buildDNSResponse(id uint16, q *dnsmessage.Question, ip net.IP) ([]byte, err
 // must not call t.Parallel: the seam is process-global.
 func withRebindingResolver(t *testing.T, dnsAddr string) {
 	t.Helper()
-	prev := dnsResolver.Load()
-	dnsResolver.Store(&net.Resolver{
+	prev := dnsResolver.Swap(resolverFor(dnsAddr))
+	t.Cleanup(func() { dnsResolver.Store(prev) })
+}
+
+// resolverFor returns a resolver that sends every query to the fake DNS server at dnsAddr, leaving
+// the process-wide seam alone.
+func resolverFor(dnsAddr string) *net.Resolver {
+	return &net.Resolver{
 		PreferGo: true,
 		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
 			return (&net.Dialer{}).DialContext(ctx, "udp", dnsAddr)
 		},
+	}
+}
+
+// startSilentDNS starts a loopback UDP socket that never answers, and returns its "host:port".
+func startSilentDNS(t *testing.T) string {
+	t.Helper()
+
+	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() { pc.Close() }) //nolint:errcheck // best-effort close in cleanup
+	return pc.LocalAddr().String()
+}
+
+// recordedDial is a connect asked of one of the dialers a guard connects through.
+type recordedDial struct {
+	via     string
+	addr    string
+	timeout time.Duration
+}
+
+// withRecordedDialers puts stand-ins for the five dialers a guard connects through where it finds
+// them, for the duration of t, and returns the connects they are asked for. Process-wide: not parallel.
+func withRecordedDialers(t *testing.T) *[]recordedDial {
+	t.Helper()
+
+	var dials []recordedDial
+	record := func(via, addr string, timeout time.Duration) net.Conn {
+		dials = append(dials, recordedDial{via: via, addr: addr, timeout: timeout})
+		return stubConn{addr: addr}
+	}
+	prev := fasthttpDialers.Swap(&dialFuncs{
+		dial:          func(addr string) (net.Conn, error) { return record("Dial", addr, 0), nil },
+		dialDualStack: func(addr string) (net.Conn, error) { return record("DialDualStack", addr, 0), nil },
+		dialTimeout: func(addr string, timeout time.Duration) (net.Conn, error) {
+			return record("DialTimeout", addr, timeout), nil
+		},
+		dialDualStackTimeout: func(addr string, timeout time.Duration) (net.Conn, error) {
+			return record("DialDualStackTimeout", addr, timeout), nil
+		},
+		netDialer: func(_, addr string) (net.Conn, error) { return record("net.Dialer", addr, 0), nil },
 	})
-	t.Cleanup(func() { dnsResolver.Store(prev) })
+	t.Cleanup(func() { fasthttpDialers.Store(prev) })
+	return &dials
 }
 
 // Test_Security_Do_BlocksDNSRebinding is the regression test for the
@@ -182,6 +281,8 @@ func Test_Security_Do_BlocksDNSRebinding(t *testing.T) {
 
 	for name, do := range dispatch {
 		t.Run(name, func(t *testing.T) {
+			// Intentionally not parallel: each case swaps the process-wide DNS resolver.
+
 			// The "internal" service the attacker wants to reach.
 			_, internalAddr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
 				return c.SendString("SECRET_INTERNAL_DATA")
@@ -224,13 +325,14 @@ func Test_Security_Do_BlocksDNSRebinding(t *testing.T) {
 	}
 }
 
-// Test_Security_NewGuardedClientDialer_BlocksWhenPrivateDisallowed verifies
+// Test_Security_ClientDialer_BlocksWhenPrivateDisallowed verifies
 // the composable client guard rejects loopback targets — literal and
 // hostname — when the active policy forbids private IPs.
-func Test_Security_NewGuardedClientDialer_BlocksWhenPrivateDisallowed(t *testing.T) {
+func Test_Security_ClientDialer_BlocksWhenPrivateDisallowed(t *testing.T) {
+	// Intentionally not parallel: it sets the strict security policy process-wide.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
-	dial := newGuardedClientDialer(nil, false)
+	dial := newDialGuard(false).clientDialer(nil)
 
 	_, err := dial("127.0.0.1:80")
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
@@ -239,10 +341,11 @@ func Test_Security_NewGuardedClientDialer_BlocksWhenPrivateDisallowed(t *testing
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
-// Test_Security_NewGuardedClientDialer_ComposesWithOrig verifies that, for
+// Test_Security_ClientDialer_ComposesWithOrig verifies that, for
 // an allowed (public) target, the guard dials the validated address through
 // the caller-supplied dialer instead of establishing its own connection.
-func Test_Security_NewGuardedClientDialer_ComposesWithOrig(t *testing.T) {
+func Test_Security_ClientDialer_ComposesWithOrig(t *testing.T) {
+	// Intentionally not parallel: it sets the strict security policy process-wide.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
 	var got string
@@ -251,21 +354,22 @@ func Test_Security_NewGuardedClientDialer_ComposesWithOrig(t *testing.T) {
 		return stubConn{addr: addr}, nil
 	}
 
-	dial := newGuardedClientDialer(orig, false)
+	dial := newDialGuard(false).clientDialer(orig)
 	conn, err := dial("203.0.113.5:80") // TEST-NET-3, not blocked
 	require.NoError(t, err)
 	require.NotNil(t, conn)
 	require.Equal(t, "203.0.113.5:80", got)
 }
 
-// Test_Security_NewGuardedClientDialer_AllowsValidatedHostname is the
+// Test_Security_ClientDialer_AllowsValidatedHostname is the
 // positive-path counterpart to the rebinding test: under the strict policy, a
 // hostname that resolves to a public (non-blocked) address must resolve,
 // validate, and dial through to that exact IP — proving the guard does not
 // over-block legitimate upstreams. Every end-to-end suite test runs with
 // AllowPrivateIPs=true (the delegate branch), so this is the only coverage of
 // the resolve→validate→dial success path.
-func Test_Security_NewGuardedClientDialer_AllowsValidatedHostname(t *testing.T) {
+func Test_Security_ClientDialer_AllowsValidatedHostname(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide policy and DNS resolver.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
 	// Resolver maps the name to a public IP on every answer (no rebinding).
@@ -278,7 +382,7 @@ func Test_Security_NewGuardedClientDialer_AllowsValidatedHostname(t *testing.T)
 		return stubConn{addr: addr}, nil
 	}
 
-	dial := newGuardedClientDialer(orig, false)
+	dial := newDialGuard(false).clientDialer(orig)
 	conn, err := dial("public.test:80")
 	require.NoError(t, err)
 	require.NotNil(t, conn)
@@ -294,6 +398,7 @@ func Test_Security_NewGuardedClientDialer_AllowsValidatedHostname(t *testing.T)
 // let the user's dialer overwrite the guard and reopen the SSRF hole, so this
 // test is the regression guard for that ordering.
 func Test_Security_EnsureClientGuarded_ComposesAndIsIdempotent(t *testing.T) {
+	// Intentionally not parallel: it sets the strict security policy process-wide.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
 	called := 0
@@ -332,21 +437,26 @@ func Test_Security_EnsureClientGuarded_ComposesAndIsIdempotent(t *testing.T) {
 	require.True(t, userDialed, "guard must delegate an allowed IP to the user's dialer")
 }
 
-// Test_Security_EnsureClientGuarded_ConcurrentIsSafe pins that guarding the
-// same client from many goroutines is race-free (run under -race) and
-// idempotent, for both the nil-ConfigureClient and pre-existing-hook paths.
-// Regression guard for the serializing mutex in ensureClientGuarded.
+// Test_Security_EnsureClientGuarded_ConcurrentIsSafe pins that guarding the same client from many
+// goroutines is race-free (run under -race) and leaves one working hook.
 func Test_Security_EnsureClientGuarded_ConcurrentIsSafe(t *testing.T) {
-	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
-
-	cases := map[string]func(*fasthttp.HostClient) error{
-		"nil ConfigureClient":          nil,
-		"pre-existing ConfigureClient": func(_ *fasthttp.HostClient) error { return nil },
-	}
+	t.Parallel()
 
-	for name, hook := range cases {
+	for name, withHook := range map[string]bool{
+		"nil ConfigureClient":          false,
+		"pre-existing ConfigureClient": true,
+	} {
 		t.Run(name, func(t *testing.T) {
-			cli := &fasthttp.Client{ConfigureClient: hook}
+			t.Parallel()
+
+			var hookCalls atomic.Int32
+			cli := &fasthttp.Client{}
+			if withHook {
+				cli.ConfigureClient = func(*fasthttp.HostClient) error {
+					hookCalls.Add(1)
+					return nil
+				}
+			}
 
 			var wg sync.WaitGroup
 			for range 32 {
@@ -358,9 +468,11 @@ func Test_Security_EnsureClientGuarded_ConcurrentIsSafe(t *testing.T) {
 
 			hc := &fasthttp.HostClient{}
 			require.NoError(t, cli.ConfigureClient(hc))
-			require.NotNil(t, hc.Dial)
-			_, err := hc.Dial("127.0.0.1:80")
-			require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+			require.NotNil(t, hc.Dial, "the guard installs a dial-time Dial")
+			require.True(t, hc.DisablePathNormalizing, "the guard hook ran")
+			if withHook {
+				require.Equal(t, int32(1), hookCalls.Load(), "the existing hook runs once per HostClient")
+			}
 		})
 	}
 }
@@ -370,6 +482,7 @@ func Test_Security_EnsureClientGuarded_ConcurrentIsSafe(t *testing.T) {
 // wrapped (fasthttp prefers DialTimeout over Dial), and the wrapped func
 // blocks a loopback target under the strict policy.
 func Test_Security_InstallHostClientGuard_GuardsDialTimeout(t *testing.T) {
+	// Intentionally not parallel: it sets the strict security policy process-wide.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
 	hc := &fasthttp.HostClient{DialTimeout: fasthttp.DialTimeout}
@@ -384,10 +497,11 @@ func Test_Security_InstallHostClientGuard_GuardsDialTimeout(t *testing.T) {
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
-// Test_Security_NewGuardedClientDialer_DelegatesWhenPrivateAllowed verifies
+// Test_Security_ClientDialer_DelegatesWhenPrivateAllowed verifies
 // that when the operator opts into private targets the guard delegates to a
 // normal dial, so loopback connections still succeed.
-func Test_Security_NewGuardedClientDialer_DelegatesWhenPrivateAllowed(t *testing.T) {
+func Test_Security_ClientDialer_DelegatesWhenPrivateAllowed(t *testing.T) {
+	// Intentionally not parallel: it sets a process-wide security policy.
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
 	withSecurityPolicyForTest(t, policy)
@@ -396,16 +510,17 @@ func Test_Security_NewGuardedClientDialer_DelegatesWhenPrivateAllowed(t *testing
 	require.NoError(t, err)
 	defer ln.Close() //nolint:errcheck // best-effort close
 
-	dial := newGuardedClientDialer(nil, false)
+	dial := newDialGuard(false).clientDialer(nil)
 	conn, err := dial(ln.Addr().String())
 	require.NoError(t, err)
 	require.NoError(t, conn.Close())
 }
 
-// Test_Security_NewGuardedClientDialer_DelegatesDualStack covers the
+// Test_Security_ClientDialer_DelegatesDualStack covers the
 // AllowPrivateIPs delegate branch with DialDualStack enabled (fasthttp's
 // DialDualStack fallback).
-func Test_Security_NewGuardedClientDialer_DelegatesDualStack(t *testing.T) {
+func Test_Security_ClientDialer_DelegatesDualStack(t *testing.T) {
+	// Intentionally not parallel: it sets a process-wide security policy.
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
 	withSecurityPolicyForTest(t, policy)
@@ -414,65 +529,300 @@ func Test_Security_NewGuardedClientDialer_DelegatesDualStack(t *testing.T) {
 	require.NoError(t, err)
 	defer ln.Close() //nolint:errcheck // best-effort close
 
-	conn, err := newGuardedClientDialer(nil, true)(ln.Addr().String())
+	conn, err := newDialGuard(true).clientDialer(nil)(ln.Addr().String())
 	require.NoError(t, err)
 	require.NoError(t, conn.Close())
 }
 
-// Test_Security_NewGuardedClientDialer_RejectsMalformedAddr covers the
-// SplitHostPort error branch of guardedDial.
-func Test_Security_NewGuardedClientDialer_RejectsMalformedAddr(t *testing.T) {
+// Test_Security_InstallHostClientGuard_DialTimeout pins which HostClients get a guarded DialTimeout.
+func Test_Security_InstallHostClientGuard_DialTimeout(t *testing.T) {
+	t.Parallel()
+
+	t.Run("no dialer of its own", func(t *testing.T) {
+		t.Parallel()
+
+		hc := &fasthttp.HostClient{}
+		installHostClientGuard(hc)
+		require.NotNil(t, hc.DialTimeout)
+		require.NotNil(t, hc.Dial)
+	})
+
+	t.Run("a Dial of its own is kept alone", func(t *testing.T) {
+		t.Parallel()
+
+		// A DialTimeout would take precedence over it, and the dialer it stands for cannot take a timeout.
+		hc := &fasthttp.HostClient{Dial: func(string) (net.Conn, error) { return nil, errors.New("unused") }}
+		installHostClientGuard(hc)
+		require.Nil(t, hc.DialTimeout)
+		require.NotNil(t, hc.Dial)
+	})
+}
+
+// Test_Security_DefaultDialTimeout_ConnectsThroughFasthttp pins that the default dialer connects with
+// the request's timeout, or fasthttp's default when it left none, where DialTimeout would fail at once.
+func Test_Security_DefaultDialTimeout_ConnectsThroughFasthttp(t *testing.T) {
+	t.Parallel()
+
+	ln, err := net.Listen(fiber.NetworkTCP4, "127.0.0.1:0")
+	require.NoError(t, err)
+	t.Cleanup(func() { ln.Close() }) //nolint:errcheck // best-effort close in cleanup
+
+	for _, dualStack := range []bool{false, true} {
+		for _, timeout := range []time.Duration{0, time.Second} {
+			conn, dialErr := defaultDialTimeout(dualStack)(ln.Addr().String(), timeout)
+			require.NoError(t, dialErr, "dual stack %v, timeout %v", dualStack, timeout)
+			require.NoError(t, conn.Close())
+		}
+	}
+}
+
+// Test_Security_DefaultDialTimeout_ChoosesTheDialer pins which of fasthttp's four dialers connects.
+func Test_Security_DefaultDialTimeout_ChoosesTheDialer(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide fasthttp dialers.
+	dials := withRecordedDialers(t)
+
+	for _, tc := range []struct {
+		want      recordedDial
+		timeout   time.Duration
+		dualStack bool
+	}{
+		{want: recordedDial{via: "Dial", addr: "198.51.100.7:80"}},
+		{want: recordedDial{via: "DialDualStack", addr: "198.51.100.7:80"}, dualStack: true},
+		{want: recordedDial{via: "DialTimeout", addr: "198.51.100.7:80", timeout: time.Second}, timeout: time.Second},
+		{want: recordedDial{via: "DialDualStackTimeout", addr: "198.51.100.7:80", timeout: time.Second}, timeout: time.Second, dualStack: true},
+	} {
+		*dials = nil
+		_, err := defaultDialTimeout(tc.dualStack)("198.51.100.7:80", tc.timeout)
+		require.NoError(t, err)
+		require.Equal(t, []recordedDial{tc.want}, *dials, "dual stack %v, timeout %v", tc.dualStack, tc.timeout)
+	}
+}
+
+// Test_Security_GuardedDialTimeouts_HandTheTimeoutOn pins that every guarded DialTimeout checks the
+// address, then connects with the time the request left, or through the bounded net.Dialer when it left none.
+func Test_Security_GuardedDialTimeouts_HandTheTimeoutOn(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide security policy and fasthttp dialers.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
+	dials := withRecordedDialers(t)
+
+	upstream := mustParseTestURL(t, "http://upstream.example")
+	for _, dualStack := range []bool{false, true} {
+		guarded := map[string]func() fasthttp.DialFuncWithTimeout{
+			"a client with no dialer of its own": func() fasthttp.DialFuncWithTimeout {
+				hc := &fasthttp.HostClient{DialDualStack: dualStack}
+				installHostClientGuard(hc)
+				return hc.DialTimeout
+			},
+			"a Balancer host client": func() fasthttp.DialFuncWithTimeout {
+				return newHostClient(upstream, &Config{DialDualStack: dualStack}, DefaultSecurityPolicy()).DialTimeout
+			},
+			"the guard": func() fasthttp.DialFuncWithTimeout {
+				return newDialGuard(dualStack).dialCheckedTimeout
+			},
+		}
+		viaTimeout := "DialTimeout"
+		if dualStack {
+			viaTimeout = "DialDualStackTimeout"
+		}
+		for name, build := range guarded {
+			dial := build()
+			require.NotNil(t, dial, "%s, dual stack %v", name, dualStack)
+
+			*dials = nil
+			_, err := dial("198.51.100.7:80", 2*time.Second)
+			require.NoError(t, err, "%s, dual stack %v", name, dualStack)
+			require.Len(t, *dials, 1, "%s, dual stack %v", name, dualStack)
+			got := (*dials)[0]
+			require.Equal(t, viaTimeout, got.via, "%s, dual stack %v", name, dualStack)
+			require.Equal(t, "198.51.100.7:80", got.addr, "%s, dual stack %v", name, dualStack)
+			require.Positive(t, got.timeout, "%s, dual stack %v: the connect gets a timeout", name, dualStack)
+			require.LessOrEqual(t, got.timeout, 2*time.Second, "%s, dual stack %v: and not fasthttp's default of %v", name, dualStack, fasthttp.DefaultDialTimeout)
+
+			*dials = nil
+			_, err = dial("198.51.100.7:80", 0)
+			require.NoError(t, err, "%s, dual stack %v", name, dualStack)
+			require.Equal(t, []recordedDial{{via: "net.Dialer", addr: "198.51.100.7:80"}}, *dials, "%s, dual stack %v", name, dualStack)
+		}
+	}
+}
+
+// Test_Security_DialWithin_SharesTheTimeout pins that the lookup and all the connects share the time
+// the request leaves: a connect gets what the earlier ones left, and none is made once it is spent.
+func Test_Security_DialWithin_SharesTheTimeout(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide DNS resolver.
+	withRebindingResolver(t, startManyAnswersDNS(t, 2)) // 198.51.100.1 and 198.51.100.2
+
+	guard := newDialGuard(false)
+
+	t.Run("a connect gets what is left", func(t *testing.T) {
+		var timeouts []time.Duration
+		dial := func(_ string, timeout time.Duration) (net.Conn, error) {
+			timeouts = append(timeouts, timeout)
+			if len(timeouts) == 1 {
+				time.Sleep(300 * time.Millisecond)
+				return nil, errors.New("connection refused")
+			}
+			return stubConn{}, nil
+		}
+
+		_, err := guard.dialWithin("many.test:80", 3*time.Second, dial)
+		require.NoError(t, err)
+		require.Len(t, timeouts, 2)
+		require.Positive(t, timeouts[0])
+		require.Less(t, timeouts[0], 3*time.Second, "the lookup took some of it")
+		require.Positive(t, timeouts[1])
+		require.LessOrEqual(t, timeouts[1], timeouts[0]-250*time.Millisecond, "the first connect took 300 ms of it")
+	})
+
+	t.Run("none is made once nothing is left", func(t *testing.T) {
+		var dialed int
+		dial := func(_ string, timeout time.Duration) (net.Conn, error) {
+			dialed++
+			time.Sleep(timeout) // an address nobody answers at, which uses all it is given
+			return nil, fasthttp.ErrDialTimeout
+		}
+
+		_, err := guard.dialWithin("many.test:80", 500*time.Millisecond, dial)
+		require.ErrorIs(t, err, fasthttp.ErrDialTimeout)
+		require.Equal(t, 1, dialed, "the second address is not tried")
+	})
+}
+
+// Test_Security_DialWithin_NoTimeout pins that a dial the request gave no time hands none on.
+func Test_Security_DialWithin_NoTimeout(t *testing.T) {
+	t.Parallel()
+
+	got := time.Hour
+	_, err := newDialGuard(false).dialWithin("198.51.100.7:80", 0, func(_ string, timeout time.Duration) (net.Conn, error) {
+		got = timeout
+		return stubConn{}, nil
+	})
+	require.NoError(t, err)
+	require.Zero(t, got)
+}
+
+// Test_Security_DialWithin_BoundsTheLookup pins that the request's time ends the lookup too: a resolver
+// that never answers costs the request what it allowed, not the five seconds of the lookup limit.
+func Test_Security_DialWithin_BoundsTheLookup(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide DNS resolver.
+	withRebindingResolver(t, startSilentDNS(t))
+
+	var dialed int
+	start := time.Now()
+	_, err := newDialGuard(false).dialWithin("silent.test:80", 200*time.Millisecond, func(string, time.Duration) (net.Conn, error) {
+		dialed++
+		return stubConn{}, nil
+	})
+
+	require.ErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	require.Zero(t, dialed)
+	require.Less(t, time.Since(start), dnsLookupTimeout-time.Second)
+}
 
-	_, err := newGuardedClientDialer(nil, false)("no-port-here")
-	require.Error(t, err)
-	require.NotErrorIs(t, err, ErrUpstreamHostBlocked)
+// Test_Security_RequestTimeout_ReachesTheConnect pins that the time a request leaves reaches the
+// dialer that connects, through DoTimeout on the shared client and through a Balancer with a Timeout.
+func Test_Security_RequestTimeout_ReachesTheConnect(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide security policy, client and fasthttp dialers.
+	restoreGlobalProxyClient(t)
+	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
+	WithClient(&fasthttp.Client{})
+	dials := withRecordedDialers(t)
+
+	// TEST-NET-2 is documentation space, outside the blocked ranges.
+	const upstream = "http://198.51.100.9"
+	timeout := 2 * time.Second // below fasthttp's default of 3 s
+	for name, handler := range map[string]fiber.Handler{
+		"DoTimeout": func(c fiber.Ctx) error { return DoTimeout(c, upstream+"/", timeout) },
+		"Balancer":  Balancer(Config{Servers: []string{upstream}, Timeout: timeout}),
+	} {
+		*dials = nil
+		app := fiber.New()
+		app.Get("/", handler)
+		resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody), fiber.TestConfig{Timeout: 5 * time.Second, FailOnTimeout: true})
+		require.NoError(t, err, name)
+		require.NoError(t, resp.Body.Close(), name) // the stand-in connection answers nothing, so the request fails
+
+		require.NotEmpty(t, *dials, name)
+		first := (*dials)[0]
+		require.Equal(t, "DialTimeout", first.via, name)
+		require.Equal(t, "198.51.100.9:80", first.addr, name)
+		require.Positive(t, first.timeout, name)
+		require.LessOrEqual(t, first.timeout, timeout, name)
+	}
 }
 
-// Test_Security_NewGuardedClientDialerWithTimeout_Delegates covers the
+// Test_Security_ClientDialerWithTimeout_Delegates covers the
 // DialFuncWithTimeout guard's delegate branch: when private IPs are allowed
 // it forwards the raw addr and timeout to the caller's dialer.
-func Test_Security_NewGuardedClientDialerWithTimeout_Delegates(t *testing.T) {
+func Test_Security_ClientDialerWithTimeout_Delegates(t *testing.T) {
+	// Intentionally not parallel: it sets a process-wide security policy.
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
 	withSecurityPolicyForTest(t, policy)
 
 	var got string
-	orig := func(addr string, _ time.Duration) (net.Conn, error) {
-		got = addr
+	var gotTimeout time.Duration
+	orig := func(addr string, timeout time.Duration) (net.Conn, error) {
+		got, gotTimeout = addr, timeout
 		return stubConn{addr: addr}, nil
 	}
-	conn, err := newGuardedClientDialerWithTimeout(orig, false)("10.0.0.1:80", time.Second)
+	conn, err := newDialGuard(false).clientDialerWithTimeout(orig)("10.0.0.1:80", time.Second)
 	require.NoError(t, err)
 	require.NotNil(t, conn)
 	require.Equal(t, "10.0.0.1:80", got)
+	require.Equal(t, time.Second, gotTimeout)
 }
 
-// Test_Security_NewGuardedClientDialerWithTimeout_ValidatedDialsThrough covers
+// Test_Security_ClientDialerWithTimeout_DefaultDelegatesThroughFasthttp pins that a client with no
+// dialer of its own delegates to fasthttp's timed or plain dialer when private IPs are allowed.
+func Test_Security_ClientDialerWithTimeout_DefaultDelegatesThroughFasthttp(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide security policy and fasthttp dialers.
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	withSecurityPolicyForTest(t, policy)
+	dials := withRecordedDialers(t)
+
+	dial := newDialGuard(false).clientDialerWithTimeout(nil)
+	_, err := dial("10.0.0.1:80", time.Second)
+	require.NoError(t, err)
+	_, err = dial("10.0.0.1:80", 0)
+	require.NoError(t, err)
+	require.Equal(t, []recordedDial{
+		{via: "DialTimeout", addr: "10.0.0.1:80", timeout: time.Second},
+		{via: "Dial", addr: "10.0.0.1:80"},
+	}, *dials)
+}
+
+// Test_Security_ClientDialerWithTimeout_ValidatedDialsThrough covers
 // the strict-policy path of the DialFuncWithTimeout guard: a hostname that
 // resolves to a public IP is validated and dialed through the caller's
 // timeout dialer at the exact resolved IP.
-func Test_Security_NewGuardedClientDialerWithTimeout_ValidatedDialsThrough(t *testing.T) {
+func Test_Security_ClientDialerWithTimeout_ValidatedDialsThrough(t *testing.T) {
+	// Intentionally not parallel: it swaps the process-wide policy and DNS resolver.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
 
 	dnsAddr, _ := startRebindingDNS(t, net.IPv4(198, 51, 100, 7), net.IPv4(198, 51, 100, 7))
 	withRebindingResolver(t, dnsAddr)
 
 	var got string
-	orig := func(addr string, _ time.Duration) (net.Conn, error) {
-		got = addr
+	var gotTimeout time.Duration
+	orig := func(addr string, timeout time.Duration) (net.Conn, error) {
+		got, gotTimeout = addr, timeout
 		return stubConn{addr: addr}, nil
 	}
-	conn, err := newGuardedClientDialerWithTimeout(orig, false)("public.test:80", time.Second)
+	conn, err := newDialGuard(false).clientDialerWithTimeout(orig)("public.test:80", time.Second)
 	require.NoError(t, err)
 	require.NotNil(t, conn)
 	require.Equal(t, "198.51.100.7:80", got, "must dial the validated resolved IP")
+	// What the lookup left of the second, not the second again.
+	require.Positive(t, gotTimeout)
+	require.Less(t, gotTimeout, time.Second)
 }
 
 // Test_Security_EnsureClientGuarded_ComposePropagatesError verifies the
 // composed hook surfaces an error from the user's existing ConfigureClient.
 func Test_Security_EnsureClientGuarded_ComposePropagatesError(t *testing.T) {
-	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
+	t.Parallel()
 
 	wantErr := errors.New("configure boom")
 	cli := &fasthttp.Client{
@@ -483,3 +833,23 @@ func Test_Security_EnsureClientGuarded_ComposePropagatesError(t *testing.T) {
 	err := cli.ConfigureClient(&fasthttp.HostClient{})
 	require.ErrorIs(t, err, wantErr)
 }
+
+// Test_Security_ClientDialer_DialsValidatedIPWithGuardDialer covers the strict-policy path for a
+// client with no dialer of its own: the validated IP is dialed through the guard's dialer.
+func Test_Security_ClientDialer_DialsValidatedIPWithGuardDialer(t *testing.T) {
+	// Intentionally not parallel: it sets the strict security policy process-wide.
+	withSecurityPolicyForTest(t, DefaultSecurityPolicy()) // AllowPrivateIPs == false
+
+	var network, address string
+	guard := dialGuard{dial: func(n, a string) (net.Conn, error) {
+		network, address = n, a
+		return stubConn{addr: a}, nil
+	}}
+
+	// TEST-NET-2 is documentation space, outside the blocked ranges.
+	conn, err := guard.clientDialer(nil)("198.51.100.7:8080")
+	require.NoError(t, err)
+	require.NotNil(t, conn)
+	require.Equal(t, "tcp", network)
+	require.Equal(t, "198.51.100.7:8080", address)
+}
diff --git a/middleware/proxy/security_test.go b/middleware/proxy/security_test.go
index a13c3499e08..83a7ba2c7ee 100644
--- a/middleware/proxy/security_test.go
+++ b/middleware/proxy/security_test.go
@@ -1,13 +1,18 @@
 package proxy
 
 import (
+	"bufio"
+	"bytes"
 	"crypto/tls"
 	"errors"
 	"io"
+	"mime/multipart"
 	"net"
 	"net/http"
 	"net/http/httptest"
 	"net/url"
+	"slices"
+	"strconv"
 	"strings"
 	"sync"
 	"sync/atomic"
@@ -20,13 +25,13 @@ import (
 	"github.com/valyala/fasthttp"
 )
 
-// withSecurityPolicyForTest installs policy for the duration of t and
-// restores the previous policy via t.Cleanup. Tests that need to
+// withSecurityPolicyForTest installs policy for the duration of tb and
+// restores the previous policy via tb.Cleanup. Tests that need to
 // exercise the strict defaults call this with an explicit policy.
-func withSecurityPolicyForTest(t *testing.T, policy SecurityPolicy) {
-	t.Helper()
+func withSecurityPolicyForTest(tb testing.TB, policy SecurityPolicy) {
+	tb.Helper()
 	prev := WithSecurityPolicy(policy)
-	t.Cleanup(func() { WithSecurityPolicy(prev) })
+	tb.Cleanup(func() { WithSecurityPolicy(prev) })
 }
 
 func Test_Security_IsBlockedIP(t *testing.T) {
@@ -42,6 +47,41 @@ func Test_Security_IsBlockedIP(t *testing.T) {
 		"169.254.169.254":          true,  // AWS metadata
 		"100.64.0.1":               true,  // CGNAT
 		"224.0.0.1":                true,  // multicast
+		"0.1.2.3":                  true,  // 0.0.0.0/8
+		"0.255.255.255":            true,  // 0.0.0.0/8
+		"192.0.0.192":              true,  // Oracle Cloud legacy metadata, 192.0.0.0/24
+		"192.0.0.1":                true,  // 192.0.0.0/24
+		"198.18.0.1":               true,  // benchmarking, 198.18.0.0/15
+		"198.19.255.254":           true,  // benchmarking
+		"240.0.0.1":                true,  // reserved, 240.0.0.0/4
+		"255.255.255.255":          true,  // limited broadcast
+		"::ffff:192.0.0.192":       true,  // IPv4-mapped 192.0.0.192
+		"64:ff9b::c000:c0":         true,  // NAT64 WKP 192.0.0.192
+		"fec0::1":                  true,  // site-local, fec0::/10
+		"fed0::1":                  true,  // site-local
+		"192.0.1.1":                false, // just outside 192.0.0.0/24
+		"192.0.2.1":                false, // TEST-NET-1 documentation range
+		"198.17.255.255":           false, // just below 198.18.0.0/15
+		"198.20.0.0":               false, // just above 198.18.0.0/15
+		"198.51.100.7":             false, // TEST-NET-2 documentation range
+		"203.0.113.9":              false, // TEST-NET-3 documentation range
+		"223.255.255.254":          false, // below 240.0.0.0/4
+		"239.255.255.255":          true,  // top of multicast
+		"9.255.255.255":            false, // just below 10.0.0.0/8
+		"11.0.0.0":                 false, // just above 10.0.0.0/8
+		"100.63.255.255":           false, // just below CGNAT, 100.64.0.0/10
+		"100.127.255.255":          true,  // top of CGNAT
+		"100.128.0.0":              false, // just above CGNAT
+		"126.255.255.255":          false, // just below 127.0.0.0/8
+		"128.0.0.0":                false, // just above 127.0.0.0/8
+		"169.253.255.255":          false, // just below link-local, 169.254.0.0/16
+		"169.255.0.0":              false, // just above link-local
+		"172.15.255.255":           false, // just below 172.16.0.0/12
+		"172.31.255.255":           true,  // top of 172.16.0.0/12
+		"172.32.0.0":               false, // just above 172.16.0.0/12
+		"192.167.255.255":          false, // just below 192.168.0.0/16
+		"192.169.0.0":              false, // just above 192.168.0.0/16
+		"fb00::1":                  false, // below fc00::/7
 		"::ffff:127.0.0.1":         true,  // IPv4-mapped loopback
 		"::ffff:10.0.0.1":          true,  // IPv4-mapped private
 		"::127.0.0.1":              true,  // IPv4-compatible loopback
@@ -109,7 +149,7 @@ func Test_Security_ValidateUpstream_BlocksPrivateIPs(t *testing.T) {
 	for _, raw := range bad {
 		t.Run(raw, func(t *testing.T) {
 			t.Parallel()
-			_, err := validateUpstream(raw, policy)
+			_, err := validateUpstream(raw, policy, nil)
 			require.ErrorIs(t, err, ErrUpstreamHostBlocked, "expected block for %q", raw)
 		})
 	}
@@ -119,7 +159,7 @@ func Test_Security_ValidateUpstream_AllowsPrivateOptIn(t *testing.T) {
 	t.Parallel()
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	u, err := validateUpstream("http://127.0.0.1:8080", policy)
+	u, err := validateUpstream("http://127.0.0.1:8080", policy, nil)
 	require.NoError(t, err)
 	require.Equal(t, "127.0.0.1:8080", u.Host)
 }
@@ -132,7 +172,7 @@ func Test_Security_ValidateUpstream_RejectsSchemes(t *testing.T) {
 	for _, raw := range bad {
 		t.Run(raw, func(t *testing.T) {
 			t.Parallel()
-			_, err := validateUpstream(raw, policy)
+			_, err := validateUpstream(raw, policy, nil)
 			require.ErrorIs(t, err, ErrUpstreamSchemeNotAllowed)
 		})
 	}
@@ -140,11 +180,12 @@ func Test_Security_ValidateUpstream_RejectsSchemes(t *testing.T) {
 
 func Test_Security_ValidateUpstream_RejectsEmpty(t *testing.T) {
 	t.Parallel()
-	_, err := validateUpstream("", DefaultSecurityPolicy())
+	_, err := validateUpstream("", DefaultSecurityPolicy(), nil)
 	require.ErrorIs(t, err, ErrUpstreamHostInvalid)
 }
 
 func Test_Security_Forward_BlocksPrivateByDefault(t *testing.T) {
+	// Intentionally not parallel: it sets the strict default policy process-wide.
 	withSecurityPolicyForTest(t, DefaultSecurityPolicy())
 
 	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
@@ -198,7 +239,7 @@ func Test_Security_Balancer_AllowsPrivateOptIn(t *testing.T) {
 }
 
 // Test_Security_HopByHopRequestStripping verifies hop-by-hop headers
-// (RFC 7230 §6.1) are dropped from the outbound request.
+// (RFC 9110 §7.6.1) are dropped from the outbound request.
 func Test_Security_HopByHopRequestStripping(t *testing.T) {
 	t.Parallel()
 
@@ -461,96 +502,25 @@ func Test_Security_JoinUpstreamPath_PreservesBasePathPrefix(t *testing.T) {
 	require.Equal(t, "http://upstream.example/api/foo", joinUpstreamPath(baseSlash, "/foo"))
 }
 
-// Test_Security_FollowRedirects_StripsCredentialsCrossHost verifies that
-// Authorization/Cookie/Proxy-Authorization are dropped when a redirect
-// crosses to a different host, but preserved on same-host redirects.
-func Test_Security_FollowRedirects_StripsCredentialsCrossHost(t *testing.T) {
-	t.Parallel()
-
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-
-	t.Run("cross-host strips", func(t *testing.T) {
-		t.Parallel()
-		var sawAuth, sawCookie string
-		client, _ := newCountingRedirectClient(map[string]redirectStep{
-			"http://first.example/": {status: fasthttp.StatusFound, location: "http://second.example/next"},
-		})
-		client.onRequest = func(req *fasthttp.Request) {
-			if string(req.URI().Host()) == "second.example" {
-				sawAuth = string(req.Header.Peek(fiber.HeaderAuthorization))
-				sawCookie = string(req.Header.Peek(fiber.HeaderCookie))
-			}
-		}
-
-		req := fasthttp.AcquireRequest()
-		resp := fasthttp.AcquireResponse()
-		defer fasthttp.ReleaseRequest(req)
-		defer fasthttp.ReleaseResponse(resp)
-		req.SetRequestURI("http://first.example/")
-		req.Header.SetMethod(fasthttp.MethodGet)
-		req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
-		req.Header.Set(fiber.HeaderCookie, "session=abc")
-
-		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://first.example/"), policy, true))
-		require.Empty(t, sawAuth, "Authorization must be stripped cross-host")
-		require.Empty(t, sawCookie, "Cookie must be stripped cross-host")
-	})
-
-	t.Run("same-host preserves", func(t *testing.T) {
-		t.Parallel()
-		var sawAuth string
-		client, _ := newCountingRedirectClient(map[string]redirectStep{
-			"http://same.example/": {status: fasthttp.StatusFound, location: "http://same.example/next"},
-		})
-		client.onRequest = func(req *fasthttp.Request) {
-			if string(req.URI().RequestURI()) == "/next" {
-				sawAuth = string(req.Header.Peek(fiber.HeaderAuthorization))
-			}
-		}
-
-		req := fasthttp.AcquireRequest()
-		resp := fasthttp.AcquireResponse()
-		defer fasthttp.ReleaseRequest(req)
-		defer fasthttp.ReleaseResponse(resp)
-		req.SetRequestURI("http://same.example/")
-		req.Header.SetMethod(fasthttp.MethodGet)
-		req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
-
-		require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://same.example/"), policy, true))
-		require.Equal(t, "Bearer secret", sawAuth, "Authorization must survive same-host redirect")
-	})
-}
-
 // Test_Security_FollowRedirects_ReappliesSchemePerHop verifies that a
 // redirect which changes the scheme is dispatched with the new scheme.
 // followRedirects re-applies currentURL.Scheme after each SetRequestURI
 // because fasthttp keeps the previous scheme when req.isTLS is set — see
-// https://github.com/gofiber/fiber/issues/1762.
+// https://github.com/gofiber/fiber/issues/1762. This request is not marked
+// TLS, so it gets the scheme from its URL either way; the re-application is
+// pinned by Test_Proxy_DoRedirects_AppliesSchemePerHopBehindTLS.
 func Test_Security_FollowRedirects_ReappliesSchemePerHop(t *testing.T) {
 	t.Parallel()
 
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-
 	var secondHopScheme string
-	client, _ := newCountingRedirectClient(map[string]redirectStep{
+	followRecording(t, "http://origin.example/", map[string]redirectStep{
 		"http://origin.example/": {status: fasthttp.StatusFound, location: "https://origin.example/secure"},
-	})
-	client.onRequest = func(req *fasthttp.Request) {
+	}, nil, func(req *fasthttp.Request) {
 		if string(req.URI().Path()) == "/secure" {
 			secondHopScheme = string(req.URI().Scheme())
 		}
-	}
-
-	req := fasthttp.AcquireRequest()
-	resp := fasthttp.AcquireResponse()
-	defer fasthttp.ReleaseRequest(req)
-	defer fasthttp.ReleaseResponse(resp)
-	req.SetRequestURI("http://origin.example/")
-	req.Header.SetMethod(fasthttp.MethodGet)
+	})
 
-	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://origin.example/"), policy, true))
 	require.Equal(t, "https", secondHopScheme, "scheme upgrade must carry through to the next hop")
 }
 
@@ -630,18 +600,27 @@ func Test_Security_IsBlockedIP_NilReturnsTrue(t *testing.T) {
 	require.True(t, isBlockedIP(nil))
 }
 
+// Test_Security_IPv6Helpers_DeclineMalformedAddress pins that the IPv6 helpers decline odd-length slices.
+func Test_Security_IPv6Helpers_DeclineMalformedAddress(t *testing.T) {
+	t.Parallel()
+
+	ip := net.IP{1, 2, 3}
+	require.False(t, isBlockedIPv6TransitionRange(ip))
+	require.Nil(t, embeddedIPv4(ip))
+}
+
 // Test_Security_ValidateHostForSSRF_EmptyHost verifies the explicit
 // empty-host short-circuit (the host == "" branch).
 func Test_Security_ValidateHostForSSRF_EmptyHost(t *testing.T) {
 	t.Parallel()
-	require.ErrorIs(t, validateHostForSSRF(""), ErrUpstreamHostInvalid)
+	require.ErrorIs(t, validateHostForSSRF("", nil), ErrUpstreamHostInvalid)
 }
 
 // Test_Security_ValidateHostForSSRF_PublicIPLiteral exercises the
 // ParseIP success path with a public address.
 func Test_Security_ValidateHostForSSRF_PublicIPLiteral(t *testing.T) {
 	t.Parallel()
-	require.NoError(t, validateHostForSSRF("8.8.8.8"))
+	require.NoError(t, validateHostForSSRF("8.8.8.8", nil))
 }
 
 // Test_Security_ValidateHostForSSRF_LookupFailure covers the
@@ -649,9 +628,60 @@ func Test_Security_ValidateHostForSSRF_PublicIPLiteral(t *testing.T) {
 // resolves, so the test does not depend on outbound DNS.
 func Test_Security_ValidateHostForSSRF_LookupFailure(t *testing.T) {
 	t.Parallel()
-	err := validateHostForSSRF("does-not-exist.invalid")
+	err := validateHostForSSRF("does-not-exist.invalid", nil)
 	require.Error(t, err)
+	// Refused like a blocked host, but told apart so a caller can answer 502 or retry.
+	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+	require.ErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	var dnsErr *net.DNSError
+	require.ErrorAs(t, err, &dnsErr)
+	require.NotContains(t, err.Error(), "blocked address")
+}
+
+// Test_Security_ValidateHostForSSRF_IPLiteralAllocs pins that an IP literal costs no allocation and no lookup.
+func Test_Security_ValidateHostForSSRF_IPLiteralAllocs(t *testing.T) {
+	// Intentionally not parallel: AllocsPerRun counts allocations process-wide and panics in a parallel test.
+	for _, host := range []string{"203.0.113.5", "2606:4700:4700::1111", "::ffff:203.0.113.5"} {
+		var err error
+		require.Zero(t, testing.AllocsPerRun(100, func() { err = validateHostForSSRF(host, upfrontLookups) }), host)
+		require.NoError(t, err, host)
+
+		_, remembered := upfrontLookups.get(host, dnsResolver.Load())
+		require.False(t, remembered, "a literal is judged where it stands: %s", host)
+	}
+}
+
+// Test_Security_ValidateHostForSSRF_ZonedLiteral pins that a zoned literal is judged through the lookup.
+func Test_Security_ValidateHostForSSRF_ZonedLiteral(t *testing.T) {
+	t.Parallel()
+
+	err := validateHostForSSRF("fe80::1%eth0", nil)
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+	require.ErrorContains(t, err, "fe80::1%eth0 -> fe80::1")
+	require.NoError(t, validateHostForSSRF("2606:4700:4700::1111%eth0", nil))
+}
+
+// Test_Security_ValidateResolved pins what a lookup may answer: one or more addresses, none blocked.
+func Test_Security_ValidateResolved(t *testing.T) {
+	t.Parallel()
+
+	public := net.IPAddr{IP: net.ParseIP("198.51.100.7")}
+	private := net.IPAddr{IP: net.ParseIP("10.0.0.1")}
+
+	_, err := validateResolved("empty.test", nil)
+	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+	require.ErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	require.ErrorContains(t, err, "empty.test could not be resolved: no addresses")
+
+	_, err = validateResolved("mixed.test", []net.IPAddr{public, private})
+	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
+	require.NotErrorIs(t, err, ErrUpstreamHostUnresolvable)
+	require.ErrorContains(t, err, "mixed.test -> 10.0.0.1")
+
+	ips, err := validateResolved("ok.test", []net.IPAddr{public})
+	require.NoError(t, err)
+	require.Len(t, ips, 1)
+	require.True(t, ips[0].Equal(public.IP))
 }
 
 // Test_Security_ValidateUpstream_EmptyHostAfterScheme covers the post-
@@ -659,7 +689,7 @@ func Test_Security_ValidateHostForSSRF_LookupFailure(t *testing.T) {
 // "http" and no host.
 func Test_Security_ValidateUpstream_EmptyHostAfterScheme(t *testing.T) {
 	t.Parallel()
-	_, err := validateUpstream("http:///path", DefaultSecurityPolicy())
+	_, err := validateUpstream("http:///path", DefaultSecurityPolicy(), nil)
 	require.ErrorIs(t, err, ErrUpstreamHostInvalid)
 }
 
@@ -694,6 +724,7 @@ func Test_Security_JoinUpstreamPath_QueryOnly(t *testing.T) {
 // covers the branch in WithSecurityPolicy that fills in the default
 // scheme allowlist when the caller leaves it empty.
 func Test_Security_WithSecurityPolicy_EmptyAllowedSchemesGetsDefault(t *testing.T) {
+	// Intentionally not parallel: it sets a process-wide security policy and reads it back.
 	prev := WithSecurityPolicy(SecurityPolicy{})
 	t.Cleanup(func() { WithSecurityPolicy(prev) })
 	got := currentSecurityPolicy()
@@ -755,7 +786,7 @@ func Test_Security_ResolvePolicy_OverrideEmptySchemes(t *testing.T) {
 // control-byte rejection at the top of resolveRedirect.
 func Test_Security_ResolveRedirect_RejectsControlChars(t *testing.T) {
 	t.Parallel()
-	_, err := resolveRedirect("https://example.com", []byte("https://example.com/\r\nX-Inject: 1"), DefaultSecurityPolicy())
+	_, err := resolveRedirect("https://example.com", []byte("https://example.com/\r\nX-Inject: 1"), DefaultSecurityPolicy(), nil)
 	require.ErrorIs(t, err, fasthttp.ErrorInvalidURI)
 }
 
@@ -766,7 +797,7 @@ func Test_Security_ResolveRedirect_RejectsDisallowedScheme(t *testing.T) {
 	t.Parallel()
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	_, err := resolveRedirect("https://example.com", []byte("gopher://example.com/x"), policy)
+	_, err := resolveRedirect("https://example.com", []byte("gopher://example.com/x"), policy, nil)
 	require.ErrorIs(t, err, ErrUpstreamSchemeNotAllowed)
 }
 
@@ -777,7 +808,7 @@ func Test_Security_ResolveRedirect_AllowsDowngradeWhenOptIn(t *testing.T) {
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
 	policy.AllowHTTPSDowngrade = true
-	out, err := resolveRedirect("https://example.com", []byte("http://example.com/x"), policy)
+	out, err := resolveRedirect("https://example.com", []byte("http://example.com/x"), policy, nil)
 	require.NoError(t, err)
 	require.NotNil(t, out)
 	require.Equal(t, "http://example.com/x", out.String())
@@ -789,7 +820,7 @@ func Test_Security_ResolveRedirect_HTTPSDowngradeBlocked(t *testing.T) {
 	t.Parallel()
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	_, err := resolveRedirect("https://example.com", []byte("http://example.com/x"), policy)
+	_, err := resolveRedirect("https://example.com", []byte("http://example.com/x"), policy, nil)
 	require.ErrorIs(t, err, ErrRedirectDowngrade)
 }
 
@@ -812,7 +843,7 @@ func Test_Security_FollowRedirects_NegativeMaxBecomesZero(t *testing.T) {
 
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	err := followRedirects(client.client, req, resp, -1, mustParseTestURL(t, "http://example.com/start"), policy, true)
+	err := followRedirects(client.client, req, resp, -1, mustParseTestURL(t, "http://example.com/start"), policy)
 	require.ErrorIs(t, err, fasthttp.ErrTooManyRedirects)
 	require.Equal(t, 1, *hits)
 }
@@ -836,36 +867,76 @@ func Test_Security_FollowRedirects_MissingLocation(t *testing.T) {
 
 	policy := DefaultSecurityPolicy()
 	policy.AllowPrivateIPs = true
-	err := followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy, true)
+	err := followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy)
 	require.ErrorIs(t, err, fasthttp.ErrMissingLocation)
 }
 
-// Test_Security_FollowRedirects_PostBecomesGetOn303 covers the POST→GET
-// rewrite branch on 303 See Other, including body and content-type
-// clearing.
-func Test_Security_FollowRedirects_PostBecomesGetOn303(t *testing.T) {
+// Test_Security_FollowRedirects_LeavesCallerRequestIntact pins that a redirect changes a copy of
+// the request: the handler's keeps its method, body and credentials.
+func Test_Security_FollowRedirects_LeavesCallerRequestIntact(t *testing.T) {
 	t.Parallel()
 
-	client, _ := newCountingRedirectClient(map[string]redirectStep{
-		"http://example.com/start": {status: fasthttp.StatusSeeOther, location: "http://example.com/after"},
-		"http://example.com/after": {status: fasthttp.StatusOK},
+	type seen struct{ method, body, contentType, auth, cookie string }
+	var hops []seen
+	req := followRecording(t, "http://first.example/start", map[string]redirectStep{
+		"http://first.example/start": {status: fasthttp.StatusSeeOther, location: "http://second.example/after"},
+	}, func(req *fasthttp.Request) {
+		req.Header.SetMethod(fasthttp.MethodPost)
+		req.Header.SetContentType(fiber.MIMEApplicationForm)
+		req.SetBodyString("token=secret&b=2")
+		withCredentials(req)
+		require.Equal(t, "secret", string(req.PostArgs().Peek("token")), "the handler read the form")
+	}, func(req *fasthttp.Request) {
+		hops = append(hops, seen{
+			method:      string(req.Header.Method()),
+			body:        string(req.Body()),
+			contentType: string(req.Header.ContentType()),
+			auth:        string(req.Header.Peek(fiber.HeaderAuthorization)),
+			cookie:      string(req.Header.Peek(fiber.HeaderCookie)),
+		})
 	})
 
-	req := fasthttp.AcquireRequest()
-	resp := fasthttp.AcquireResponse()
-	defer fasthttp.ReleaseRequest(req)
-	defer fasthttp.ReleaseResponse(resp)
-	req.SetRequestURI("http://example.com/start")
-	req.Header.SetMethod(fasthttp.MethodPost)
-	req.Header.SetContentType("application/json")
-	req.SetBodyString(`{"x":1}`)
+	require.Equal(t, []seen{
+		{method: fasthttp.MethodPost, body: "token=secret&b=2", contentType: fiber.MIMEApplicationForm, auth: "Bearer secret", cookie: "session=abc"},
+		{method: fasthttp.MethodGet},
+	}, hops)
 
-	policy := DefaultSecurityPolicy()
-	policy.AllowPrivateIPs = true
-	require.NoError(t, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, "http://example.com/start"), policy, true))
-	require.Equal(t, fasthttp.MethodGet, string(req.Header.Method()))
-	require.Empty(t, req.Body())
-	require.Empty(t, req.Header.ContentType())
+	require.Equal(t, fasthttp.MethodPost, string(req.Header.Method()))
+	require.Equal(t, "token=secret&b=2", string(req.Body()))
+	require.Equal(t, fiber.MIMEApplicationForm, string(req.Header.ContentType()))
+	require.Equal(t, "Bearer secret", string(req.Header.Peek(fiber.HeaderAuthorization)))
+	require.Equal(t, "session=abc", string(req.Header.Peek(fiber.HeaderCookie)))
+	require.Equal(t, "secret", string(req.PostArgs().Peek("token")))
+}
+
+// Test_Security_FollowRedirects_KeepsMultipartForm pins that a multipart form the handler already
+// parsed survives a redirect that drops the body: removing it would delete its temp files.
+func Test_Security_FollowRedirects_KeepsMultipartForm(t *testing.T) {
+	t.Parallel()
+
+	var body bytes.Buffer
+	mw := multipart.NewWriter(&body)
+	require.NoError(t, mw.WriteField("a", "1"))
+	fw, err := mw.CreateFormFile("f", "f.txt")
+	require.NoError(t, err)
+	_, err = fw.Write([]byte("file-bytes"))
+	require.NoError(t, err)
+	require.NoError(t, mw.Close())
+
+	req := followRecording(t, "http://example.com/start", map[string]redirectStep{
+		"http://example.com/start": {status: fasthttp.StatusSeeOther, location: "http://example.com/after"},
+	}, func(req *fasthttp.Request) {
+		req.Header.SetMethod(fasthttp.MethodPost)
+		req.Header.SetMultipartFormBoundary(mw.Boundary())
+		req.SetBody(body.Bytes())
+		_, formErr := req.MultipartForm()
+		require.NoError(t, formErr)
+	}, nil)
+
+	form, err := req.MultipartForm()
+	require.NoError(t, err)
+	require.Equal(t, []string{"1"}, form.Value["a"])
+	require.Len(t, form.File["f"], 1)
 }
 
 // Test_Security_FollowRedirects_PropagatesClientError covers the
@@ -885,7 +956,7 @@ func Test_Security_FollowRedirects_PropagatesClientError(t *testing.T) {
 	req.SetRequestURI("http://example.com/")
 	req.Header.SetMethod(fasthttp.MethodGet)
 
-	err := followRedirects(cli, req, resp, 1, mustParseTestURL(t, "http://example.com/"), DefaultSecurityPolicy(), true)
+	err := followRedirects(cli, req, resp, 1, mustParseTestURL(t, "http://example.com/"), DefaultSecurityPolicy())
 	require.ErrorIs(t, err, sentinel)
 }
 
@@ -947,34 +1018,32 @@ func Test_Security_RoundRobin_WrapsAround(t *testing.T) {
 	t.Run("counter limit", func(t *testing.T) {
 		t.Parallel()
 
+		// The wrap repeats one upstream, then the cycle resumes.
 		r := &urlRoundrobin{pool: []*url.URL{a, b, c}}
 		r.next.Store(^uint64(0) - 1)
 		require.Same(t, c, r.get())
 		require.Same(t, a, r.get())
+		require.Same(t, a, r.get())
 		require.Same(t, b, r.get())
 	})
 }
 
 func Test_Security_RoundRobin_ConcurrentSelection(t *testing.T) {
 	t.Parallel()
+
 	pool := []*url.URL{
 		{Scheme: schemeHTTP, Host: "a"},
 		{Scheme: schemeHTTP, Host: "b"},
 		{Scheme: schemeHTTP, Host: "c"},
 	}
+
 	r := &urlRoundrobin{pool: pool}
 
 	var counts [3]atomic.Int32
 	var wg sync.WaitGroup
 	for range 300 {
 		wg.Go(func() {
-			selected := r.get()
-			for i, candidate := range pool {
-				if selected == candidate {
-					counts[i].Add(1)
-					return
-				}
-			}
+			counts[slices.Index(pool, r.get())].Add(1)
 		})
 	}
 	wg.Wait()
@@ -997,7 +1066,7 @@ func Test_Security_Balancer_PanicsOnInvalidUpstream(t *testing.T) {
 // validateUpstream "no private IP, lookup succeeds" success path.
 func Test_Security_ValidateUpstream_PublicIPLiteral(t *testing.T) {
 	t.Parallel()
-	u, err := validateUpstream("http://8.8.8.8", DefaultSecurityPolicy())
+	u, err := validateUpstream("http://8.8.8.8", DefaultSecurityPolicy(), nil)
 	require.NoError(t, err)
 	require.Equal(t, "8.8.8.8", u.Host)
 }
@@ -1063,12 +1132,12 @@ func Test_Security_Balancer_BuildsHTTPSHostClient(t *testing.T) {
 	require.NotNil(t, h)
 }
 
-// Test_Security_NewSSRFDialer_BlocksLoopback verifies the dial-time SSRF
+// Test_Security_DialChecked_BlocksLoopback verifies the dial-time SSRF
 // guard rejects both literal and hostname loopback targets before any
 // connection is made — this is what defeats DNS rebinding.
-func Test_Security_NewSSRFDialer_BlocksLoopback(t *testing.T) {
+func Test_Security_DialChecked_BlocksLoopback(t *testing.T) {
 	t.Parallel()
-	dial := newSSRFDialer(false)
+	dial := newDialGuard(false).dialChecked
 
 	_, err := dial("127.0.0.1:80")
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
@@ -1077,14 +1146,22 @@ func Test_Security_NewSSRFDialer_BlocksLoopback(t *testing.T) {
 	require.ErrorIs(t, err, ErrUpstreamHostBlocked)
 }
 
-// Test_Security_NewSSRFDialer_RejectsMalformedAddr covers the
-// SplitHostPort error branch.
-func Test_Security_NewSSRFDialer_RejectsMalformedAddr(t *testing.T) {
+// Test_Security_DialChecked_RejectsMalformedAddr covers the SplitHostPort error, which keeps the reason.
+func Test_Security_DialChecked_RejectsMalformedAddr(t *testing.T) {
 	t.Parallel()
-	dial := newSSRFDialer(false)
-	_, err := dial("no-port-here")
-	require.Error(t, err)
-	require.NotErrorIs(t, err, ErrUpstreamHostBlocked)
+	dial := newDialGuard(false).dialChecked
+	for addr, reason := range map[string]string{
+		"no-port-here": "missing port in address",
+		"a:b:c":        "too many colons in address",
+		"[::1":         "missing ']' in address",
+	} {
+		_, err := dial(addr)
+		require.Error(t, err, addr)
+		require.NotErrorIs(t, err, ErrUpstreamHostBlocked, addr)
+		var addrErr *net.AddrError
+		require.ErrorAs(t, err, &addrErr, addr)
+		require.ErrorContains(t, err, reason, addr)
+	}
 }
 
 // Test_Security_Balancer_HostnameDefersToDial verifies that a hostname
@@ -1177,3 +1254,730 @@ func mustParseTestURL(t *testing.T, raw string) *url.URL {
 	require.NoError(t, err)
 	return u
 }
+
+// followRecording follows start through steps with a GET that setup may reshape, and hands record
+// each request as it reaches the transport. It returns the caller's request, valid until test end.
+func followRecording(t *testing.T, start string, steps map[string]redirectStep, setup, record func(req *fasthttp.Request)) *fasthttp.Request {
+	t.Helper()
+
+	req, err := followRecordingErr(t, start, steps, setup, record)
+	require.NoError(t, err)
+	return req
+}
+
+func followRecordingErr(t *testing.T, start string, steps map[string]redirectStep, setup, record func(req *fasthttp.Request)) (*fasthttp.Request, error) {
+	t.Helper()
+
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	policy.AllowHTTPSDowngrade = true
+	client, _ := newCountingRedirectClient(steps)
+	client.onRequest = record
+
+	req := fasthttp.AcquireRequest()
+	resp := fasthttp.AcquireResponse()
+	t.Cleanup(func() {
+		fasthttp.ReleaseRequest(req)
+		fasthttp.ReleaseResponse(resp)
+	})
+	req.SetRequestURI(start)
+	req.Header.SetMethod(fasthttp.MethodGet)
+	if setup != nil {
+		setup(req)
+	}
+
+	return req, followRedirects(client.client, req, resp, 3, mustParseTestURL(t, start), policy)
+}
+
+// withCredentials gives req what a redirect to another origin must not carry.
+func withCredentials(req *fasthttp.Request) {
+	req.Header.Set(fiber.HeaderAuthorization, "Bearer secret")
+	req.Header.Set(fiber.HeaderCookie, "session=abc")
+}
+
+// redirectRewriteCases is what a redirect leaves of a request, by method and status.
+var redirectRewriteCases = []struct {
+	name       string
+	method     string
+	wantMethod string
+	status     int
+	wantBody   bool
+}{
+	{name: "301 POST", method: fasthttp.MethodPost, status: fasthttp.StatusMovedPermanently, wantMethod: fasthttp.MethodGet},
+	{name: "302 POST", method: fasthttp.MethodPost, status: fasthttp.StatusFound, wantMethod: fasthttp.MethodGet},
+	{name: "301 PUT", method: fasthttp.MethodPut, status: fasthttp.StatusMovedPermanently, wantMethod: fasthttp.MethodPut, wantBody: true},
+	{name: "302 PATCH", method: fasthttp.MethodPatch, status: fasthttp.StatusFound, wantMethod: fasthttp.MethodPatch, wantBody: true},
+	{name: "302 DELETE", method: fasthttp.MethodDelete, status: fasthttp.StatusFound, wantMethod: fasthttp.MethodDelete, wantBody: true},
+	{name: "303 POST", method: fasthttp.MethodPost, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodGet},
+	{name: "303 PUT", method: fasthttp.MethodPut, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodGet},
+	{name: "303 PATCH", method: fasthttp.MethodPatch, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodGet},
+	{name: "303 DELETE", method: fasthttp.MethodDelete, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodGet},
+	{name: "303 GET", method: fasthttp.MethodGet, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodGet, wantBody: true},
+	{name: "303 HEAD", method: fasthttp.MethodHead, status: fasthttp.StatusSeeOther, wantMethod: fasthttp.MethodHead, wantBody: true},
+	{name: "307 POST", method: fasthttp.MethodPost, status: fasthttp.StatusTemporaryRedirect, wantMethod: fasthttp.MethodPost, wantBody: true},
+	{name: "308 PUT", method: fasthttp.MethodPut, status: fasthttp.StatusPermanentRedirect, wantMethod: fasthttp.MethodPut, wantBody: true},
+	{name: "200 is no redirect", method: fasthttp.MethodPost, status: fasthttp.StatusOK, wantMethod: fasthttp.MethodPost, wantBody: true},
+}
+
+// Test_Security_RedirectRequest pins the request a redirect leaves for the next hop (RFC 9110 §15.4).
+func Test_Security_RedirectRequest(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range redirectRewriteCases {
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(req)
+			req.Header.SetMethod(tc.method)
+			req.Header.SetContentType("text/plain")
+			req.SetBodyString("payload")
+			req.Header.SetContentLength(len("payload"))
+
+			changes := redirectChangesMethod(req, tc.status)
+			require.Equal(t, !tc.wantBody, changes)
+			if changes {
+				redirectRequest(req)
+			}
+
+			require.Equal(t, tc.wantMethod, string(req.Header.Method()))
+			if tc.wantBody {
+				require.Equal(t, "payload", string(req.Body()))
+				require.Equal(t, "text/plain", string(req.Header.ContentType()))
+				require.Equal(t, len("payload"), req.Header.ContentLength())
+				return
+			}
+			require.Empty(t, req.Body())
+			require.Empty(t, req.Header.ContentType())
+			require.Zero(t, req.Header.ContentLength())
+		})
+	}
+}
+
+// Test_Security_RedirectRequest_LeavesTheHandlerBody pins that rewriting a hop copy leaves the
+// handler's body alone.
+func Test_Security_RedirectRequest_LeavesTheHandlerBody(t *testing.T) {
+	t.Parallel()
+
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	req.Header.SetMethod(fasthttp.MethodPut)
+	req.SetBodyString("payload-of-request-A")
+	held := req.Body()
+
+	hop := copyRequest(req)
+	redirectRequest(hop)
+
+	// Another request takes a pooled body buffer, as another connection would.
+	other := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(other)
+	other.SetBodyString("payload-of-request-B")
+
+	require.Equal(t, "payload-of-request-A", string(held))
+	require.Empty(t, hop.Body())
+}
+
+// Test_Security_RedirectRequest_DropsParsedForm pins that a parsed form goes with the body.
+func Test_Security_RedirectRequest_DropsParsedForm(t *testing.T) {
+	t.Parallel()
+
+	for _, method := range []string{fasthttp.MethodPost, fasthttp.MethodPut} {
+		t.Run(method, func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(req)
+			req.SetRequestURI("http://example.com/start")
+			req.Header.SetMethod(method)
+			req.Header.SetContentType(fiber.MIMEApplicationForm)
+			req.SetBodyString("token=secret&b=2")
+			require.Equal(t, "secret", string(req.PostArgs().Peek("token")), "the handler read the form")
+
+			redirectRequest(req)
+
+			wire := req.String()
+			requestLine, _, _ := strings.Cut(wire, "\r\n")
+			require.Equal(t, "GET /start HTTP/1.1", requestLine)
+			require.NotContains(t, wire, "token=secret")
+			require.NotContains(t, wire, "Content-")
+		})
+	}
+}
+
+// Test_Security_RedirectRequest_DropsFraming pins that a dropped chunked body takes its framing with it.
+func Test_Security_RedirectRequest_DropsFraming(t *testing.T) {
+	t.Parallel()
+
+	const raw = "POST /start HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTrailer: X-Sum\r\n\r\n" +
+		"3\r\nabc\r\n0\r\nX-Sum: 1\r\n\r\n"
+	req := fasthttp.AcquireRequest()
+	defer fasthttp.ReleaseRequest(req)
+	require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+	require.Equal(t, -1, req.Header.ContentLength(), "the request is chunked")
+
+	redirectRequest(req)
+
+	wire := req.String()
+	requestLine, _, _ := strings.Cut(wire, "\r\n")
+	require.Equal(t, "GET /start HTTP/1.1", requestLine)
+	require.NotContains(t, wire, "Transfer-Encoding")
+	require.NotContains(t, wire, "Trailer")
+	require.NotContains(t, wire, "abc")
+}
+
+// Test_Security_FollowRedirects_MethodPerStatus drives the same cases through the redirect loop.
+func Test_Security_FollowRedirects_MethodPerStatus(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range redirectRewriteCases {
+		if !fasthttp.StatusCodeIsRedirect(tc.status) {
+			continue
+		}
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var hops []string
+			followRecording(t, "http://example.com/start", map[string]redirectStep{
+				"http://example.com/start": {status: tc.status, location: "http://example.com/after"},
+			}, func(req *fasthttp.Request) {
+				req.Header.SetMethod(tc.method)
+				req.SetBodyString("payload")
+			}, func(req *fasthttp.Request) {
+				hops = append(hops, string(req.Header.Method())+" "+string(req.Body()))
+			})
+
+			second := tc.wantMethod + " "
+			if tc.wantBody {
+				second += "payload"
+			}
+			require.Equal(t, []string{tc.method + " payload", second}, hops)
+		})
+	}
+}
+
+// Test_Security_FollowRedirects_StripsCredentialsOnOriginChange pins that an origin is scheme, host and
+// port (RFC 6454): a change of any loses the credentials, a spelled-out default port does not.
+func Test_Security_FollowRedirects_StripsCredentialsOnOriginChange(t *testing.T) {
+	t.Parallel()
+
+	for name, tc := range map[string]struct {
+		start    string
+		location string
+		wantAuth string
+	}{
+		"same scheme, host and port": {start: "http://same.example:8080/", location: "http://same.example:8080/next", wantAuth: "Bearer secret"},
+		"default http port spelled":  {start: "http://same.example/", location: "http://same.example:80/next", wantAuth: "Bearer secret"},
+		"default https port spelled": {start: "https://same.example/", location: "https://same.example:443/next", wantAuth: "Bearer secret"},
+		"other host":                 {start: "http://first.example/", location: "http://second.example/next"},
+		"other port":                 {start: "http://same.example:8080/", location: "http://same.example:9090/next"},
+		"http to https":              {start: "http://same.example/", location: "https://same.example/next"},
+		"https to http":              {start: "https://same.example/", location: "http://same.example/next"},
+		"https with the http port":   {start: "https://same.example/", location: "https://same.example:80/next"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			var sawAuth, sawCookie string
+			followRecording(t, tc.start, map[string]redirectStep{
+				tc.start: {status: fasthttp.StatusFound, location: tc.location},
+			}, withCredentials, func(req *fasthttp.Request) {
+				if string(req.URI().Path()) == "/next" {
+					sawAuth = string(req.Header.Peek(fiber.HeaderAuthorization))
+					sawCookie = string(req.Header.Peek(fiber.HeaderCookie))
+				}
+			})
+
+			require.Equal(t, tc.wantAuth, sawAuth)
+			if tc.wantAuth == "" {
+				require.Empty(t, sawCookie)
+			} else {
+				require.Equal(t, "session=abc", sawCookie)
+			}
+		})
+	}
+}
+
+// Test_Security_FollowRedirects_CopiedHopKeepsPreParsedMultipart pins that a copied hop keeps the body
+// of a multipart form the server parsed ahead of the handler: CopyTo leaves such a form out.
+func Test_Security_FollowRedirects_CopiedHopKeepsPreParsedMultipart(t *testing.T) {
+	t.Parallel()
+
+	var form bytes.Buffer
+	mw := multipart.NewWriter(&form)
+	require.NoError(t, mw.WriteField("field", "value"))
+	fw, err := mw.CreateFormFile("file", "f.txt")
+	require.NoError(t, err)
+	_, err = fw.Write([]byte("file-bytes"))
+	require.NoError(t, err)
+	require.NoError(t, mw.Close())
+	raw := "POST http://first.example/start HTTP/1.1\r\nHost: first.example\r\n" +
+		"Content-Type: multipart/form-data; boundary=" + mw.Boundary() + "\r\n" +
+		"Content-Length: " + strconv.Itoa(form.Len()) + "\r\n\r\n" + form.String()
+
+	var bodies []string
+	req := followRecording(t, "http://first.example/start", map[string]redirectStep{
+		"http://first.example/start": {status: fasthttp.StatusTemporaryRedirect, location: "http://second.example/next"},
+	}, func(req *fasthttp.Request) {
+		require.NoError(t, req.Read(bufio.NewReader(strings.NewReader(raw))))
+	}, func(req *fasthttp.Request) {
+		bodies = append(bodies, string(req.Body()))
+	})
+
+	require.Len(t, bodies, 2)
+	for hop, body := range bodies {
+		require.Contains(t, body, "value", "hop %d", hop)
+		require.Contains(t, body, "file-bytes", "hop %d", hop)
+	}
+
+	// The caller's request still holds its form.
+	parsed, err := req.MultipartForm()
+	require.NoError(t, err)
+	require.Equal(t, []string{"value"}, parsed.Value["field"])
+	require.Len(t, parsed.File["file"], 1)
+}
+
+// Test_Security_FollowRedirects_CopiedHopKeepsBody pins that a copied hop that keeps its method sends
+// the request's body again.
+func Test_Security_FollowRedirects_CopiedHopKeepsBody(t *testing.T) {
+	t.Parallel()
+
+	for name, tc := range map[string]struct {
+		method string
+		body   string
+		status int
+	}{
+		"307 POST":       {method: fasthttp.MethodPost, status: fasthttp.StatusTemporaryRedirect, body: "payload"},
+		"308 PUT":        {method: fasthttp.MethodPut, status: fasthttp.StatusPermanentRedirect, body: "payload"},
+		"302 PUT":        {method: fasthttp.MethodPut, status: fasthttp.StatusFound, body: "payload"},
+		"307 without":    {method: fasthttp.MethodPost, status: fasthttp.StatusTemporaryRedirect},
+		"307 GET (none)": {method: fasthttp.MethodGet, status: fasthttp.StatusTemporaryRedirect},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			var hops []string
+			followRecording(t, "http://first.example/start", map[string]redirectStep{
+				"http://first.example/start": {status: tc.status, location: "http://second.example/next"},
+			}, func(req *fasthttp.Request) {
+				req.Header.SetMethod(tc.method)
+				req.SetBodyString(tc.body)
+			}, func(req *fasthttp.Request) {
+				hops = append(hops, string(req.Header.Method())+" "+string(req.Body()))
+			})
+
+			want := tc.method + " " + tc.body
+			require.Equal(t, []string{want, want}, hops)
+		})
+	}
+}
+
+// closeCounter counts the Close calls fasthttp makes on user values it releases.
+type closeCounter struct{ closed atomic.Int32 }
+
+func (c *closeCounter) Close() error {
+	c.closed.Add(1)
+	return nil
+}
+
+// Test_Security_FollowRedirects_CopiedHopKeepsTimeoutAndUserValues pins that a copied hop carries the
+// request timeout and the user values CopyTo leaves out, and does not Close the values it shares.
+func Test_Security_FollowRedirects_CopiedHopKeepsTimeoutAndUserValues(t *testing.T) {
+	t.Parallel()
+
+	type hopState struct {
+		trace   any
+		timeout time.Duration
+	}
+	for name, tc := range map[string]struct {
+		method   string
+		location string
+		status   int
+	}{
+		"another origin": {method: fasthttp.MethodGet, status: fasthttp.StatusTemporaryRedirect, location: "http://second.example/next"},
+		"another method": {method: fasthttp.MethodPost, status: fasthttp.StatusFound, location: "http://first.example/next"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			closer := &closeCounter{}
+			var hops []hopState
+			followRecording(t, "http://first.example/", map[string]redirectStep{
+				"http://first.example/": {status: tc.status, location: tc.location},
+			}, func(req *fasthttp.Request) {
+				req.Header.SetMethod(tc.method)
+				req.SetTimeout(750 * time.Millisecond)
+				req.SetUserValue("trace", "abc")
+				req.SetUserValue("closer", closer)
+			}, func(req *fasthttp.Request) {
+				hops = append(hops, hopState{trace: req.UserValue("trace"), timeout: req.GetTimeOut()})
+			})
+
+			require.Len(t, hops, 2)
+			for hop, state := range hops {
+				require.Equal(t, "abc", state.trace, "hop %d", hop)
+				// The client hands the transport what is left of the timeout.
+				require.Positive(t, state.timeout, "hop %d", hop)
+				require.LessOrEqual(t, state.timeout, 750*time.Millisecond, "hop %d", hop)
+			}
+			require.Zero(t, closer.closed.Load(), "the copy must not Close the caller's values")
+		})
+	}
+}
+
+// Test_Security_FollowRedirects_StreamedBody pins that a redirect keeping the body of a streamed
+// request fails, as fasthttp's own loop does, and that one dropping the body goes on.
+func Test_Security_FollowRedirects_StreamedBody(t *testing.T) {
+	t.Parallel()
+
+	for _, tc := range redirectRewriteCases {
+		if !fasthttp.StatusCodeIsRedirect(tc.status) {
+			continue
+		}
+		t.Run(tc.name, func(t *testing.T) {
+			t.Parallel()
+
+			var methods []string
+			_, err := followRecordingErr(t, "http://example.com/start", map[string]redirectStep{
+				"http://example.com/start": {status: tc.status, location: "http://example.com/after"},
+			}, func(req *fasthttp.Request) {
+				req.Header.SetMethod(tc.method)
+				req.SetBodyStream(strings.NewReader("payload"), len("payload"))
+			}, func(req *fasthttp.Request) {
+				methods = append(methods, string(req.Header.Method()))
+				if req.IsBodyStream() { // sending the request consumes the stream
+					body, readErr := io.ReadAll(req.BodyStream())
+					require.NoError(t, readErr)
+					require.Equal(t, "payload", string(body))
+					require.NoError(t, req.CloseBodyStream())
+				}
+			})
+
+			if tc.wantBody {
+				require.ErrorIs(t, err, fasthttp.ErrRedirectBodyStream)
+				require.Equal(t, []string{tc.method}, methods, "nothing is replayed")
+				return
+			}
+			require.NoError(t, err)
+			require.Equal(t, []string{tc.method, fasthttp.MethodGet}, methods)
+		})
+	}
+}
+
+// streamedRequest makes req what fasthttp's server hands a handler when StreamRequestBody is on: the
+// head parsed, up to 8 KiB of a known-length body read ahead, the rest behind a stream. raw is the request.
+func streamedRequest(tb testing.TB, req *fasthttp.Request, raw string) {
+	tb.Helper()
+
+	br := bufio.NewReader(strings.NewReader(raw))
+	require.NoError(tb, req.Header.Read(br))
+	require.NoError(tb, req.ContinueReadBodyStream(br, 1<<20))
+	require.True(tb, req.IsBodyStream())
+}
+
+// Test_Security_FollowRedirects_ServerStreamedBody pins that a body-keeping redirect of a server-streamed
+// request is followed when the server read the whole body ahead (up to 8 KiB), and fails otherwise.
+func Test_Security_FollowRedirects_ServerStreamedBody(t *testing.T) {
+	t.Parallel()
+
+	const readAhead = 8 * 1024
+	for _, tc := range []struct {
+		name    string
+		framing string
+		onWire  string // the body as it is on the connection
+		payload string // the body a hop sends
+		wantErr bool
+	}{
+		{name: "empty", framing: "Content-Length: 0"},
+		{name: "small", framing: "Content-Length: 7", onWire: "payload", payload: "payload"},
+		{name: "as much as is read ahead", framing: "Content-Length: " + strconv.Itoa(readAhead), onWire: strings.Repeat("a", readAhead), payload: strings.Repeat("a", readAhead)},
+		{name: "more than is read ahead", framing: "Content-Length: " + strconv.Itoa(readAhead+1), onWire: strings.Repeat("a", readAhead+1), wantErr: true},
+		{name: "chunked", framing: "Transfer-Encoding: chunked", onWire: "7\r\npayload\r\n0\r\n\r\n", wantErr: true},
+	} {
+		for _, location := range []string{"http://example.com/after", "http://other.example/after"} {
+			for _, status := range []int{fasthttp.StatusTemporaryRedirect, fasthttp.StatusPermanentRedirect} {
+				t.Run(tc.name+" "+strconv.Itoa(status)+" to "+location, func(t *testing.T) {
+					t.Parallel()
+
+					var wires []string
+					_, err := followRecordingErr(t, "http://example.com/start", map[string]redirectStep{
+						"http://example.com/start": {status: status, location: location},
+					}, func(req *fasthttp.Request) {
+						streamedRequest(t, req, "POST /start HTTP/1.1\r\nHost: example.com\r\n"+tc.framing+"\r\n\r\n"+tc.onWire)
+					}, func(req *fasthttp.Request) {
+						wires = append(wires, req.String()) // sending the request consumes the stream
+					})
+
+					if tc.wantErr {
+						require.ErrorIs(t, err, fasthttp.ErrRedirectBodyStream)
+						require.Len(t, wires, 1, "nothing is sent again")
+						return
+					}
+					require.NoError(t, err)
+					require.Len(t, wires, 2)
+					for hop, wire := range wires {
+						head, body, found := strings.Cut(wire, "\r\n\r\n")
+						require.True(t, found, "hop %d", hop)
+						require.Contains(t, head, "Content-Length: "+strconv.Itoa(len(tc.payload)), "hop %d", hop)
+						require.Equal(t, tc.payload, body, "hop %d", hop)
+					}
+				})
+			}
+		}
+	}
+}
+
+// Test_Security_FollowRedirects_StreamedBodyEndsWithTheMethod pins that a redirect making a streamed
+// request a GET ends the stream rule, so a later method-keeping redirect is followed.
+func Test_Security_FollowRedirects_StreamedBodyEndsWithTheMethod(t *testing.T) {
+	t.Parallel()
+
+	for name, tc := range map[string]struct{ framing, onWire string }{
+		"known length": {framing: "Content-Length: 7", onWire: "payload"},
+		"chunked":      {framing: "Transfer-Encoding: chunked", onWire: "7\r\npayload\r\n0\r\n\r\n"},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			var methods []string
+			_, err := followRecordingErr(t, "http://example.com/start", map[string]redirectStep{
+				"http://example.com/start": {status: fasthttp.StatusSeeOther, location: "http://example.com/mid"},
+				"http://example.com/mid":   {status: fasthttp.StatusTemporaryRedirect, location: "http://example.com/end"},
+			}, func(req *fasthttp.Request) {
+				streamedRequest(t, req, "POST /start HTTP/1.1\r\nHost: example.com\r\n"+tc.framing+"\r\n\r\n"+tc.onWire)
+			}, func(req *fasthttp.Request) {
+				methods = append(methods, string(req.Header.Method()))
+				_ = req.String() // sending the request consumes the stream
+			})
+
+			require.NoError(t, err)
+			require.Equal(t, []string{fasthttp.MethodPost, fasthttp.MethodGet, fasthttp.MethodGet}, methods)
+		})
+	}
+}
+
+// Test_Security_FollowRedirects_UnreadStream pins that a stream the transport left unread is not
+// buffered by the redirect, which fails.
+func Test_Security_FollowRedirects_UnreadStream(t *testing.T) {
+	t.Parallel()
+
+	reader := &countingReader{Reader: strings.NewReader("payload")}
+	_, err := followRecordingErr(t, "http://example.com/start", map[string]redirectStep{
+		"http://example.com/start": {status: fasthttp.StatusTemporaryRedirect, location: "http://example.com/after"},
+	}, func(req *fasthttp.Request) {
+		req.Header.SetMethod(fasthttp.MethodPost)
+		req.SetBodyStream(reader, len("payload"))
+	}, nil)
+
+	require.ErrorIs(t, err, fasthttp.ErrRedirectBodyStream)
+	require.Zero(t, reader.read.Load(), "the stream stays unread")
+}
+
+type countingReader struct {
+	io.Reader
+	read atomic.Int64
+}
+
+func (r *countingReader) Read(p []byte) (int, error) {
+	n, err := r.Reader.Read(p)
+	r.read.Add(int64(n))
+	return n, err //nolint:wrapcheck // a pass-through
+}
+
+// contentFieldNames are the fields a request without content must not carry (RFC 9110 §8, §10.1.1).
+var contentFieldNames = []string{
+	fiber.HeaderContentEncoding, fiber.HeaderContentLanguage, fiber.HeaderContentLocation,
+	fiber.HeaderExpect, "Digest", "Content-MD5",
+}
+
+// Test_Security_RedirectRequest_DropsContentFields pins that the fields describing or expecting
+// content go with it, whatever case they are stored under.
+func Test_Security_RedirectRequest_DropsContentFields(t *testing.T) {
+	t.Parallel()
+
+	for name, canonical := range map[string]bool{"canonical names": true, "names as sent": false} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			req := fasthttp.AcquireRequest()
+			defer fasthttp.ReleaseRequest(req)
+			if !canonical {
+				req.Header.DisableNormalizing()
+			}
+			req.SetRequestURI("http://example.com/")
+			req.Header.SetMethod(fasthttp.MethodPost)
+			for _, field := range contentFieldNames {
+				if !canonical {
+					field = strings.ToLower(field)
+				}
+				req.Header.Set(field, "x")
+			}
+			req.Header.Set("X-Kept", "kept")
+			req.SetBodyString("payload")
+
+			redirectRequest(req)
+
+			wire := strings.ToLower(req.String())
+			for _, field := range contentFieldNames {
+				require.NotContains(t, wire, strings.ToLower(field)+":", field)
+			}
+			require.Contains(t, wire, "x-kept: kept")
+		})
+	}
+}
+
+// Test_Security_FollowRedirects_ContentFieldsFollowTheBody pins that the fields describing or
+// expecting content leave with a body a redirect drops, and stay with one it repeats.
+func Test_Security_FollowRedirects_ContentFieldsFollowTheBody(t *testing.T) {
+	t.Parallel()
+
+	for name, tc := range map[string]struct {
+		status int
+		kept   bool
+	}{
+		"302 drops the body": {status: fasthttp.StatusFound},
+		"307 repeats it":     {status: fasthttp.StatusTemporaryRedirect, kept: true},
+	} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			var hops [][]string
+			followRecording(t, "http://example.com/start", map[string]redirectStep{
+				"http://example.com/start": {status: tc.status, location: "http://example.com/after"},
+			}, func(req *fasthttp.Request) {
+				req.Header.SetMethod(fasthttp.MethodPost)
+				req.SetBodyString("payload")
+				for _, field := range contentFieldNames {
+					req.Header.Set(field, "x")
+				}
+			}, func(req *fasthttp.Request) {
+				var present []string
+				for _, field := range contentFieldNames {
+					if len(req.Header.Peek(field)) > 0 {
+						present = append(present, field)
+					}
+				}
+				hops = append(hops, present)
+			})
+
+			require.Len(t, hops, 2)
+			require.Equal(t, contentFieldNames, hops[0])
+			if tc.kept {
+				require.Equal(t, contentFieldNames, hops[1])
+			} else {
+				require.Empty(t, hops[1])
+			}
+		})
+	}
+}
+
+// Test_Security_KeepHopByHopHeaders_Balancer pins the opt-out for a Balancer with its own policy.
+func Test_Security_KeepHopByHopHeaders_Balancer(t *testing.T) {
+	t.Parallel()
+
+	for name, keep := range map[string]bool{"stripped by default": false, "kept with the opt-out": true} {
+		t.Run(name, func(t *testing.T) {
+			t.Parallel()
+
+			seen := make(chan [2]string, 1)
+			_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+				seen <- [2]string{c.Get(fiber.HeaderProxyAuthorization), c.Get(fiber.HeaderKeepAlive)}
+				c.Set(fiber.HeaderProxyAuthenticate, "Basic")
+				c.Set(fiber.HeaderKeepAlive, "timeout=7")
+				return c.SendString("ok")
+			})
+
+			policy := DefaultSecurityPolicy()
+			policy.AllowPrivateIPs = true
+			policy.KeepHopByHopHeaders = keep
+			app := fiber.New()
+			app.Use(Balancer(Config{Servers: []string{addr}, SecurityPolicy: &policy}))
+
+			req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+			req.Header.Set(fiber.HeaderProxyAuthorization, "Basic dXNlcjpwYXNz")
+			req.Header.Set(fiber.HeaderKeepAlive, "timeout=5")
+			resp, err := app.Test(req)
+			require.NoError(t, err)
+			require.Equal(t, fiber.StatusOK, resp.StatusCode)
+
+			got := <-seen
+			if keep {
+				require.Equal(t, "Basic dXNlcjpwYXNz", got[0])
+				require.Equal(t, "timeout=5", got[1])
+				require.Equal(t, "Basic", resp.Header.Get(fiber.HeaderProxyAuthenticate))
+				require.Equal(t, "timeout=7", resp.Header.Get(fiber.HeaderKeepAlive))
+				return
+			}
+			require.Empty(t, got[0])
+			require.Empty(t, got[1])
+			require.Empty(t, resp.Header.Get(fiber.HeaderProxyAuthenticate))
+			require.Empty(t, resp.Header.Get(fiber.HeaderKeepAlive))
+		})
+	}
+}
+
+// Test_Security_KeepHopByHopHeaders_Do is the same opt-out for the helpers, via the process-wide policy.
+func Test_Security_KeepHopByHopHeaders_Do(t *testing.T) {
+	// Intentionally not parallel: it sets a process-wide security policy.
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+	policy.KeepHopByHopHeaders = true
+	withSecurityPolicyForTest(t, policy)
+
+	seen := make(chan string, 1)
+	_, addr := createProxyTestServerIPv4(t, func(c fiber.Ctx) error {
+		seen <- c.Get(fiber.HeaderProxyAuthorization)
+		c.Set(fiber.HeaderProxyAuthenticate, "Basic")
+		return c.SendString("ok")
+	})
+
+	app := fiber.New()
+	app.Get("/", func(c fiber.Ctx) error { return Do(c, "http://"+addr) })
+
+	req := httptest.NewRequest(fiber.MethodGet, "/", http.NoBody)
+	req.Header.Set(fiber.HeaderProxyAuthorization, "Basic dXNlcjpwYXNz")
+	resp, err := app.Test(req)
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.Equal(t, "Basic dXNlcjpwYXNz", <-seen)
+	require.Equal(t, "Basic", resp.Header.Get(fiber.HeaderProxyAuthenticate))
+}
+
+// Test_Security_ValidateUpstream_UnparsableIsHostInvalid pins that an address net/url cannot
+// parse is ErrUpstreamHostInvalid, with the *url.Error still reachable.
+func Test_Security_ValidateUpstream_UnparsableIsHostInvalid(t *testing.T) {
+	t.Parallel()
+
+	for _, raw := range []string{"http://[::1", "http://exam ple.com", "http://%zz.com/", "http://a:b:c/"} {
+		_, err := validateUpstream(raw, DefaultSecurityPolicy(), nil)
+		require.ErrorIs(t, err, ErrUpstreamHostInvalid, raw)
+		_, ok := errors.AsType[*url.Error](err)
+		require.True(t, ok, "the net/url error must stay reachable: %q", raw)
+	}
+
+	// "" and "http:///path" are pinned by RejectsEmpty and EmptyHostAfterScheme.
+	for _, raw := range []string{"   ", "http://", "http://:8080"} {
+		_, err := validateUpstream(raw, DefaultSecurityPolicy(), nil)
+		require.ErrorIs(t, err, ErrUpstreamHostInvalid, raw)
+	}
+}
+
+// Test_Security_ValidateUpstreamForBalancer_Schemes pins the scheme of each accepted Balancer server
+// form; Test_Proxy_Balancer_RejectsNonOriginServer pins what is refused.
+func Test_Security_ValidateUpstreamForBalancer_Schemes(t *testing.T) {
+	t.Parallel()
+
+	policy := DefaultSecurityPolicy()
+	policy.AllowPrivateIPs = true
+
+	for raw, wantScheme := range map[string]string{
+		"203.0.113.5:8080":          schemeHTTP,
+		"http://203.0.113.5:8080":   schemeHTTP,
+		"http://203.0.113.5:8080/":  schemeHTTP,
+		"https://upstream.example":  schemeHTTPS,
+		"http://[2001:db8::1]:8080": schemeHTTP,
+	} {
+		u, err := validateUpstreamForBalancer(raw, policy)
+		require.NoError(t, err, raw)
+		require.Equal(t, wantScheme, u.Scheme, raw)
+	}
+}

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path middleware/limiter/limiter_test.go --path middleware/proxy/bench_test.go --path middleware/proxy/coverage_test.go --path middleware/proxy/fuzz_test.go --path middleware/proxy/lookupcache_test.go --path middleware/proxy/proxy_test.go --path middleware/proxy/security_rebinding_test.go --path middleware/proxy/security_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/limiter ./middleware/proxy')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./middleware/limiter ./middleware/proxy' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
