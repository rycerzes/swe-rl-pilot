# Issue

**Title:** 🐛 bug: preserve nil first field lines when joining headers

## Description

# Description

`headerlist.JoinNext` uses a nil accumulated value to identify the first field line. If that first line is itself nil, the next call incorrectly treats the second line as the first: joining nil and `gzip` yields `gzip` instead of `,gzip`, and the multiple-line flag stays false.

Keep a non-nil empty slice after an empty first line so subsequent calls preserve its position. Related #4604 (header-list helpers).

## Changes introduced

- Document the empty-leading-line regression guarantee.

- Add four table-driven cases for nil and empty leading field lines, checked against `Join`.
- The regression fails before the fix and passes afterward.
- Existing `Benchmark_PeekJoinedRequestHeader` allocation counts are unchanged: 0, 1 and 2 allocations for one, two and three lines respectively. Timing was noisy under concurrent checks; no speedup is claimed.
- No public API or documentation changes.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fb4b9f6ba468` and running the modified tests.