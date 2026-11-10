# Issue

**Title:** Prune nested components in `k_components` reconstruction and add tests the private helpers

## Description

and its review discussion with @dschult and @rossbar. Two main things in this PR: a hardening fix in `_reconstruct_k_components` found while writing the helper-level tests, and the unit tests for the private helpers themselves. ALso a bit of house keeping: a proper doctest for k_components and removing slowest markers for `test_kcomponents.py`.

## Reconstruction could emit a nested, non-maximal component

A single `_consolidate` pass merges sets on pairwise overlaps of at least k nodes, so its output can still contain a set nested inside a merged one. Concretely: a component propagated down from level k+1 that shares fewer than k nodes with each of two level-k candidates is not merged with either of them, yet when those two candidates merge with *each other* it ends up a strict subset of their union. A nested set is never a maximal k-connected subgraph, so it should not appear in the decomposition.

Minimal input that reproduces the bug at `test_reconstruct_k_components_drops_nested_candidate`, this test **fails on current main and passes on this branch**: at level 4, candidates `A = {1..8}` and `B = {5..12}` share four nodes, so they consolidate into `A | B`. The level-5 component `c = {2, 3, 4, 9, 10, 11}` propagates down to level 4 but shares only three nodes with each of A and B, so it merges with neither; and lands as a strict subset of `A | B` in the output.

## Unit tests for the private helpers

As discussed in the #8734 review: both bugs fixed there lived in private helpers (`_generate_partition`, `_reconstruct_k_components`) whose contracts were only implicit, and neither was reachable by end-to-end tests on the small classic graphs alone. This PR adds direct unit tests that state the contracts:

- `_reconstruct_k_components`:
  - propagates a (k+1)-level component that spans several k-level candidates without being a subset of any of them (the #8734 fix; the pre-fix union-coverage check fails this test),
  - drops a propagated component that ends up nested inside a consolidated merge (`test_reconstruct_k_components_drops_nested_candidate`, the fix in this PR: fails on current main, passes here),
  - never returns a level containing a component that is a strict subset of another at the same level.
- `_generate_partition`, checked over the biconnected components of the karate club, Davis Southern Women, and two seeded G(n, p) graphs:
  - never loses a node (the #8734 bug 1 failure mode: every cutset node has a neighbor outside the cutset, or the cutset would not be minimum),
  - every part is a strict subset of the input part (the recursion's termination argument),
  - every part induces a connected subgraph.

## Slow markers removed

The three `pytest.mark.slow` markers in this test file predate the `all_node_cuts` fix, which is what made these tests slow in the first place. They are fast now (the whole file runs in under 2 seconds with `--runslow`, and the slowest single test (`test_random_gnp[50-0.2]`) takes 0.96s) so the markers are removed and the `k_components` suite runs complete by default.

## Doctest

The `k_components` docstring example claimed the Petersen graph result in a comment; it is now a real doctest asserting it.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b1f956344071` and running the modified tests.