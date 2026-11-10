# Issue

**Title:** group_betweenness_centrality is inaccurate for groups of 3+ nodes, even on connected graphs

## Description

Split out of #8559, which is about directed graphs that are not strongly connected. This one is independent of reachability: it shows up on plain connected undirected graphs and on strongly connected digraphs.

## Reproduction

```python
import itertools
import networkx as nx

G = nx.Graph([(0, 1), (0, 2), (0, 3), (0, 4), (1, 3), (2, 3), (2, 4), (3, 4), (4, 5)])
assert nx.is_connected(G)

C = {0, 1, 2}
print(nx.group_betweenness_centrality(G, C, normalized=False, endpoints=False))
# 0.125
```

The true value is `0.0`. The non-group nodes are 3, 4 and 5, and no shortest path between them has an interior node in `C`:

- `3 - 4` is an edge,
- `4 - 5` is an edge,
- `3 - 4 - 5` is the only shortest 3–5 path, and its only interior node is 4.

## Scope

Comparing against a brute-force group betweenness (sum over ordered pairs of non-group nodes of the fraction of shortest paths with an interior node in the group) over random graphs of 4–7 nodes:

| graph | connectivity | \|C\| | cases | disagreements |
|---|---|---|---|---|
| undirected | connected | 1 | 151 | 0 |
| undirected | connected | 2 | 168 | 0 |
| undirected | connected | 3 | 162 | 19 |
| undirected | disconnected | 1–3 | 533 | 0 |
| directed | strongly connected | 1 | 100 | 0 |
| directed | strongly connected | 2 | 114 | 0 |
| directed | strongly connected | 3 | 108 | 34 |

Sizes 1 and 2 are exact everywhere; the errors begin at size 3. That matches where the sequential peeling in `group_betweenness_centrality` first has to work on an already-peeled state: the loop updates `sigma_m` and `PB_m` as each group node is removed, but keeps testing the distance identities against the original `D` from `_group_preprocessing`. Distances among the remaining nodes can change once a node is removed, so from the third removal on the recurrences are applied under conditions that no longer hold.

I have not tried to fix this — it needs a look at the underlying recurrences from Puzis et al. rather than a local patch, and the errors are small and value-dependent rather than a crash.

`prominent_group` builds on the same code path and is likely affected for `k >= 3`.

## Environment

- NetworkX `main` (3.7rc0.dev0)
- Python 3.12

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `73cb92bbaed1` and running the modified tests.