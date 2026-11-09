# Issue

**Title:** peekable: avoid caching entire iterable on negative slice with omitted stop

## Description

### Issue reference
None

### Changes
A reverse slice with an omitted stop, such as `peekable(count())[5::-1]`, ends at index 0. The old implementation treated the internal negative stop sentinel as right-relative indexing and cached the entire source. This hangs on an infinite iterator and buffers unnecessary items on a large finite source.

Cache only through `start + 1` for this case; retain full caching for actual negative indices or an omitted reverse start. The release note is under Unreleased, above the existing 11.2.1/11.2.0 history.

### Checks and tests
- Preserve the finite-source regression and add a guarded infinite source: prefill three cached items, take repeated reverse slices, then verify normal iteration order. A seventh source read fails immediately instead of hanging. Adapted from @carlitogwapito's [test-only ).
- The same guarded test fails with the exact read-bound assertion on master `4aeb433` and passes on this branch. Imports were checked against each checkout.
- Python 3.13.3: full unittest run, 932 tests with 5 skipped; 100% statement coverage.
- Ruff format/check, stubtest, Sphinx with `-W`, Flit sdist/wheel build, and Twine checks passed. Gate components ran individually with pinned development tools; the literal `make all-checks` target and the full version/OS matrix were not run.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `4aeb4338ae14` and running the modified tests.