# Issue

**Title:** 🩹 Fix: Decode a path parameter exactly once in FromParam

## Description

# Description

Fix-first item 3 of #4604.

`extractors.FromParam` always ran `url.PathUnescape` on `c.Params()`. With the default `UnescapePath: false` that is the single decode and it is correct. With `UnescapePath: true` the router already decoded the path in `configDependentPaths`, so the value was decoded a second time here — the number of decodes depended on a config flag the extractor never looked at.

Effect: a client sending a literal `%20` (on the wire as `%2520`) reached the extractor as a space.

    UnescapePath: false → "%2520" → router leaves it → FromParam decodes once → "%20"   ✅
    UnescapePath: true  → "%2520" → router decodes → "%20" → FromParam decodes again → " "   ❌

The decode now happens only when the router left the value raw, so the count is exactly one under either setting. A value with no percent sign returns immediately, which skips both the config read and the decode on the common path.

This matters beyond the extractor package: `FromParam` backs the parameter-based token lookups used by middleware such as keyauth and csrf, so under `UnescapePath: true` a token containing a percent-escape was compared in a form the client never sent.

## Changes introduced

- [ ] Benchmarks: no benchmark added; the change removes work on the common path (an early return before the config read) and adds none.
- [ ] Documentation Update: not needed, the documented behavior ("retrieves a value from a URL parameter") is what now actually happens.
- [ ] Changelog/What's New: happy to add an entry if you would like one.
- [ ] Migration Guide: not needed. Only affects apps running `UnescapePath: true` with percent-escaped parameter values, which were receiving over-decoded values.
- [ ] API Alignment with Express: n/a, no public API change.
- [x] API Longevity: no exported surface changed.
- [ ] Examples: n/a.

Test added: `Test_FromParam_DecodesOnce` runs the same request (`/test/%2520`) under both `UnescapePath` settings and requires the same extracted value, `"%20"`. It fails on `main` for the enabled case.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0e2ce9d260b6` and running the modified tests.