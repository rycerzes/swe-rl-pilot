# Issue

**Title:** Make default baseUrl https://example.org/

## Description

If I want to create a very basic site, the only reason I currently need to create a config file is to set the `baseUrl`.

So, having the `baseURL` default to https://example.org/  would be a slightly breaking change, but it would solve more issues than it introduces.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8bac4de7a173` and running the modified tests.