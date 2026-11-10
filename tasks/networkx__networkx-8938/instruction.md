# Issue

**Title:** BUG: Prominent group refactor and correction of betweenness values

## Description

Fix and refactor `prominent_group`. This is a follow-up to the group betweenness centrality PRs #8881, #8882, #8883 and #8931, #8932.

The `prominent_group` function used a combination of recursive
function calls along with a queue storing all the layers of 
the recursion (instead of letting the function calls store the
layers). This PR removes the recursive function calls and
uses the queue directly.

The `prominent_group` function converted the dict info from shortest
paths to pandas and numpy data structures in order to manipulate
the data in a way that is easier done with dict structure in the
first place. e.g. `np.diag(GBC)` is written `{n: GBC[n][n] for n in G}`.
This PR removes `numpy` and `pandas` and uses the dicts directly.

This PR also implements the changes made in group betweenness
into the prominent group code so we 
- fix the errors for `normalized=True` while `endpoints=True`
- fixes the KeyErrors that arise with some disconnected directed graphs.

The tests now include a `prominent_group_brute_force` function which
just tries all possible groups to find the max. That gives us a "ground truth"
for small graphs.

I still have a few pretty serious reservations about the whole Group Betweenness Centrality code. 
- the prominent_group code doesn't return the best group in many cases (low %age, but still many). The graph atlas test (currently marked xfail) fails on many of those disconnected graphs.
- The path betweenness, `PB`, variable sometimes holds negative values. It is defined as a sum of positive numbers so should never be <0.
- The paper makes clear that when more than one of the if-clauses for the 3 orderings v-x-y, x-v-y, x-y-v passes, only one should be chosen. The statement is strange since directed graphs can certainly have both
cases when they both need to be updated. And selecting only one causes tests to fail. Perhaps they meant to only talk about undirected graphs and the case of interest was when x=v or y=v. 

I still think its worth merging these changes as it allows `prominent_group` to
match the changes made in August for GBC. It also makes the code noticeably
faster for running tests (and after adding more tests too). But I'd like to come back to it -- or have someone come back to it :) It'd be good to figure out why prominent_group doesn't find the best group.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `92f497e2eb81` and running the modified tests.