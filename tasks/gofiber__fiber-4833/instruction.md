# Issue

**Title:** ⚡ perf: walk Cache-Control lists with headerlist and write Retry-After without a string

## Description

## Description

Related #4604 (cluster 5, comma-list header scanning).

The cache middleware's Cache-Control parser kept its own quote-aware comma scanner beside `headerlist.AllQuotedPairs`. This moves both onto a single quoted-pair walk in `internal/headerlist`, and drops the per-request string allocation for `Retry-After` in the limiter.

### Behavior

No observable change. The new walk was checked against the previous implementations byte for byte (table cases plus differential fuzzing) on empty values, empty elements (`a,,b`, leading or trailing commas), SP/HTAB/CR/LF/VT/FF, quoted commas, escaped quotes, a trailing backslash inside and outside quotes, unterminated quotes, case and duplicates. The same holds for nil-vs-empty directive values and early-exit iteration.

New tests:
- `Test_NextQuoted`, `Test_AllQuotedPairs_EarlyExit`, `Test_Quoted_NoAllocations` (headerlist)
- `Test_parseCacheControlDirectives_Elements` (cache), which also passes unchanged on `main`
- `Test_Limiter_RejectRetryAfterDoesNotAllocate` (limiter), which fails on `main`

### Benchmarks

benchstat, `main` vs this branch, interleaved runs, n=10:

| Benchmark | main | this PR | delta |
| --- | --- | --- | --- |
| parseCacheControlDirectives | 403.8 ns | 299.7 ns | -25.8% |
| hasDirective | 59.0 ns | 60.4 ns | ~ |
| Contains | 65.6 ns | 57.4 ns | -12.4% |
| Limiter_Reject/fixed | 319.2 ns, 2 allocs | 288.2 ns, 1 alloc | -9.7% |
| Limiter_Reject/fixed_skip_failed | 312.2 ns, 2 allocs | 285.5 ns, 1 alloc | -8.5% |
| Limiter_Reject/sliding | 317.4 ns, 2 allocs | 300.2 ns, 1 alloc | -5.4% |
| Limiter_Reject/sliding_disable_headers | 237.3 ns | 244.2 ns | ~ |
| Limiter_Headers (4 cases) | | | ~ |

No allocation increases in these benchmarks.

Local-only benchmarks (not included in this PR) also show the shared walk removing the per-backslash cost on hostile input: Cache-Control with 1 KiB of `\` goes from 1941 ns to 66 ns (-96.6%), an unterminated quote from 2130 ns to 49 ns (-97.7%), and `AllQuotedPairs` on 1 KiB of `\` from 11662 ns to 51 ns (-99.6%). Happy to add those benchmarks to the PR if you'd like them kept.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3cd12aa83f3f` and running the modified tests.