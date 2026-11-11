# Issue

**Title:** 🐛 bug: fix client, session, basicauth and other bugs found in the audit

## Description

# Description

Fixes the code bugs that turned up while the documentation was checked against the code in #4751. Each fix has a regression test, and the docs sentences that described the old behavior are updated in the same commit.

This PR is stacked on #4751: its base is that PR's branch (`ccr-6f9d8fb1-xolqmg`), so the diff shows only these changes. Once #4751 merges, the base should be switched to `main`.

Fixes # (issue): none, found by the docs audit.

Client fixes:

- **Path normalizing:** `SetDisablePathNormalizing` was only written to the request URI, which fasthttp overwrites with its own client's setting just before writing, so `/a//b/./c%2Fd` was always sent as `/a/b/c/d`. The Fiber setting alone also lifted the check that keeps a path parameter inside its segment even though the path was still normalized when written, so a value containing `..` could change the request path. The setting now reaches the wrapped `fasthttp.Client`, `HostClient` or every host client behind an `LBClient`, and the check is lifted only when Fiber knows that the wrapped client sends the path as built: a client from `New`, `NewWithHostClient` or `NewWithLBClient`, or a `fasthttp.Client` given to `NewWithClient` that was created with `DisablePathNormalizing: true`. A `fasthttp.Client` handed over without it may have served hosts already, whose host clients keep normalizing whatever the field says later, and Fiber cannot tell. A value that is exactly `.` or `..`, and an empty one, is rejected either way: no escape stops the receiving server from resolving a dot segment or from merging the slashes of `//`.
- **Cookie jar:** an attribute fasthttp cannot parse, such as `Max-Age=abc`, made the jar drop every attribute after it (`Secure`, `Path`). The jar now drops only the unusable attribute, and discards a cookie whose name and value cannot be parsed.
- **Logger:** the default logger was always nil, so `Debug()` printed nothing and `SetRootCertificate*` failed with a nil dereference instead of its documented panic.
- **`Referer`:** no empty `Referer:` header is sent when none is configured.

Session fix:

- **Retained context:** with `PassLocalsToContext`, a context kept from `c.Context()` still led to the pooled `*session.Middleware`, which a later request could acquire, so `session.FromContext` on the kept context could resolve that request's middleware. A middleware the request context holds is now reset and marked released but never pooled, and `session.FromContext` returns nil for a released one.

Middleware and other fixes:

- **`basicauth.New()` without a config** called nil functions on the first request. It now goes through the same defaults, and with no users and no `Authorizer` nothing is let through. The default 401 also adds `Authorization` to `Vary` instead of replacing it.
- **`Res.Type` and `Attachment`:** `Type("csv")` and `Attachment("x.csv")` sent `charset=utf-8; charset=utf-8`, because `utils.GetMIME` answered an extension outside its table with the standard library's type and its parameters, and `Req.Is` and `Accepts` never matched such an extension. `gofiber/utils` v2.6.2 (gofiber/), which `main` uses since #4760, returns the bare type, so this PR no longer changes `Type`, `Is` or `Accepts`. It keeps three tests that fail on v2.6.1 and pass on v2.6.2, and a paragraph in `docs/api/ctx.md`.
- **Limiter:** a zero or negative `ExpirationFunc` result falls back to the configured `Expiration`, not the one-minute default.
- **Cache:** `Cache-Control: no-cache, only-if-cached` on a fresh stored entry answers 504 (RFC 9111 Section 5.2.1.7) instead of running the handler.
- **Retry:** a zero-value `ExponentialBackoff` returned nil without calling `f`. A field at zero or below now takes its default, as `NewExponentialBackoff(Config{...})` gives it, also on a struct literal. The zero value calls `f` up to 10 times and takes about 160 seconds when `f` keeps failing. A literal that sets only some fields waits too: `{MaxRetryCount: 2}` re

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e090d85da6bc` and running the modified tests.