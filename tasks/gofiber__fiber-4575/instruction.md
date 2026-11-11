# Issue

**Title:** 🐛 fix: de-flake the clock-sensitive tests

## Description

# Description

`main` has been going red on isolated test failures for months, and the retry that
should absorb them was never running. This fixes both.

**Cause 1, the cached clock.** The memory storages compare entry expiry against
`utils.Timestamp()`, a Unix second refreshed by a background 1s ticker, not against the
wall clock. Under `-race` on a loaded runner that goroutine's store lands up to 1.6s late,
and >100ms late on about half the ticks, so expiry can lag its nominal TTL by roughly two
seconds. Every test that slept `TTL + 100..500ms` and then asserted expiry was flaky by
construction.

Reproduced at the storage level in 2 of 24 rounds (TTL=5s, 5.1s sleep), and at test level
as the exact failures seen on main in 2 of 8 rounds under `GOMAXPROCS=2` with in-process
CPU load. Zero of 8 with the fix. Note the load has to be in-process, an external load
generator does not starve Go's own scheduler and shows nothing.

**Cause 2, dead reruns.** `test.yml` sets `rerun-fails: '2'`, but every run aborted with
`rerun aborted because previous run had a suspected panic and some test may not have run`.
gotestsum flags a package as panicked the moment any output line starts with `panic: `
(`testjson/execution.go` `addOutput`) and `cmd/rerunfails.go` skips the rerun if any
package is flagged. The recover middleware wrote exactly that prefix for a panic it had
just recovered, so one line cost the whole 4248-test suite its retries.

Affected runs: [30523196027](https://github.com/gofiber/fiber/actions/runs/30523196027),
[30397573119](https://github.com/gofiber/fiber/actions/runs/30397573119),
[28373765289](https://github.com/gofiber/fiber/actions/runs/28373765289),
[28302993228](https://github.com/gofiber/fiber/actions/runs/28302993228),
[28206382069](https://github.com/gofiber/fiber/actions/runs/28206382069).

## Changes introduced

**`test(session,csrf,limiter)`** Add `internal/clocktest.SleepPast`, which sleeps the TTL
and then waits for the cached clock to catch up, and use it where that clock is what
decides. Sleeping longer is not a fix, the updater delay has no upper bound.

I checked per call site which clock actually governs, because the helper shortens the
wall-clock margin and that is only safe where the cached clock decides:

| path | clock |
| --- | --- |
| session idle timeout (`Save` to `Storage.Set(.., idleTimeout)`) | cached |
| session absolute timeout (`absExpiration`) | real `time.Now()` |
| csrf without `Session` (`storageManager`, `internal/memory`) | cached |
| csrf with `Session` (`token.Expiration.Before(time.Now())`) | real `time.Now()` |
| limiter windows (`cfg.currentSecond()`) | cached, no `time.Now()` at all |

The two real-clock paths are deliberately left on a plain `time.Sleep`.

**`test(cache)`** `Test_CacheMaxStaleRespectsProxyRevalidateSharedAuth` failed with
expected `miss`, actual `unreachable`. A different mechanism: the store phase reads
`cfg.now()` twice (`cache.go:714` and `cache.go:784`) and charges the whole second in
between as the response's apparent age, which consumes a one-second lifetime entirely.
Raising it to two seconds makes the test immune without changing what it asserts.

**`test(timeout)`** `TestTimeout_Exceeded` bounded elapsed at 150ms against a 50ms timeout
and a 200ms handler sleep, and failed at 150.78ms. Only 100ms of headroom meant it
measured runner load, not early return. Handler sleep to 2s, bound at half of it.

**`fix(recover)`** Prefix the default stack trace with `recovered`, and pin it with a test
that captures the output through an `os.Pipe` and asserts it no longer looks fatal.

## Open question for maintainers

The cache double clock read is a real bug, not just a test annoyance, and I did not touch
it here. A response with `max-age=1` fails to be cached at all whenever the store phase
crosses a second boundary, because `responseTS - e.date` charges fiber's own processing
latency as response age. RFC 9111 defines apparent age against the same response event,

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1104ec30d669` and running the modified tests.