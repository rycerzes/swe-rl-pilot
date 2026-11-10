# Issue

**Title:** Clear the dispatch cache in `remove_{node,edge}_attributes`

## Description

These functions mutate the graph, so the cache should be cleared

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e1193f66d97d` and running the modified tests.