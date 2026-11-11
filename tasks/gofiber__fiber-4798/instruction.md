# Issue

**Title:** 🐛 [Bug]: hostauthorization compares IPv6 hosts by spelling, so an allowed [::1] refuses [0:0:0:0:0:0:0:1]

## Description

### Bug Description

`hostauthorization` compares IPv6 hosts by their text, not by the address they denote. `normalizeHost` strips the brackets and the port, lowercases, and leaves the rest as written; `isValidHostSyntax` parses the literal with `utils.ParseIPv6` only to check validity and discards the parsed value. Matching is then a byte-equal lookup in `parsed.exact`, so two spellings of the same address never match.

An IPv6 address has many valid textual forms (RFC 4291 Section 2.2), and RFC 5952 Section 1 notes that comparing addresses as text is unreliable for exactly this reason. Browsers and most HTTP clients serialize the host in the compressed RFC 5952 form, so an `AllowedHosts` entry written in any other form (`[2001:db8:0:0:0:0:0:1]`, `[2001:0db8::0001]`) rejects every request with 403, while the configuration looks correct.

### How to Reproduce

```go
app := fiber.New()
app.Use(hostauthorization.New(hostauthorization.Config{AllowedHosts: []string{"[::1]"}}))
app.Get("/", func(c fiber.Ctx) error { return c.SendString("ok") })

req := httptest.NewRequest(fiber.MethodGet, "/", nil)
req.Host = "[0:0:0:0:0:0:0:1]:3000"
resp, _ := app.Test(req)
fmt.Println(resp.StatusCode)
```

| AllowedHosts | Host | Status | Expected |
|---|---|---|---|
| `[::1]` | `[::1]:3000` | 200 | 200 |
| `[::1]` | `[0:0:0:0:0:0:0:1]:3000` | **403** | 200 |
| `[::1]` | `[0000:0000:0000:0000:0000:0000:0000:0001]` | **403** | 200 |
| `[2001:db8:0:0:0:0:0:1]` | `[2001:db8::1]:8080` (what a browser sends) | **403** | 200 |
| `[2001:0db8::0001]` | `[2001:db8::1]` | **403** | 200 |
| `[::ffff:127.0.0.1]` | `[::ffff:7f00:1]` | **403** | 200 |
| `[::1]` | `[0:0:0:0:0:0:0:2]` | 403 | 403 |

### Expected Behavior

Every spelling of one IPv6 address matches the same `AllowedHosts` entry, and a different address is still refused. The natural place is `normalizeHost`, which already runs on both the configured hosts and the request host: when the host parses as an IPv6 address, write it back in its canonical RFC 5952 form (`addr.String()`), and leave anything else untouched. Hostnames have no `:` and skip the branch, so their path is unchanged.

I have a patch with a table test for the cases above (plus rows in `Test_NormalizeHost` / `Test_ParseNormalizedAuthority`), a one-line docs addition to the "Host Normalization" list, and benchmarks unchanged (`Benchmark_matchHost_ExactMatch` 4.8 ns/op, 0 allocs, before and after). Will open a PR.

### Fiber Version

v3, `main` at 3acc355

### Code Snippet (optional)

See above.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `95d7398102ac` and running the modified tests.