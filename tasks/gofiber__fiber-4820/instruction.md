# Issue

**Title:** 🧹 chore: share forwarded IP scanning and ignore empty elements

## Description

# Description

`extractIPsFromHeader` and the forward/reverse paths in `extractIPFromHeader` scan comma-separated proxy headers independently. Share this work through small, inlinable `internal/headerlist.Next` and `Prev` helpers, while keeping whitespace handling, IP validation and proxy selection in the callers.

`IPs()` also now ignores every element that is empty after `TrimOWS`, as requested in review and required by RFC 9110 Section 5.6.1.2. With validation disabled, both `a,,b` and `a,,,b` return `["a", "b"]`; `,,,` and whitespace-only lists return an empty slice. The previous leading-comma special case is removed. `IP()` selection, trusted-proxy handling and fallback behavior are unchanged.

Related #4604 (the X-Forwarded-For scanning portion of cluster 8; this does not complete the whole cluster).

## Changes introduced

- Put `Next`/`Prev` in `internal/headerlist/headerlist.go` and their raw-element tests in `headerlist_test.go`. The helpers preserve empty elements and whitespace so each caller can apply its own rules.
- Put the forwarded-IP regression tests beside the existing IPs tests in `ctx_test.go`; cover empty elements, SP/HTAB trimming, invalid addresses, IPv4-mapped IPv6, validation modes and forward/reverse selection.
- Use the existing `utils.IsIPv4`/`IsIPv6` validators when list validation is enabled, instead of classifying every byte during delimiter scanning.
- Document the empty-element behavior in `docs/api/ctx.md`, `docs/whats_new.md` and the generated interface comments. No new public signatures or dependencies.

## Performance

Existing `Benchmark_Ctx_IP*` benchmarks, Go 1.26.10, Linux/amd64, Intel Core Ultra 9 285H. Pinned to one CPU, `GOMAXPROCS=1`, eight alternating before/after rounds, 200ms per benchmark; comparison uses benchstat. The baseline uses `req.go` from the original PR base `f1371701` via a Go overlay in the same test tree. B/op and allocs/op are unchanged in all eight benchmarks.

| Benchmark | Before ns/op | After ns/op | Change |
| --- | ---: | ---: | ---: |
| IPs | 50.87 | 45.68 | -10.2% |
| IPs IPv6 | 87.91 | 65.93 | -25.0% |
| IPs with validation | 63.44 | 58.85 | -7.2% |
| IPs IPv6 with validation | 147.6 | 125.4 | -15.0% |
| IP with proxy header | 16.84 | 16.61 | -1.4% |
| IP with proxy header and validation | 39.17 | 39.19 | no significant difference |
| IP without proxy header (unchanged control path) | 21.91 | 21.55 | -1.6% |
| IP with trusted proxy chain | 148.3 | 152.8 | +3.0% |

The list benchmarks improve, while the trusted-chain benchmark is about 4.5 ns slower in this run. These are local microbenchmarks, not application throughput measurements.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `ee9db9d0b8b5` and running the modified tests.