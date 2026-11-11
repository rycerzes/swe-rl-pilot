# Issue

**Title:** 🐛 bug: fix header, body, routing and session handling defects

## Description

# Description

Nine correctness fixes in request and response handling across the client, the router's mount handling and several middleware, each with a regression test. No public API signature changes; one exported error is added (`client.ErrRedirectTrailers`).

- **static**: `static.New("")` with no `FS` served the filesystem root, since fasthttp joins the request path to an empty root as is and its `os.Root` confinement is off for one. `New` now panics on an empty root on disk and keeps `AllowEmptyRoot` for io/fs roots only, where an empty root is the root of that file system.
- **timeout**: fasthttp sends the timeout response from a fresh `RequestCtx` that never saw the request, so a timed-out HEAD request was answered with a body, which a keep-alive client read as the start of the next response (RFC 9110 §9.3.2). The method is read before the handler starts and `SkipBody` is set on both timeout responses, keeping one `OnTimeout` set itself.
- **proxy (trailers)**: deleting `Trailer` from an upstream response has fasthttp return the fields of its trailer section to the header section, so the hop-by-hop strip handed them to the client as header lines, which a recipient must not merge (RFC 9110 §6.5.1). The section is now dropped first, in `Forward`, `Do` and `Balancer` alike and whatever the hop-by-hop policy; more names than `fieldname.MaxTrailers` answer 502 with the response reset. A client that streams response bodies receives the section only when the body has been read, after that point: the proxy reads such a body, and every response through a custom `Balancer` client, whose clients it cannot ask, into a response of its own and releases it once the body has been sent, so the section reaches neither a hook nor the client.
- **mount**: an app started with `DisableHeadAutoRegister` registered no HEAD companion for a guard it added with `Get`, yet the apps mounted into it still contributed an automatic HEAD route for each of their GET routes, which the flattened HEAD stack ran with nothing in front. The opt-out now covers plain, `Group` and `Domain` mounts, including a sub-app started before it was mounted.
- **cache**: the variant key is built from the request header as the lookup saw it. A header an inner middleware added since (for example an `X-User-Id` derived from the session cookie) contributed the same lines for every client, so the first client's personalized page was stored under a key every other client computed and served to them as a hit. Such a response is now left unstored and sent with `X-Cache: unreachable`, and so is one varying on `Cookie` when the middleware added a cookie beside the ones the client sent, counted by name; a header rewritten in place or removed keeps the lookup's key.
- **proxy (bounds)**: the client behind `Do`, `DoRedirects`, `Forward`, `DomainForward` and `BalancerForward` had no timeout and no response body cap, and `Balancer` buffered an upstream response of any size. The default client now gives each request 30 seconds and buffers at most 100 MiB; `Balancer`'s `MaxResponseBodySize` defaults to the same cap, and a negative value lifts it.
- **session / csrf**: the guard that keeps a running request from storing its snapshot over a change another request made meanwhile asked the `dirty` flag, which a `Get` of a slice, map, struct or pointer sets too. Such a read made the request a writer, as did `Regenerate` and the CSRF middleware in session mode, which set its token on every request, so a change stored meanwhile (a role taken away, say) came back when the request finished. A new `mutated` flag, set by `Set`, `Delete` and `Reset`, now decides the guard, and a value changed in place through `Get` counts as the request's own change too, told from a read by decoding the loaded snapshot again on that rare path; `Regenerate` decodes what another request stored since the load into the rotated session when this one changed nothing; the CSRF middleware leaves a token with more than half

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `f994fd2e2c61` and running the modified tests.