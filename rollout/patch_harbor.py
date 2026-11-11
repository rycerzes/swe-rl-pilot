"""Local fixes to Harbor 0.25.0 for HF Sandbox rollouts. Idempotent; run after every `uv sync`.

1. HF sandboxes refuse the ownership changes in Harbor's upload untar, so every verifier upload
   fails and all rewards are None. Same one-line fix as TRL's examples/async_grpo_harbor README.
2. mini-swe-agent is installed with an unpinned litellm, and current litellm imports `mcp` at
   startup, so the agent dies before its first model call. Harbor main already installs
   `litellm[mcp]`; this applies the same change until a release has it.
"""

import pathlib
import site

import harbor.agents.installed.mini_swe_agent as msa
import harbor.environments.tar_transfer as t

PATCHES = [
    (t.__file__, "tar -xzf ", "tar --no-same-owner -xzf "),
    (msa.__file__, '"--with litellm --with orjson', "\"--with 'litellm[mcp]' --with orjson"),
]

# 3. huggingface_hub#5306 (merged, unreleased in 2.4.0): a digest-pinned image makes the derived
#    sandbox job name exceed the Hub's 100-character label limit, so no sandbox starts. A .pth
#    hook loads the same truncation TRL's sft_agent_traces example uses, in every process.
HUB_NAME_FIX = """try:
    import huggingface_hub.hf_api as _hf_api
    _orig = _hf_api._default_job_name_from_image
    def _short_name(image, command, **kwargs):
        name = _orig(image, command, **kwargs)
        return name if len(name) <= 100 else name[:91] + name[-9:]
    _hf_api._default_job_name_from_image = _short_name
except Exception:
    pass
"""
site_dir = pathlib.Path(site.getsitepackages()[0])
(site_dir / "_pilot_hub_jobname_fix.py").write_text(HUB_NAME_FIX)
(site_dir / "_pilot_hub_jobname_fix.pth").write_text("import _pilot_hub_jobname_fix\n")
print("installed hub job-name fix in", site_dir.name)

# 4. egress/pilot_harbor_egress.py: HF Sandbox honors [agent].user (setpriv), and with
#    PILOT_EGRESS_ALLOW set, the agent's run phase gets the Landlock + allowlist-proxy jail.
import shutil

egress = pathlib.Path(__file__).with_name("egress")
shutil.copyfile(egress / "pilot_harbor_egress.py", site_dir / "pilot_harbor_egress.py")
files = site_dir / "pilot_egress_files"
files.mkdir(exist_ok=True)
for name in ("allowlist_proxy.py", "landlock_exec.py"):
    shutil.copyfile(egress / name, files / name)
(site_dir / "_pilot_harbor_egress.pth").write_text("import pilot_harbor_egress\n")
print("installed HF Sandbox user switching + egress jail in", site_dir.name)

for file, old, new in PATCHES:
    path = pathlib.Path(file)
    text = path.read_text()
    if new in text:
        print("already patched", path.name)
        continue
    assert old in text, f"{path}: expected text not found; recheck the patch"
    path.write_text(text.replace(old, new))
    print("patched", path.name)
