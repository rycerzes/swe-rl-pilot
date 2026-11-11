# Issue

**Title:** 🐛 [Bug]: Logger reports 200 for requests rejected by GETOnly with 405

## Description

### Bug Description

When `GETOnly: true`, non-GET/HEAD requests are correctly rejected with `405 Method Not Allowed`, but the logger records them as `200`.

Minimal config:

```
app := fiber.New(fiber.Config{
    GETOnly:             true,
})

app.Use(logger.New())
app.Get("/", func(c fiber.Ctx) error {
		return c.SendStatus(fiber.StatusOK)
	})

log.Fatal(app.Listen(":8080"))
```

### How to Reproduce

1. Request:
`curl -i -X POST http://localhost:8080/`
2. The client correctly receives:
`HTTP/1.1 405 Method Not Allowed`
3. But the server log contains something like:
`11:38:33 | 200 |         167ns |       127.0.0.1 | POST    | /`

### Expected Behavior

The log should report the actual response status `405 POST /`.

### Fiber Version

3.5.0

### Code Snippet (optional)

```go

```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d835c422349a` and running the modified tests.