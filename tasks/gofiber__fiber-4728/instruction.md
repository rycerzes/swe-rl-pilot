# Issue

**Title:** 🐛 [Bug]: static on a partial wildcard route strips its prefix without a segment boundary

## Description

### Bug Description

With `static.New` mounted on a route whose wildcard follows the prefix without a slash (`app.Get("/static*", ...)`), the prefix `/static` is stripped without checking for a following `/`. `GET /staticprivate/secret.txt` therefore opens `private/secret.txt` under the root, so middleware mounted on `/static/private` does not run for it. Segment-bounded mounts (`/static/*`, `app.Use("/static", ...)`) answer 404 for the same request.

### How to Reproduce

```go
app := fiber.New()
app.Use("/static/private", func(c fiber.Ctx) error {
	return c.SendStatus(fiber.StatusForbidden)
})
app.Get("/static*", static.New("./public")) // ./public/private/secret.txt exists
```

- `GET /static/private/secret.txt` returns 403
- `GET /staticprivate/secret.txt` returns 200 with the contents of `private/secret.txt`

### Expected Behavior

static serves only what lies below the mount's path segment: for `/static*` the remainder should be empty or start with `/`, otherwise 404.

### Fiber Version

v3.0.0 through v3.5.0, and main at 0a8f3635.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0a8f3635d9e5` and running the modified tests.