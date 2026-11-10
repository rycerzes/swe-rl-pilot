# Issue

**Title:** `group_betweenness_centrality` returns negative values on directed non-strongly-connected graphs

## Description

group_betweenness_centrality produces incorrect results on directed graphs that are not strongly connected. In the worst case it returns negative values, which are mathematically impossible for betweenness centrality.

Additionally, multi-node groups on such graphs crash with a KeyError.

### Expected Behavior
For a single-node group {v}, group_betweenness_centrality(G, {v}) should equal betweenness_centrality(G)[v] -- they are the same quantity by definition. This holds on undirected and strongly-connected directed graphs but fails on directed graphs that are not strongly connected.

### Steps to Reproduce

```python
import networkx as nx

G = nx.path_graph(4, create_using=nx.DiGraph)  # 0->1->2->3
per_node = nx.betweenness_centrality(G, normalized=False, endpoints=False)

for v in G.nodes():
    gv = nx.group_betweenness_centrality(G, {v}, normalized=False, endpoints=False)
    print(f"node {v}: per_node={per_node[v]:.1f}  group={gv:.1f}")

# Multi-node group crashes:
nx.group_betweenness_centrality(G, {0, 2}, normalized=False, endpoints=False)
```

Both bad results and crashes:
```
node 0: per_node=0.0  group=-3.0
node 1: per_node=2.0  group=1.0
node 2: per_node=2.0  group=3.0
node 3: per_node=0.0  group=3.0
Traceback (most recent call last):
  File "/Users/selman.ozleyen/projects/rustworkx/nx_group_betweenness_bug.py", line 11, in <module>
    nx.group_betweenness_centrality(G, {0, 2}, normalized=False, endpoints=False)
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "<class 'networkx.utils.decorators.argmap'> compilation 29", line 3, in argmap_group_betweenness_centrality_26
    import gzip
            ^^^
  File "/Users/selman.ozleyen/projects/rustworkx/.venv/lib/python3.13/site-packages/networkx/utils/backends.py", line 551, in _call_if_no_backends_installed
    return self.orig_func(*args, **kwargs)
           ~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^
  File "/Users/selman.ozleyen/projects/rustworkx/.venv/lib/python3.13/site-packages/networkx/algorithms/centrality/group.py", line 149, in group_betweenness_centrality
    if D[x][v] == D[x][y] + D[y][v]:
                            ~~~~^^^
KeyError: 0
```

### Environment

```
Environment
NetworkX: main branch (3.7rc0.dev0, ). Same on 3.6.1.
Python: 3.13
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `73cb92bbaed1` and running the modified tests.