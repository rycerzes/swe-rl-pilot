# Issue

**Title:** [BUG][PERF] Fix ISMAGS directed matching and monomorphism overhead

## Description

Fix a few ISMAGS issues found after #8838, with one commit per fix:

- `0be5f6ab4`: Apply the candidate sets for incoming edges. These were computed but not used, allowing incorrect mappings for directed graphs. Add tests for edge existence, edge colors and multiedge counts.
- `e6a85d93b`: Skip computing `not_gn_nbrs` when finding monomorphisms. Nonneighbors only need to be checked for isomorphism and induced subgraph isomorphism.
- `4ade591e4`: Fix a test assertion that always passed for `Graph` and `DiGraph` without checking the number of mappings.
- `8f31c83b0`: Clarify the monomorphism docstrings and add an example showing how symmetries of the subgraph affect the number of mappings.
- `aa6d9a2ab`: Remove the unused `self_ge_partition` variable.

For example, this used to return `True`, although `G` contains no directed cycle of length 3:

```python
G = nx.DiGraph([(1, 3), (2, 3), (3, 1), (3, 2)])
S = nx.DiGraph([(0, 1), (1, 2), (2, 0)])
nx.isomorphism.ISMAGS(G, S).subgraph_is_isomorphic()  # Now False
```

Finding all monomorphisms of `path_graph(2)` in `path_graph(10000)` took 2.78 s before and 0.15 s after, with the same 19,998 mappings (median of three runs, Python 3.14, `symmetry=False`).

Tests: 1,568 passed, 740 expected failures; all pre-commit checks passed.

AI assisted with the changes, which were checked with regression tests, doctests and benchmarks.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0db822700087` and running the modified tests.