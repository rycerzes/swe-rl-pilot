# Issue

**Title:** 🐛 bug: use HTTP quoted strings in auth challenges

## Description

## Summary

- move Fiber's existing RFC 9110 quoted-string encoder into `internal/quotedstring` and retain its zero-allocation clean-value fast path
- use the shared encoder for Content-Disposition filenames and Link `rel` values, deleting the core-only implementation
- replace BasicAuth's `strconv.Quote` and KeyAuth's `%q` formatting for generated challenge parameters
- cover quotes, backslashes, C0 controls, DEL, CR/LF, pooled-buffer detachment, and non-ASCII values across core, BasicAuth, and KeyAuth
- document generated challenge escaping; custom KeyAuth `Challenge` values remain verbatim

## Behavior changes

Generated BasicAuth and KeyAuth parameter values now use HTTP quoted-string syntax instead of Go string-literal syntax. Quotes and backslashes use quoted-pair escaping, CR/LF use `\\r`/`\\n`, and other C0 controls plus DEL are percent-encoded instead of producing invalid `\\uXXXX`/`\\xXX` forms. Ordinary values are byte-identical.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `c344047e1028` and running the modified tests.