# Issue

**Title:** tpl: Make StripHTML (plainify) more robust and faster

## Description

Replace the multi-pass implementation built on `html/template`'s `stripTags`
with a single pass over a small, allocation-free tag scanner, now shared
with the summary tag balancing in `resources/page` (moved to `common/hhtml`).

This fixes several corner cases:

* Tags inside `textarea` and other RCDATA elements are stripped.
* Doctypes, CDATA sections and processing instructions are removed.
* `<br/>`, `<BR>`, `<br class="x">` and `</P>` are converted to newlines.
* Text in adjacent block elements is kept apart, e.g. `<li>a</li><li>b</li>`
  becomes `a b` and not `ab`.
* An unterminated tag at the end of the input is removed.

It also fixes a bug in the scanner where a self-closing tag (e.g. `<br/>`)
swallowed the next tag.

`StripHTML` is now about 3.5-9x faster and does at most one allocation:

```
name                 old time/op    new time/op    delta
StripHTML/Small      426ns ±22%      91ns ± 1%    -78.74%
StripHTML/NoTags    30.4ns ± 2%     3.4ns ± 1%    -88.95%
StripHTML/Page      96.6µs ± 7%    26.2µs ± 3%    -72.90%

name                 old alloc/op   new alloc/op   delta
StripHTML/Small       208B ± 0%       48B ± 0%    -76.92%
StripHTML/Page      102kB ± 0%     12.0kB ± 0%    -88.24%

name                 old allocs/op  new allocs/op  delta
StripHTML/Small       7.00 ± 0%      1.00 ± 0%    -85.71%
StripHTML/Page        22.0 ± 0%       1.0 ± 0%    -95.45%
```

Fixes 

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `77230eba0469` and running the modified tests.