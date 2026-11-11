# Issue

**Title:** 🐛 [Bug]: compress middleware ignores no-transform on repeated response Cache-Control lines and misparses quoted directive arguments

## Description

### Bug Description

While #4708 updated `shouldSkip` in `middleware/compress` to check request `Cache-Control: no-transform` directives across repeated field lines and quoted directive arguments via `c.HasHeaderValue(fiber.HeaderCacheControl, "no-transform")`, the response check on the next line still calls `headerlist.ContainsFold(c.GetRespHeader(fiber.HeaderCacheControl), "no-transform")`.

Because `c.GetRespHeader` reads only the first `Cache-Control` response field line and `headerlist.ContainsFold` splits on commas inside quoted directive arguments:
1. A `no-transform` directive added on a second response `Cache-Control` line (`RFC 9110 §5.3` / `RFC 9111 §5.2.2.6`) is ignored and the response is compressed anyway.
2. A response header such as `Cache-Control: public, ext="x,no-transform,y"` is split inside the quotes and falsely treated as `no-transform`.
3. A response header with an escaped quote before `no-transform` (`Cache-Control: ext="a\"", no-transform`) fails to match `no-transform`.

### How to Reproduce

```go
app := fiber.New()
app.Use(compress.New())
app.Get("/", func(c fiber.Ctx) error {
    c.Response().Header.Add(fiber.HeaderCacheControl, "public")
    c.Response().Header.Add(fiber.HeaderCacheControl, "no-transform")
    return c.SendString(strings.Repeat("hello ", 200))
})

req := httptest.NewRequest(fiber.MethodGet, "/", nil)
req.Header.Set("Accept-Encoding", "gzip")
resp, _ := app.Test(req)
fmt.Println(resp.Header.Get("Content-Encoding")) // Prints "gzip" instead of ""
```

### Expected Behavior

shouldSkip in middleware/compress should honor no-transform across all response Cache-Control field lines and ignore commas inside quoted directive arguments, matching DefaultReq.HasHeaderValue.

### Fiber Version

v3.1.0-beta / main

### Code Snippet (optional)

```go
package main

import "github.com/gofiber/fiber/v3"
import "log"

func main() {
  app := fiber.New()

  // Steps to reproduce

  log.Fatal(app.Listen(":3000"))
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `f6b465f53549` and running the modified tests.