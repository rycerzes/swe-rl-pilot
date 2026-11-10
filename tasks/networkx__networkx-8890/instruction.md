# Issue

**Title:** ISMAGS raises ValueError if no nodes are compatible

## Description

### Current Behavior

Hi!
If I do something silly, and ask ismags for the largest common subgraph between a graph and subgraph that have no compatible nodes due to attribute mismatches, I get presented with a fairly gnarly ValueError:

```py
graph = nx.Graph()
graph.add_nodes_from([0])

subgraph = nx.Graph()
subgraph.add_nodes_from({0: {'attr1': 0}}.items())

node_match = nx.isomorphism.categorical_node_match(['attr1'], [None])

ismags = nx.algorithms.isomorphism.ISMAGS(graph, subgraph, node_match=node_match)
symmetric = list(ismags.largest_common_subgraph(False))
```
Gives:
```
Traceback (most recent call last):
  File "/homes/peterkroon/Documents/vermouth-martinize/derp/ismags_mess.py", line 42, in <module>
    symmetric = list(ismags.largest_common_subgraph(False))
  File "/homes/peterkroon/Documents/networkx/networkx/algorithms/isomorphism/ismags.py", line 842, in largest_common_subgraph
    yield from self._largest_common_subgraph(
        candidate_sets, constraints, to_be_mapped
    )
  File "/homes/peterkroon/Documents/networkx/networkx/algorithms/isomorphism/ismags.py", line 1271, in _largest_common_subgraph
    next_sgn = min(nodes, key=lambda n: min(len(x) for x in candidates[n]))
ValueError: min() iterable argument is empty

```

### Expected Behavior
I would prefer an empty dict as answer

### Environment

NetworkX version: master branch ()

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8e0b38e1a113` and running the modified tests.