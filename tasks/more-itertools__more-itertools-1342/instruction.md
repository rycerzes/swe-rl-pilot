# Issue

**Title:** fix: validate the chunk size in chunked_even

## Description

### Issue reference

N/A — trivial boundary fix; no issue was filed.

### Changes

`chunked_even(iterable, n)` did not validate `n` before handing it to `islice`. A negative size leaked `ValueError: Indices for islice()...`; a zero size leaked `ValueError: Step for islice()...` and consumed two source items before raising. Its sibling sizing functions (`chunked`, `ichunked`, `sliced`) already define the contract: `n == 0` yields nothing without consuming the source, `n < 0` raises `ValueError('n must be at least 0')`.

The fix adds those two guards at the top of `chunked_even`, before `iter(iterable)`, so invalid sizes fail before any source consumption and match the rest of the module.

### Checks and tests

The new `test_zero_chunk_size` and `test_negative_chunk_size` fail on `4aeb433` with the `islice` errors and pass on this branch. They also assert the source iterator is untouched after the error/empty result.

`pytest -q` → 767 passed, 21,194 subtests passed. `ruff check more_itertools tests` and `ruff format --check more_itertools tests` pass.

<details><summary>Details</summary>

`chunked_even(..., None)` remains unsupported (`TypeError`), unchanged. Other itertools recipes with bare `ValueError` tests (`take`, `nth`, `consume`, `spy`, `nth_or_last`) are outside this change because they have no sibling-consistency contract.

</details>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `4aeb4338ae14` and running the modified tests.