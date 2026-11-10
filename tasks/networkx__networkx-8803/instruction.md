# Issue

**Title:** MAINT: allow isomorphism match helpers to be lists or not

## Description

The docstrings for the match helper functions (`numerical_node_match`, etc) say that inputs can be singular or a list. But they don't always do that. This PR adds the code needed to allow that, adds tests to check that it works and what errors might arise, updates the doc-strings and rewrites the `generic_multiedge_match` function for readability.

This was motivated by comments in #8738 that indicated that list inputs with different lengths were leading to `zip` truncation. So adding the `strict=True` kwarg to `zip` idioms is desired and implemented here. The code also didn't handle singular and list versions of the input, so that was added too.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e1193f66d97d` and running the modified tests.