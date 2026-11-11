# Issue

**Title:** test: close three coverage gaps in logger, shutdown and docs

## Description

# Description

Three independent coverage gaps, one commit each. No production code changes,
apart from two headings in the middleware docs.

Relates to #3370.

## Changes introduced

**Colored logger output.** The colored branch of the default access log format
is only reachable with `ForceColors` when the stream is not `os.Stdout`, so it
ran in benchmarks alone. Nothing pinned the colored status and method segments,
the red error suffix, or the control byte scrubbing that suffix applies (it is
assembled directly instead of going through the `${error}` tag, ).
`beforeHandlerFunc`, which decides whether stdout keeps its escape sequences for
`NO_COLOR`, `TERM=dumb` and `ForceColors`, had no test at all.

**Shutdown with a streamed body.** The existing shutdown tests all block inside
the handler. A streamed body is written after the handler has returned, which is
the case reported in #3370 against v3.0.0-beta.4. Current behaviour is correct
(fasthttp closes only idle connections and counts open ones), so this pins it.
Checked the other way round as well: with a 10ms timeout the same test fails
with `context deadline exceeded`.

**Middleware doc structure.** Every page under `docs/middleware/` is expected to
carry `## Signatures`, `## Config` and `## Examples`, so a reader can jump
straight to either. Four pages deviate for a reason and now say so in the test
rather than being tolerated silently. Two did not have a reason: `adaptor.md`
used "Usage Examples" and `rewrite.md` nested Examples under Config at level 3.
Neither anchor was linked anywhere, so both were renamed. This runs with
`go test ./...` and needs no CI wiring.

- [x] Documentation Update: `docs/middleware/adaptor.md` and
      `docs/middleware/rewrite.md`, heading names only

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d3085b5ed68a` and running the modified tests.