# Issue

**Title:** Add ISMAGS monomorphism support

## Description

This PR adds support for monomorphism checking with ISMAGS.
That means we can iterate over monomorphisms and get only one
morphisms for each group of morphisms that are symmetrically the same.
The symmetries are found in the subgraph and used to restrict reported
monomorphisms.

The monomorphism code is intertwined with the isomorphisms using `if` 
clauses and operator function `SG_fits` and `mono_fits` functions.
That reduces a lot of duplicate code -- but might affect performance.
I did run a profiler and found that creating `gn2_cands` was poorly behaved
so rewrote those loops. I'm sure more can be done for optimization.
But this at least gets the functionality in place. 

```release-note {label=Highlight}
The isomorphism checking suite of tools has been upgraded. The ISMAGS symmetry
aware isomorphism and subgraph isomorphism checking tools now support directed
and multigraph Graphs. And, now in addition to support for (induced) subgraph
isomorphisms, they support (non-induced subgraph) monomorphism.
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `30bfe1b2c32a` and running the modified tests.