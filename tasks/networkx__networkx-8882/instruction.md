# Issue

**Title:** BUG: Handle KeyErrors in directed not strongly-connected group_betweenness_centrality

## Description

This PR tests and fixes KeyErrors in using the `D` dict-of-dicts for group_betweenness_centrality.
The first commit adds the test -- I was pleased to find that a path graph with the group being an
interior 3-path segment tested all the KeyErrors needed.

**The fix:**    (Note: I use e.g. `Dv = D[v]`, to pre-lookup and name the outer dicts)
D[x][y] is needed for all 3 cases where adjustment of counts occurs.
So I made the for-loop over `y` only loop over keys in `D[x]` (and in the group). 
The case `D[y][x]` is not used. We are looking for where `v` fits into a path from `x` to `y`.
So we don't care about `y` to `x`. Note that the loop will cover the `y` to `x` path
eventually with the names switched. So we do get that case in another iteration of the loop.

Of the remaining cases, `x_in_Dv` and `v_in_Dx` are stored in the middle loop (where x and v are known).
Then `y_in_Dv` and `v_in_Dy` are stored in the inner loop. Neither of these save much time -- but I found it
much easier to read `y_in_Dx` than `y in Dx` next to the rest of the multiple phrase if-condition. 
The underscores hold that operation together -- and there could be a very small help from pre-computing.

The resulting lines are like:
`if x_in_Dv and Dv[y] == Dv[x] + Dx[y] and sig_vy:`
A nearby comment points out that `y_in_Dv` must hold if `x_in_Dv`. The reason is that y is a descendant of x. So if x is a descendant of v, y is also a descendant of v. So we only need one `D` membership check in the first two cases and two checks in the third case. The `sig_vy` part of the if-condition ensures that we skip when division by zero would occur.

This treatment allows the tests to pass!

Also note that we recently included the example from #8666 by @amcandio as a test. It is passing here without KeyError (and with the correct value of `1` instead of `3`). That bug was already fixed before this PR. But that test raised a KeyError in #8854 and doesn't with this approach.

We still have on our list these two points:
- [ ] Discover the meaning of keyword `endpoints=True` and figure out how to make it meaningful, or remove that option.
- [ ] propagate these test changes to `prominent_group_*`, `group_degree_*` and `group_closeness_*`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `c279073cc33d` and running the modified tests.