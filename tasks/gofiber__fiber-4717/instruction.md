# Issue

**Title:** 🐛 [Bug]: panic on route pattern with trailing escape character

## Description

### Bug Description

Registering a route whose pattern ends with a trailing backslash — for example `/:id\` — causes an unrecovered `index out of range [-1]` panic during application startup.

The backslash is a parameter-end character, so `/:id\` creates a parameter segment followed by a constant segment whose `Const` field is empty (after `RemoveEscapeChar`). In `addParameterMetaInfo` (`path.go:863`), the `else` branch indexes `segs[i].Const[len(segs[i].Const)-1]` without checking that `Const` is non-empty, which panics on `Const[-1]`.

### How to Reproduce

Steps to reproduce the behavior:
1. Create a Fiber v3 application
2. Register a route with pattern \`/:id\\\`
3. Application panics at startup with \`runtime error: index out of range [-1]\`

### Expected Behavior

Route registration should not panic. The framework should either handle the empty constant segment gracefully or reject the invalid pattern with a clear error.

### Fiber Version

v3.5.0 (main branch, )

### Code Snippet (optional)

\`\`\`go
package main

import "github.com/gofiber/fiber/v3"
import "log"

func main() {
  app := fiber.New()

  app.Get("/:id\\", func(c fiber.Ctx) error {
    return c.SendString("hello")
  })

  log.Fatal(app.Listen(":3000"))
}
\`\`\`

Stack trace:
\`\`\`
goroutine 1 [running]:
github.com/gofiber/fiber/v3.addParameterMetaInfo({...})
    path.go:863 +0x190
github.com/gofiber/fiber/v3.(*routeParser).parseRoute(...)
    path.go:583 +0x40f
github.com/gofiber/fiber/v3.parseRoute(...)
    path.go:810 +0xb0
\`\`\`

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `7c56c53bb2ea` and running the modified tests.