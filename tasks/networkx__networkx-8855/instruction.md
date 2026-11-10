# Issue

**Title:** `p2g` module does not lazy-load

## Description

Just something I noticed while reviewing other PRs - this is the first instance since the adoption of lazy-importing that a module defined in the source tree isn't accessible viz lazy-import:

```python
>>> import networkx as nx
>>> nx.readwrite.p2g
Traceback (most recent call last)
   ...
AttributeError: module 'networkx.readwrite' has no attribute 'p2g'

# Module successfully discoverable after explicit import
>>> import networkx.readwrite.p2g
>>> nx.readwrite.p2g
<module 'networkx.readwrite.p2g' from ...
```

I haven't taken the time to chase this down - it's possible that making `p2g` less discoverable was intentional.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1dda6d2fa692` and running the modified tests.