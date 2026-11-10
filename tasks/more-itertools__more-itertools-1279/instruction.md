# Issue

**Title:** Fix one() and only() dropping a falsy user-supplied exception

## Description

### Summary
`one(it, too_long=exc)` and `only(it, too_long=exc)` used `raise too_long or ValueError(msg)` (and similar for `too_short`), which caused any custom exception instance whose boolean evaluation is falsy (e.g. an exception class defining `__bool__` returning `False`) to be discarded, erroneously raising the default `ValueError`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9ed3dbb0ae52` and running the modified tests.