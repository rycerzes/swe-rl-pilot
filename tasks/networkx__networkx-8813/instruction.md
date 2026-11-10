# Issue

**Title:** vf2pp_isomorphism returns mappings in the reverse direction after #8506

## Description

After #8506, vf2pp_isomorphism(G1, G2) and vf2pp_all_isomorphisms(G1, G2) return mappings from nodes in G2 to nodes in G1.

Previously, these functions returned mappings from G1 to G2.

For example, the mapping direction changed from:

{1: "a", 2: "b", 3: "c"}

to:

{"a": 1, "b": 2, "c": 3}

This breaks code that indexes the result using nodes from the first input graph, for example:

mapping[node_from_G1]

which now raises a KeyError.

Expected Behavior

The existing full-graph isomorphism functions should continue to return mappings from the first input graph to the second input graph:

G1 node -> G2 node

In particular, the keys of the mapping returned by:

nx.vf2pp_isomorphism(G1, G2)

should be nodes from G1, and its values should be nodes from G2.

The same should hold for every mapping yielded by:

nx.vf2pp_all_isomorphisms(G1, G2)
Steps to Reproduce
import networkx as nx

G1 = nx.Graph(
    [
        (1, 2),
        (2, 3),
        (3, 4),
        (4, 1),
    ]
)

G2 = nx.Graph(
    [
        ("a", "b"),
        ("b", "c"),
        ("c", "d"),
        ("d", "a"),
    ]
)

mapping = nx.vf2pp_isomorphism(G1, G2)

print("mapping:", mapping)
print("keys:", set(mapping))
print("values:", set(mapping.values()))

assert set(mapping) == set(G1)
assert set(mapping.values()) == set(G2)

for node in G1:
    print(node, "->", mapping[node])

Before #8506, the assertions pass.

At , the returned mapping has nodes from G2 as keys. The first assertion therefore fails, and indexing the mapping with a node from G1 raises a KeyError.

The same direction change occurs for vf2pp_all_isomorphisms:

for mapping in nx.vf2pp_all_isomorphisms(G1, G2):
    assert set(mapping) == set(G1)
    assert set(mapping.values()) == set(G2)
Environment

Python version: 3.10

NetworkX version: 3.7rc0.dev0 (main)

Originally reproduced at commit:

Additional Context

The existence of an isomorphism is symmetric, but the direction of the returned mapping is observable behavior.

Code using the previous G1 -> G2 mapping direction may fail even though the two graphs are still correctly identified as isomorphic.

The new subgraph and monomorphism APIs may require a different internal graph order, but it would be helpful for the existing full-graph APIs to preserve their previous mapping direction.

The reversed mapping direction is also present in the current `main` branch (`3.7rc0.dev0`).

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `f884a12db34c` and running the modified tests.