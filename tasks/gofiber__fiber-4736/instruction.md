# Issue

**Title:** 🐛 bug: key cache entries by request scheme and host

## Description

# Description

The cache middleware's default key was built from the request path, the canonical query string, a header subset (`Accept`, `Accept-Encoding`, `Accept-Language`) and opt-in cookies. It did not include the request's scheme or authority. RFC 9111 [§2](https://www.rfc-editor.org/rfc/rfc9111#section-2) composes a cache key from the request method and the target URI at a minimum, and the target URI carries both. Two requests that differed only in `Host` therefore shared one entry, so an app that serves several hosts could answer a request on one host with the response generated for another:

- With host-based routing (`app.Domain()`), the first host to load `/dash` populated the entry and the second host was served that page with `X-Cache: hit`.
- A handler that redirects to `c.BaseURL() + "/landing"` produced a `Location` for the first host, and the cached `301` was then served on the second host with the first host's `Location`.

**The fix.** The default key now leads with `scheme=<scheme>|host=<host>`, read through `c.Scheme()` and `c.Host()` so `X-Forwarded-Proto` and `X-Forwarded-Host` apply behind a trusted proxy. That is the authority `app.Domain()` routes on and `c.BaseURL()` builds from, so the key splits along the dimension the response was built on, and behind such a proxy every host may arrive under the backend's own `Host`. Both segments are escaped and bounded like every other segment (hashed past 192 bytes), so the key format cannot be disturbed by the value and the key cannot grow without limit. The `Vary` manifest key is derived from the base key, so it is partitioned the same way. `cacheKeyVersion` moves to `v3` so an external store that survives the upgrade starts cold instead of serving entries keyed without a host.

**One core change.** `IsProxyTrusted`, which `Scheme()` and `Host()` both call, copied the 624-byte `fiber.Config` by value to read one bool. Profiling the key generator after the change showed that copy as the largest single item of the new cost, so it now reads through a pointer. This also benefits `c.IP()`, `c.IPs()`, `c.Hostname()` and `c.BaseURL()`.

Before and after, with the shipped defaults:

```text
GET /dash       Host: tenant-a.example  -> 200 "tenant-a"                            (miss)
GET /dash       Host: tenant-b.example  -> 200 "tenant-a"  (hit)   before
                                        -> 200 "tenant-b"  (miss)  after

GET /canonical  Host: tenant-a.example  -> 301 Location: http://tenant-a.example/landing (miss)
GET /canonical  Host: tenant-b.example  -> 301 Location: http://tenant-a.example/landing (hit)   before
                                        -> 301 Location: http://tenant-b.example/landing (miss)  after
```

No linked issue.

**Behavior change:** an application that deliberately shared one entry across hosts, for example `www.` and the apex serving identical content, now holds one entry per host, and one per scheme where a trusted proxy forwards both `http` and `https`. Fragmentation stays bounded. A configuration that already lists `Host` in `KeyHeaders`, or sends `Vary: Host`, keeps working; those settings are now redundant.

## Changes introduced

Two commits:

1. 🐛 the fix in `middleware/cache/keygen.go`, the version bump in `cache.go`, the `IsProxyTrusted` pointer in `req.go`, tests and docs.
2. 🧹 `make generate` rewrites one doc comment line in `res_interface_gen.go` (`Vary`). That drift predates this branch (#4735 noted it and left it out); it is included here as its own commit so `make generate` is clean on this branch, and it can be dropped if preferred.

- [x] Benchmarks: this branch vs `origin/main`, `benchstat`, 6 runs each, allocations identical throughout.
  - `Benchmark_Cache` (cached request): 954 ns → 1010 ns (+5.9%, p=0.004), 80 → 96 B/op, 1 alloc before and after. The extra bytes are the longer key string in the one existing allocation.
  - `Benchmark_Cache_AdditionalHeaders`: 1.129 µs → 1.179 µs (not significant, p=0.31). `Bench

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `78b8ee93c988` and running the modified tests.