# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM python:3.12-slim
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && echo "---" && cat pyproject.toml 2>/dev/null | head -80
RUN cd /workspace && sed -n '80,200p' pyproject.toml && echo "=== requirements ===" && ls requirements && echo "---" && cat requirements/*.txt 2>/dev/null | head -60
RUN cd /workspace && pip install -e . 2>&1 | tail -5 && pip install pytest pytest-xdist pytest-cov numpy scipy matplotlib pandas 2>&1 | tail -3
RUN cd /workspace && python -m pytest --collect-only -q 2>&1 | tail -15
