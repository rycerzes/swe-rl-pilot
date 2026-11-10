# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM python:3.12-slim
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && cat pyproject.toml 2>/dev/null | head -80
RUN cd /workspace && ls requirements && echo "---setup.cfg---" && cat setup.cfg && echo "---tox---" && cat tox.ini && echo "---reqs---" && for f in requirements/*; do echo "== $f =="; cat "$f"; done
RUN cd /workspace && pip install -e . && pip install pytest pytest-xdist coverage ruff && python -c 'import more_itertools; print(more_itertools.__version__)'
RUN cd /workspace && python -m pytest --collect-only -q 2>&1 | tail -20
