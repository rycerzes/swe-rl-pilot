# Issue

**Title:** Improve/document security.http.urls override behavior

## Description

In  (unreleased) we added a dial-time URL validation to catch URLs that's valid according to the whitelist but that resolves to a loopback, private or link-local IP addresses. That check is skipped it if the user has a custom `security.http.urls` setup, as it would not make sense to block local development servers.

See `CheckAllowedHTTPAddress`.

This has been reported by @Reload3d  as a potential security issue, and while I think the current behaviour is the pragmatic correct approach, I'm creating this issue for visibility and to see if this can be improved further (e.g. better documentation).

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3b2d3b828d76` and running the modified tests.