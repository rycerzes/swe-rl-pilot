# Issue

**Title:** BUG: group betweenness centrality changes output with reorder of input group nodes

## Description

While refactoring `prominent_group`, I discovered a strange order error in `group_betweenness_centrality`. It is strange because the order should not matter for the final answer, but order apparently needs to be consistent within the double-loops over the group in the algorithm. The outer loop iterates over `group`, while the inner loop iterates over `group & Dx.keys()`. The set created by intersection can have a different order from the set `group`. So the outer loop order differs from the inner loop order.  Both of these loops are inside another loop and the order of that matters too.  We are updating `PB`, a dict-of-dict matrix of btwnness values. And the v-th diagonal value **must have all updates done for all nodes before it** for each v value.  I haven't chased down how the inner double loop depends on the order, but I've convinced myself that doing the three loops in the same order is what the algorithm in the article intended.

Only directed graphs are affected and that makes sense as PB is symmetric for undirected graphs.

Two examples that show this bug are:
```python
G = nx.path_graph(5, create_using=nx.DiGraph)
nx.add_path(G, range(6, 11))
nx.add_path(G, [3, 2, 1])  # only affects DiGraph
C = [1, 3, 7, 9]
b_order1 = nx.group_betweenness_centrality(G, C, normalized=False)  # --> 6 
C = [9, 7, 3, 1]
b_order2 = nx.group_betweenness_centrality(G, C, normalized=False) # --> 7
```
and a slightly smaller
```python
G = nx.DiGraph([(1, 0), (1, 5), (2, 0), (2, 3), (3, 2), (5, 3)])
C = [2, 3]
b_order1 = nx.group_betweenness_centrality(G, C, normalized=False)  # --> 1
C = [3, 2]
b_order2 = nx.group_betweenness_centrality(G, C, normalized=False)  # --> 6
```

The fix I chose is to use `for y in (n for n in group if n in Dx):` instead of set intersection. (intersection is a comprehension during creation of a set -- so just use the comprehension.)

The first commit introduces the tests which fails at that commit.
The second commit fixes the code so the tesst pass.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9f6079c01204` and running the modified tests.