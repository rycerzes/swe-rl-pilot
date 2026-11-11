# Issue

**Title:** 🐛 bug: overwrite X-Real-IP in proxy.Balancer like the other forwarding helpers

## Description

## Summary

`Forward`, `DomainForward` and `BalancerForward` replace a client-sent `X-Real-IP` with `c.IP()`; `Balancer` forwarded it unchanged. It now calls the same `setRealIP`, before `ModifyRequest`, so an application setting its own value keeps it. The docs no longer tell `Balancer` users to replicate this by hand.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `11954d103387` and running the modified tests.