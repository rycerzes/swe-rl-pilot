# Issue

**Title:** 🐛 fix(proxy): fold DomainForward's configured hostname to Punycode

## Description

This PR was written in part with the assistance of generative AI.

# Description

`DomainForward("münchen.example.com", ...)` never proxies a single real request.

A conforming client always sends the Punycode form on the wire (RFC 5891): `Host: xn--mnchen-3ya.example.com`. The configured hostname was compared to that wire value byte for byte, with no folding on either side, so the two can never match. The rule is silently dead for any internationalized domain, which is exactly the kind of value a non-English deployment would write as a Unicode literal directly in Go source.

Verified end to end before touching anything, not just at the string-comparison level: a real request through the actual middleware, with the wire `Host` set to the Punycode form a browser would send, falls through to the next handler instead of being proxied. That test is in this PR (`Test_Proxy_DomainForward_HostMatchFoldsIDN`), and I reverted the fix locally first to confirm it fails without it.

## Root cause

```go
host := utils.UnsafeString(c.Request().Host())
if !utils.EqualFold(host, hostname) && !utils.EqualFold(hostWithoutPort(host), hostname) {
    return c.Next()
}
```

Both branches fold case (`EqualFold`) and the second folds an explicit port off the wire value, but neither side is ever folded to Punycode. `middleware/hostauthorization` already does this correctly for its own allowlist matching; `DomainForward` never picked it up.

