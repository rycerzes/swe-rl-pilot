# Issue

**Title:** Upgrade to Go 1.27.2

## Description

A fair amount of security fixes in here: https://github.com/golang/go/issues?q=milestone%3AGo1.27.2

- [x] New build image and version bump
- [x] Sync template packages

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `46123a609bd1` and running the modified tests.