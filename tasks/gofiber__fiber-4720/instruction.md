# Issue

**Title:** 🐛 bug: make static, proxy, adaptor and rewrite act on the path the router matched

## Description

# Description

Middleware half of the path-guard work split out of #4713. The core half (router normalization and `SendFile`) is #4719. The two are independent and either can merge first: the full suite passes on current `main` with this PR, with #4719, and with both.

`app.Use("/admin", auth)` only protects a resource while the router and the code that finally acts on the path agree on its name. This PR fixes the middleware that read the path again on its own terms: the static file server, the proxy handlers, the net/http adaptor and `rewrite`. Each now fails closed or hands on exactly the path the router matched. Every case has an end-to-end test that fails without its fix.

## Before / after

| Component | Before | After |
|---|---|---|
| **Static**<br>`middleware/static` | The routed path was percent-decoded a second time. `/static/%%370rivate/secret.txt` reaches the router as `/static/%70rivate/secret.txt`, misses a guard on `/static/private`, and the file server decoded `%70` and opened `private/secret.txt`. On Windows `private./secret.txt` opened `private/secret.txt`. | The routed path is validated, not decoded again. An escape of an unreserved character, which only a forged stray `%` can leave, is `404`. Escapes the router keeps stay encoded (`UnescapePath` gives decoded names). Windows rejects a segment ending in `.` or a space. |
| **Proxy**<br>`middleware/proxy` | The raw request line was forwarded and re-normalized on the way out, so `/public/..%2Fadmin/secret` reached the upstream as `/admin/secret` without the `/admin` middleware having run. A `Host` with userinfo, or a routed target fasthttp reads as an authority, replaced the upstream `Host` and injected `Authorization: Basic`. `Servers: ["http://backend/api"]` silently reached the whole upstream. | `Balancer`, `DomainForward` and `BalancerForward` forward the routed path, rooted, with bytes a path may not carry raw escaped and the query as the client sent it. A path an upstream could read as another path gets `400`: `%2F` or `//` (opt-out: `SecurityPolicy.AllowAmbiguousSlashes`), a backslash (WHATWG parsers, IIS), a dot segment with parameters such as `..;` (Tomcat, Jetty), or a forged escape. The authority cases are `400` too. A `Servers` entry must be `scheme://host`. Host clients the proxy dispatches through stop normalizing paths. |
| **Adaptor**<br>`middleware/adaptor` | net/http re-read the raw line. `//admin/x`, `/public/..%2Fadmin/x` and a forged `/public/%2e%2e/admin/x` were served as `/admin/x` by an `http.FileServer` behind a Fiber guard, a guard on `r.URL.Path` saw `/a/../admin/x`, and `http.StripPrefix` was ignored on the way back into Fiber. | Requests are built from the routed path, the raw query and the host Fiber saw. `HTTPHandler*` answer `404` for `//`, `%2F`, a backslash, a dot segment with parameters or a forged escape. `HTTPMiddleware` and `ConvertRequest` keep `%2F` in `RawPath` and answer `400` for an authority-shaped path or a forged escape. The original request line is restored after the handler returns or panics. `FiberHandler*` and `FiberApp` route `r.RequestURI` as received, or the line net/http would write for a rewritten `r.URL`. |
| **Rewrite**<br>`middleware/rewrite` | With `UnescapePath`, a capture was decoded twice: `/files/%252e%252e/secret` through `/files/* → /public/$1` reached the handler as `/secret`. | Captures are escaped again before insertion. |

## Changes introduced

- **`internal/wiretarget`** (new, shared by proxy and adaptor):
  - `Routed(c)` is `c.Path()` spelled for the wire plus the query. The path is rooted, bytes outside RFC 3986 `pchar` are escaped, a stray `%` is written as `%25`, and under `UnescapePath` the decoded path is escaped again segment by segment. The query is as sent unless a handler changed the arguments. It returns `c.OriginalURL()` itself when that already is the target.
  - `SegmentsAsRouted` refuses an empty segment, `%2F`, a backslash, a dot segment with parameters and a forged escape.

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0923873f4a1b` and running the modified tests.