# Issue

**Title:** bucket: a failed lookup or `in` test adds a phantom key to the keys returned by iteration

## Description

### Description

Testing a key against a `bucket` — with `in`, or by selecting a bucket that turns out to be empty — permanently adds that key to the keys returned by iterating the bucket. The key is reported even though no item ever had it, and even though `in` says it is not there.

```python
>>> from more_itertools import bucket
>>> s = bucket(['a1', 'b1', 'a2'], key=lambda x: x[0])
>>> 'c' in s
False
>>> sorted(s)
['a', 'b', 'c']          # expected ['a', 'b']
>>> list(s['c'])
[]
```

So `'c' in s` is `False` while `'c' in list(s)` is `True`, for the same object at the same moment.

Selecting the bucket directly does it too, with no membership test involved:

```python
>>> s = bucket(['a1', 'b1'], key=lambda x: x[0])
>>> list(s['zzz'])
[]
>>> sorted(s)
['a', 'b', 'zzz']
```

A `validator` does not help — it only filters which keys can be invented:

```python
>>> s = bucket(['a1', 'b1'], key=lambda x: x[0], validator=lambda k: k in {'a', 'b', 'c'})
>>> 'c' in s
False
>>> sorted(s)
['a', 'b', 'c']
```

The docstring's own example is affected. `sorted(list(s))` is documented as "Get the keys", and one membership test changes the answer:

```python
>>> iterable = ['a1', 'b1', 'c1', 'a2', 'b2', 'c2', 'b3']
>>> s = bucket(iterable, key=lambda x: x[0])
>>> 'd' in s
False
>>> sorted(list(s))
['a', 'b', 'c', 'd']     # documented as ['a', 'b', 'c']
```

Each miss is sticky and they accumulate, so a lookup-heavy loop can leave the key list mostly phantoms:

```python
>>> s = bucket(['a1'], key=lambda x: x[0])
>>> for k in ('q', 'r', 's'):
...     _ = k in s
>>> sorted(s)
['a', 'q', 'r', 's']
>>> {k: list(s[k]) for k in sorted(s)}
{'a': [], 'q': [], 'r': [], 's': []}
```

### Cause

`_cache` is a `defaultdict(deque)`, and `_get_values` begins by *reading* it:

```python
def _get_values(self, value):
    while True:
        # If we've cached some items that match the target value, emit
        # the first one and evict it from the cache.
        if self._cache[value]:          # <- a read that creates the entry
```

On a miss that read inserts an empty `deque` under `value`. `__iter__` then reports whatever keys `_cache` holds:

```python
return iter(self._cache)
```

so the empty entry is indistinguishable from a real key. `__contains__` routes through `_get_values` as well, which is why a plain `in` test is enough to trigger it.

`__iter__` was added later than the cache (#371, for #370), so the two have simply never agreed on what a key is.

### Expected behaviour

Iterating a `bucket` should yield only keys that at least one item actually had. `k in s` and `k in list(s)` should agree.

I have a fix and tests ready and will open a PR referencing this issue. It makes `_cache` a plain `dict` so a lookup cannot insert, and registers a key only where an item is actually seen. The existing `test_list` case — where a key whose items were fully consumed through `s[key]` must still be listed — keeps working, since that key is registered when its first item is produced rather than by the lookup itself.

Found by machine analysis while probing for invariant mismatches, not by hitting it in production.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b2f3aff76330` and running the modified tests.