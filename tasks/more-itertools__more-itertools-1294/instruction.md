# Issue

**Title:** Repeated zero-cache seekable.peek() retains nested chain iterators

## Description

On current master (`b5e3886`), the fix for #1268 preserves values but each `seekable(..., maxlen=0).peek()` prepends a new `chain` around the previous source. Repeated peeking without advancing retains an iterator chain proportional to the number of calls, despite having no history cache.

```python
import tracemalloc
from more_itertools import seekable

s = seekable(range(3), maxlen=0)
tracemalloc.start()
s.peek()
baseline = tracemalloc.get_traced_memory()[0]
for _ in range(10000):
    assert s.peek() == 0
print(tracemalloc.get_traced_memory()[0] - baseline)
print(list(s.elements()), list(s))
```

On CPython 3.12.13/macOS this retains 2,427,672 additional bytes; output remains `[] [0, 1, 2]`. A single lookahead slot should be sufficient regardless of the number of repeated `peek()`/`bool()` calls. I am checking a fix that reuses the existing `peekable` helper only in the zero-history case, with unchanged bounded/unbounded history behavior.

Investigation performed with AI assistance.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b5e3886a3720` and running the modified tests.