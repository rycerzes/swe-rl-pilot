# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM python:3.12-slim
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && echo "---" && cat pyproject.toml | head -80
RUN cd /workspace && sed -n '80,260p' pyproject.toml
RUN cd /workspace && sed -n '60,90p' pyproject.toml && echo "=== core ===" && ls pydantic-core && echo "=== core pyproject ===" && head -40 pydantic-core/pyproject.toml 2>/dev/null && echo "=== rust? ===" && which cargo rustc 2>/dev/null; echo "=== installed pydantic-core ===" && python -c "import pydantic_core; print(pydantic_core.__version__, pydantic_core.__file__)" 2>&1 | head
RUN cd /workspace && cat pydantic/version.py | head -20 && echo "=== pip index ===" && pip index versions pydantic-core 2>&1 | head -5
RUN cd /workspace && pip install "pydantic-core==2.50.0" 2>&1 | tail -5
RUN cd /workspace && pip install -e . 2>&1 | tail -5
RUN cd /workspace && pip install pytest pytest-mock pytest-pretty pytest-examples faker pytest-benchmark pytest-run-parallel dirty-equals jsonschema packaging pytz time-machine 2>&1 | tail -5
RUN cd /workspace && python -m pytest --collect-only -q 2>&1 | tail -20
RUN cd /workspace && pip install hypothesis 2>&1 | tail -2 && python -c "import pydantic_core; print([x for x in dir(pydantic_core) if 'Model' in x])"
RUN cd /workspace && grep -n "ModelFieldsSet" pydantic-core/python/pydantic_core/__init__.py | head; echo "---"; grep -rn "version" pydantic-core/Cargo.toml | head -5; echo "--- rust ---"; ls ~/.cargo/bin 2>/dev/null; which rustup cargo 2>/dev/null; echo "done"
RUN cd /workspace && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal 2>&1 | tail -5
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates build-essential git 2>&1 | tail -3
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal 2>&1 | tail -5
RUN cd /workspace && . "$HOME/.cargo/env" && pip install maturin 2>&1 | tail -2 && cd pydantic-core && maturin develop --release 2>&1 | tail -15
RUN cd /workspace/pydantic-core && . "$HOME/.cargo/env" && maturin build --release --out /tmp/wheels 2>&1 | tail -8
RUN cd /workspace && pip install --force-reinstall /tmp/wheels/pydantic_core-2.50.0-cp312-cp312-manylinux_2_34_x86_64.whl 2>&1 | tail -3 && python -c "from pydantic_core import ModelFieldsSet; print('ok')"
RUN cd /workspace && python -m pytest --collect-only -q 2>&1 | tail -15
RUN cd /workspace && pip install inline_snapshot 2>&1 | tail -2 && python -m pytest --collect-only -q 2>&1 | tail -8
RUN cd /workspace && python -m pytest tests/test_main.py -x -q 2>&1 | tail -8
