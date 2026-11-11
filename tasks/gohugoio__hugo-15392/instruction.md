# Issue

**Title:** collections: Preserve slice type when appending an empty slice

## Description

Appending an empty slice to a typed slice currently widens it to `[]any`. A subsequent append of a typed slice then inserts that slice as a nested element. Preserve the destination type when the appended slice has no elements.

, specifically the empty-slice reproduction in  This addresses that case only; it does not change the broader multidimensional append semantics discussed in the issue.

Added table tests for empty and nil `[]any` inputs and a template integration test covering the subsequent append. The integration test fails before the fix.

Validation:
- `./check.sh ./common/collections/...` and `./check.sh ./tpl/collections/...`: passed.
- Full `./check.sh`: formatting and staticcheck passed; tests hit the pre-existing `TestSlugInBranchPagesCascadesToDescendants` RSS link expectation failure. The same test fails with `common/collections/append.go` restored to the unmodified base commit.
- `go test ./... -skip '^TestSlugInBranchPagesCascadesToDescendants$'`: passed.

This PR was written and tested primarily by OpenAI Codex. The contributor has personally reviewed the changes and tests, and the CLA check has passed.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fdbba5a6614d` and running the modified tests.