# Issue

**Title:** ISMAGS shows wrong behaviour with edge and node match functions

## Description

After Dan's downright heroic and deeply impressive reimplementation of my ismags implementation I was looking to migrate my existing downstream code. As part of that I figured I'd run it through my testset.

### Current Behavior
```py
import networkx as nx

graph = nx.Graph()
graph.add_edges_from([(0, 1)])
subgraph = nx.Graph()
subgraph.add_node(0)

ismags = nx.algorithms.isomorphism.ISMAGS(graph, subgraph, edge_match=(lambda e1, e2: True))
print(list(ismags.find_isomorphisms()))   # -> []

ismags = nx.algorithms.isomorphism.ISMAGS(graph, subgraph, edge_match=None)
print(list(ismags.find_isomorphisms()))   # -> [{0: 0}, {1: 0}]
```
I.e. an edge matching function that states that all edges are equal behaves different from edge_match=None, which should also mean all edges are equal. Note that if subgraph *does* have an edge, both cases behave equal.

### Environment

Python version: 3.13.5
NetworkX version: 3.6.1

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e1193f66d97d` and running the modified tests.