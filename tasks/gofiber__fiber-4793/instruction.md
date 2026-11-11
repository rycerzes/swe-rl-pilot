# Issue

**Title:** 🐛 bug: trim the whitespace around comma-split header values in Bind

## Description

# Description

With `EnableSplittingOnParsers: true`, `c.Bind().Header()` and `c.Bind().RespHeader()` split a header value with `strings.SplitSeq(value, ",")`, so the space after each comma stays in the element. Header lists are written with optional whitespace around the commas (RFC 9110 Section 5.6.1), and browsers' `fetch()` and proxies that merge repeated lines join values with `", "`.

For a struct with `Roles []string header:"X-Roles"` and `IDs []int header:"X-Ids"`:

- `X-Roles: admin, editor` binds `["admin" " editor"]`, so a check for `"editor"` fails.
- `X-Ids: 1, 2` fails the bind with `schema: error converting value for index 1 of "X-Ids"` (500).

The same values sent as two header lines already bind correctly, so the result depends on how the client joined them.

For the header and response header binders, `split` now trims each comma-split element with `headerlist.TrimOWS`, which removes only SP and HTAB (RFC 9110 Section 5.6.3). Any other byte stays in the element for the converter. Empty elements are skipped (RFC 9110 Section 5.6.1), so a trailing or doubled comma adds no zero value, and a value made only of empty elements binds as an empty value, so the header still replaces what was bound. Quoted strings are not parsed, as on `main`. Query, form and cookie splitting are unchanged. With splitting on, the logger's `${reqHeaders}` re-joins a split value without the space (`KHTML,like Gecko`), and `Test_HeaderBinder_Bind_Splitting_StringMapNotSplit` is updated for that. `docs/api/bind.md` describes the behavior in the Header section and the `EnableSplittingOnParsers` note, and `docs/whats_new.md` has a bullet for it.

New tests `Test_HeaderBinder_Bind_Splitting_TrimsListWhitespace` and `Test_RespHeaderBinder_Bind_Splitting_TrimsListWhitespace` fail on `main` with the conversion error above and pass with the fix. `Test_HeaderBinder_Bind_Splitting_SkipsEmptyListElements` checks `1, 2,` and `3,, 4` on `[]int` fields and that `X-Roles: " , "` still replaces an existing map entry and struct field. `Test_Bind_Splitting_KeepsElementWhitespace` checks that the query, form and cookie binders keep `a, b` as `["a", " b"]`.

Ran: `go test ./... -count=1 -shuffle=on`, `golangci-lint run ./...` (v2.14.0), `gofumpt -extra=group_params -l`, `go vet ./...`; after the review: `go test ./binder/ -count=1 -shuffle=on`, `go test . -run 'Bind|Header'`, `go vet ./binder/`, `gofumpt -extra -l binder/`

## Changes introduced

- [ ] Benchmarks: Describe any performance benchmarks and improvements related to the changes.
- [x] Documentation Update: Detail the updates made to the documentation and links to the changed files.
- [x] Changelog/What's New: Include a summary of the additions for the upcoming release notes.
- [ ] Migration Guide: If necessary, provide a guide or steps for users to migrate their existing code to accommodate these changes.
- [ ] API Alignment with Express: Explain how the changes align with the Express API.
- [ ] API Longevity: Discuss the steps taken to ensure that the new or updated APIs are consistent and not prone to breaking changes.
- [ ] Examples: Provide examples demonstrating the new features or changes in action.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `7c22c42eecd2` and running the modified tests.