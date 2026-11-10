# Issue

**Title:** BUG: Fix node connectivity and node cuts for digraphs

## Description

`node_connectivity`, `minimum_node_cut` and `minimum_st_node_cut` return wrong results on directed graphs. `node_connectivity` is also wrong on graphs with self-loops or parallel edges, and `minimum_node_cut` on graphs with self-loops. `minimum_node_cut` can return a set that is not a cut at all.

As an illustration of the bugs:

```python
>>> import networkx as nx

>>> # a directed triangle has node connectivity 1
>>> nx.minimum_node_cut(nx.DiGraph([(0, 1), (1, 2), (2, 0)]))
set()

>>> # weakly but not strongly connected, so the node connectivity is 0
>>> nx.node_connectivity(nx.DiGraph([(0, 3), (1, 2), (2, 1), (3, 0), (3, 1), (3, 2)]))
1

>>> # K5 has node connectivity 4, self-loops should not change that
>>> G = nx.complete_graph(5)
>>> G.add_edges_from((u, u) for u in G)
>>> nx.node_connectivity(G)
6
```

All three functions implement algorithm 11 of Esfahanian's *Connectivity Algorithms* (cited in the docstrings), which is from Esfahanian and Hakimi (Networks 14:355-366, 1984). That algorithm is stated for **undirected graphs only**; section 4 of the chapter and section III of the 1984 paper never mention digraphs. When I implemented this for NetworkX in 2012 it seems that I just derived the implementation for digraphs, and introduced 5 bugs in doing so:

1. **Starting node chosen by total degree.** Node connectivity of a digraph is bounded by the smaller of the in-degree and the out-degree, since isolating a node only requires removing all its predecessors *or* all its successors.

2. **Initial cutset from successors only.** `minimum_node_cut` used `set(G[v])`, which does not isolate a node that also has predecessors and is empty for a node without successors.

3. **Duplicated neighbors.** Predecessors and successors were chained without deduplication, so a node that is both was yielded twice and paired with itself.

4. **`minimum_st_node_cut` checked on both arc directions.** It returned the empty set when `G.has_edge(s, t) or G.has_edge(t, s)`. An arc from `t` to `s` is not an `s`-`t` path and does not stop `s` from being separated from `t`. `minimum_node_cut` then accepted that empty set as a smaller cut.

5. **Starting node only ever used as the source.** Node connectivity of a digraph is a minimum over *ordered* pairs and the two orders need not agree, so when the starting node lay on the target side of every minimum cut the smallest value was never computed.

Bugs 1 and 3 also affect self-loops and parallel edges: they inflate the initial bound, and on a complete graph no pair of nodes is left to lower it again, so the inflated value is returned.

In order to fix bug 5 I checked the literature and found that Even and Tarjan, *Network Flow and Testing Graph Connectivity* (SIAM J. Comput. 4(4):507-518, 1975), p. 513 say:

> In case G is a directed graph, similar definitions and approach lead to the
> same result, except that for each v1, v2, ..., vk, we compute **both
> N(vi, v) and N(v, vi)** (which are now not necessarily the same) for each
> applicable v.

and its footnote 7, which is exactly the rule in bug 4:

> If there is an edge from vi to v, N(vi, v) is not computed, and if there is an
> edge from v to vi, N(v, vi) is not computed.

Even and Tarjan paper is now cited in the docstrings of all three functions.

These fixes have an impact on public functions:

* `minimum_st_node_cut` changes behavior on digraphs. Where the pair is joined only by an arc from target to source, it now returns a real cut instead of `set()`. Undirected graphs are unaffected.

* `minimum_node_cut` may also return a *different* minimum cut than before on some digraphs. It is still a minimum cut and the concrete cut returned was already dependent on iteration order.

I found all these bugs while working on a pre-filter proposed for node_connectivity by Sinkovits (ICCS 2021) which provides a 2.5x-52x speedup while being also exact. Some tests for digraphs failed and that got me into this rabbit hole.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `30bfe1b2c32a` and running the modified tests.