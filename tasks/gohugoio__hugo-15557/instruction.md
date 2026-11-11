# Issue

**Title:** sort leaves items unsorted when some of them lack the sort key

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
Built from master at 8502b60 (v0.170.0-DEV), go1.27.3 windows/amd64.
</pre>

### Does this issue reproduce with the latest release?

I reproduced it on master only. `tpl/collections/sort.go` has not changed since before v0.169.0, so I expect v0.169.0 behaves the same.

### What happened

When some items in a collection don't have the key you sort by, `sort` returns the items in their original order, for both ascending and descending:

```
-- hugo.toml --
-- layouts/home.html --
{{ $values := slice (dict "t" "b") (dict "x" 1) (dict "t" "a") }}
Asc: {{ sort $values "t" }}
Desc: {{ sort $values "t" "desc" }}
Pages: {{ range sort site.RegularPages "Params.color" }}{{ .Title }}|{{ end }}
-- content/p1.md --
---
title: p1
params:
  color: blue
---
-- content/p2.md --
---
title: p2
---
-- content/p3.md --
---
title: p3
params:
  color: azure
---
```

Actual:

```
Asc: [map[t:b] map[x:1] map[t:a]]
Desc: [map[t:b] map[x:1] map[t:a]]
Pages: p1|p2|p3|
```

Expected (a missing key sorts as the zero value, as the code intends):

```
Asc: [map[x:1] map[t:a] map[t:b]]
Desc: [map[t:b] map[t:a] map[x:1]]
Pages: p2|p3|p1|
```

### Cause

In `pairList.Less`, when one side's key is missing, the other side is compared against `reflect.Zero(iv.Type())`, which passes the `reflect.Value` itself rather than the zero value it holds. For map values `iv` also has the interface type, so its zero value is nil. Either way the missing item compares equal to every string, and the sort leaves the order as it was.

I have a fix with an integration test and can open a PR if this is accepted as a bug.

I used Claude Code to find this and write this report.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `2d6cf3a851f3` and running the modified tests.