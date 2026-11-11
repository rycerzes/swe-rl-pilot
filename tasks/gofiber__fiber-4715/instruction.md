# Issue

**Title:** 📝 [Proposal]: raise the default ReadBufferSize and WriteBufferSize to 16 KB

## Description

### Feature Proposal Description

Fiber pins fasthttp's per-connection buffers at 4096 bytes (`DefaultReadBufferSize` / `DefaultWriteBufferSize`, applied unconditionally in `init`), a value fasthttp inherited from its first commit in 2015, when it was sized for 100K-connection memory budgets. Two effects of 4 KB are worth revisiting:

- The read buffer is also the request header limit. 4 KB is the strictest default in the field: nginx and Apache default to 8 KB, Node.js (and so Express) to 16 KB, net/http to 1 MB. Cookie-heavy requests fail with `431` / "too big request header" until users discover the setting ( and similar questions).
- On the write side, 4 KB holds only a few small responses, so a pipelined batch (TechEmpower's plaintext test pipelines 16 deep) goes out in several write syscalls; with 16 KB the whole batch fits in one. On a fasthttp branch I measured with wrk pipelining, 16 KB buffers gave +11–18% requests/s on Linux and macOS. Large single responses no longer depend on the buffer size on fasthttp master (valyala/ sends header and body with writev), so the gain is specific to pipelining and to responses between 4 and 16 KB.

The cost is memory: 32 KB per open connection instead of 8 KB, which matters at very high connection counts. `ReduceMemoryUsage` already targets that profile, and an explicit `ReadBufferSize: 4096, WriteBufferSize: 4096` restores the previous footprint exactly.

I proposed the same default change to fasthttp and withdrew it there, since a library changing an observable default is a different matter from a framework that already sets both values explicitly. The decision belongs here.

One note on gofiber/benchmarks: its harness parses requests in memory and never writes to a socket, so this change is invisible there; it shows up with a socket load generator.

### Alignment with Express API

Express runs on Node's HTTP server, whose default maximum header size is 16 KB. A 16 KB read buffer gives Fiber the same header limit out of the box.

### HTTP RFC Standards Compliance

RFC 9110 sets no header size limit and defines `431 Request Header Fields Too Large` for servers that enforce one. Raising the default only changes where Fiber draws that line, to a value in line with common practice.

### API Stability

Only the two default values change. Applications that set `ReadBufferSize` / `WriteBufferSize` explicitly are unaffected. Worth a line in the v3 changelog for users who size memory by connection count.

### Feature Examples

```go
app := fiber.New() // 16 KB read and write buffers by default

app := fiber.New(fiber.Config{ // previous footprint
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
})
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `ae1ef46ff2cc` and running the modified tests.