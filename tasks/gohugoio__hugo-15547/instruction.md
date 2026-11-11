# Issue

**Title:** resources.Concat: Accept a []any containing only resources

## Description

Reference: <https://discourse.gohugo.io/t/using-apply-to-convert-a-slice-of-strings-into-resources/25582>

```go-html-template
{{ $ss := slice "a.js" "b.js" "c.js" }}
{{ $sr := collections.Apply $ss "resources.Get" . }}
{{ $r := resources.Concat "bundle.js" $sr }}
```

```text
error calling Concat: expected slice of Resource objects, received []interface {} instead
```

`collections.Apply` always returns `[]any`. `page.ToPages` already accepts a `[]any` of pages; `resources.Concat` could do the same for resources.

Tested with: hugo v0.170.0-DEV-7ff95e04

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fe34313e88a4` and running the modified tests.