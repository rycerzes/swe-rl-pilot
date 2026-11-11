# Issue

**Title:** 🐛 bug: refuse a repeated Authorization field in basicauth

## Description

# Description

`Authorization` is a single-value field (RFC 9110 [§11.6.2](https://www.rfc-editor.org/rfc/rfc9110#section-11.6.2)), and RFC 9110 [§5.2](https://www.rfc-editor.org/rfc/rfc9110#section-5.2) says a sender must not generate it on more than one field line. The `basicauth` middleware read it with `c.Get`, which answers with the first field line that holds a value, while `net/http`'s `Header.Get` and fasthttp's `Peek` answer with the first line even when it is empty. For a request carrying

```http
Authorization:
Authorization: Basic am9objpkb2U=
```

a `net/http` handler in front of the app (through `adaptor.FiberApp`) and `basicauth` behind it therefore disagreed about whether the request carried a credential at all. `v3.5.0` read the first line through `Peek` and agreed with `net/http`; the difference dates from the `c.Get` rewiring in `73df8412` on `main`.

`basicauth` now reads the field through `headerlookup.Value`, as the `extractors` package and `csrf` already do, and answers `400 Bad Request` when the field is carried on more than one line, whatever the lines are spelled like or hold. Picking the first line would hide a credential behind an empty one and picking the first non-empty line would let whoever wrote the other line decide, so a message with no single meaning is refused the way a malformed header is, without a `WWW-Authenticate` challenge. A single empty line is still `401`.

`Get` keeps its first-non-empty rule, which `GetAll` and `HasHeader` share and which `dcc39c66` introduced so an empty `Origin` line does not hide the one beside it. The rule is now documented on `Get`, and the adaptor docs gain a caution that the `net/http` side and the Fiber side read a repeated header differently, with the patterns a `net/http` handler should use instead of comparing `Header.Get` with the empty string.

No linked issue.

**Behavior change:** a request that carries `Authorization` on more than one line now gets `400 Bad Request` from `basicauth` instead of being read by its first non-empty line. A client that sends one `Authorization` line, as browsers and HTTP client libraries do, sees no difference.

## Changes introduced

Two commits:

1. `8b9bc259` 🐛 the fix: `basicauth` reads `Authorization` through `headerlookup.Value` and refuses a repeated field with `400`. `Test_BasicAuth_RepeatedAuthorizationIsRefused` covers the lines under the canonical name, under two spellings with `DisableHeaderNormalizing`, and through `adaptor.FiberApp`; `Test_Ctx_Get_EmptyFirstLine` pins the documented `Get` rule. Docs for `Get`, the adaptor, `basicauth` and what's new.
2. `1660b2c5` 🧹 `make generate` carries one existing doc comment line (`Vary`) from `res.go` into `res_interface_gen.go`. This is pre-existing drift on `main`, also noted in #4735, included so the branch is generate-clean. Drop it if preferred.

- [x] Benchmarks: `Benchmark_Middleware_BasicAuth`, 6 runs each on `main` and on this branch: 32 B/op and 2 allocs/op before and after, 428–509 ns/op before and 435–467 ns/op after, within the machine's noise. On the normalized path `headerlookup.Value` is one `PeekAll` with no allocation.
- [x] Documentation Update: [`docs/api/ctx.md`](https://github.com/gofiber/fiber/blob/ccr-a0780098-o3z7zd/docs/api/ctx.md#get) (`Get`: repeated field lines), [`docs/middleware/adaptor.md`](https://github.com/gofiber/fiber/blob/ccr-a0780098-o3z7zd/docs/middleware/adaptor.md) (caution after the `FiberApp` example and a bullet under Notes and limitations), [`docs/middleware/basicauth.md`](https://github.com/gofiber/fiber/blob/ccr-a0780098-o3z7zd/docs/middleware/basicauth.md) (the `400` case in the intro and in the `BadRequest` row).
- [x] Changelog/What's New: one sentence in the BasicAuth section of [`docs/whats_new.md`](https://github.com/gofiber/fiber/blob/ccr-a0780098-o3z7zd/docs/whats_new.md#basicauth).
- [ ] Migration Guide: n/a, no API change (see the behavior note above).
- [ ] API Alignment with Express: n/a, no API change.
- [

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `78b8ee93c988` and running the modified tests.