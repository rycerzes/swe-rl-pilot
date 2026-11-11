# Issue

**Title:** Fix resource transformation chaining after content access

## Description

When a transformed resource had been initialized (e.g. via .Data, .Content
or .RelPermalink) before chaining another transformation, the new chain
would run on the transformed output instead of the original source,
re-running all transformations on their own output.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8a55df7af2e6` and running the modified tests.