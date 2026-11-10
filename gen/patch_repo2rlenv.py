"""Local fixes to the pinned Repo2RLEnv. Idempotent; run after every `uv sync` in gen/.

1. The pytest configuration guard (`_pytest_config_guard.py`, embedded in validation stages and
   in every task's test.sh) raises "Configuration must be a regular file" when the base commit
   has a runner config file that is a symlink. networkx commits `benchmarks/pyproject.toml` as
   one, so the guard exited 1 before pytest on every PR and nothing was ever graded. A base
   symlink the tree still has, unchanged, is now left alone; any other state of that path is
   a graded change (AgentChange), so the agent can't use the exemption to swap in a config.
   Upstream: not filed (see ../notes in the pilot memory).
"""

import pathlib

import repo2rlenv.pipelines._pytest_config_guard as guard

PATCHES = [
    (
        guard.__file__,
        "            expected = original(relative)\n",
        "            item = base.get(relative)\n"
        "            if item is not None and item[0] == \"120000\":\n"
        "                # swe-rl-pilot: a base symlink kept as is is not a change.\n"
        "                if path.is_symlink() and os.fsencode(os.readlink(path)) == read(\n"
        "                    \"cat-file\", \"blob\", item[1]\n"
        "                ):\n"
        "                    continue\n"
        "                raise AgentChange(\"Symlinked runner configuration changed\")\n"
        "            expected = original(relative)\n",
    ),
]

for file, old, new in PATCHES:
    path = pathlib.Path(file)
    text = path.read_text()
    if new in text:
        print("already patched", path.name)
        continue
    assert text.count(old) == 1, f"{path}: expected text not found once; recheck the patch"
    path.write_text(text.replace(old, new))
    print("patched", path.name)
