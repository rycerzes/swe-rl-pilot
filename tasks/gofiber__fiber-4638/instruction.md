# Issue

**Title:** 🔥 feat: expand context, response and request helpers

## Description

# Description

v3's `Req`/`Res` split gave `Ctx` a request half and a response half, but a lot of everyday work still drops through to raw fasthttp. `c.Response().StatusCode()` alone appears 15 times across eight built-in middlewares; response headers have no `Del`; and there is no way to read back a cookie the response is already set to send.

This does three things:

1. **Fixes a receiver mistake in the previous helper batch.** Fifteen request helpers (`UserAgent`, `MediaType`, `Charset`, the `Accepts*`/`Is*` predicates, …) were written with a `*DefaultCtx` receiver inside `req.go`, which kept them off the `Req` interface `ifacemaker` generates from `DefaultReq`: `c.UserAgent()` compiled, `c.Req().UserAgent()` did not. They move onto `*DefaultReq`, along with `Path`, `Secure`, `XHR`, `HasBody`, `IsWebSocket` and `IsPreflight` out of `ctx.go` — request methods on the wrong type for the same reason. `Req` goes from 39 to 74 methods.
2. **Adds 29 helpers**, mostly closing the paths where middleware in this repo escapes to fasthttp.
3. **Updates twelve middlewares** to use them, which also fixes five latent bugs.

No issue — this came out of an audit of what `ctx.go`/`req.go`/`res.go` were missing.

## Not a breaking change

`DefaultCtx` embeds `DefaultReq`, so every moved method is still promoted: `c.IsWebSocket()` and friends are untouched. Verified rather than assumed:

- Diffing the **reflected method sets** of `Ctx`, `*DefaultCtx`, `*DefaultReq` and `*DefaultRes` between `main` and this branch: **nothing removed, no signature changed**. All four are strict supersets.
- A **consumer module** exercising interface calls, method values (`f := c.HasBody`), method expressions (`(*fiber.DefaultCtx).HasBody`), concrete calls, `var _ fiber.Ctx = (*fiber.DefaultCtx)(nil)`, and a custom Ctx embedding `fiber.DefaultCtx` (including one overriding `HasBody`) compiles identically against both. The only difference is `c.Req().HasBody()`, which fails on `main` and works here.

The interfaces gained methods (`Ctx` +33, `Req` +35, `Res` +11), which normally breaks implementers — but `Ctx` already declares 31 **unexported** methods (`release()`, `getMethodInt()`, `setIndexRoute()`, …), `Req` 7, `Res` 3. Go qualifies unexported method names by package, so no type outside `package fiber` has ever been able to implement them; the documented pattern (embed `fiber.DefaultCtx`) picks new methods up for free. Confirmed by compiling a hand-written `Ctx` against released `main` — it fails there exactly as it does here.

### Risks that remain

- **Assignment, not implementation.** An earlier revision named the response cookie accessor `Res.Cookies() []*Cookie`, which collides with `Req.Cookies(key string, ...string) string`. Same name, different signature, so `Ctx` stopped satisfying `Res`: `func writeHeaders(r fiber.Res)` could no longer be handed a `c`, and `interface { fiber.Req; fiber.Res }` failed to compile. Splitting a handler into a request half and a response half is the reason the split exists, so that shape is not exotic. It is now `Res.GetCookies()`, beside the `GetCookie` it belongs with; `apidiff` reports **0 incompatible / 139 compatible** changes, and `ctx_helpers_test.go` pins `Req` and `Res` on both `Ctx` and `*DefaultCtx` so a future collision fails at compile time rather than on a user's assignment.
- **Ambiguous selector on a double embed.** `HasBody` and the other moved methods are now promoted one level deeper. A type embedding `fiber.DefaultCtx` **alongside** another type supplying the same name at exactly depth 2 goes from "DefaultCtx wins" to `ambiguous selector`. It needs a deliberate double-embed collision and fails loudly at compile time.
- **Silent shadowing on an unequal embed.** The same depth change cuts the other way when the collision is *not* at equal depth. Where a user's own method sits strictly deeper than fiber's, a name this PR adds to `Ctx` now wins where the user's used to: the same program compiles on both rev

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `a9981a7db37d` and running the modified tests.