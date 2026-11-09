# Issue

**Title:** fix: honour a falsey validator in bucket

## Description

## Problem

`bucket` selects its validator with `validator or (lambda x: True)`, so a
callable that is falsey is silently replaced by the default that accepts every
key. An empty `set` subclass defining `__call__` is one example:

```python
from more_itertools import bucket

class AllowedKeys(set):
    def __call__(self, key):
        return key in self

allowed = AllowedKeys()  # falsey: it is an empty set
buckets = bucket(iter([1, 2, 3]), key=lambda x: x, validator=allowed)
list(buckets[1])  # [1], expected []
```

The validator rejects every key, so the bucket should be empty (and the source
should not be scanned for it). Instead the key is treated as valid.

## Changes

- Use an `is None` check instead of truthiness when defaulting the validator.
- Add a regression test using a falsey callable.
- Note the fix in the unreleased changelog.

## Verification

- The new test fails on `main` (`[10] != []`) and passes with the fix.
- Full suite: 768 passed, 21202 subtests passed.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1ea82a711c69` and running the modified tests.