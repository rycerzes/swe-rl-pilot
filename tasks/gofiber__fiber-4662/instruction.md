# Issue

**Title:** 🐛 bug: prevent typed-nil view engine panics

## Description

### Motivation

- A recent change started treating typed-nil view engines as absent at startup but request-time rendering still used a plain interface nil check, allowing a typed-nil `Views` to be invoked and panic during request handling.  
- That panic is reachable by an unauthenticated request when an operator accidentally supplies a typed-nil engine, risking process termination unless the app installs recover middleware.  
- The intent of this change is to make request-time rendering use the same typed-nil detection as startup so typed-nil engines are treated as absent and rendering falls back to ancestor engines or raw templates.

### Description

- Updated the request-scoped rendering check to use the existing `isNilViews` predicate so typed-nil `Views` are treated as absent in `DefaultRes.Render` (`res.go`).
- Applied the same `isNilViews` check to domain-mounted view resolution so domain mounts do not dispatch to typed-nil engines (`mount.go`).
- Added a regression test `Test_Ctx_Render_TypedNilEngine` to `ctx_test.go` proving that a typed-nil engine does not panic and raw template rendering still succeeds.
- Changes are limited to runtime nil-detection and tests; no public API behavior was changed.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1d8094097b7a` and running the modified tests.