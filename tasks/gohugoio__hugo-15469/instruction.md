# Issue

**Title:** partialCached: Site variant hashes to language only, ignoring version and role

## Description

### TL;DR

- A `Site` passed as a `partialCached` variant hashes to its language only
- **Expected**: a `Site` variant keys on its full site vector (language, version, role), not just its language
- Cause: `siteWrapper.Key()` returns `Language().Lang` (`resources/page/site.go`); returning what `String()` encodes would fix it

### Repro

`hugo.yaml`:

```yaml
defaultContentVersion: v2.0.0
versions:
  v1.0.0: {}
  v2.0.0: {}
```

`content/_index.md` front matter: `sites: { matrix: { versions: ["**"] } }`
`layouts/_partials/p.html`: `{{ return .String }}`
`layouts/all.html`: `{{ range hugo.Sites }}{{ partialCached "p.html" . . }};{{ end }}`

**Expected**: `Site [0 0 0]: [en v2.0.0 guest];Site [0 1 0]: [en v1.0.0 guest];`
**Actual**: `Site [0 0 0]: [en v2.0.0 guest];Site [0 0 0]: [en v2.0.0 guest];`

Keying by `.String` instead of `.` gives the expected output.

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.168.0- darwin/arm64 BuildDate=2026-10-13T16:42:50Z
</pre>

Does this issue reproduce with the latest release? Yes (also on v0.166.0).

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `77230eba0469` and running the modified tests.