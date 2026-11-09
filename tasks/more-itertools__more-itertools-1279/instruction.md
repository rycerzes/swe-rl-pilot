# Issue

**Title:** Fix one() and only() dropping a falsy user-supplied exception

## Description

### Summary
`one(it, too_long=exc)` and `only(it, too_long=exc)` used `raise too_long or ValueError(msg)` (and similar for `too_short`), which caused any custom exception instance whose boolean evaluation is falsy (e.g. an exception class defining `__bool__` returning `False`) to be discarded, erroneously raising the default `ValueError`.

### Changes
- Check `if too_long is not None:` and `if too_short is not None:` instead of truthiness.
- Only construct the default exception message when no custom exception is supplied, avoiding unnecessary string formatting or potential errors in item `__repr__`.
- Add unit tests verifying custom falsy exceptions are preserved and raised as expected.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9ed3dbb0ae52` and running the modified tests.