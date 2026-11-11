# Issue

**Title:** 🐛 bug: keep stray percents from forging escapes, root every request target and take the SendFile name literally

## Description

# Description

Core half of the path-guard work split out of #4713. The middleware half (static, proxy, adaptor, rewrite) is #4720. The two are independent and either can merge first: the full suite passes on current `main` with this PR, with #4720, and with both.

`app.Use("/admin", auth)` only protects a resource while the router and the code that finally acts on the path agree on its name. This PR closes the router-level and `SendFile` cases where they disagreed. Every case has an end-to-end test that fails without its fix.

## Before / after

| Area | Before | After |
|---|---|---|
| **Router: stray `%`**<br>`path.go` | A stray `%` that begins no escape was kept as sent while the escape after it was decoded, so the two lined up into a new escape: `/%%370rivate` reached `c.Path()` as `/%70rivate`, which anything decoding the path again read as `private`. | A stray `%` is written as `%25` only where an escape decoded after it would complete a new one (`/%%370rivate` is matched as `/%2570rivate`). Anywhere else it is kept as sent, so a param does not depend on the rest of the path: `/files/100%` and `/files/./100%` both give `100%`. By default `c.Path()` never holds an escape of an unreserved character. |
| **Router: unrooted targets**<br>`path.go`, `ctx.go` | `OPTIONS *`, `GET http://host?q` and the authority form fasthttp admits for `CONNECT` (`CONNECT admin//secret`) reached the router unrooted: every root-level `Use` middleware was skipped while a `/*` route still matched. | Every unrooted target is rooted before matching. `pathNeedsNormalization` sends every path without a leading slash through normalization whatever its length. |
| **`RoutePatternMatch`** | The root wildcard pattern matched an unrooted string (`RoutePatternMatch("*", "/*")` was `true`) while every other pattern did not. | It takes a path, not a request target: `""` is read as `/`, and any other unrooted string matches no pattern. |
| **SendFile**<br>`res.go` | The name was handed to fasthttp as a request URI. It was decoded a second time (`filepath.Join(root, "..%2Fsecret.txt")` then escaped the root) and truncated at `?` or `#`; a directory answered `302` with its filesystem path in `Location`; a control byte served `index.html`. | The name is taken literally, as `os.Open` takes it. A directory and a control byte get a generic `404` that names no path. `Download` follows. |

## Changes introduced

- `path.go`: `unescapeSafePath` writes a stray `%` as `%25` only when the next two bytes it writes are hex digits, which only a decoded escape can produce. The copy for that cold path is a single allocation, since each `%25` pairs with an escape that shortened the path. `normalizeRequestPath` roots an unrooted target. `RoutePatternMatch` reads `""` as `/` and answers `false` for any other unrooted path.
- `ctx.go`: `pathNeedsNormalization` also normalizes every path without a leading slash. It stays inlined.
- `res.go`: `SendFile` escapes the name into a pooled buffer before it becomes a request URI, rejects a control byte, and answers a directory with `ErrNotFound`.

**Tests.** The router cases go through the raw request line, since net/http's request builders reject these spellings.
- Router: `Test_UnescapeSafePath` (forgery and idempotency cases), `Test_UnescapeSafePath_NoForgedEscape` (exhaustive walk over short paths), `Test_UnescapeSafePath_OneCopy`, `Test_Router_StrayPercent`, `Test_Router_StrayPercentParamIsStable`, `Test_NormalizeRequestPath` (rooting cases), `Test_Router_UnrootedTargetIsRooted` (`CONNECT` forms included), `Test_PathNeedsNormalization`, `Test_RoutePatternMatch_UnrootedPath`.
- SendFile: `Test_Ctx_SendFile_NameIsLiteral`, `_EncodedSeparatorStaysInDirectory`, `_DirectoryIsNotFound` (the body names no path), `_ControlByteIsNotFound`, `_DecodedParamWithRoot` (the documented recipe).

- [x] Benchmarks: the router hot path is unchanged. A well-formed path takes the same in-place pass in `unescapeSafePath`, and the unrooted check in `pathNe

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `73fa3b3faf15` and running the modified tests.