# Issue

**Title:** tpl/collections: intersect/union/uniq collapse or drop distinct big integers beyond the float64 exact range

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
master (5698de94), built from source
</pre>

### Does this issue reproduce with the latest release?

Yes, 0.166.0 shows the same class of wrong result (see below)

### Steps to reproduce

1. render this in a layout

```
{{ intersect (slice 9007199254740993 9007199254740992) (slice 9007199254740992 9007199254740993) }}
{{ intersect (slice 9007199254740993) (slice 9007199254740993) }}
{{ in (slice 9007199254740993) 9007199254740992 }}
```

2. Expected: the first intersect returns both values bcs they are in both lists, the second returns the value, in returns false bcs the two numbers are distinct (2^53+1 vs 2^53)
3. Actual on master:

```
intersectBoth: [9007199254740992]
intersectSame: []
inDiff: true
```

9007199254740993 silently disappears from the intersect result even though it is in both lists, a value does not match itself, and two distinct numbers compare equal

on 0.166.0 the same template prints intersectBoth: [9007199254740993] and inDiff: true, so the collision is there too, just a different arm of it

the set operations key numbers through float64, so int64 values beyond 2^53 (where float64 stops being exact) collapse or get dropped depending on which path takes them, the tpl/compare consolidation (4d628bbd) already made eq and where compare numbers exactly, the set operations in tpl/collections still go through the old float64 paths

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1d87ee5b7005` and running the modified tests.