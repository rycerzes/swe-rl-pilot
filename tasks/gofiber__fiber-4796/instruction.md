# Issue

**Title:** 🐛 Bug: hostauthorization rejects a valid port spelled with more than five digits

## Description

`hostauthorization` rejects a valid `Host` whose port is spelled with more than five digits, even when the numeric value is in range:

```go
app.Use(hostauthorization.New(hostauthorization.Config{AllowedHosts: []string{"example.com"}}))
```

| Host | Status | Expected |
|---|---|---|
| `example.com:80` | 200 | 200 |
| `example.com:080` | 200 | 200 |
| `example.com:00080` | 200 | 200 |
| `example.com:000080` | **403** | 200 |
| `example.com:065535` | **403** | 200 |
| `example.com:000000000000065535` | **403** | 200 |
| `example.com:65536` | 403 | 403 |

`isValidPort` starts with `if raw == "" || len(raw) > 5 { return false }`, so the decision depends on how many digits the port is written with, before the value is read. A port is `*DIGIT` (RFC 3986 Section 3.2.3), the middleware's own docs describe rejection numerically ("a port that is empty, not numeric or above 65535"), and five-digit zero padding already passes — the six-digit boundary looks accidental.

Expected: leading zeros are accepted and stripped for an allowed host, and only a value above 65535 is rejected. The value can be bounded inside the parsing loop, which also removes the overflow concern the length check was guarding against.

I have a patch that bounds the value instead of the digit count, with a table test for the cases above, and will open a PR.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3acc355f448b` and running the modified tests.