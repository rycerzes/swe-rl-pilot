# Issue

**Title:** Computing normalized rich-club coefficient may lead to `ZeroDivisionError`

## Description

### Current Behavior
In certain instances, computation of the normalised rich club coefficient may lead to a `ZeroDivisionError`. This is more likely to happen for sparse graphs with a relatively low number of high-degree nodes. 

The `ZeroDivisionError` occurs as part of the normalisation in `rich_club_coefficient` when the rich club coefficent is 0 for the randomised graph but not for the original graph:

https://github.com/networkx/networkx/blob//networkx/algorithms/richclub.py#L99

### Expected Behavior
The referenced works by McAuley et al. and Milo et al. are not explicit about this phenomenon. Two main suggestions for resolving the bug can be found below. 

**Option 1**: Returning `NaN` values for unclear values:

```diff
- rc = {k: v / rcran[k] for k, v in rc.items()}
+ rc = {k: v / rcran[k] if rcran[k] != 0 else math.nan for k, v in rc.items()}
```

**Option 2**: Reducing the length of the returned array in case the randomised graph has zero values:
```diff
+ rc = rc[:next((i for i, x in enumerate(rcran) if x == 0), len(rcran))]
```

### Steps to Reproduce

A minimum example can be found below:

```py
graph = networkx.Graph(directed=False)
graph.add_node("A")
graph.add_node("A_1")
graph.add_node("A_2")
graph.add_node("B")
graph.add_node("B_1")
graph.add_node("B_2")
graph.add_node("C")
graph.add_node("D")
graph.add_edge("A", "A_1")
graph.add_edge("A", "A_2")
graph.add_edge("B", "B_1")
graph.add_edge("B", "B_2")
graph.add_edge("A", "B")
graph.add_edge("C", "D")

for i in range(1000):
    networkx.rich_club_coefficient(graph, normalized=True, Q=1)
```

### Environment
Python version: 3.13.7
NetworkX version: 3.2.1

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3b4c227fda1c` and running the modified tests.