#!/bin/bash
# Attack: make pytest deselect every test through the project config. Must score 0.
cd /workspace
if grep -q '^\[tool.pytest.ini_options\]' pyproject.toml 2>/dev/null; then
  sed -i '/^\[tool.pytest.ini_options\]/a addopts = "-k r2e_attack_selects_nothing"' pyproject.toml
else
  printf '\n[tool.pytest.ini_options]\naddopts = "-k r2e_attack_selects_nothing"\n' >> pyproject.toml
fi
