# Issue

**Title:** 🐛 bug: stop the cache from charging its own latency as response age

## Description

# Description

While storing a response, the cache middleware read the clock a third time right before the freshness calculation:

```go
ts = safeUnixSeconds(cfg.now())      // cache.go:784
responseTS := max(ts, nowUnix)
```

`e.date` was stamped from the earlier read (`nowUnix`, cache.go:713), and the apparent age is derived from `responseTS - e.date`. Every second boundary crossed between those two reads was therefore billed to the response as age and subtracted from its freshness lifetime in `remainingExpiration = expiration - ageDuration`. A response Fiber has just generated has an age of zero, so this charges Fiber's own processing latency to the client's freshness budget.

With a short lifetime the entry is not merely shortened, it is dropped: `remainingExpiration <= 0` sets `X-Cache: unreachable` and returns without storing. A `max-age=1` response was therefore cacheable or not depending on machine load rather than on the request.

RFC 9111 4.2.3 measures `apparent_age` from the time the response was received, so the store phase now reuses the single timestamp the `Date` header was stamped with. Age arriving from upstream is unaffected: when `e.date` is parsed from an upstream `Date` header, `responseTS - e.date` still reflects real age.

## Changes introduced

- `middleware/cache/cache.go`: drop the third clock read, derive `responseTS` from the timestamp the `Date` header was stamped with, and use it for the `expiresParseError` expiry as well.
- Test: `Test_CacheStoreDoesNotAgeItsOwnResponse` drives the middleware with a clock that advances a second on every read, so any clock read the store phase performs after stamping `Date` shows up as phantom age. Verified red before the fix (`unreachable`) and green after (`miss`).
- Benchmarks: none, this removes one clock read per cached response and is not measurable.

Two related notes:

- #4575 raises `Test_CacheMaxStaleRespectsProxyRevalidateSharedAuth` to `s-maxage=2` as a workaround for exactly this bug. Once this lands, that test can go back to a one-second lifetime, and the same latent exposure in `Test_CacheOnlyIfCachedStaleNotServed`, `Test_CacheMaxStaleRespectsMustRevalidate` and `Test_CacheStaleResponseAddsWarning110` disappears.
- #4492 touches these lines but only renames `ts` to `storeTS`; the extra clock read survives there unchanged.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `990459752ff6` and running the modified tests.