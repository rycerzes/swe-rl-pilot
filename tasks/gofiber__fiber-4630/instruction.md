# Issue

**Title:** 🐛 bug: unify cookie SameSite handling

## Description

## Summary

- add one internal, case-insensitive SameSite parser that owns Fiber's public mode strings and maps each mode to both `net/http` and fasthttp cookie values
- use that mapping in `DefaultRes.Cookie` and session cookie emission, removing the two divergent switch statements
- make session honor `CookieSameSiteDisabled`, preserve an explicitly configured `CookieSecure` value for every non-None mode, and continue forcing Secure for SameSite=None
- reject unsupported session SameSite modes during initialization and document the accepted values
- document why core validates with `net/http.Cookie.Valid` before fasthttp can silently mutate invalid cookie bytes

## Behavior changes

- session `CookieSameSite: "Disabled"` now omits the SameSite attribute instead of silently becoming Lax
- invalid non-empty session SameSite values now panic during configuration instead of silently becoming Lax
- core `Cookie` keeps its existing invalid/empty-to-Lax compatibility behavior

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1d6d6088fce6` and running the modified tests.