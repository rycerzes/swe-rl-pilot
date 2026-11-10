# Issue

**Title:** GraphMatcher.isomorphsism_iter() can yield isomorphisms for non-isomorphic graphs

## Description

### Current Behavior

The following code (using Networkx 3.6):

```
import networkx as nx
from networkx.algorithms import isomorphism

mg1 = nx.Graph()
mg1.add_node(1)
mg1.add_node(2)

mg2 = nx.Graph()
mg2.add_node(1)

gm = isomorphism.GraphMatcher(mg1,mg2)

print(gm.is_isomorphic())

for iso in gm.isomorphisms_iter():
    print(iso)

```
Produces the following output:
False
{1: 1}
{2: 1}

So GraphMatcher.is_isomorphic correctly reports that the two graphs are not isomorphic, but the generator yields two mappings, nonetheless. Of course, neither of these mappings are isomorphisms.  

### Expected Behavior

The expected behaviour would be that the code above produces just:
False
as output, ie no isomorphisms should be yielded for non-isomorphic graphs.

GraphMatcher.isomorphsism_iter() should only yield isomorphisms

### Steps to Reproduce

The code above produces this bug.

### Environment

Python 3.11
Network 3.6
Linux

Python version:
NetworkX version:

### Additional context

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9979772bb51f` and running the modified tests.