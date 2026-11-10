# Issue

**Title:** capacity_scaling returns a zero-cost infeasible flow instead of raising NetworkXUnfeasible

## Description

networkx 3.7 and main (92f497e).

```python
import networkx as nx
G = nx.DiGraph()
G.add_node(0, demand=1)
G.add_node(1, demand=-1)
G.add_edge(1, 0, capacity=0, weight=1)

nx.network_simplex(G)   # raises NetworkXUnfeasible (correct)
nx.min_cost_flow(G)     # raises NetworkXUnfeasible (correct)
nx.capacity_scaling(G)  # returns (0, {0: {}, 1: {0: 0}}), no exception
```

The returned flow does not meet the demands (net flow 0 at both nodes vs demands 1 and -1). The graph is weakly connected and the demands sum to zero. The docstring says NetworkXUnfeasible is raised when "There is no flow satisfying all demand" (capacityscaling.py:228). A graph with the same two demands and no edges at all behaves the same way.

Cause: the "Residual network has no edges" early return (capacityscaling.py:297-300) fires before the excess check at capacityscaling.py:396-397, so the infeasibility is never detected.

(Found with the help of an AI code-auditing agent; I reran the reproducer above on 3.7.)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e59d71890e74` and running the modified tests.