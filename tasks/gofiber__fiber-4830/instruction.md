# Issue

**Title:** 🐛 bug: send the measured Content-Length of an unsized body in app.Test

## Description

# Description

`app.Test` copies `req.ContentLength` into a `Content-Length` header. For a body that `net/http` cannot size, which is any reader other than `bytes.Buffer`, `bytes.Reader` or `strings.Reader` (an `*os.File`, the reader of an `io.Pipe`, `io.MultiReader`, ...), that value is `-1` from `httptest.NewRequest` and `0` from `http.NewRequest`. So testing an upload or raw-body endpoint with a fixture file or a streamed multipart body fails, and the error points at `Content-Length` rather than at the reader:

- `app.Test(httptest.NewRequest("PUT", "/raw", f))` with `f, _ := os.Open("testdata/fixture.json")` returns `error when reading request headers: cannot parse content-length: unexpected first char found: expecting 0-9 ... "PUT /raw HTTP/1.1\r\nHost: example.com\r\nContent-Length: -1\r\n\r\n{\"name\":\"fixture\"}"`.
- A multipart upload written through `io.Pipe` and passed to `http.NewRequest` runs the handler with an empty body (`c.FormFile` fails), then the body is read as a second request: `error when reading request headers: cannot find http request method in "--<boundary>\r\nContent-Disposition: form-data; name=\"file\"..."`.

`app.Test` now reads such a body (`req.Body != nil && req.ContentLength <= 0`) and sends its measured `Content-Length`; `httputil.DumpRequest` already read the whole body into the dump. A known length, a nil body and a `Content-Length` set by the caller keep the old path. With the change the two cases above answer `200 got 18 bytes` and `200 uploaded fixture.json`.

`Test_App_Test_BodyOfUnknownLength` covers a `-1` body from `httptest.NewRequest`, a `0` body from `http.NewRequest` and an HTTP/1.0 request (all three fail on `main`), and checks that the handler sees the body's `Content-Length`. Rows for an empty body, an empty body with `StreamRequestBody` and a known length cover the paths that already worked. `docs/api/app.md` (Test) and `docs/whats_new.md` (Test Config) get one sentence each.

Ran: `go test ./... -count=1 -shuffle=on`, `golangci-lint run ./...` (v2.14.0), `gofumpt -extra=group_params -l .`, `go vet ./...`, `betteralign -test_files -generated_files ./...` (v0.8.0), `markdownlint-cli2` on the two docs files.

## Changes introduced

- [ ] Benchmarks: Describe any performance benchmarks and improvements related to the changes.
- [x] Documentation Update: Detail the updates made to the documentation and links to the changed files.
- [x] Changelog/What's New: Include a summary of the additions for the upcoming release notes.
- [ ] Migration Guide: If necessary, provide a guide or steps for users to migrate their existing code to accommodate these changes.
- [ ] API Alignment with Express: Explain how the changes align with the Express API.
- [ ] API Longevity: Discuss the steps taken to ensure that the new or updated APIs are consistent and not prone to breaking changes.
- [ ] Examples: Provide examples demonstrating the new features or changes in action.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b6a1184d51a7` and running the modified tests.