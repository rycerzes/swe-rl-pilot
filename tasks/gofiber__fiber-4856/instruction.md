# Issue

**Title:** 🐛 bug: skip empty forwarded host and proto elements and restore the Next loop

## Description

,  (cluster 8).

- `headerlist.Next` is a byte loop again: `utils.CutByte[go.shape.string]` does not inline, so every list element cost two calls and `c.IPs()` on a comma-padded `X-Forwarded-For` got ~4.5x slower (that header is read without a trust check).
- `c.Host()` reads `X-Forwarded-Host` like the IP readers: lines in received order, empty elements skipped (RFC 9110 5.6.1.2), and the `Host` header when no host is left. Before, `,a.example` gave `""` (BaseURL `http://`, hostauthorization 403, cache entries of different hosts merged), and an empty chunked body or a `Header.Del` could swap which of two lines answered.
- `c.Scheme()` skips empty `X-Forwarded-Proto`/`-Protocol` elements, so `,https` announces `https`.
- Tests pin the new behavior (including a raw chunked request for line order); new benchmarks cover the trusted Host/Scheme paths and a comma-padded `X-Forwarded-For`.
- Docs: ctx.md, reverse-proxy guide, hostauthorization, whats_new; limiter.md drops the paragraph that repeated the KeyGenerator row and the guide.

Benchmarks vs main (M2 Pro): IPs_EmptyElements -77%, Host_TrustedProxy -16%, Scheme_TrustedProxy +5%, IPs_v6 +36% (back to the  level), rest neutral, allocations unchanged.

<sub>🤖 Maintainers: `/generate` re-runs the code generators on this branch</sub>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `95d7398102ac` and running the modified tests.