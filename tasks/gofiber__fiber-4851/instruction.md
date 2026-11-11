# Issue

**Title:** 🧹 chore: share host splitting and IDNA folding

## Description

# Description

This is the dedup-only first step of cluster 2 (host normalization and IDNA) of #4604. The status table on the issue listed it as not started: several host comparators, two IDNA call paths and no shared helper.

It adds `internal/hostname` and moves two hand-written splitters and the IDNA package into it:

- **`SplitPort(authority)`** is `parseAddr` without its whitespace trim: a bracketed IPv6 literal kept up to its first `]`, and a bare value with several colons returned whole. Its scan now runs forward with `IndexByte`, which gives the same result. `Hostname()` and the listener banner, the two `parseAddr` callers, trim before calling it. Proxy's `DomainForward` uses it in place of `hostWithoutPort`, which is deleted.
- **`ToASCII(host)`** is `internal/idnafold.ToASCII` with the code unchanged and a shorter doc comment that keeps the contract. `internal/idnafold` is deleted.
- **`ToUnicode(host)`** is the Punycode decode `Subdomains` did inline. `golang.org/x/net/idna` is now imported only by `internal/hostname`.

**Behavior is identical for every `Host` the fasthttp server accepts.** The one difference outside that set: `DomainForward` now splits an unclosed `[` with one colon (`[a:80` gives `[a`, where `hostWithoutPort` returned it whole). fasthttp's server rejects that host, but a request built by hand or arriving through `adaptor` can carry it. The `SplitPort` doc states this and `Test_Proxy_DomainForward_UnparsedHost` pins it at the gate. How this was checked is below.

Related #4604

## Changes introduced

- **`internal/hostname`:** adds `SplitPort`, `ToASCII` and `ToUnicode`, with the unit-test rows of `parseAddr`, `hostWithoutPort` and `idnafold` moved over, plus benchmarks. `Benchmark_ToASCII_*` keep their names.
- **Core:** `parseAddr` is deleted. `Hostname()` and `prepareListenData` call `hostname.SplitPort(utils.TrimSpace(...))`. `Subdomains` lowercases once and then calls `hostname.ToUnicode`. The old code lowercased again after decoding, and the harness found no input where the second fold changes the result.
- **`middleware/proxy`:** `hostWithoutPort` is deleted and `foldHostnameLabel` calls `hostname.ToASCII`. The gate returns early when the Host is no longer than the domain: `SplitPort` returns a prefix of its input, so a second compare could not match. The gate's comment now just says why it uses `EqualFold` (RFC 9110 §4.2.3). The import is aliased `hostnamepkg` so the documented `DomainForward(hostname, addr, ...)` signature stays the same.
- **`middleware/hostauthorization`:** `idnafold.ToASCII` becomes `hostname.ToASCII`. The strict authority parsing and `isValidHostSyntax` are untouched, since they validate rather than normalize.
- **`Host()`:** a one-line comment records that the trusted `X-Forwarded-Host` branch returns its first non-empty element, neither validated nor case-folded.
- **Rows that pin existing behavior:**
  - `Test_Ctx_Host_ForwardedHost`: a trusted `X-Forwarded-Host` keeps its case.
  - `Test_Ctx_Subdomains`: an upper-case trusted `XN--` host is still decoded, which pins the fold before `ToUnicode`.
  - `Test_Proxy_DomainForward_HostMatch`: `DomainForward("[::1]")` matches `Host: [::1]:8080`.
  - `Test_Proxy_DomainForward_UnparsedHost`: a Host that does not parse reaches the gate as sent, which pins both `EqualFold` calls and the unclosed `[`.
  - `Test_SplitPort`: `[::1]]:80`, `[::1]x:80` and `[a:80`.
  - `Test_ToUnicode`: upper-case `XN--` is left alone; `xn--` anywhere in the host maps the other labels too, while a host without it is not mapped; one rejected label leaves the whole host unchanged. `idna.Lookup.ToUnicode("xn--.example.com")` returns `.example.com`, an x/net deviation from UTS #46 that `Subdomains` already had. A comment on that row says to update it when x/net aligns.
  - `Test_ToASCII_ToUnicode_RoundTrip`: asserts the Punycode in between.
  - `Test_Ctx_Hostname` and `Test_PrepareListenData_TrimsAddr`: the trim now done by the callers, which the delete

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d67318800364` and running the modified tests.