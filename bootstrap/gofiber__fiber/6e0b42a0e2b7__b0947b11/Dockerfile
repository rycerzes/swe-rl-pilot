# Auto-generated from r2e-bootstrap agent transcript.
# Build from the cloned repo root: `docker build -t my-image .`
FROM golang:1.27
WORKDIR /workspace
COPY . /workspace

RUN cd /workspace && ls -la && echo "---GO VERSION---" && go version && echo "---GO.MOD---" && head -20 go.mod
RUN ls /usr/local/go/bin 2>/dev/null; ls /usr/local/ 2>/dev/null; which go; ls /go 2>/dev/null; find / -name 'go' -type f -path '*bin*' 2>/dev/null | head
RUN export PATH=$PATH:/usr/local/go/bin && go version && cd /workspace && head -20 go.mod
RUN export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go mod download 2>&1 | tail -5 && echo "---BUILD---" && go build ./... 2>&1 | tail -20 && echo "BUILD_DONE"
RUN export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -list '.*' ./... 2>&1 | head -20 && echo "---VET---" && go vet ./... 2>&1 | tail -5
RUN export PATH=$PATH:/usr/local/go/bin && export GOFLAGS=-mod=mod && cd /workspace && go test -run TestNewTestCtx_ReturnsDefaultCtx ./... 2>&1 | tail -20
