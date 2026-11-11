"""Harbor HF Sandbox: run the agent as its task user, and only its run phase in an egress jail.

Loaded in every process of the rollout venv by a .pth hook (rollout/patch_harbor.py installs it).

1. User switching (Harbor H1). `HFSandboxEnvironment.exec` ignores `user` and runs everything as
   root, so a task's `[agent].user` has no effect. Root in an HF Sandbox can still switch users
   (its user namespace maps uids 0-65535), so a non-root `exec` here runs through `setpriv` with
   HOME set. On first use the user is created if the image lacks it (prebuilt images), and gets
   the task workdir, its home, /installed-agent and /logs/agent. Harbor's installed agents already
   install as the agent user and run setup as root; only this environment dropped the user.

2. Egress jail, opt-in with PILOT_EGRESS_ALLOW="host1,.domain2" in the Harbor process's
   environment. While an installed agent's `run` executes (not its install), every non-root
   command runs under landlock_exec.py: TCP only to a root-owned allowlist proxy
   (allowlist_proxy.py) on 127.0.0.1:47121, with HTTPS_PROXY/HTTP_PROXY pointing at it. A command
   that ignores the proxy can't connect at all; one that uses it reaches allowed hosts only. The
   proxy logs every request to /logs/agent/pilot-egress.log. HF Sandbox has no CAP_NET_ADMIN and
   no network policy yet (huggingface_hub #5303, sandbox-server #32), so this is enforced from
   inside the sandbox. Gaps: UDP (DNS) isn't filtered; Landlock matches ports, not addresses.
"""

from __future__ import annotations

import os
import shlex
from pathlib import Path

PORT = 47121
REMOTE_DIR = "/opt/pilot-egress"
HERE = Path(__file__).with_name("pilot_egress_files")
PYTHONS = ("/usr/local/bin/python3", "/usr/bin/python3", "/opt/harbor-grader/python3",
           "/opt/conda/bin/python3")


def _q(value: object) -> str:
    return shlex.quote(str(value))


def install() -> None:
    try:
        from harbor.agents.installed.base import BaseInstalledAgent
        from harbor.environments import hf_sandbox
    except Exception:  # noqa: BLE001 - never break interpreter startup
        return
    env_cls = hf_sandbox.HFSandboxEnvironment
    if getattr(env_cls, "_pilot_patched", False):
        return
    original_exec = env_cls.exec

    async def as_root(self, command: str, timeout_sec: int | None = 300):
        return await original_exec(self, command, timeout_sec=timeout_sec, user="root")

    async def ensure_user(self, name: str) -> None:
        done = self.__dict__.setdefault("_pilot_users", set())
        if name in done:
            return
        # The task's workdir, or the image's WORKDIR (where an exec without cwd starts): our
        # Repo2RLEnv tasks set none in task.toml, and a root-owned /workspace left the agent
        # unable to create or edit any file.
        workdir = self.task_env_config.workdir or ""
        wd = _q(workdir) if workdir else '"$(pwd)"'
        script = (
            f"id -u {_q(name)} >/dev/null 2>&1 || useradd -m {_q(name)} 2>/dev/null "
            f"|| adduser -D {_q(name)}; "
            f"H=$(getent passwd {_q(name)} | cut -d: -f6); mkdir -p \"$H\" && chown {_q(name)} \"$H\"; "
            f"mkdir -p /installed-agent /logs/agent; chown -R {_q(name)} /installed-agent /logs/agent; "
            f"WD={wd}; [ -n \"$WD\" ] && [ \"$WD\" != / ] && chown -R {_q(name)} \"$WD\"; "
            # Per-user dirs the image's ENV points somewhere root-owned (SWE-rebench images set
            # XDG_*_HOME, PIP_CACHE_DIR and PYTHONPYCACHEPREFIX under /workspace): the agent's
            # installer (uv), pip and Python's bytecode cache must be able to write there.
            "for v in XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME PIP_CACHE_DIR "
            "PYTHONPYCACHEPREFIX UV_CACHE_DIR npm_config_cache CARGO_HOME GOCACHE; do "
            "  d=$(printenv \"$v\"); "
            f"  [ -n \"$d\" ] && [ \"$d\" != / ] && mkdir -p \"$d\" && chown -R {_q(name)} \"$d\"; "
            "done; "
            # Go: the image's module cache must stay the one used (a fresh one under the agent's
            # home would need the network) and be writable (go takes lock files in it even for
            # cached modules), else every build tries proxy.golang.org.
            "if command -v go >/dev/null 2>&1 || [ -x /usr/local/go/bin/go ]; then "
            "  GO=$(command -v go || echo /usr/local/go/bin/go); "
            "  M=$($GO env GOMODCACHE 2>/dev/null); "
            f"  [ -n \"$M\" ] && [ -d \"$M\" ] && chown -R {_q(name)} \"$M\" && echo \"PILOT_GOMODCACHE=$M\"; "
            "fi; "
            "command -v setpriv >/dev/null"
        )
        result = await as_root(self, script, timeout_sec=1800)
        if getattr(result, "return_code", 0) not in (0, None):
            raise RuntimeError(f"pilot: could not prepare user {name!r} (setpriv missing?): "
                               f"{getattr(result, 'stdout', '')}{getattr(result, 'stderr', '')}")
        for line in (getattr(result, "stdout", "") or "").splitlines():
            if line.startswith("PILOT_GOMODCACHE="):
                self.__dict__.setdefault("_pilot_env", {})["GOMODCACHE"] = line.split("=", 1)[1]
        done.add(name)

    async def ensure_proxy(self) -> str:
        python = self.__dict__.get("_pilot_python")
        if python:
            return python
        sandbox = self._require_sandbox()
        for name in ("allowlist_proxy.py", "landlock_exec.py"):
            sandbox.files.write(f"{REMOTE_DIR}/{name}", (HERE / name).read_bytes())
        found = await as_root(self, "for p in " + " ".join(PYTHONS)
                              + " \"$(command -v python3)\"; do [ -x \"$p\" ] && "
                              "\"$p\" -c 'import sys; sys.exit(sys.version_info < (3, 8))' "
                              "2>/dev/null && { echo \"$p\"; break; }; done")
        python = (getattr(found, "stdout", "") or "").strip().splitlines()[-1:] or [""]
        python = python[0]
        if not python:
            raise RuntimeError("pilot: no Python >= 3.8 in the image for the egress jail")
        allow = " ".join(f"--allow {_q(a.strip())}"
                         for a in os.environ["PILOT_EGRESS_ALLOW"].split(",") if a.strip())
        await as_root(
            self,
            # landlock_exec.py runs as the agent user; the proxy only as root.
            f"chmod 755 {REMOTE_DIR} && chmod 644 {REMOTE_DIR}/landlock_exec.py && "
            f"chmod 600 {REMOTE_DIR}/allowlist_proxy.py && "
            f"(nohup {python} {REMOTE_DIR}/allowlist_proxy.py --port {PORT} {allow} "
            f"--log /logs/agent/pilot-egress.log > /tmp/pilot-egress.out 2>&1 &) && sleep 1 && "
            f"{python} -c 'import socket; socket.create_connection((\"127.0.0.1\", {PORT}), 5)'",
        )
        self.__dict__["_pilot_python"] = python
        return python

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        who = self._resolve_user(user)
        if who is None or str(who) in ("root", "0"):
            return await original_exec(self, command, cwd=cwd, env=env,
                                       timeout_sec=timeout_sec, user=user)
        name = str(who)
        await ensure_user(self, name)
        env = {**self.__dict__.get("_pilot_env", {}), **dict(env or {})}
        inner = command
        if self.__dict__.get("_pilot_jail") and os.environ.get("PILOT_EGRESS_ALLOW"):
            python = await ensure_proxy(self)
            proxy = f"http://127.0.0.1:{PORT}"
            env.update(HTTPS_PROXY=proxy, HTTP_PROXY=proxy, https_proxy=proxy, http_proxy=proxy,
                       NO_PROXY="", no_proxy="",
                       # litellm fetches its price map from raw.githubusercontent.com at import;
                       # denied, it scored the rollout 0 before the agent's first call.
                       LITELLM_LOCAL_MODEL_COST_MAP="True")
            inner = (f"{_q(python)} {REMOTE_DIR}/landlock_exec.py --tcp-port {PORT} -- "
                     f"/bin/bash -c {_q(command)}")
        wrapped = (
            f"H=$(getent passwd {_q(name)} | cut -d: -f6); "
            f"exec setpriv --reuid={_q(name)} --regid={_q(name)} --init-groups "
            # XDG_BIN_HOME: uv's installer puts binaries in $XDG_DATA_HOME/../bin when that's
            # set (SWE-rebench images point it under root-owned /workspace), not in
            # $HOME/.local/bin where Harbor's installed agents look for them.
            f"env HOME=\"$H\" USER={_q(name)} LOGNAME={_q(name)} XDG_BIN_HOME=\"$H/.local/bin\" "
            f"/bin/bash -c {_q(inner)}"
        )
        return await original_exec(self, wrapped, cwd=cwd, env=env, timeout_sec=timeout_sec,
                                   user="root")

    env_cls.exec = exec
    env_cls._pilot_patched = True

    def jail_run(run):
        async def run_in_jail(self, instruction, environment, *args, **kwargs):
            environment.__dict__["_pilot_jail"] = True
            try:
                return await run(self, instruction, environment, *args, **kwargs)
            finally:
                environment.__dict__["_pilot_jail"] = False

        run_in_jail._pilot_jail = True
        return run_in_jail

    def wrap(cls) -> None:
        run = cls.__dict__.get("run")
        if run is not None and not getattr(run, "_pilot_jail", False):
            cls.run = jail_run(run)

    original_init_subclass = BaseInstalledAgent.__dict__.get("__init_subclass__")

    @classmethod
    def init_subclass(cls, **kwargs):
        if original_init_subclass is not None:
            original_init_subclass.__func__(cls, **kwargs)
        else:
            super(BaseInstalledAgent, cls).__init_subclass__(**kwargs)
        wrap(cls)

    BaseInstalledAgent.__init_subclass__ = init_subclass
    stack = list(BaseInstalledAgent.__subclasses__())
    while stack:  # agent classes imported before this hook ran
        cls = stack.pop()
        wrap(cls)
        stack.extend(cls.__subclasses__())


install()
