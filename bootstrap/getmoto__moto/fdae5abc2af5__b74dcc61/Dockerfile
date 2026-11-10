# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM python:3.12-slim
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && echo "---" && cat setup.py 2>/dev/null | head -50 && echo "---PYPROJECT---" && cat pyproject.toml 2>/dev/null | head -80
RUN cd /workspace && cat setup.cfg | head -80 && echo "---REQ---" && cat requirements.txt requirements-tests.txt requirements-dev.txt
RUN cd /workspace && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git build-essential curl ca-certificates > /dev/null 2>&1; echo "apt done"; python --version; pip --version
RUN cd /workspace && pip install -e ".[all,server]" -q 2>&1 | tail -20; echo "EXIT=$?"
RUN cd /workspace && pip install -q pytest pytest-cov pytest-order pytest-xdist freezegun pyotp coverage pycognito 2>&1 | tail -5; echo "EXIT=$?"
RUN cd /workspace && python -c "import moto; print(moto.__version__)" && python -m pytest --collect-only -q 2>&1 | tail -15
RUN cd /workspace && python -m pytest --collect-only -q other_langs/tests_sagemaker_client/test_model_training.py 2>&1 | tail -15
RUN cd /workspace && python -m pytest --collect-only -q tests/ 2>&1 | tail -5
