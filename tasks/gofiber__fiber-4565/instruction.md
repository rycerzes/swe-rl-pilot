# Issue

**Title:** 🐛 bug: avoid reading omitted request bodies in Bind.All

## Description

### Motivation

- Fix a regression where `Bind.All` eagerly inspected `Request().Body()` before honoring a struct's `binding_source` precedence, which can force buffering of streamed request bodies and undermine `StreamRequestBody` streaming/DoS protections.

### Description

- Remove the unconditional `hasBody` precomputation and defer calling `Request().Body()` until the `body` source is actually selected in the custom-precedence loop or the default precedence path. 
- Preserve existing behavior when `body` is included in precedence (default or custom) so body-binding still occurs when intended. 
- Add a regression test `Test_Bind_All_CustomPrecedence_DoesNotReadOmittedBody` that uses `SetBodyStream` and asserts a query-only `binding_source:"query"` does not consume the request body stream.
- Commit recorded as `fix(bind): avoid reading omitted request bodies` and PR metadata created with the same summary title.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `6955385b9a19` and running the modified tests.