# Issue

**Title:** 🐛 [Bug]: Vary dedups field names byte-exactly, so a differing case is listed twice

## Description

### Bug Description

`Res.Vary()` decides whether a field name is already listed by comparing bytes, so the same field name in a different case is added again. Field names are case-insensitive (RFC 9110 Section 5.1), so `Vary: accept, Accept` names one thing twice.

The awkward part is that Fiber already reads `Vary` case-insensitively in two places, so it will not recognise on the way in what it just wrote on the way out:

* `middleware/compress` checks `Vary` for `Accept-Encoding` with a case-insensitive token match, and skips adding its own entry when it finds one.
* `middleware/cache` `parseVary` lowercases every name before building the variant key, so `accept` and `Accept` are the same dimension there. A response carrying both hashes that one request header twice, and both count toward `maxVaryHeaders` (32).

This is a conformance bug rather than a security one. Nothing is mis-served, since caches lowercase field names too, so the duplicate is redundant rather than wrong. What it costs is a malformed-looking `Vary` on the wire and a value Fiber contradicts itself about.

It is easy to hit without doing anything unusual, because several built-ins add `Vary` themselves in canonical case. `Res.AutoFormat()` calls `Vary("Accept")`, so a handler that spelled it `c.Vary("accept")` gets both.

### How to Reproduce

1. Run the snippet below against v3.5.0.
2. Observe `Vary: "accept, Accept"` on the first line, from a handler that named one field.

The second line is the direct form, without `AutoFormat` involved.

### Expected Behavior

`Vary` should treat its members as case-insensitive field names, so the second call is recognised as already listed and the header stays `Vary: accept` (first spelling wins, matching how the method already keeps existing members in place).

Actual output:

```
Vary: "accept, Accept"
Vary: "Accept-Encoding, accept-encoding"
```

Scope note: this is specific to `Vary`, whose members are defined to be field names. The generic `Res.Append()` also dedups byte-exactly, but that is defensible, since it is used for `Link`, `Cache-Control` and others whose members are not all case-insensitive. Only `Vary` has the guarantee that makes the folded comparison correct. `Vary("*")` collapsing is unaffected and already works.

I ran into this while consolidating the comma-list scanners in #4637, and flagged it in that PR description as belonging in its own change rather than being folded into a refactor, so filing it here. Happy to send the fix if you agree with the shape.

### Fiber Version

v3.5.0 (also on current `main`, e7229b1b)

### Code Snippet (optional)

```go
package main

import (
	"fmt"
	"log"
	"net/http/httptest"

	"github.com/gofiber/fiber/v3"
	"github.com/valyala/fasthttp"
)

func main() {
	app := fiber.New()

	// A handler that varies on Accept, spelled lower case, then hands off to
	// AutoFormat, which internally calls Vary("Accept").
	app.Get("/", func(c fiber.Ctx) error {
		c.Vary("accept")
		return c.AutoFormat("hello")
	})

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Accept", "text/plain")
	resp, err := app.Test(req)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Vary: %q\n", resp.Header.Get("Vary")) // "accept, Accept"

	// Direct form.
	c := app.AcquireCtx(&fasthttp.RequestCtx{})
	c.Vary("Accept-Encoding")
	c.Vary("accept-encoding")
	fmt.Printf("Vary: %q\n", string(c.Response().Header.Peek("Vary"))) // "Accept-Encoding, accept-encoding"
	app.ReleaseCtx(c)
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `5be18454639e` and running the modified tests.