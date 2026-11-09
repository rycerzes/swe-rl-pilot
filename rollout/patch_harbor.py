"""Local fixes to Harbor 0.25.0 for HF Sandbox rollouts. Idempotent; run after every `uv sync`.

1. HF sandboxes refuse the ownership changes in Harbor's upload untar, so every verifier upload
   fails and all rewards are None. Same one-line fix as TRL's examples/async_grpo_harbor README.
2. mini-swe-agent is installed with an unpinned litellm, and current litellm imports `mcp` at
   startup, so the agent dies before its first model call. Harbor main already installs
   `litellm[mcp]`; this applies the same change until a release has it.
"""

import pathlib

import harbor.agents.installed.mini_swe_agent as msa
import harbor.environments.tar_transfer as t

PATCHES = [
    (t.__file__, "tar -xzf ", "tar --no-same-owner -xzf "),
    (msa.__file__, '"--with litellm --with orjson', "\"--with 'litellm[mcp]' --with orjson"),
]

for file, old, new in PATCHES:
    path = pathlib.Path(file)
    text = path.read_text()
    if new in text:
        print("already patched", path.name)
        continue
    assert old in text, f"{path}: expected text not found; recheck the patch"
    path.write_text(text.replace(old, new))
    print("patched", path.name)
