# Issue

**Title:** 🩹 fix: Honor only-if-cached for non-shareable entries

## Description

# Description

Authorized requests must not reuse cached responses unless those responses are explicitly shareable. When an authorized `only-if-cached` request encountered a cached entry that was not marked shareable, the cache middleware bypassed the entry and forwarded the request to the origin.

That behavior conflicts with RFC 9111: `only-if-cached` prevents forwarding when the cache cannot satisfy the request. The middleware now returns `504 Gateway Timeout` and marks the cache result as `unreachable` instead of contacting the origin.

The same rule now applies when `only-if-cached` is combined with `Cache-Control: no-cache` or `Pragma: no-cache`. In those cases, `no-cache` prevents using the stored response without validation while `only-if-cached` prevents contacting the origin to perform that validation, so the request must receive a 504 response.

Requests without `only-if-cached`, including requests containing only `no-cache`, retain the existing behavior and continue to the origin. The non-shareable cached entry is left untouched.

.

## Changes introduced

- Return `504 Gateway Timeout` when an authorized `only-if-cached` request encounters a non-shareable cached entry.
- Apply the `only-if-cached` restriction independently of request `no-cache` handling.
- Handle both `Cache-Control: no-cache, only-if-cached` and `Cache-Control: only-if-cached` combined with `Pragma: no-cache` without forwarding to the origin.
- Set the configured cache status header to `unreachable` for these responses.
- Preserve normal origin forwarding for authorized requests without `only-if-cached`, including plain `no-cache` requests.
- Preserve the existing non-shareable cache entry and its separately stored body.
- Add external-storage regression coverage for each directive combination, origin-call behavior, cache-entry retention, and custom cache status headers.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `a2a6d290f4a1` and running the modified tests.