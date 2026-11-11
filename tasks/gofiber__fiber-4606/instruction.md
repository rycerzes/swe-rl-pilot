# Issue

**Title:** 🐛 bug: preserve Connection tokens through adaptor middleware

## Description

### Motivation

- A `net/http` middleware that rewrites the request's `Connection` field had its edit hidden from everything downstream. fasthttp holds either the close flag or an arbitrary value, never both, so setting the flag made `Peek` answer `"close"` and dropped the remaining tokens — the ones naming which fields are hop-by-hop, which a proxy downstream is meant to strip.

### Description

- Record whether the joined `Connection` value lists `close`, leave the request field itself intact, and carry the close instruction on the response instead — `c.Response().Header.SetConnectionClose()`.
- The response is where it has to go to have any effect at all: fasthttp stores `ctx.Request.Header.ConnectionClose()` *before* invoking the handler and never reads it again (`server.go`, "store req.ConnectionClose so even if it was changed inside of handler"). Only the response flag is consulted once the handler returns, so writing the request flag back from a handler cost every observer the complete field and closed nothing.
- Applied after `c.Next()` rather than before, because one flag stands for the whole response and the downstream chain can clear it: a handler calling `c.Response().Reset()`, or setting a `Connection` value of its own, otherwise left the connection reused despite the rewrite that asked for it to close.
- The request field now survives the whole chain — downstream handlers, middleware resuming after `Next`, and the app's `ErrorHandler`, which writes the response without touching this field.

Files changed: `middleware/adaptor/adaptor.go`, `middleware/adaptor/adaptor_test.go`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `a105acad6c1e` and running the modified tests.