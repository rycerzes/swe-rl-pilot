# Issue

**Title:** 🐛 [Bug]: Logger middleware — no sanitization on user-controlled log values (log injection)

## Description

### Bug Description

The logger middleware writes user-controlled values (path, URL, user-agent, body, headers) directly to the log buffer without sanitizing control characters. An attacker can inject `\r\n` sequences to forge log lines, evade SIEM detection, or corrupt audit trails.

### How to Reproduce

Steps to reproduce the behavior:
1. Use the logger middleware with `${path}` or `${url}` in the format
2. Send a request with `GET /admin%0d%0a200+GET+/legitimate+HTTP/1.1`
3. The logger writes two lines — the second looks like a legitimate 200 response
4. SIEM/audit tools interpret it as a separate request

### Affected Tags

`${path}`, `${url}`, `${ua}`, `${referer}`, `${ip}` (X-Forwarded-For), `${host}`, `${body}`, `${resBody}`, `${reqHeaders}`, `${queryParams}`, `${reqHeader:X}`, `${query:X}`, `${form:X}`, `${cookie:X}` — 15+ tag functions in `logger/tags.go` write user input without sanitization.

### Contrast

The `log/context.go` subsystem has proper sanitization via `writeSanitized()` that replaces control characters. The logger middleware does not use it.

### Affected Code

`middleware/logger/tags.go:108-151` (representative):
```go
TagPath: func(output Buffer, c fiber.Ctx, _ *Data, _ string) (int, error) {
    return output.WriteString(c.Path())       // No sanitization
},
TagURL: func(output Buffer, c fiber.Ctx, _ *Data, _ string) (int, error) {
    return output.WriteString(c.OriginalURL()) // No sanitization
},
TagBody: func(output Buffer, c fiber.Ctx, _ *Data, _ string) (int, error) {
    return output.Write(c.Body())             // No sanitization
},
```

### Expected Behavior

Apply the same `isControlByte` sanitization used in `log/context.go` to all tag functions that write user-controlled data.

### Fiber Version

v3 (latest main branch)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d8ae9aaaaea0` and running the modified tests.