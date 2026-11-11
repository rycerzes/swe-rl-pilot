# Issue

**Title:** markup/highlight: Re-emit token colors dropped by Chroma's minifier

## Description

Chroma drops token rules whose color equals the style's default foreground
(e.g. .nx in github-dark). In a paired light/dark setup the other sheet's
explicit rule then leaks in, since an explicit declaration beats inheritance
from .chroma. Apply the chromaCSSOverrides custom CSS unconditionally so
these rules survive in modeSelector sheets too.

Updates #15161

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `70db201ed4f7` and running the modified tests.