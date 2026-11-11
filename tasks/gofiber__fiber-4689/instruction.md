# Issue

**Title:** 🐛 bug: preserve IPv6 brackets in proxy domain forwarding

## Description

### Motivation
- Fix a regression where `foldHostnameLabel` removed the brackets from bracketed IPv6 authorities (e.g. `[::1]:8080`) when reconstructing host:port, causing `DomainForward` rules with port-qualified IPv6 literals to fail to match incoming `Host` headers.

### Description
- Reconstruct configured host-and-port values with `net.JoinHostPort` so bracketed IPv6 literals remain bracketed after IDNA/case folding and preserved ports are compared correctly.
- Add an end-to-end regression test `Test_Proxy_DomainForward_HostMatchPreservesIPv6Brackets` that verifies `DomainForward("[::1]:8080", ...)` proxies a matching request instead of falling through.
- Import `net` in `middleware/proxy/proxy.go` and update `foldHostnameLabel` to use `net.JoinHostPort`; no change to runtime matching logic beyond preserving bracketed IPv6 formatting.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `255b89cd10c9` and running the modified tests.