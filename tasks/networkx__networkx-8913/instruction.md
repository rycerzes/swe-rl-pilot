# Issue

**Title:** Desired semantics: chordal graphs with self-loops

## Description

What should the semantics for chordal graphs with self-loops be? Currently, an exception is raised:

```python
>>> G = nx.complete_graph(5)
>>> G.add_edge(0, 0)
>>> nx.is_chordal(G)
Traceback (most recent call last)
   ...
NetworkXError: Self loop found in _is_complete_graph()
```

where the exception message originates from an internal function (and therefore is not particularly direct/clear).

The docstring for `is_chordal` (and several internal functions) state that self-loops are ignored, but that's clearly not the case. How should self-loops be handled in this context? A few options:
 - Raise when a self-loop is found (current behavior)
 - Ignore self-loops (what the documentation currently says should happen)
 - Treat graphs with self-loops as not chordal
 - Other ideas?

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `4e74880b0da0` and running the modified tests.