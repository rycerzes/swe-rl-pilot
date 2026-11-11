# Issue

**Title:** 🐛 [Bug]: X-Forwarded-For IP validation rejects tab OWS

## Description

### Bug description

With `EnableIPValidation` enabled, Fiber rejects otherwise valid `X-Forwarded-For` elements if HTTP optional whitespace contains a tab. RFC 9110 allows both SP and HTAB as OWS around list members. `DefaultReq.extractIPsFromHeader` and both traversal paths in `extractIPFromHeader` trim spaces but leave tabs, so IP validation fails.

### Reproduction

On `main` at `0923873f`, with a trusted remote proxy at `10.0.0.1` and:

```http
X-Forwarded-For: \t203.0.113.50\t,\t10.0.0.1\t
```

`c.IPs()` returns an empty slice and `c.IP()` falls back to `10.0.0.1`. The equivalent header with spaces instead of tabs returns the expected chain and client IP.

### Expected behavior

`c.IPs()` returns `[]string{"203.0.113.50", "10.0.0.1"}` and `c.IP()` returns `203.0.113.50`. Only surrounding SP/HTAB should be ignored; tabs inside an address must remain invalid.

### Environment

- Fiber: `main` at `0923873f`
- Go: 1.26.0
- OS: macOS (darwin/amd64)

A focused regression test reproduces this on the current `main` branch. This also relates to the duplicate forwarded-header trimming tracked in #4604.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0923873f4a1b` and running the modified tests.