# Issue

**Title:** 🐛 fix: match HTTP field names the way a recipient must

## Description

# Description

**2 of 3, split out of #4581.** Based on #4584 — review that one first, or read this diff against `claude/split-1-url-composition`.

Field names are case-insensitive ([RFC 9110 §5.1](https://www.rfc-editor.org/rfc/rfc9110#section-5.1)), but fasthttp's `Peek`, `PeekAll` and `Del` compare the stored key **byte for byte**. That is enough while fasthttp canonicalizes it — under `DisableHeaderNormalizing` the store keeps the spelling the client sent, and **lower case is what HTTP/2 and HTTP/3 put on the wire**, so it is what a front end translating down to HTTP/1.1 preserves. Every guard below was then reading a header that was there as if it were absent.

Measured, with `DisableHeaderNormalizing` set:

```
Peek("Authorization") = ""            stored key: "authorization"
Peek("Content-Type")  = "text/plain"  <- special slot, works either way
```

That last line is why this survived review: the names fasthttp keeps in a slot of their own still resolve, so a spot check on the obvious header passes.

## What was wrong

### cache

**An anonymous request was served another user's authenticated page.** A lower-case `authorization:` read as no credential at all, so the response was stored as anonymous and replayed to everyone — bearer token included. `Set-Cookie2`, `Vary` and `KeyHeaders` missed the same way, storing and replaying a personalized response and dropping a `Vary` dimension silently out of the key. `public` was injected into a response that never said it — exactly the token that lifts RFC 9111 §3.5 for a response to an authenticated request.

Unrelated to case, in the same paths: a cached 3xx lost its `Location`, so the first client got `301 Location: /new` and every one after a bare 301; a `Set-Cookie` on a shared entry handed one client's session to everyone matching the key; and a repeated header name was collapsed on replay, so a response sending `Vary` twice came back varying only on the second.

### proxy

**Every sanitizer removed nothing.** A cross-host redirect carried the caller's `authorization:` and `cookie:` to the redirect target; `upgrade`, `te`, `keep-alive` and a `connection:`-listed header reached the upstream; and the client's own `x-real-ip` arrived beside the one the proxy writes, so the upstream attributed the request to an address the client chose.

The response strip also asked the wrong object: a proxied response is parsed by the outbound `fasthttp.Client`, which carries its own setting and stamps it onto that header each hop. A proxy preserving upstream casing in front of a normalizing app stripped nothing.

### csrf

**The origin check was switched off by the case of a header name.** With a valid double-submit pair, `Origin: http://evil.com` → 403, but `origin: http://evil.com` → **200**. An absent Origin is not a failure there — on a plaintext connection the check is skipped for it entirely.

### others

- `extractors.FromHeader`: a token sent under the lower-case name was not found, and the request refused for carrying no token when it carried one.
- logger: `${ips}` logged an empty chain while the trust decisions went on using the header it could not see; `RegisterContextTag` wrote its value raw, where a CR or LF forged a log line.
- adaptor: a wrapped `net/http` middleware's header edits were lost — a `Header.Set` collapsing a multi-valued header left the other values in place, a middleware that changed nothing duplicated the last value of every multi-valued header, and removals never propagated at all.
- form parsing: fasthttp matches the media type and `boundary=` case-sensitively, so a legal `Multipart/Form-Data` bound nothing and reported no error.
- `Scheme()`: only `http` and `https` are accepted from a proxy header. The value is spliced into a URL by `BaseURL` and compared for origin equality by csrf and `Redirect().Back`, so no other scheme — `javascript` included — may become the request's.

`basicauth` and `cors` were checked too and fail **closed** — a lower-case name l

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e98ccd8aa286` and running the modified tests.