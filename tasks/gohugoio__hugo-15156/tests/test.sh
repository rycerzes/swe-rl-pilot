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
for f in resources/resource_transformers/cssjs/inline_imports_test.go resources/resource_transformers/cssjs/tailwindcss_integration_test.go resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go tpl/css/build_integration_test.go; do if git cat-file -e 8a468df065a75c1c7cf9f6850f32148746590ea5:"$f" 2>/dev/null; then git checkout 8a468df065a75c1c7cf9f6850f32148746590ea5 -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 8a468df065a75c1c7cf9f6850f32148746590ea5 "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/resources/resource_transformers/cssjs/inline_imports_test.go b/resources/resource_transformers/cssjs/inline_imports_test.go
index 3578e261286..bfbef977a35 100644
--- a/resources/resource_transformers/cssjs/inline_imports_test.go
+++ b/resources/resource_transformers/cssjs/inline_imports_test.go
@@ -14,6 +14,7 @@
 package cssjs
 
 import (
+	"context"
 	"regexp"
 	"strings"
 	"testing"
@@ -21,10 +22,12 @@ import (
 	"github.com/gohugoio/hugo/common/loggers"
 	"github.com/gohugoio/hugo/htesting/hqt"
 	"github.com/gohugoio/hugo/identity"
+	"github.com/gohugoio/hugo/resources/resource"
 
 	"github.com/gohugoio/hugo/helpers"
 
 	"github.com/spf13/afero"
+	"github.com/spf13/cast"
 
 	qt "github.com/frankban/quicktest"
 )
@@ -103,6 +106,7 @@ LOCAL_STYLE
 @import "e.css";`)
 
 	imp := newImportResolver(
+		t.Context(),
 		mainStyles,
 		"styles.css",
 		InlineImports{},
@@ -130,6 +134,70 @@ E_STYLE`)
 	})
 }
 
+func TestImportResolverImportContext(t *testing.T) {
+	c := qt.New(t)
+	fs := afero.NewMemMapFs()
+
+	writeFile := func(name, content string) {
+		c.Assert(afero.WriteFile(fs, name, []byte(content), 0o777), qt.IsNil)
+	}
+
+	// Loses to the import context entry with the same name.
+	writeFile("css/a.css", "A_STYLE_FS")
+	writeFile("css/b.css", "B_STYLE_FS")
+
+	importContext := testImportContext{
+		"a.css":     "@import \"c.css\";\nA_STYLE",
+		"c.css":     "C_STYLE",
+		"css/d.css": "D_STYLE",
+	}
+
+	mainStyles := strings.NewReader(`@import "a.css";
+@import "b.css";
+@import "./d.css";
+LOCAL_STYLE`)
+
+	imp := newImportResolver(
+		t.Context(),
+		mainStyles,
+		"css/styles.css",
+		InlineImports{ImportContext: importContext},
+		fs, loggers.NewDefault(),
+		identity.NopManager,
+	)
+
+	r, err := imp.resolve()
+	c.Assert(err, qt.IsNil)
+	rs := helpers.ReaderToString(r)
+	result := regexp.MustCompile(`\n+`).ReplaceAllString(rs, "\n")
+
+	c.Assert(result, hqt.IsSameString, `C_STYLE
+A_STYLE
+B_STYLE_FS
+D_STYLE
+LOCAL_STYLE`)
+}
+
+type testImportContext map[string]string
+
+func (g testImportContext) Get(name any) resource.Resource {
+	s := cast.ToString(name)
+	if content, found := g[s]; found {
+		return testImportContextResource{name: s, content: content}
+	}
+	return nil
+}
+
+type testImportContextResource struct {
+	resource.Resource
+	name    string
+	content string
+}
+
+func (r testImportContextResource) Name() string { return r.name }
+
+func (r testImportContextResource) Content(context.Context) (any, error) { return r.content, nil }
+
 func BenchmarkImportResolver(b *testing.B) {
 	c := qt.New(b)
 	fs := afero.NewMemMapFs()
@@ -161,6 +229,7 @@ LOCAL_STYLE
 	for b.Loop() {
 		b.StopTimer()
 		imp := newImportResolver(
+			b.Context(),
 			strings.NewReader(mainStyles),
 			"styles.css",
 			InlineImports{},
diff --git a/resources/resource_transformers/cssjs/tailwindcss_integration_test.go b/resources/resource_transformers/cssjs/tailwindcss_integration_test.go
index e2ce293e3a8..03cd1e07eb7 100644
--- a/resources/resource_transformers/cssjs/tailwindcss_integration_test.go
+++ b/resources/resource_transformers/cssjs/tailwindcss_integration_test.go
@@ -64,6 +64,45 @@ CSS: {{ $css.Content | safeCSS }}|
 	b.AssertFileContent("public/index.html", "/*! tailwindcss v4.")
 }
 
+// See issue 15103.
+func TestTailwindCSSImportContext(t *testing.T) {
+	t.Parallel()
+	htesting.SkipSlowTestUnlessCI(t)
+
+	files := `
+-- hugo.toml --
+disableKinds = ['page','rss','section','sitemap','taxonomy','term']
+-- assets/css/main.css --
+@import "tailwindcss";
+
+@import "foo.css";
+@import "bar.css";
+-- assets/css/foo.css --
+.foo {color: orange;}
+-- layouts/home.html --
+{{ $foo := resources.FromString "foo.css" ".foo {color: blue;}" }}
+{{ $bar := resources.FromString "bar.css" ".bar {color: green;}" }}
+{{ $opts := dict "importContext" (slice $foo $bar) }}
+{{ $css := resources.Get "css/main.css" | css.TailwindCSS $opts }}
+CSS: {{ $css.Content | safeCSS }}|
+-- package.json --
+{
+  "devDependencies": {
+    "@tailwindcss/cli": "^4.1.7",
+    "tailwindcss": "^4.1.7"
+  }
+}
+`
+
+	b := hugolib.Test(t, files, hugolib.TestOptOsFs(), hugolib.TestOptWithNpmInstall(), hugolib.TestOptInfo())
+
+	// foo.css resolves in the import context before the assets filesystem.
+	b.AssertFileContent("public/index.html",
+		".foo {\n    color: blue;\n  }",
+		".bar {\n    color: green;\n  }",
+	)
+}
+
 func TestTailwindCSSNoInlineImportsIssue13719(t *testing.T) {
 	t.Parallel()
 	htesting.SkipSlowTestUnlessCI(t)
diff --git a/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go b/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
index 72e01266718..2acbd819405 100644
--- a/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
+++ b/resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go
@@ -51,6 +51,35 @@ T1: {{ $r.Content }}
 	b.AssertFileContent("public/index.html", `T1: moo{color:#fff}`)
 }
 
+// See issue 15103.
+func TestTransformImportContext(t *testing.T) {
+	t.Parallel()
+	if !dartsass.Supports() {
+		t.Skip()
+	}
+
+	files := `
+-- hugo.toml --
+-- assets/scss/_foo.scss --
+body { color: orange; }
+-- assets/scss/main.scss --
+@import "foo";
+@import "bar";
+-- layouts/home.html --
+{{ $foo := resources.FromString "foo.scss" "body { color: blue; }" }}
+{{ $bar := resources.FromString "bar.scss" "@import \"baz\";\nbody { color: green; }" }}
+{{ $baz := resources.FromString "baz.scss" "p { color: red; }" }}
+{{ $opts := dict "transpiler" "dartsass" "outputStyle" "compressed" "importContext" (slice $foo $bar $baz) }}
+{{ $r := resources.Get "scss/main.scss" | css.Sass $opts }}
+T1: {{ $r.Content }}
+	`
+
+	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
+
+	// foo resolves in the import context before the assets filesystem.
+	b.AssertFileContent("public/index.html", `T1: body{color:blue}p{color:red}body{color:green}`)
+}
+
 func TestTransformImportRegularCSS(t *testing.T) {
 	t.Parallel()
 	if !dartsass.Supports() {
diff --git a/tpl/css/build_integration_test.go b/tpl/css/build_integration_test.go
index 31b692a8ef5..1818bcf1150 100644
--- a/tpl/css/build_integration_test.go
+++ b/tpl/css/build_integration_test.go
@@ -731,3 +731,181 @@ body {
 		"--text-color: #333;",
 	)
 }
+
+func TestCSSBuildImportContext(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+-- assets/foo.css --
+body { color: orange; }
+-- assets/css/main.css --
+@import "foo.css" screen;
+@import "bar.css" print;
+p {
+  font-color: red;
+}
+-- layouts/home.html --
+{{ $foo := resources.FromString "foo.css" "body { color: blue; }" }}
+{{ $bar := resources.FromString "bar.css" "body { color: green; }" }}
+{{/* resource.Resources implements the resources.ResourceGetter interface (the type of importContext). */}}
+{{ $resources := slice  $foo $bar}}
+{{ $opts := dict "minify" true "importContext" $resources }}
+{{ $css := resources.Get "css/main.css" | css.Build $opts }}
+CSS: {{ $css.RelPermalink }}|
+`
+
+	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
+
+	b.AssertFileContent("public/css/main.css", `@media screen{body{color:#00f}}@media print{body{color:green}}p{font-color:red}`)
+}
+
+func TestCSSBuildImportContextChromaStyles(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+disableKinds = ["taxonomy", "term", "rss", "sitemap", "section", "page"]
+[markup.highlight]
+style = "monokai"
+-- assets/css/components/all.css --
+@import "./chroma-light.css";
+@import "./chroma-dark.css" (prefers-color-scheme: dark);
+-- assets/css/main.css --
+@import "./components/all.css";
+
+:root {
+  color-scheme: light dark;
+}
+
+-- layouts/home.html --
+{{ $light := css.ChromaStyles (dict "targetPath" "css/components/chroma-light.css" "style" "github" "mode" "light") }}
+{{ $dark := css.ChromaStyles (dict "targetPath" "css/components/chroma-dark.css" "style" "github" "mode" "dark") }}
+{{ $opts := dict "minify" true "importContext" (slice $light $dark) }}
+{{ $css := resources.Get "css/main.css" | css.Build $opts }}
+CSS: {{ $css.RelPermalink }}|
+`
+
+	b := hugolib.Test(t, files, hugolib.TestOptOsFs())
+
+	b.AssertFileContent("public/index.html", "CSS: /css/main.css|")
+	b.AssertFileContent("public/css/main.css", ".bg{background-color:#f7f7f7}.chroma", "@media(prefers-color-scheme:dark){.bg{color:#e6edf3")
+}
+
+func TestCSSBuildImportContextHashes(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+-- assets/foo.css --
+body { color: orange; }
+-- assets/css/main.css --
+@import "foo.css" screen;
+@import "bar.css" print;
+p {
+  font-color: red;
+}
+-- layouts/home.html --
+{{ $foo := resources.FromString "foo.css" "body { color: blue; }" }}|
+{{ $foo2 := resources.FromString "foo2.css" "body { color: blue; }" }}|
+{{ $foo3 := resources.FromString "foo.css" "body { color: indigo; }" }}|
+{{ $bar := resources.FromString "bar.css" "body { color: green; }" }}|
+{{ $resources := slice $foo $bar}}
+{{ $resourcesMount1 := $resources.Mount "a" "b"}}
+{{ $resourcesMount2 := $resources.Mount "a" "c"}}
+{{ $opts := dict "minify" true "importContext" $resources }}
+foo: {{ $foo | testinginternal.HashString }}|
+foo2: {{ $foo2 | testinginternal.HashString }}|
+foo3: {{ $foo3 | testinginternal.HashString }}|
+bar: {{ $bar | testinginternal.HashString }}|
+resources: {{ $resources | testinginternal.HashString }}|
+resourcesMount1: {{ $resourcesMount1 | testinginternal.HashString }}|
+resourcesMount2: {{ $resourcesMount2 | testinginternal.HashString }}|
+resources namespace: {{ resources | testinginternal.HashString }}|
+opts: {{ $opts | testinginternal.HashString }}|
+home: {{ . | testinginternal.HashString }}|{{ .Key }}|
+slice with Page: {{ slice $foo $bar . | testinginternal.HashString }}|
+map with Page: {{ dict "foo" $foo "bar" $bar "page" . | testinginternal.HashString }}|
+{{ $css := resources.Get "css/main.css" | css.Build $opts -}}
+css: {{ $css | testinginternal.HashString }}|
+cached1: {{ testinginternal.NewCachedResourceGetter $resources resources | testinginternal.HashString}}
+cached2: {{ testinginternal.NewCachedResourceGetter $resources | testinginternal.HashString}}
+cached3: {{ testinginternal.NewCachedResourceGetter $resources resources $resourcesMount1 $resourcesMount2 | testinginternal.HashString}}
+
+
+`
+
+	for range 2 {
+
+		b := hugolib.Test(t, files, hugolib.TestOptOsFs())
+
+		b.AssertFileContent("public/index.html", `
+foo: 17610550322594361312|
+foo2: 12741631597870435822|
+foo3: 4488319114298108946|
+bar: 11981658863051989001|
+resources: 10963320145636139629|
+resourcesMount1: 7843365040860281860|
+resourcesMount2: 10632811173795339581|
+resources namespace: 12714111578321948564|
+opts: 7538269917289793785|
+css: 8075855322897706813|
+home: 166103792234269065|/html|
+slice with Page: 7769684332502419906|
+map with Page: 10393165700333352395|
+cached1: 7064840587060576200
+cached2: 6730658186132701788
+cached3: 13761938017162285970
+`)
+
+	}
+}
+
+func TestCSSBuildImportContextEdit(t *testing.T) {
+	t.Parallel()
+
+	files := `
+-- hugo.toml --
+disableLiveReload = true
+-- assets/css/common/baz.css --
+body { color: purple; }
+-- assets/css/main.css --
+@import "foo.css" screen;
+@import "bar.css" print;
+@import "baz.css" screen and (min-width: 768px);
+p {
+  font-color: red;
+}
+-- layouts/home.html --
+{{ $foo := resources.FromString "foo.css" "body { color: blue; }" }}
+{{ $bar := resources.FromString "bar.css" "body { color: green; }" }}
+{{ $common := resources.Match "/css/common/*.css" }}
+{{ $commonMount := ($common.Mount "/css/common" ".")}}
+{{ $resources := slice $foo $bar }}
+{{ $opts := dict "minify" true "importContext" (slice $resources $commonMount) }}
+resources: {{ $resources | testinginternal.HashString }}|
+{{ $css := resources.Get "css/main.css" | css.Build $opts }}
+CSS: {{ $css.RelPermalink }}|
+`
+
+	b := hugolib.TestRunning(t, files, hugolib.TestOptOsFs())
+
+	b.AssertFileContent("public/css/main.css", `
+@media screen{body{color:#00f}}@media print{body{color:green}}
+@media screen and (min-width:768px){body{color:purple}}
+`)
+
+	// Edit resource built with resources.FromString.
+	b.EditFileReplaceAll("layouts/home.html", "color: green", "color: yellow").Build()
+	b.AssertFileContent("public/css/main.css", `
+@media screen{body{color:#00f}}@media print{body{color:#ff0}}
+@media screen and (min-width:768px){body{color:purple}}
+`)
+
+	// Edit resource in the mounted slice.
+	b.EditFileReplaceAll("assets/css/common/baz.css", "purple", "orange").Build()
+	b.AssertFileContent("public/css/main.css", `
+@media screen{body{color:#00f}}@media print{body{color:#ff0}}
+@media screen and (min-width:768px){body{color:orange}}
+`)
+}

EOF_R2E_TEST_PATCH
R2E_APPLY_RC=$?
[ "$R2E_APPLY_RC" -eq 0 ] || r2e_finish graded test_patch_apply_failed 'test patch failed to apply'
R2E_MTIME="$(date +%s)"
"$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path resources/resource_transformers/cssjs/inline_imports_test.go --path resources/resource_transformers/cssjs/tailwindcss_integration_test.go --path resources/resource_transformers/tocss/dartsass/dartsass_integration_test.go --path tpl/css/build_integration_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded grader_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 120 -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./resources/resource_transformers/cssjs ./resources/resource_transformers/tocss/dartsass ./tpl/css')"
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
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./resources/resource_transformers/cssjs ./resources/resource_transformers/tocss/dartsass ./tpl/css' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
