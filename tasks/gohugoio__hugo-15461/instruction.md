# Issue

**Title:** Redirect .Params.title etc. to .Title etc. and deprecate it

## Description

Reserved front matter fields such as title and summary are currently also
stored in .Params. Lookups such as .Params.title are now redirected to the
corresponding Page method (e.g. .Title) and logged as deprecated, unless the
field was set in params. .Params.summary is redirected to the new .RawSummary
method.

The content of .Params is unchanged for now.

Updates #15411

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3e67572c5df6` and running the modified tests.