# Issue

**Title:** Raise NetworkXError on unknown attribute class in GEXF reader

## Description

#### What does this implement/fix?

`GEXFReader` dispatches on the `class` attribute of each `<attributes>` element and ends the chain with a bare `raise` outside of an exception handler (`networkx/readwrite/gexf.py:835`). Reading a file whose `<attributes>` element carries any other class — or no class at all — therefore fails with

```
RuntimeError: No active exception to reraise
```

Reproduction on `main`:

```python
import io, networkx as nx

s = """<?xml version="1.0" encoding="UTF-8"?>
<gexf xmlns="http://www.gexf.net/1.2draft" version="1.2">
  <graph mode="static" defaultedgetype="undirected">
    <attributes class="graph">
      <attribute id="0" title="url" type="string"/>
    </attributes>
    <nodes><node id="0" label="a"/><node id="1" label="b"/></nodes>
    <edges><edge id="0" source="0" target="1"/></edges>
  </graph>
</gexf>"""

nx.read_gexf(io.StringIO(s))
# RuntimeError: No active exception to reraise
```

Dropping `class="graph"` to just `<attributes>` gives the same result.

This replaces the bare `raise` with `NetworkXError`, naming the offending class, which is what the rest of the module does for malformed input (`Unknown GEXF version`, `No <graph> element in GEXF file.`, `Undirected edge found in directed graph.`). The test covers both the unknown-class and the missing-class case; it fails with `RuntimeError` on `main` and passes with the fix. `networkx/readwrite/tests/test_gexf.py` is otherwise unchanged: 33 passed, 1 skipped.

#### Additional information

Per the Automated Contributions Policy — AI assistance was used on this PR. Tool: Claude Opus (Claude Code). Scope: it ran the static-analysis sweep that surfaced the bare `raise`, wrote the one-line fix and the test, and ran the test suite. I read the diff and the reproduction before submitting and can explain the change.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `f884a12db34c` and running the modified tests.