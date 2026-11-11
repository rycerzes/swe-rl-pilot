# Issue

**Title:** 🐛 fix(limiter): floor sub-second expiration in sliding window

## Description

## Description

`SlidingWindow` computes the window length as:

```go
expiration := uint64(expirationDuration.Seconds())
```

Any **positive sub-second** `ExpirationFunc` value truncates to `0`. The window weight is then

```go
weight := float64(resetInSec) / float64(expiration) // / 0  -> +Inf/NaN
rate   := int(math.Ceil(float64(e.prevHits)*weight)) + e.currHits
```

so `rate` becomes garbage and **every request — including the first — is rejected with `429`**, regardless of `Max`. A limiter configured with, say, `ExpirationFunc: func(fiber.Ctx) time.Duration { return 500*time.Millisecond }` blocks all traffic.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `990459752ff6` and running the modified tests.