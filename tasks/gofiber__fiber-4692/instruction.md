# Issue

**Title:** 🐛 bug: read "$10" as the tenth capture in redirect and rewrite targets

## Description

# Description

While reading `captureTokens` in the redirect and rewrite middleware I noticed that it hands `"$1", "$2", ...` to `strings.NewReplacer` in ascending order. A `Replacer` compares keys in argument order and takes the first one that matches at a position, so once a rule has ten or more captures, `$10` in the target is read as `$1` followed by `0`.

With the rule `{From: "/t/*/*/*/*/*/*/*/*/*/*/*", To: "/r/$11/$10/$1"}`, a request for `/t/a/b/c/d/e/f/g/h/i/j/k` redirects (or rewrites) to `/r/a1/a0/a` instead of `/r/k/j/a`. In redirect this is easier to reach than the wildcard count suggests, since a rule key is regexp syntax and its own groups count toward `$N` as well.

The fix lists the keys highest index first in both copies, so the longer token is tried before its prefix. The authority guard in redirect (`placeholderEnd`) already takes every digit of a `$N` token, so it now reads a target the same way the Replacer does; `Test_Redirect_TenthCaptureInAuthority` still refuses its rule, and I only reworded its comment, which described the old `$1` + `0` reading.

Related to #4604 (cluster 4 mentions these two `captureTokens` copies).

## Changes introduced

- `middleware/redirect/redirect.go`, `middleware/rewrite/rewrite.go`: build the replacer pairs from the highest capture index down. Same number of allocations as before.
- `Test_Redirect_TwoDigitCaptures` and `Test_Rewrite_TwoDigitCaptures` cover `$11`, `$10` and `$1` in one target.

Before the change both new tests fail:

```
expected: "/r/k/j/a"
actual  : "/r/a1/a0/a"
--- FAIL: Test_Redirect_TwoDigitCaptures
expected: "k j a"
actual  : "a1 a0 a"
--- FAIL: Test_Rewrite_TwoDigitCaptures
```

After it, `go test -race ./middleware/redirect/ ./middleware/rewrite/ -count=1` passes, and `go vet` and `gofmt -l` report nothing (Go 1.26.0, linux/amd64).

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e90c824775a0` and running the modified tests.