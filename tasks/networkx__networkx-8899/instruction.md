# Issue

**Title:** _hits_numpy(normalized=False) can return inf/NaN after switching to eigh

## Description

### Current Behavior

`_hits_numpy(G, normalized=False)` can return `inf`/`NaN` values for a simple graph.

For example, with `nx.path_graph(3)`, the dominant eigenvector returned by `np.linalg.eigh` can have negative nonzero entries and zero entries. The current normalization then divides the vector by `h.max()` / `a.max()`. If the maximum entry is `0`, this results in division by zero.

An example result is:

```python
hubs = {0: -inf, 1: nan, 2: -inf}
authorities = {0: -inf, 1: nan, 2: -inf}
```

with runtime warnings about division by zero and invalid values.

### Expected Behavior

`_hits_numpy(G, normalized=False)` should return finite hub and authority scores for this graph and should not produce `inf` or `NaN` values due to the arbitrary sign of an eigenvector returned by the eigensolver.

### Steps to Reproduce

```python
import numpy as np
import networkx as nx
from networkx.algorithms.link_analysis.hits_alg import _hits_numpy

G = nx.path_graph(3)

hubs, authorities = _hits_numpy(G, normalized=False)

print("hubs:", hubs)
print("authorities:", authorities)

assert all(np.isfinite(v) for v in hubs.values())
assert all(np.isfinite(v) for v in authorities.values())
```

The assertions can fail because the current implementation contains:

```python
e, ev = np.linalg.eigh(H)
h = ev[:, np.argmax(e)]

e, ev = np.linalg.eigh(A)
a = ev[:, np.argmax(e)]

...

h /= h.max()
a /= a.max()
```

For this graph, `np.linalg.eigh` can return a dominant eigenvector such as:

```python
[-0.70710678, 0.0, -0.70710678]
```

so that:

```python
h.max() == 0.0
```

and the subsequent normalization divides by zero.

### Environment

Python version: 3.10.14
NetworkX version: current `main` (after #8859)

### Additional context

This appears to be related to the change in #8859 from `np.linalg.eig` to `np.linalg.eigh`.

Using `eigh` for the symmetric hub and authority matrices seems appropriate, but eigenvectors are only defined up to sign: if `v` is an eigenvector, `-v` is an equally valid eigenvector. Therefore, the normalization should not rely on the eigensolver returning a particular sign orientation.

Before #8859, the sign orientation returned by `np.linalg.eig` happened not to trigger this case. With `np.linalg.eigh`, the same computation can return the equivalent negative orientation, exposing the assumption in:

```python
h /= h.max()
a /= a.max()
```

One possible fix would be to canonicalize the sign of each dominant eigenvector before normalization. For example:

```python
h = ev[:, np.argmax(e)]
if h[np.argmax(np.abs(h))] < 0:
    h = -h
```

and similarly for `a`.

This preserves the eigenvector up to its arbitrary global sign while ensuring that the largest-magnitude component has a positive orientation before the existing normalization.

Alternatively, the normalization could be made explicitly independent of the sign returned by the eigensolver.

I would be happy to submit a PR with a regression test if this approach looks reasonable.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0db822700087` and running the modified tests.