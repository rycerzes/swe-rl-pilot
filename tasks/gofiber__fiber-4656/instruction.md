# Issue

**Title:** 🐛 bug: prevent unbounded function-backed SendFile caching

## Description

### Motivation
- A previous change to `sameFS` caused function-backed `fs.FS` values to never match existing `SendFile` handlers, which made every request create and retain a new fasthttp handler and grow `app.sendfiles` unboundedly. 
- The intent is to preserve correct SendFile behavior while preventing unbounded memory and goroutine retention when users serve files from function-valued `fs.FS` implementations.

### Description
- Add a `cacheHandler` guard in `DefaultRes.SendFile` so function-backed `fs.FS` (dynamic kind `reflect.Func`) do not participate in the persistent `app.sendfiles` handler cache. 
- Disable fasthttp's per-handler file cache for these transient handlers by setting `SkipCache` when `cacheHandler` is false. 
- Only read/append `app.sendfiles` when `cacheHandler` is true, preventing the pathological append-on-every-request behavior. 
- Add `Test_Ctx_SendFile_FunctionFSDoesNotGrowHandlerCache` in `ctx_test.go` to exercise a stable function-backed FS over repeated requests and assert `app.sendfiles` remains empty.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `bd6071b4b60c` and running the modified tests.