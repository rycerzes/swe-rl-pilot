# Issue

**Title:** bug(healthcheck): HEAD requests return 404 instead of matching GET status

## Description

## Bug Description

The healthcheck middleware only checks for `GET` requests:

```go
if c.Method() != fiber.MethodGet {
    return c.Next()
}
```

A `HEAD` request to `/livez` or `/readyz` falls through to `c.Next()` and returns 404.

## Expected Behavior

Per RFC 9110 §9.3.2, `HEAD` must respond identically to `GET` (same status code, same headers) but with no response body. A healthy probe should return 200, an unhealthy probe should return 503.

## How to Reproduce

```go
app := fiber.New()
app.Use(healthcheck.New())

req := httptest.NewRequest(http.MethodHead, "/livez", nil)
resp, _ := app.Test(req)
fmt.Println(resp.StatusCode) // prints 404, expected 200
```

## Fiber Version

v3 (latest main)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `1104ec30d669` and running the modified tests.