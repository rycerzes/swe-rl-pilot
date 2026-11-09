# Issue

**Title:** Issue 1304: ichunked matches chunked for n=0 and negative n

## Description

### Issue reference
more-itertools/

### Changes
`ichunked` is documented as being like `chunked`, but a nonempty iterable with `n=0` called `islice(iterator, -1)` and raised islice's `ValueError`. Negative `n` leaked the same islice message instead of `n must be at least 0`.

Treat `n=0` as an empty iterator (without consuming the source) and reject negative `n` the same way `chunked` does.

### Checks and tests
- `python -m unittest tests.test_more.IchunkedTests` — OK
- `python -m unittest` — 932 tests OK
- `ruff check more_itertools/more.py tests/test_more.py` — OK
- `ruff format --check more_itertools/more.py tests/test_more.py` — OK

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `790bb0bb2c03` and running the modified tests.