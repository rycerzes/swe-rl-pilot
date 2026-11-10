# Issue

**Title:** BUG: group betweenness gives incorrect values for undirected connected graph

## Description

This splits off the simplest bug reported in #8666 and #8559 and fixes it. Related discussion in #8827.
I'm hoping splitting these up makes review simple.

The bug is that `sigma` is used instead of `sigma_m` in two places where the symmetry of the formulas makes it clear that it should have been `sigma_m`.  This corrects an easily checked test where no shortest paths between non-group nodes pass through the group. So `GBC==0`.  It was giving `0.125`.

I also added a test that checks many groups at once and compares singleton groups with the BC values from `betweenness_centrality`  to ensure they are the same.  That test passes before or after this fix, but I found it helpful to see that symmetry so I included it in this PR.

Upcoming PRs: (todo list)
- [x] test and fix the subtraction of paths with an endpoint in the group so it works for directed graphs that aren't strongly connected. #8880
- [x] test and fix the bug of skipping all 3 adjustments when any denominator is zero (should only skip the one with zero denominator). #8881
- [ ] test and fix cases where not strongly connected directed graphs give KeyErrors. #8882
- [ ] Discover the meaning of keyword `endpoints=True` and figure out how to make it meaningful, or remove that option.
- [ ] propagate these test changes to `prominent_group_*`, `group_degree_*` and `group_closeness_*`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e8981d030808` and running the modified tests.