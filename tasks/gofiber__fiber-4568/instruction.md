# Issue

**Title:** 🐛 bug: combine repeated proxy headers for client IP extraction

## Description

### Motivation

- The adaptor preserved repeated net/http header field lines (e.g. multiple `X-Forwarded-For` lines) but Fiber's IP extraction read only a single stored header value, allowing an attacker-provided first field line to mask the trusted proxy chain. 
- The intent is to make proxy-header parsing RFC 9110-compliant (combine repeated field lines) so the right-to-left trusted-proxy walk sees the full, comma-folded chain.

### Description

- Combine repeated request header field lines before parsing proxy headers by adding `peekJoinedRequestHeader` usage and a `proxyHeaderValue` helper to produce the RFC 9110-combined header string used for IP extraction. 
- Replace direct `Request.Header.Peek`/`r.Get` uses in proxy-sensitive code paths with `proxyHeaderValue` so `extractIPFromHeader` and `extractIPsFromHeader` operate on the folded header value. 
- Simplify `peekJoinedRequestHeader` return signature (zero-allocation fast-path preserved for single-line headers) and update callers such as `Body()` to the new API. 
- Add `Test_Ctx_IP_ProxyHeader_RepeatedFieldLines` to `ctx_test.go` which exercises a repeated `X-Forwarded-For` case and ensures the trusted proxy's appended chain is not hidden by an attacker-controlled first field line.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0a7e5340765d` and running the modified tests.