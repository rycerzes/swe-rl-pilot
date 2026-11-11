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
for f in client/client_test.go client/cookiejar_test.go ctx_test.go middleware/adaptor/adaptor_test.go middleware/cache/cache_test.go middleware/hostauthorization/hostauthorization_test.go middleware/paginate/paginate_test.go middleware/proxy/fuzz_test.go; do if git cat-file -e 6639aefb9577472efe8b80e9bb366cb1c6358ddb:"$f" 2>/dev/null; then git checkout 6639aefb9577472efe8b80e9bb366cb1c6358ddb -- "$f"; else rm -f -- "$f"; fi; done || true
R2E_GUARD_ENV="$(mktemp)"
"$R2E_PY" -B -I -S - 6639aefb9577472efe8b80e9bb366cb1c6358ddb "$R2E_GUARD_ENV" <<'R2E_PYTEST_CONFIG_GUARD'
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
diff --git a/client/client_test.go b/client/client_test.go
index 3f4c3a2d2d5..2034329e09d 100644
--- a/client/client_test.go
+++ b/client/client_test.go
@@ -2396,12 +2396,17 @@ func Benchmark_Client_Request_Send_ContextCancel(b *testing.B) {
 	app, ln, start := createHelperServer(b)
 
 	startedCh := make(chan struct{})
+	canceledCh := make(chan struct{})
 	errCh := make(chan error)
 	respCh := make(chan *Response)
 
 	app.Post("/", func(c fiber.Ctx) error {
 		startedCh <- struct{}{}
-		time.Sleep(time.Millisecond) // let cancel be called
+		// Hold the response until the loop has received Send's outcome:
+		// with the reply still pending, the client's response channel
+		// cannot be ready, so Send can only return through its
+		// ctx.Done() branch — no race against the reply.
+		<-canceledCh
 		return c.Status(fiber.StatusOK).SendString("post")
 	})
 
@@ -2433,8 +2438,14 @@ func Benchmark_Client_Request_Send_ContextCancel(b *testing.B) {
 		<-startedCh // request is made, we can cancel the context now
 		cancel()
 
-		require.Nil(b, <-respCh)
-		require.ErrorIs(b, <-errCh, ErrTimeoutOrCancel)
+		// Send must return before the handler is released below, so these
+		// receives can only observe the cancellation outcome.
+		resp := <-respCh
+		err := <-errCh
+		canceledCh <- struct{}{} // release the handler; core's drainer reclaims the late response
+
+		require.Nil(b, resp)
+		require.ErrorIs(b, err, ErrTimeoutOrCancel)
 	}
 }
 
diff --git a/client/cookiejar_test.go b/client/cookiejar_test.go
index 200cf90decb..d1456623602 100644
--- a/client/cookiejar_test.go
+++ b/client/cookiejar_test.go
@@ -322,6 +322,29 @@ func Test_CookieJar_HostPort(t *testing.T) {
 	require.Equal(t, "fasthttp.com", string(cookies[0].Domain()))
 }
 
+func Test_CookieJar_isIPLiteral(t *testing.T) {
+	t.Parallel()
+
+	// Pinned to net.ParseIP semantics: zoned addresses are rejected.
+	tests := []struct {
+		host string
+		want bool
+	}{
+		{"192.0.2.1", true},
+		{"::1", true},
+		{"[::1]", true},
+		{"::ffff:192.0.2.1", true},
+		{"fe80::1%eth0", false},
+		{"[fe80::1%eth0]", false},
+		{"example.com", false},
+		{"192.0.2.256", false},
+		{"", false},
+	}
+	for _, tt := range tests {
+		require.Equal(t, tt.want, isIPLiteral(tt.host), "isIPLiteral(%q)", tt.host)
+	}
+}
+
 func Test_CookieJar_Domain(t *testing.T) {
 	t.Parallel()
 
diff --git a/ctx_test.go b/ctx_test.go
index c1a08e59700..1d31b03f042 100644
--- a/ctx_test.go
+++ b/ctx_test.go
@@ -2957,6 +2957,7 @@ func Test_Ctx_Fresh_ObsoleteDateFormats(t *testing.T) {
 		"Wed, 21 Oct 2015 07:28:00 GMT",     // IMF-fixdate
 		"Wednesday, 21-Oct-15 07:28:00 GMT", // obsolete RFC 850 format
 		"Wed Oct 21 07:28:00 2015",          // ANSI C asctime() format
+		" Wed, 21 Oct 2015 07:28:00 GMT ",   // surrounding OWS tolerated (RFC 9110 §5.5)
 	} {
 		c := app.AcquireCtx(&fasthttp.RequestCtx{})
 		c.Request().Header.Set(HeaderIfModifiedSince, date)
diff --git a/middleware/adaptor/adaptor_test.go b/middleware/adaptor/adaptor_test.go
index 6ef711bf70c..0b20ec33719 100644
--- a/middleware/adaptor/adaptor_test.go
+++ b/middleware/adaptor/adaptor_test.go
@@ -1778,3 +1778,141 @@ func TestUnixSocketAdaptor(t *testing.T) {
 		t.Fatal("server shutdown timed out")
 	}
 }
+
+// Test_ResolveRemoteAddr_FastPathEquivalence pins the ip:port fast path to
+// net.ResolveTCPAddr: for every literal form the fast path accepts, both
+// must produce the same address, and inputs the fast path rejects must
+// still resolve identically through the fallback.
+func Test_ResolveRemoteAddr_FastPathEquivalence(t *testing.T) {
+	t.Parallel()
+
+	addrs := []string{
+		"1.2.3.4:6789",
+		"127.0.0.1:80",
+		"255.255.255.255:65535",
+		"[::1]:8080",
+		"[2001:db8::1]:443",
+		"[::ffff:1.2.3.4]:80",
+		"[fe80::1%eth0]:80",
+		"1.2.3.4:0",
+	}
+	for _, addr := range addrs {
+		got, err := resolveRemoteAddr(addr, nil)
+		require.NoError(t, err, "resolveRemoteAddr(%q)", addr)
+		want, err := net.ResolveTCPAddr("tcp", addr)
+		require.NoError(t, err, "ResolveTCPAddr(%q)", addr)
+		gotTCP, ok := got.(*net.TCPAddr)
+		require.True(t, ok, "resolveRemoteAddr(%q) type", addr)
+		require.True(t, want.IP.Equal(gotTCP.IP), "IP for %q: got %v want %v", addr, gotTCP.IP, want.IP)
+		require.Equal(t, want.Port, gotTCP.Port, "port for %q", addr)
+		require.Equal(t, want.Zone, gotTCP.Zone, "zone for %q", addr)
+		require.Equal(t, want.String(), gotTCP.String(), "String() for %q", addr)
+	}
+
+	// Rejected by the fast path, resolved by the fallback: identical results.
+	fallbackAddrs := []string{
+		"localhost:80",   // hostname
+		"1.2.3.4:0080",   // leading-zero port (fast path parses digits only, both accept)
+		"1.2.3.4",        // missing port -> :80 default via fallback
+		"01.2.3.4:80",    // leading-zero octet (rejected by ParseIPv4, accepted by resolver)
+		"1.2.3.4:99999",  // port out of range -> error from both? fallback errors
+		"1.2.3.4:",       // empty port -> fast path rejects, resolver yields port 0
+		"1.2.3.4:123456", // six digits -> fast path length guard, resolver errors
+		"1.2.3.4:8a",     // non-digit port -> fast path rejects, resolver service lookup fails
+	}
+	for _, addr := range fallbackAddrs {
+		got, gotErr := resolveRemoteAddr(addr, nil)
+		want, wantErr := net.ResolveTCPAddr("tcp", addr)
+		if addr == "1.2.3.4" {
+			// resolveRemoteAddr appends :80 for missing ports; ResolveTCPAddr errors.
+			require.NoError(t, gotErr)
+			require.Equal(t, "1.2.3.4:80", got.String())
+			continue
+		}
+		if wantErr != nil {
+			require.Error(t, gotErr, "addr %q", addr)
+			continue
+		}
+		require.NoError(t, gotErr, "addr %q", addr)
+		require.Equal(t, want.String(), got.String(), "String() for %q", addr)
+	}
+}
+
+// Test_FiberHandlerFunc_MultiValueHeaders verifies repeated header lines on
+// the net/http request all reach the fiber handler instead of collapsing to
+// the last value.
+func Test_FiberHandlerFunc_MultiValueHeaders(t *testing.T) {
+	t.Parallel()
+
+	var got []string
+	h := FiberHandlerFunc(func(c fiber.Ctx) error {
+		for _, v := range c.Request().Header.PeekAll("X-Multi") {
+			got = append(got, string(v))
+		}
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	r := httptest.NewRequest(http.MethodGet, "/", http.NoBody)
+	r.Header.Add("X-Multi", "one")
+	r.Header.Add("X-Multi", "two")
+	r.Header.Add("X-Multi", "three")
+	w := httptest.NewRecorder()
+	h.ServeHTTP(w, r)
+
+	require.Equal(t, []string{"one", "two", "three"}, got)
+}
+
+// Test_FiberHandlerFunc_EmptyHeaderValues verifies a header key mapped to an
+// empty value slice is skipped instead of panicking or producing an empty
+// header.
+func Test_FiberHandlerFunc_EmptyHeaderValues(t *testing.T) {
+	t.Parallel()
+
+	var seen bool
+	h := FiberHandlerFunc(func(c fiber.Ctx) error {
+		seen = len(c.Request().Header.PeekAll("X-Empty")) > 0
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	r := httptest.NewRequest(http.MethodGet, "/", http.NoBody)
+	r.Header["X-Empty"] = []string{}
+	w := httptest.NewRecorder()
+	h.ServeHTTP(w, r)
+
+	require.Equal(t, http.StatusOK, w.Code)
+	require.False(t, seen)
+}
+
+// Test_HTTPMiddleware_MultiValueHeaders verifies multi-value headers added
+// by a wrapped net/http middleware survive the copy-back onto the fiber
+// request.
+func Test_HTTPMiddleware_MultiValueHeaders(t *testing.T) {
+	t.Parallel()
+
+	mw := func(next http.Handler) http.Handler {
+		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+			r.Header.Add("X-Multi", "one")
+			r.Header.Add("X-Multi", "two")
+			r.Header["X-Empty"] = nil // empty value slices must be skipped
+			next.ServeHTTP(w, r)
+		})
+	}
+
+	app := fiber.New()
+	app.Use(HTTPMiddleware(mw))
+	var got []string
+	var emptyHeaderValues int
+	app.Get("/", func(c fiber.Ctx) error {
+		for _, v := range c.Request().Header.PeekAll("X-Multi") {
+			got = append(got, string(v))
+		}
+		emptyHeaderValues = len(c.Request().Header.PeekAll("X-Empty"))
+		return c.SendStatus(fiber.StatusOK)
+	})
+
+	resp, err := app.Test(httptest.NewRequest(http.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, fiber.StatusOK, resp.StatusCode)
+	require.Equal(t, []string{"one", "two"}, got)
+	require.Zero(t, emptyHeaderValues, "empty header value slices must not be copied")
+}
diff --git a/middleware/cache/cache_test.go b/middleware/cache/cache_test.go
index 23be245772f..1c5791bce71 100644
--- a/middleware/cache/cache_test.go
+++ b/middleware/cache/cache_test.go
@@ -2168,6 +2168,40 @@ func Test_CacheExpiresFutureAllowsCaching(t *testing.T) {
 	require.Equal(t, "expires1", string(body))
 }
 
+// Test_CacheExpiresObsoleteFormatAllowsCaching pins the RFC 9110 §5.6.7
+// acceptance set: a future Expires in the obsolete RFC 850 format is a valid
+// HTTP-date and must enable caching rather than hit the parse-error
+// (force-revalidate) path, consistently with how the Date header is parsed.
+func Test_CacheExpiresObsoleteFormatAllowsCaching(t *testing.T) {
+	t.Parallel()
+
+	app := fiber.New()
+	app.Use(New(Config{
+		StoreResponseHeaders: true,
+	}))
+
+	var count int
+	app.Get("/", func(c fiber.Ctx) error {
+		count++
+		c.Set(fiber.HeaderExpires, time.Now().Add(30*time.Second).UTC().Format("Monday, 02-Jan-06 15:04:05 GMT"))
+		return c.SendString("expires" + strconv.Itoa(count))
+	})
+
+	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheMiss, resp.Header.Get("X-Cache"))
+	body, err := io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "expires1", string(body))
+
+	resp, err = app.Test(httptest.NewRequest(fiber.MethodGet, "/", http.NoBody))
+	require.NoError(t, err)
+	require.Equal(t, cacheHit, resp.Header.Get("X-Cache"))
+	body, err = io.ReadAll(resp.Body)
+	require.NoError(t, err)
+	require.Equal(t, "expires1", string(body))
+}
+
 func Test_CacheExpiresPastPreventsCaching(t *testing.T) {
 	t.Parallel()
 
diff --git a/middleware/hostauthorization/hostauthorization_test.go b/middleware/hostauthorization/hostauthorization_test.go
index 39b1ac2312c..2e10b08d07a 100644
--- a/middleware/hostauthorization/hostauthorization_test.go
+++ b/middleware/hostauthorization/hostauthorization_test.go
@@ -188,6 +188,8 @@ func Test_IsValidHostSyntax(t *testing.T) {
 		{name: "ipv6 literal", host: "::1", valid: true},
 		{name: "ipv6 full", host: "2001:db8::1", valid: true},
 		{name: "malformed ipv6", host: "::g", valid: false},
+		{name: "ipv4 mapped ipv6", host: "::ffff:192.0.2.1", valid: true},
+		{name: "zoned ipv6 rejected", host: "fe80::1%eth0", valid: false},
 		{name: "digit label", host: "1.example.com", valid: true},
 		{name: "leading hyphen label", host: "-bad.example.com", valid: false},
 		{name: "trailing hyphen label", host: "bad-.example.com", valid: false},
diff --git a/middleware/paginate/paginate_test.go b/middleware/paginate/paginate_test.go
index 6813eddf4c7..fbf6dd9d57c 100644
--- a/middleware/paginate/paginate_test.go
+++ b/middleware/paginate/paginate_test.go
@@ -6,6 +6,7 @@ import (
 	"fmt"
 	"net/http"
 	"net/http/httptest"
+	"net/url"
 	"testing"
 
 	"github.com/gofiber/fiber/v3"
@@ -231,6 +232,22 @@ func Test_PageInfoNextPageURLWithExistingQueryParams(t *testing.T) {
 	require.Contains(t, result, "limit=10")
 }
 
+func Test_encodeQueryValues(t *testing.T) {
+	t.Parallel()
+
+	cases := []url.Values{
+		{},
+		{"a": {"1"}},
+		{"filter": {"active"}, "page": {"2"}, "limit": {"10"}},
+		{"q": {"a b+c&d=e", "second value"}, "sp ace": {"100%"}},
+		{"unicode": {"héllo wörld"}, "reserved": {";/?:@&=+$,#[]"}},
+		{"empty": {""}, "multi": {"", "x", ""}},
+	}
+	for _, q := range cases {
+		require.Equal(t, q.Encode(), encodeQueryValues(q))
+	}
+}
+
 func Test_PageInfoPreviousPageURLWithExistingQueryParams(t *testing.T) {
 	t.Parallel()
 
@@ -306,9 +323,9 @@ func Test_NextCursorURL(t *testing.T) {
 		p := &PageInfo{Limit: 20}
 		require.NoError(t, p.SetNextCursor(map[string]any{"id": float64(42)}))
 
-		url := p.NextCursorURL("https://example.com/users")
+		nextURL := p.NextCursorURL("https://example.com/users")
 		expected := fmt.Sprintf("https://example.com/users?cursor=%s&limit=20", p.NextCursor)
-		require.Equal(t, expected, url)
+		require.Equal(t, expected, nextURL)
 	})
 
 	t.Run("without HasMore", func(t *testing.T) {
diff --git a/middleware/proxy/fuzz_test.go b/middleware/proxy/fuzz_test.go
index 1513cf53417..13bc17e6c60 100644
--- a/middleware/proxy/fuzz_test.go
+++ b/middleware/proxy/fuzz_test.go
@@ -4,6 +4,10 @@ import (
 	"net/url"
 	"strings"
 	"testing"
+
+	"github.com/valyala/fasthttp"
+
+	"github.com/gofiber/fiber/v3"
 )
 
 // FuzzValidateUpstream stresses the upstream URL parser with adversarial
@@ -131,7 +135,16 @@ func FuzzConnectionListedHeaders(f *testing.F) {
 	for _, s := range seeds {
 		f.Add(s)
 	}
-	f.Fuzz(func(_ *testing.T, v string) {
-		_ = connectionListedHeaders([][]byte{[]byte(v)})
+	f.Fuzz(func(t *testing.T, v string) {
+		// Exercise the parser against a real header so deletions during
+		// iteration are covered too, mirroring production use.
+		var req fasthttp.Request
+		req.Header.Set(fiber.HeaderConnection, v)
+		req.Header.Set("X-Foo", "1")
+		req.Header.Set("X-Bar", "2")
+		delConnectionListedHeaders(&req.Header, req.Header.PeekAll(fiber.HeaderConnection))
+		if t.Failed() {
+			t.Logf("input: %q", v)
+		}
 	})
 }

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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path client/client_test.go --path client/cookiejar_test.go --path ctx_test.go --path middleware/adaptor/adaptor_test.go --path middleware/cache/cache_test.go --path middleware/hostauthorization/hostauthorization_test.go --path middleware/paginate/paginate_test.go --path middleware/proxy/fuzz_test.go --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./client ./ ./middleware/adaptor ./middleware/cache ./middleware/hostauthorization ./middleware/paginate ./middleware/proxy')"
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
  "$R2E_PY" -B -I -S "$SCRIPT_DIR/grader_tools.py" settle --root /workspace --path client/client_test.go --path client/cookiejar_test.go --path ctx_test.go --path middleware/adaptor/adaptor_test.go --path middleware/cache/cache_test.go --path middleware/hostauthorization/hostauthorization_test.go --path middleware/paginate/paginate_test.go --path middleware/proxy/fuzz_test.go --spec "$SCRIPT_DIR/mutants.json" --mutated --mtime "$R2E_MTIME" >/dev/null || r2e_finish ungraded mutant_setup_failed 'hidden test setup failed'
R2E_LAUNCH_OUT="$("$R2E_PY" -B -I -S "$SCRIPT_DIR/launcher.py" --log /logs/verifier/run/output.log --seconds-out /logs/verifier/run/seconds --cwd /workspace --path "$R2E_CHILD_PATH" --writable /workspace --readable "${GOMODCACHE:-${GOPATH:-$HOME/go}/pkg/mod}" --timeout 150 --purge -- 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./client ./ ./middleware/adaptor ./middleware/cache ./middleware/hostauthorization ./middleware/paginate ./middleware/proxy')"
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
  if [ "$R2E_A_TIMED_OUT" = 0 ] && [ "$("$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --claimed --log /logs/verifier/run/run_a.log --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./client ./ ./middleware/adaptor ./middleware/cache ./middleware/hostauthorization ./middleware/paginate ./middleware/proxy' --mutants "$SCRIPT_DIR/mutants.json")" != 0 ]; then r2e_run_b; else R2E_B_SKIPPED=1; fi
else
  r2e_run_b
  r2e_run_a
fi
TEST_EXIT_CODE="$R2E_A_EXIT"; R2E_TIMED_OUT="$R2E_A_TIMED_OUT"
mv -f /logs/verifier/run/run_a.log /logs/verifier/test_output.log 2>/dev/null
mv -f /logs/verifier/run/run_a.seconds /logs/verifier/run.seconds 2>/dev/null
tail -c 1048576 /logs/verifier/test_output.log 2>/dev/null
"$R2E_PY" -B -I -S "$SCRIPT_DIR/verifier.py" --log /logs/verifier/test_output.log --mutants "$SCRIPT_DIR/mutants.json" --mutant-log /logs/verifier/mutant_output.log --mutant-exit-code "$R2E_B_EXIT" --mutant-timed-out "$R2E_B_TIMED_OUT" --mutant-skipped "$R2E_B_SKIPPED" --mutant-seconds /logs/verifier/run_b.seconds --f2p "$SCRIPT_DIR/f2p.json" --p2p "$SCRIPT_DIR/p2p.json" --test-cmds 'export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -count=1 -v ./client ./ ./middleware/adaptor ./middleware/cache ./middleware/hostauthorization ./middleware/paginate ./middleware/proxy' --exit-code "$TEST_EXIT_CODE" --timed-out "$R2E_TIMED_OUT" --seconds /logs/verifier/run.seconds --out-dir /logs/verifier
R2E_VERIFIER_RC=$?
[ "$R2E_VERIFIER_RC" -eq 3 ] && r2e_finish ungraded verifier_error 'grader inputs in /tests are unreadable'
[ "$R2E_VERIFIER_RC" -eq 0 ] || r2e_finish graded log_unparseable 'the test output could not be graded'
r2e_open_logs
exit 0
