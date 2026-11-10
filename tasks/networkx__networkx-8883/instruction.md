# Issue

**Title:** BUG: correct normalization of group betweenness centrality when endpoints is true

## Description

The keyword `endpoints` in `group_betweenness_centrality` does more than what "endpoints" does for `betweenness_centrality`.  This PR makes it more clear what `endpoints=True` implies and corrects a mistake in the normalization in this case.

In `betweenness_centrality` the `endpoints` keyword causes node-pairs (and their paths) to count as "passing through" the path's endpoints. So a node counts as "between" itself and any other node. [call this the **endpoints rule**]

In `group_betweenness_centrality` the keyword `endpoints=True` tells us to use **endpoints rule**, but also tells us to examine node-pairs from all nodes rather than only node-pairs from outside `C`. So paths that start or end in `C` are now counted. [call this **all_node_pairs rule**].

I think these two rules are orthogonal, but we haven't implemented all combinations. The default (`endpoints=False`) only considers node-pairs that are outside `C`. It doesn't use the **all_node_pairs rule**. Note that when we consider only paths with endpoints outside `C`, then it doesn't matter whether or not we include the endpoints. All the endpoints are not in `C` by design. So the **endpoints rule** is irrelevant when we don't use the **all_node_pairs rule**.

But if we do use the **all_node_pairs rule**, then we have to figure out how to count the node-pairs that start/end in `C`. Currently, our `endpoints` keyword turns on both **all_node_pairs rule** and **endpoints rule**. So every node-pair that involves a node from `C` counts as passing through `C`.  We don't even have to look beyond connectivity. If `C` has `N_{in}` nodes and is connected, we will add `N_{in}(N_{in}-1)` paths to the raw score. If `C` is not (strongly)connected, we have to count how many node-pairs are reachable. But we don't have to look at the shortest paths because we know an endpoint is in `C`. Even after normalizing, there is a positive minimum centrality score for the group based on its size even if no other paths pass through it. This is a strange way to measure betweenness.

Brandes argues that sometimes we want the original sender of the information to be included in the "between" category. After-all they know the information and have to do some work to send it. That's a good argument for the **endpoints rule**, but it doesn't do much to help us justify the **all_node_pairs rule**. None of the papers other than the Brandes paper use the **all_node_pairs rule**, so the **endpoints rule** is irrelevant.

The option missing from the discussion is to allow the **all_node_pairs rule** while turning off the **endpoints rule**.  So, we count paths between any node pairs if the interior of the path involves anode in `C`. Endpoints are not considered as "between" nodes on the path. But paths from/to nodes in `C` do get counted if another node from `C` lies on the shortest path.  I haven't seen this discussed anywhere. It comes up because it completes the set of options we could offer. It might model a group that is crucial to propagating information even within the group. We don't care about sending/receiving, only propagating. And we care about both within-group paths and paths from/to nodes outside the group. I'm not sure how hard this would be to do.

This PR does NOT implement any such system for group betweenness centrality. It just makes the docs more clear about what `endpoints=True` means. And it corrects the normalization for that case.

Normalization:  The normalization divides by the maximal number of node-pairs that could be counted. That is `N(N-1)` when using the **all_node_pairs rule** and `N_{out}(N_{out}-1)` otherwise. Current code uses the same factor whether endpoints is True or False. This PR changes the scaling for normalizing the `endpoints=True` case to `N(N-1)`. 

Still to do:
- [ ] propagate these test changes to `prominent_group_*`, `group_degree_*` and `group_closeness_*`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8e0b38e1a113` and running the modified tests.