# Issue

**Title:** 🐛 bug: refuse proxy path parameters and stop idempotency cookie replay

## Description

# Description

Two fixes about what the app hands on or replays for a request it did not match.

**Proxy path parameters.** `Balancer`, `DomainForward` and `BalancerForward` refused a `;` only on a `.` or `..` segment. A servlet container such as Tomcat or Jetty strips the path parameters from every segment before it matches routes, so the middleware mounted on `/admin` in Fiber did not run for `/admin;x/secret`, `/admin;/secret` or `/;/admin/secret`, while the upstream served each of them as `/admin/secret`. They are now answered with `400 Bad Request` by default, and a new `AllowPathParameters` field on the proxy policy (off by default) forwards them for an upstream that relies on `;jsessionid` or keeps the `;` as part of the name.

**Idempotency replays.** The key alone identifies a request, so whoever sends a stored key receives the stored response, its status, body and every header, on any route or method, and the default validator only checks the length. A handler that set a session cookie handed that session to the next client that sent the key, for as long as `Lifetime` kept the entry. Cookies are no longer stored, and a new `KeyScope` function scopes keys by user.

No linked issue.

**What this PR changes**

*Proxy*

1. `wiretarget.SegmentsAsRouted` refuses a `;` in any segment unless it is told to let it through. Its flag parameter becomes a set, `wiretarget.Allowance` (`AllowSlashes` for the escaped slash and the empty segment, `AllowParameters` for path parameters). `SegmentsAsRoutedSlashesAside` is gone, and the proxy builds the set from its policy.
2. Behind `AllowPathParameters`, a `.` or `..` segment that carries parameters is still refused, after a raw slash and, with `AllowAmbiguousSlashes`, after an escaped one (`/a%2F..;/b`). A segment made of parameters alone before another segment is an empty one once the parameters are stripped and needs `AllowAmbiguousSlashes` as well; as the last segment (`/app/;jsessionid=x`) it only spells the trailing slash and passes. A backslash and a forged escape stay refused.
3. With `UnescapePath` a `;` is forwarded as `%3B` already; tests pin it.
4. The `net/http` adaptor keeps handing on a `;` on a named segment, which `net/http` reads as part of the name, and answers `404` for a segment of parameters alone before another, as it already did for `..;` and `//admin`: an `httputil.ReverseProxy` behind it may hand the path to an upstream that strips the parameters.

*Idempotency*

5. `Set-Cookie` and the obsolete `Set-Cookie2` (the new `fiber.HeaderSetCookie2`, which the cache middleware uses too) are left out of the stored response unless `KeepResponseHeaders` names them. One `keepHeader` predicate decides at store time, before a name is copied, and again on replay, so an entry written by an earlier version or under another configuration is replayed with the headers this one keeps.
6. `KeyScope` (new, opt-in) returns the scope a key belongs to, such as the ID of the authenticated user. The response is stored and locked under a SHA-256 digest of the scope and the key, with the length of the scope in front so that no key can spell another scope, 64 hex characters whatever either is. A key two users share makes neither wait for the other. Without `KeyScope` nothing changes, down to the storage key.
7. The key is copied once, before the validator, `KeyScope` and the digest read it.

Where to look: `internal/wiretarget/wiretarget.go` (the scan) and `middleware/idempotency/idempotency.go`. Most of the added lines are tests.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `56f2c776809c` and running the modified tests.