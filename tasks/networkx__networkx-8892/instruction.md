# Issue

**Title:** BUG: Hold the graph weakly in cached edge and degree views

## Description

We ran into https://github.com/networkx/networkx/discussions/7697 in one of our services too!
This was raised in  too and unsetting the cached_property was the solution in the dowstream package, but I want to bring this up again and just wanted to understand if we can just use something like `weakref` to avoid depending on the cyclic garbage collector in CPython to clean up networkx graphs. A quick example to show the cyclic issue

```python
>>> import gc, weakref, networkx as nx
>>> gc.disable()
>>> G = nx.DiGraph([(0, 1)])
>>> r = weakref.ref(G)
>>> G.number_of_edges()
>>> del G
>>> print(r() is None)
```

will lead to `False` on main branch and `True` after this change.

A claude generated minimal reproduction which kind of matches our issues in task graphs that holds arrays in graph nodes.

```python
import gc, resource, sys, numpy as np, networkx as nx
mb = (1 << 20) if sys.platform == "darwin" else 1024
state, resident = [], []
for i in range(40):
    G = nx.path_graph(5)                                # a small task graph...
    G.graph["payload"] = np.full(30_000_000 // 8, 1.0)  # ...carrying 30 MB (untracked: invisible to the GC counters)
    G.number_of_edges()                                 # any view read: G is now in a cycle with its cached view
    state.extend([i] for i in range(4000))              # surviving allocations (a growing accumulator); the young sweeps they trigger promote G
    for _ in range(100_000): tmp = [0]                  # the rest of the work allocates and discards -> nets to zero on the GC counters
    resident.append(sum(isinstance(o, nx.Graph) for o in gc.get_objects()) - 1)
print("dead graphs resident, every 5th iteration:", resident[::5], "| final:", resident[-1])
print("automatic gen-2 sweeps:", gc.get_stats()[2]["collections"], "| peak RSS: %d MB" % (resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / mb))
```

| | dead graphs resident, every 5th iteration | final | gen-2 sweeps | peak RSS |
|---|---|---|---|---|
| `main`, 3.13 (= 3.14.5+) | `[0, 5, 5, 5, 5, 5, 5, 10]` | 9 | 0 | 415 MB |
| `main`, 3.12 | `[0, 3, 2, 4, 7, 9, 0, 3]` | 5 | 2 | 448 MB |
| this PR | `[0, 0, 0, 0, 0, 0, 0, 0]` | 0 | 0 | 95 MB |

#3011 and #5614 should also have some more context.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8e0b38e1a113` and running the modified tests.