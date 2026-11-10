# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM golang:1.27
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && echo "---" && cat go.mod | head -20 && echo "---" && go version
RUN ls /usr/local/go/bin 2>/dev/null; which go; ls /usr/local/ 2>/dev/null; echo "PATH=$PATH"
RUN export PATH=$PATH:/usr/local/go/bin && go version && cd /workspace && export GOFLAGS=-mod=mod && go mod download 2>&1 | tail -5; echo "download exit=$?"
RUN export PATH=$PATH:/usr/local/go/bin && cd /workspace && export GOFLAGS=-mod=mod && go build ./... 2>&1 | tail -20; echo "build exit=${PIPESTATUS[0]}"
RUN cd /workspace && git config --global --add safe.directory /workspace && git status 2>&1 | head -3; echo "---"; export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go build ./... 2>&1 | tail -5; echo "build exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go test -list '.*' ./common/... 2>&1 | head -20; echo "exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go test ./common/collections/... 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go test -list '.*' ./hugolib/... 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go test ./common/... 2>&1 | tail -8; echo "exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && go test -list '.*' ./... 2>&1 | grep -iE "cannot|error|no required module|build failed" | head -20; echo "done"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && timeout 120 go test -list '.*' ./tpl/... 2>&1 | grep -iE "cannot|error|build failed" | head; echo "tpl done exit=$?"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && timeout 200 go test -list '.*' . ./hugolib 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
RUN cd /workspace && export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && timeout 200 go test ./common/collections/... ./common/text/... 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
