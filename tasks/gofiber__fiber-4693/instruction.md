# Issue

**Title:** 🐛 bug: keep idempotency response headers unsplit

## Description

# Description

While reading the idempotency middleware I noticed it snapshots the response headers with `c.Bind().RespHeader(headers)`. That binder honours the app-wide `EnableSplittingOnParsers` setting, which splits values on commas — a request-parsing convenience that has no business touching a response the handler already wrote.

The consequence is that on an app built with `fiber.New(fiber.Config{EnableSplittingOnParsers: true})`, the first request is answered normally, but the replay served from the idempotency cache emits one header line per comma-separated fragment. Two concrete cases:

- `Set-Cookie: session=abc; expires=Mon, 21 Oct 2030 07:28:00 GMT` comes back as two `Set-Cookie` lines, `session=abc; expires=Mon` and ` 21 Oct 2030 07:28:00 GMT`, so the client loses the cookie.
- `Content-Disposition: attachment; filename="a,b.txt"` comes back as `attachment; filename="a` and `b.txt"`.

So the same request, retried with the same idempotency key, does not get the same response — which is the one guarantee this middleware exists to provide.

I fixed it at the point where the snapshot is taken: the header lines are now read straight from the response with `c.Response().Header.All()` and copied as-is. Nothing else changes — the same names reach `KeepResponseHeaders`, the same values reach storage, and the binder is simply no longer in the path. Apps that leave `EnableSplittingOnParsers` off (the default) see identical behaviour.

Fixes # (issue)

## Changes introduced

- `middleware/idempotency`: snapshot the response headers directly instead of through the response-header binder.
- Added `Test_New_StoreRetrieve_HeadersWithCommas`, which replays a response carrying a `Set-Cookie` with an `Expires` date and a `Content-Disposition` with a comma in the filename under `EnableSplittingOnParsers: true`, and compares the replayed header lines to the original ones.

Before the fix that test fails on the first assertion:

```
expected: []string{"attachment; filename=\"a,b.txt\""}
actual  : []string{"attachment; filename=\"a", "b.txt\""}
```

After it, and the whole package under `-race`:

```
$ go test ./middleware/idempotency/ -count=1 -race
ok  	github.com/gofiber/fiber/v3/middleware/idempotency	40.064s
```

- [ ] Benchmarks: not applicable; the new loop allocates the same map the binder filled, minus the pooled intermediate map and the reflect-based decode.
- [ ] Documentation Update: none needed, the documented behaviour is unchanged.
- [ ] Changelog/What's New: none.
- [ ] Migration Guide: none.
- [ ] API Alignment with Express: not applicable.
- [ ] API Longevity: no exported API touched.
- [ ] Examples: none.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e90c824775a0` and running the modified tests.