# Issue

**Title:** 🐛 bug: fix RFC 9110/9112 compliance gaps in core, static and timeout

## Description

# Description

Fixes eight places where the core, the static middleware and the timeout middleware depart from RFC 9110/9112, and documents a ninth, the chunked reply to an HTTP/1.0 request, as an intentional deviation. They were found by auditing the core against the RFCs. Each change has tests and a docs entry. Nothing new is exported: `internal/byterange` is internal, and the generated `Ctx`, `Req` and `Res` interfaces differ from `main` only in doc comments.

Fixes # (issue): no linked issue; found by the audit above.

| | Before | Now | RFC |
|---|---|---|---|
| `GETOnly` 405 | no `Allow` | `Allow: GET, HEAD` | 9110 §15.5.6 |
| Unknown `Transfer-Encoding` | 400, body repeated the start of the request | 501 | 9112 §6.1 |
| `Content-Length` with `Transfer-Encoding` | connection stayed open | closed after the response | 9112 §6.1 |
| `AcceptsEncodings` | `identity` only if listed; an empty header read as absent | implicit `identity`, `identity;q=0` and `*;q=0` honoured; an empty header accepts only `identity` | 9110 §12.5.3 |
| `Status`, `SendStatus`, `NewError` | `0`, `-1` went out as `200 OK`, `99` and `1000` as a malformed status line | outside 100–999: logged, sent as 500 | 9112 §4 |
| `Cookie()` | a value with a space or comma written raw; a value already in quotes dropped | quoted as `net/http` does; quoted input accepted | 6265 §4.1.1 |
| timeout middleware | 408 | 503 | 9110 §15.5.9, §15.6.4 |
| `SendFile`, static with `ByteRange` | `If-Range` ignored; several ranges, an unknown unit or `Bytes=` got 416; `HEAD` and `POST` got 206 | `If-Range` honoured; several ranges, an unknown unit and non-GET get the whole file; the unit is case-insensitive | 9110 §13.1.5, §14.2 |
| `SendStream`, `SendStreamWriter` | chunked response to an HTTP/1.0 request | unchanged; documented as an intentional deviation | 9112 §6.1 |

## Decisions worth a look

- **Status range is 100–999.** RFC 9110 §15 defines only 100–599, but 600–999 is still a well-formed status line (9112 §4), and Express 5's `res.status` accepts the same range.
- **HTTP/1.0 streams keep their chunked reply.** RFC 9112 §6.1 does not allow chunked framing for a request older than HTTP/1.1, and an earlier version of this PR buffered the stream and sent a `Content-Length`. The Codex security review showed why that is worse: the writer ran inside the handler, so a client that left was never noticed, and a few abandoned HTTP/1.0 requests to an SSE route kept every slot of a `Concurrency: 4` server (the base frees them on the first failed write; a 256 KiB cap takes hours to fill with heartbeats). fasthttp cannot end a body by closing the connection (§6.3), and rejecting the request would break streams behind proxies that speak HTTP/1.0 to their upstream, nginx before 1.29.7 by default. So the chunked reply stays; `docs/api/ctx.md` calls it an intentional deviation and says to pass the size when it is known (a stream of known size gets a `Content-Length` whatever the version); and a test pins that a departed HTTP/1.0 client frees the writer. 505 is not an option: it is defined for a *major* version the server refuses (9110 §15.6.6), and HTTP/1.0 and 1.1 are both major version 1.
- **Several ranges are ignored, not answered with `multipart/byteranges`.** RFC 9110 §14.2 allows ignoring `Range`, and the whole file is a correct and cheaper answer. A date in `If-Range` must equal `Last-Modified` and be two seconds old, because the header has whole-second resolution. A file rewritten twice within one second can still match the older copy's date; the docs say so and suggest a strong `ETag` for files replaced in place.
- **Cookie quoting mirrors `net/http`.** RFC 6265 §4.1.1 allows neither space nor comma, even inside quotes; the docs say to percent-encode a value that has to cross a strict parser.
- **501 is chosen from fasthttp's error text**, because its sentinel also covers faults that stay 400 (an HTTP/1.0 message with the field, a repeated field). With `Server.SecureErrorLogMessa

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `014cfa68cbbf` and running the modified tests.