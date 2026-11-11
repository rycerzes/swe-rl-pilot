# Issue

**Title:** 🐛 bug: fix proxy redirect, SSRF and Balancer issues and limiter key aliasing

## Description

# Description

Fixes redirect, SSRF-check, `Balancer` and limiter issues in the proxy and limiter middleware. `proxy.go` and `security.go` are also split by concern (`balancer`, `blockedip`, `client`, `domain`, `headers`, `lookupcache`, `redirect`, `ssrf`, `upstream`). Most of the moved functions carry one of the fixes below rather than moving unchanged; `WithSecurityPolicy` also drops a nil check that `init`, which installs the default policy, made unnecessary.

**Proxy: redirects (`DoRedirects`)**

- A hop that has to differ from the handler's request (another method, another origin) is sent as a private copy. After a redirect the handler still sees its own method, body, parsed form, uploaded files and credentials. The copy keeps the request timeout, the user values and the body of a multipart form the server parsed ahead of the handler.
- Methods follow RFC 9110 §15.4: `303` turns every method but `GET` and `HEAD` into `GET`, `301` and `302` turn `POST` into `GET`, `307` and `308` repeat the request. A method change drops the body, the parsed form and the fields that frame, describe or expect content (`Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, `Content-Location`, `Transfer-Encoding`, `Trailer`, `Expect`, `Digest`, `Content-MD5`).
- An origin is scheme, host and port (RFC 6454). `Authorization`, `Proxy-Authorization`, `Proxy-Authenticate`, `WWW-Authenticate`, `Cookie` and `Cookie2` are dropped when any of the three changes; a default port spelled out in `Location` stays the same origin.
- A redirect that repeats the body of a request streamed with `StreamRequestBody` is followed when the first hop left the whole body in memory (known length up to 8 KiB, an empty body included); otherwise it fails with `fasthttp.ErrRedirectBodyStream`.

**Proxy: SSRF checks**

- The blocklist adds `0.0.0.0/8`, `192.0.0.0/24` (Oracle Cloud's `192.0.0.192`), `198.18.0.0/15`, `240.0.0.0/4` (the broadcast address included) and the IPv6 site-local range `fec0::/10`.
- New `ErrUpstreamHostUnresolvable` matches, together with `ErrUpstreamHostBlocked`, a lookup that fails or answers with no address (the check still fails closed); `errors.As` finds the `*net.DNSError`. An address `net/url` cannot parse is `ErrUpstreamHostInvalid` with the `*url.Error` wrapped, and a host with only IPv6 addresses and no `DialDualStack` gets an error that says so instead of `ErrUpstreamHostBlocked`.
- The up-front lookup of a hostname is remembered for one second in a fixed-size cache (1024 slots, seeded hash, per resolver; answers of more than 32 addresses are not stored). Only the shared client uses it, because its dials are checked again at connect time; a client with a `Transport` or passed per call is judged by a lookup of its own.
- The dial guard also wraps `DialTimeout`, so the time a `DoTimeout`, `DoDeadline` or `Balancer` `Timeout` allows bounds the lookup and the connects together. A connect the request gives no time keeps its five-second bound (`net.Dialer`), as before. `dialChecked` keeps the `*net.AddrError` of a malformed address.

**Proxy: Balancer and helpers**

- `Balancer()`, `Balancer(Config{})` and a `Client` without `Clients` panic at startup instead of on the first request.
- A server without a port is dialed on the port of its scheme, and each upstream client sets its own scheme, so an `https` upstream works behind a plain-HTTP listener and the reverse.
- A host client of a custom `Config.Client` that already has `DisablePathNormalizing` set is left alone.
- The round-robin picks with one atomic add.

**Limiter**

- The key a `KeyGenerator` returns can point into request memory. It is copied before a custom `Storage`, which may keep it, sees it. The built-in store copies the keys it keeps, so there the copy is made only for the read after `c.Next`, and a rejected request makes none.
- `FixedWindow.New` and `SlidingWindow.New` fill in the defaults on a copy of the config, so a `Config` that did not go through `limite

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `45156761f9c6` and running the modified tests.