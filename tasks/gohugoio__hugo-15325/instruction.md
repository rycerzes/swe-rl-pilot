# Issue

**Title:** tpl/compare: eq, le and ge disagree when comparing an int with an equal float

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.166.0-DEV- darwin/arm64
</pre>

### Does this issue reproduce with the latest release?

I built `master` at `ae07063` and reproduced it there. I did not run a tagged release binary, so I have not confirmed it against one directly, though the code path is unchanged in `tpl/compare/compare.go`.

### What did you expect to see?

`eq`, `ne`, `lt`, `le`, `gt` and `ge` agreeing with each other. Whatever the rule for comparing an `int` against a `float`, exactly one of `lt`/`eq`/`gt` should hold for a given pair, `le` should mean `lt or eq`, and `ge` should mean `gt or eq`.

### What did you see instead?

For `1` against `1.0`, the six functions contradict each other. `le` and `ge` are both true while `lt`, `gt` and `eq` are all false, so the value is reported as neither less than, nor greater than, nor equal to itself.

`layouts/index.html`:

```go-html-template
eq  1 1.0 = {{ eq 1 1.0 }}
ne  1 1.0 = {{ ne 1 1.0 }}
lt  1 1.0 = {{ lt 1 1.0 }}
le  1 1.0 = {{ le 1 1.0 }}
gt  1 1.0 = {{ gt 1 1.0 }}
ge  1 1.0 = {{ ge 1 1.0 }}
```

Rendered output:

```
eq  1 1.0 = false
ne  1 1.0 = true
lt  1 1.0 = false
le  1 1.0 = true
gt  1 1.0 = false
ge  1 1.0 = true
```

`eq` normalises an `int` to `int64` and a `float` to `float64` and then compares them as `any`, so they are never equal. `lt`/`le`/`gt`/`ge` go through `compareGet`, which converts both to `float64`, so they compare numerically. The two halves of the API use different rules.

Same result for `0` vs `0.0`, `-1` vs `-1.0`, `int64(3)` vs `float64(3)` and `uint(4)` vs `4.0`. Mixed values where the numbers genuinely differ (`1` vs `2.0`) are consistent, so this only shows up when the two are numerically equal.

This is adjacent to #3721, which asked for `eq` to be more lenient and was closed by the stale bot in 2018 without a decision. This report is narrower: whichever convention you prefer, the current combination is not self-consistent.

I have not sent a patch because the fix is a semantics choice, either making `eq` compare numerically or making `le`/`ge` strict about mixed types, and that is your call. Happy to send a PR once you say which.

This issue was written primarily by Claude Code, including the reproduction above.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `a374b865f7e9` and running the modified tests.