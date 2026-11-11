# Issue

**Title:** 🐛 bug: preserve redirects and errors in Fresh checks

## Description

## Summary

`Fresh()` currently evaluates request validators without checking the response status. A handler that selects 404 and then checks freshness can send 304 for `If-None-Match: *`, hiding the missing resource and dropping its error body. Matching ETags and modification dates also report redirects and errors as fresh.

Only allow 2xx responses and an existing 304 to be fresh. This preserves errors and redirects, follows the precondition ordering in [RFC 9110 §13.2.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.2.1), and matches Express's response-status guard. `Stale()` remains the inverse of `Fresh()`.

- Add the guard to the shared request implementation, without changing public signatures or dependencies.
- Test matching ETags, wildcard validators, and modification dates across successful, redirect, and error statuses; add an HTTP regression preserving the 404 body.
- Update the context API documentation and generated interface comments.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `7b91997ad06a` and running the modified tests.