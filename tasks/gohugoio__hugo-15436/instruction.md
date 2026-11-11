# Issue

**Title:** js.Build / css.Build: expose esbuild's `charset` option (allow `utf8` to avoid `\uXXXX` escaping)

## Description

## Proposal

Add a `charset` option to the `js.Build` and `css.Build` options maps to control esbuild's output character encoding.

Supported values:
- `ascii` (default): Escape non-ASCII characters.
- `utf8`: Preserve non-ASCII characters in the output.

This exposes esbuild's existing `Charset` option, which Hugo currently does not provide.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `c9f6e4d4abc3` and running the modified tests.