# Issue

**Title:** 🐛 bug: preserve published route buckets during rebuilds

## Description

### Motivation
- A recent change began recycling previous route buckets (reusing backing arrays) when rebuilding the route tree, which allows an in-flight request scanning a previously published bucket to observe mid-rewrite mutations and produce route confusion. 
- The intent is to restore an invariant that published route buckets remain immutable for readers while keeping `RebuildTree` documented as not safe for concurrent use.

### Description
- Allocate fresh per-build buckets in `buildTree` (use `make([]*Route, 0, ...)`) instead of recycling previous buckets and remove the recycling path so published trees are not overwritten in-place. 
- Remove the `reuseRouteBucket` recycling helper and update comments/docstrings in `router.go` and `app.go` to reflect that published buckets remain immutable during a rebuild while `RebuildTree` itself is still not concurrency-safe. 
- Add `Test_RebuildTree_PreservesPublishedBuckets` in `router_test.go` to assert that a captured published bucket is unchanged after removing a route and calling `RebuildTree`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `73ca92207791` and running the modified tests.