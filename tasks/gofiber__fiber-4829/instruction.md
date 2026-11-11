# Issue

**Title:** 🐛 bug: make Links add to the Link header instead of replacing it

## Description

# Description

`c.Links()` overwrites the `Link` header, so anything set before it is lost. Calling it twice keeps only the second call's links. After `SendEarlyHints`, it is worse: the hints are separate field lines and `Set` only rewrites the first one, so the final response keeps some preload hints and drops others:

```go
app.Get("/", func(c fiber.Ctx) error {
	_ = c.SendEarlyHints([]string{"</a.css>; rel=preload; as=style", "</b.js>; rel=preload; as=script"})
	c.Links("/items?page=2", "next")
	return c.SendString("ok")
})
// Link: </items?page=2>; rel="next"
// Link: </b.js>; rel=preload; as=script      <- a.css is gone
```

Express adds to the existing header instead (`res.links` reads `this.get('Link')` and appends, in both 4.x and 5.x). `Links` now does the same: it folds any existing `Link` lines into one value, the same way `Append` does with `peekJoinedResponseHeader`, and adds the new links after them. Two calls now give the same header as one call with all the links.

## Changes introduced

- `res.go`: `Links` starts its buffer with the existing `Link` value, then removes the existing lines in every spelling (`Res.Del`) before setting the folded one, so a lower-case `link` kept with `DisableHeaderNormalizing` is not sent twice. The generated interface comments are updated by `make generate`.
- `ctx_test.go`: new `Test_Ctx_Links_KeepsEarlierLinks` covers a second call, a header set earlier, `SendEarlyHints`, and a lower-case `link` line with `DisableHeaderNormalizing`. All four fail on `main`. `Test_Ctx_Links` and `Benchmark_Ctx_Links` reuse one ctx, so they now clear the header between calls.
- `docs/api/ctx.md`: one sentence in the `Links` section.

- [x] Benchmarks: `Benchmark_Ctx_Links` is about 64 ns/op on `main` and 69 ns/op with the change, 0 allocs in both.
- [x] Documentation Update: `docs/api/ctx.md`, Links.
- [ ] Changelog/What's New
- [ ] Migration Guide: not needed, no API change.
- [x] API Alignment with Express: matches `res.links`, which appends to the existing `Link` header.
- [ ] API Longevity
- [ ] Examples

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b6a1184d51a7` and running the modified tests.