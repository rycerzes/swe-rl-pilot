# Issue

**Title:** 🐛 bug: preserve aliased path rewrites

## Description

### Motivation
- A recent optimization fused the path copy and ASCII-fold into a one-pass SWAR loop but incorrectly assumed the source string could not alias the destination, which allowed an aliased substring rewrite (for example `c.Path(c.Path()[4:])`) to corrupt the routing detection path and enable route-confusion attacks.
- The intent of this change is to keep the one-pass performance benefit while making the helper safe when `src` may alias a reused destination buffer coming from `c.path`.

### Description
- Change `appendCopyLowerASCII` to preload the overlapping SWAR tail word before performing destination writes, preventing stores from mutating bytes the tail load still needs to read; the helper comment was updated to document aliasing constraints accordingly (`helpers.go`).
- Replace the vulnerable tail-load with the preloaded `tail` value when finishing the overlapping word to ensure correctness with aliased substring sources (`helpers.go`).
- Add a regression test that reproduces the reported aliased-substring rewrite (`/api/bar/fooX` → `/bar/fooX`) and asserts both the original-case path and the lowercase detection path are correct (`helpers_test.go`).
- Files changed: `helpers.go`, `helpers_test.go` and a small commit recorded as `🐛 fix: preserve aliased path rewrites`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `224578c90b05` and running the modified tests.