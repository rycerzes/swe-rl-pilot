# Issue

**Title:** 🐛 fix: open redirects in composed route URLs and redirect rules

## Description

# Description

**1 of 3, split out of #4581.** This one is independent and can merge on its own.

A URL Fiber composes goes out as composed — a `Location` header is written verbatim, and the parser that decides where it points runs in the client afterwards. That parser strips C0 controls, removes tab/LF/CR, folds backslashes to slashes, percent-decodes, applies UTS #46 mapping, and absorbs a trailing numeric label into an IPv4 address, all **before** it reads the host. A guard reading the bytes as written is judging a different URL than the one the client will fetch.

## What was wrong

### `middleware/redirect`

Roughly a dozen readings where a captured `$N` chose the host:

| target | request | composed | reaches |
|---|---|---|---|
| `https://$1:8080` | `/p/evil.com` | `https://evil.com:8080` | evil.com — a port pins no host |
| `https://example.com@$1` | `/p/evil.com` | `…@evil.com` | evil.com — everything before `@` is userinfo |
| `https://$1.1` | `/r/127.0.0` | `https://127.0.0.1` | loopback — a numeric last label makes the whole host IPv4 |
| `https://$1` | `/r/evil.com` | `https://evil.com` | evil.com — UTS #46 deletes the soft hyphen |
| `mailto:$1` | `/r///evil.com` | `mailto://evil.com` | evil.com — `//` opens an authority for every scheme |

`authoritySpan` also required a literal `//`, which a special scheme does not need: `https://cdn.example.com$1` refused `@evil.com` while `https:cdn.example.com$1` composed `https:cdn.example.com@evil.com`, whose host is the request's.

A rule whose target hands the whole host to the request now **never fires**, and logs a warning naming it at startup — there is no way to tell the intended host from an attacker's. Rule order is most-specific-first, so `/cdn/*x` is no longer left dead behind `/cdn/*`.

### `Route.URL`, `GetRouteURL`, `Redirect().Route`

A parameter escaped its path segment. On a `/*` route, `/evil.com` composed `//evil.com`, `\evil.com` composed `/\evil.com`, and `\t/evil.com` composed `/\t/evil.com` — a browser resolves all three to evil.com. All three APIs now answer the same, since the value reaches the same place whether it lands in a `Location` header or an `href`.

`Redirect().Route` queries: a `?` in a parameter folded the query into the earlier parameter's value; a `#` put it in the fragment, where it is never sent.

### `Redirect().Back`

A cross-origin referer arrived as what `net/url` reports as an ordinary relative path. `Back` now redirects to the *normalized* referer, so a client that does not fold backslashes itself cannot resolve a different origin than the one that was validated.

### Flash data

Zeroed before the ctx and the `*Redirect` go back to their pools. `WithInput` copies the whole submitted form into those entries — a rejected login carries the password just typed — and a bare re-slice left them reachable for as long as the pooled object lived.

## Changes introduced

- [x] **Benchmarks:** `Benchmark_Redirect_Route` and `_WithQueries` hold at 16 B/op and 1 alloc/op. An earlier shape of the query merge cost a second allocation because returning the concatenation across a function boundary defeats the stack-buffer optimization; a memory profile found it, and the merge point is now computed separately so the caller concatenates.
- [x] **Documentation Update:** `docs/middleware/redirect.md` (a table of every target shape that pins no host, and an explicit warning that these checks ask whether the *author* wrote the host, not whether you own it — Fiber has no public-suffix list and cannot tell `"$1.com"` from `"$1.example.com"`), `docs/api/redirect.md`, `docs/api/ctx.md`.
- [ ] Changelog/What's New: not written yet.
- [ ] Migration Guide: not needed — see below.
- [ ] API Alignment with Express: no API surface changes.
- [x] **API Longevity:** no signature changes. One new internal package, `internal/urlnorm`, holds the input handling `router.go` and `middleware/redirect` had each written out separately.
- [x] **Examples:** covered by the t

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `a2a6d290f4a1` and running the modified tests.