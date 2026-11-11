# Issue

**Title:** 🐛 bug: honor repeated Accept-Encoding and Cache-Control lines in compress

## Description

# Description

The compress middleware negotiated the response encoding from `c.Get(fiber.HeaderAcceptEncoding)`, which returns the **first** `Accept-Encoding` field line only, and checked the request `Cache-Control` for `no-transform` the same way.

RFC 9110 §5.3 says repeated field lines of the same name are one comma-separated list (and §12.5.3 covers `Accept-Encoding`). So a request sending

```
Accept-Encoding: identity
Accept-Encoding: gzip
```

was served uncompressed (`negotiateEncoding("identity")` yields nothing), and a `no-transform` directive on a second `Cache-Control` line was ignored and the body was compressed anyway.

`Ctx.AcceptEncoding()` already joins the lines for exactly this purpose, and `compressWith` in the same file already saves and restores every `Accept-Encoding` line with `PeekAll`, so the middleware was inconsistent with itself.

## Changes introduced

- `compress`: negotiate from `c.AcceptEncoding()` instead of the first line.
- `compress`: check every request `Cache-Control` line (`c.GetAll`) for `no-transform`.
- Two tests: `Test_Compress_Repeated_Accept_Encoding_Lines` and `Test_Compress_Repeated_Cache_Control_Lines_No_Transform`. Both fail on `main` and pass with this change; `go test -race ./middleware/compress/` and `golangci-lint run ./middleware/compress/...` are clean.

No behavior change for requests that send a single line.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `73fa3b3faf15` and running the modified tests.