# Issue

**Title:** 🐛 [Bug]: "ShutdownWithTimeout" & "ShutdownTimeout" not respected

## Description

### Bug Description

I created a dummy function, that just offers a 10GB file as download and send it the stop signal (`CRTL + C`) after starting the download.
Even though I started the server with `ShutdownTimeout=10 * time.Second` and stopped him with `app.ShutdownWithTimeout(10 * time.Second)` the app shut down immediately and did not wait the configured time.

### How to Reproduce

1. `dd if=/dev/urandom of=/tmp/large_files/large_file.bin bs=1M count=10240 status=progress`

2. CONFIG
```go
// Pfad zur großen Datei
const largeFilePath = "/tmp/large_files/large_file.bin"

// HandleLargeFileStream streamt eine echte 10GB Datei
// Dies hält die Verbindung für eine längere Zeit offen, abhängig von der Downloadgeschwindigkeit
func HandleLargeFileStream(c fiber.Ctx) error {
	// Datei öffnen
	file, err := os.Open(largeFilePath)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).SendString(fmt.Sprintf("Fehler beim Öffnen der Datei: %v", err))
	}
	defer file.Close()

	// Dateigröße ermitteln
	fileInfo, err := file.Stat()
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).SendString(fmt.Sprintf("Fehler beim Abrufen der Dateigröße: %v", err))
	}
	fileSize := fileInfo.Size()

	// Header setzen
	c.Set("Content-Type", "application/octet-stream")
	c.Set("Content-Disposition", "attachment; filename=\"large_file.bin\"")
	c.Set("Content-Length", fmt.Sprintf("%d", fileSize))

	c.SendFile(largeFilePath)
	return nil
}
```
```go
// Fiber Listen configuration
fiberConfig := fiber.ListenConfig{
	ShutdownTimeout: 10 * time.Second,
}
```

Set up this Signal-Trap:

```go
// Set up graceful shutdown
c := make(chan os.Signal, 1)
signal.Notify(c, os.Interrupt, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)
go func() {
	<-c
	_ = app.ShutdownWithTimeout(cfg.Server.ShutdownTimeout)
}()
```

### Expected Behavior

I was expecting it to close all listeners but to respect ALL currently active connections (untill the timeout). But this did not happen, the app shut down immediately.

### Fiber Version

v3.0.0-beta.4

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `aadd456b8335` and running the modified tests.