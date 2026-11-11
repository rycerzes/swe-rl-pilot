# Issue

**Title:** 🐛 [Bug]: Idempotency replay duplicates headers set by upstream middleware (CORS, Request-ID)

## Description

### Bug Description

With `cors.New()` registered before `idempotency.New()`, repeating a POST with the same idempotency key produces two `Access-Control-Allow-Origin` response headers: one from CORS for the current request and another replayed from the cached response.

The handler still runs only once and both responses have status 200, but multiple Allow-Origin values are invalid for browser CORS checks ([MDN explanation](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors/CORSMultipleAllowOriginNotAllowed)). A browser therefore cannot expose the replayed response to the frontend.

The collision is not specific to CORS: with `requestid.New()` before idempotency, the replay contains both the current and previous `X-Request-ID`. The example below demonstrates both; removing requestid still reproduces the CORS problem.

### How to Reproduce

1. Register CORS, requestid (optional), and idempotency in that order, using their default configurations.
2. Send two POST requests with the same Origin and idempotency key, but different request IDs.
3. Inspect the response headers on the cache hit.

Run the following program against the Fiber revision below. For example, save it outside a checkout as `/tmp/fiber-idempotency-repro.go`, then run `go run /tmp/fiber-idempotency-repro.go` from the checkout root.

Actual output:

```text
request=1 status=200 handler_calls=1 body="order-created"
  Access-Control-Allow-Origin: ["*"]
  X-Request-ID: ["request-1"]
request=2 status=200 handler_calls=1 body="order-created"
  Access-Control-Allow-Origin: ["*" "*"]
  X-Request-ID: ["request-2" "request-1"]
```

This reproduction uses `app.Test` to inspect the returned headers; it does not run a browser.

### Expected Behavior

A replay should preserve the stored business response without making the current response's CORS headers invalid. I would also expect the requestid middleware's response header to identify the current request rather than contain both request IDs.

### Fiber Version

Fiber v3, `main` at ``.
Reproduced against a clean source snapshot of that commit with Go 1.26.10 on linux/amd64.

### Code Snippet

```go
package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/cors"
	"github.com/gofiber/fiber/v3/middleware/idempotency"
	"github.com/gofiber/fiber/v3/middleware/requestid"
)

func main() {
	app := fiber.New()
	app.Use(cors.New())
	app.Use(requestid.New()) // Optional: demonstrates another header collision.
	app.Use(idempotency.New())

	calls := 0
	app.Post("/orders", func(c fiber.Ctx) error {
		calls++
		return c.SendString("order-created")
	})

	for i := 1; i <= 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/orders", http.NoBody)
		req.Header.Set("Origin", "https://shop.example")
		req.Header.Set("X-Idempotency-Key", "00000000-0000-0000-0000-000000000000")
		req.Header.Set("X-Request-ID", fmt.Sprintf("request-%d", i))

		res, err := app.Test(req)
		if err != nil {
			panic(err)
		}
		body, err := io.ReadAll(res.Body)
		if err != nil {
			panic(err)
		}
		if err := res.Body.Close(); err != nil {
			panic(err)
		}
		fmt.Printf("request=%d status=%d handler_calls=%d body=%q\n", i, res.StatusCode, calls, body)
		fmt.Printf("  Access-Control-Allow-Origin: %q\n", res.Header.Values("Access-Control-Allow-Origin"))
		fmt.Printf("  X-Request-ID: %q\n", res.Header.Values("X-Request-ID"))
	}
}
```

### Suspected Cause and Fix Scope

In [maybeWriteCachedResponse](https://github.com/gofiber/fiber/blob//middleware/idempotency/idempotency.go#L118-L128), each stored header value is replayed using `Response.Header.Add`, even when upstream middleware has already set that header for this request.

Before implementing a fix, I would like to confirm the intended behavior with maintainers:

- Should headers already set for the current request take precedence over cached headers, or should specific per-request headers be excluded from storage/re

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `3a397ad690eb` and running the modified tests.