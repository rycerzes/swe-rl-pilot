# Issue

**Title:** ⚡ perf: adopt gofiber/utils v2.4.0 helpers and optimize adaptor/proxy hot paths

## Description

# Description

Adopts the helper functions introduced in [gofiber/utils v2.4.0](https://github.com/gofiber/utils) (`ParseHTTPDate`/`AppendHTTPDate`, `ParseIPv4`/`ParseIPv6`, `AppendQueryEscape`) across every hot path in the framework where they beat the stdlib/fasthttp equivalent, and follows up with targeted optimizations of the proxy and adaptor middlewares plus two correctness fixes surfaced along the way. Every conversion is either provably behavior-identical or an explicitly documented, test-pinned RFC 9110 compliance improvement.

Benchmarks below were taken on the CI-like environment (Intel Xeon @ 2.10 GHz, linux/amd64, `-count=3`); absolute numbers are noisy on that VM, the before/after deltas are what matters.

## Changes introduced

**HTTP date parsing/formatting (`req.go`, `middleware/cache`)**

- `parseHTTPDate` (backs `Fresh()`/`If-Modified-Since`) now delegates to `utils.ParseHTTPDate`: net/http.ParseTime semantics (IMF-fixdate + obsolete RFC 850/asctime, RFC 9110 §5.6.7) behind an allocation-free scalar fast path, dropping the `string(date)` conversion.
- The cache middleware writes the `Date` header with `utils.AppendHTTPDate` (direct field writer) instead of `fasthttp.AppendHTTPDate` (which delegates to `time.AppendFormat`), on both the cache-hit and cache-store paths.
- The cache middleware parses `Date` **and** `Expires` with `utils.ParseHTTPDate`, so both share one RFC 9110 acceptance set. Previously a response dating itself consistently in RFC 850 got its `Date` honored while its `Expires` was routed to the parse-error/force-revalidate path. Pinned by `Test_CacheExpiresObsoleteFormatAllowsCaching` (fails on the old parser).
- `utils.ParseHTTPDate` tolerates surrounding ASCII whitespace (RFC 9110 §5.5 OWS exclusion), which `net/http.ParseTime` does not; this is documented on `parseHTTPDate` and pinned by a `Fresh()` test case.

| Benchmark | Before | After |
|---|---|---|
| `Benchmark_Ctx_Fresh_LastModified` | 229 ns/op | 208 ns/op (−9%) |
| `AppendHTTPDate` (Date header rendering, micro) | 150 ns/op | 39 ns/op (−74%) |

**IP parsing (`req.go`, `middleware/hostauthorization`, `client`)**

- `isTrustedProxyIP` uses `utils.ParseIPv4`/`ParseIPv6` instead of `netip.ParseAddr` — identical acceptance, no error allocation for invalid client-supplied addresses.
- `net.ParseIP` is `netip.ParseAddr` minus zoned addresses (Go ≥1.17), so hostauthorization's IPv6 `Host` validation and the client cookie jar's `isIPLiteral` now screen `%` and delegate to the utils parsers: identical acceptance, zero allocations on either outcome. Pinned by tests covering zoned rejection, IPv4-mapped IPv6, bracketed literals, and malformed octets.

**Query escaping (`redirect.go`, `middleware/cache`, `middleware/paginate`)**

- `Redirect.Route` escapes query values straight into the pooled buffer via `utils.AppendQueryEscape`.
- The cache key generator escapes query keys/values in place, dropping two intermediate strings per parameter pair; the buffer bound check is restated post-append in an exactly equivalent form.
- Paginate renders page URLs through an `url.Values.Encode`-equivalent that escapes into a single buffer; output is pinned byte-for-byte against `Encode` across escaping-heavy inputs.

| Benchmark | Before | After |
|---|---|---|
| `Benchmark_Redirect_Route_WithQueries` | 275 ns/op | 256 ns/op (−7%) |
| `Benchmark_defaultKeyGenerator/multiparam` | ~893 ns/op | ~819 ns/op (−8%) |

**Adaptor middleware (`middleware/adaptor`)**

- `handlerFunc` (the `FiberHandlerFunc`/`FiberApp` serving path) builds the fasthttp request directly into the pooled `RequestCtx` instead of filling a standalone `Request` and `CopyTo`-ing it across — `Init2` only touches connection metadata and buffer flags, so in-place construction is fasthttp's own `Init` order minus the full header+body copy.
- The `noopConn` is pooled together with the `RequestCtx` and the stateless logger is shared, removing two per-request allocations.
- `resolveRemoteAddr` takes

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `6639aefb9577` and running the modified tests.