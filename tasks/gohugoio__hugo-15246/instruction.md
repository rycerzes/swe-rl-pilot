# Issue

**Title:** hugo mod npm pack emits a publishable, checkout-named package.json

## Description

**TL;DR**: the generated `package.json` has no `"private": true` and a checkout-derived `name`, so committed copies are publishable under names sites don't control. Suggested fix: emit `"private": true` and a stable (ideally scoped) default name.

### What version of Hugo are you using (`hugo version`)?

```
hugo v0.165.0-+extended darwin/arm64 BuildDate=2026-08-12T14:26:28Z VendorInfo=gohugoio
```

### Does this issue reproduce with the latest release?

Yes (transcript below is v0.165.0). The behavior is in master's [package_builder.go](https://github.com/gohugoio/hugo/blob/master/modules/npm/package_builder.go).

### What happened

`hugo mod npm pack` writes `packages/hugoautogen/package.json` with:

- a **name derived from the checkout directory**, so it varies per clone and can be a registry name the site doesn't control, and
- **no `"private": true`**, npm's do-not-publish guard for internal packages.

The file is regenerated wholesale on each run, so hand-set fields don't survive. From a fresh clone of a repo whose committed copy was hand-normalized:

```console
$ git clone https://github.com/google/docsy-example.git site-a && cd site-a
$ grep -E '"(name|version|private)"' packages/hugoautogen/package.json
  "name": "@docsy/hugoautogen",
  "version": "0.1.0",
  "private": true
$ hugo mod npm pack
$ grep -E '"(name|version|private)"' packages/hugoautogen/package.json
  "name": "site-a",
  "version": "0.1.0"
```

A sibling clone of the same repo into `site-b` yields `"name": "site-b"`.

### Why it matters

Sites that commit the generated workspace (e.g. so `npm ci` works without running Hugo first) end up carrying a manifest that npm workspace publishing and common release tools treat as publishable by default: `npm publish --dry-run --workspaces` packs it as `site-a@0.1.0`, while with `"private": true` npm skips the workspace. The name variance also churns the committed manifest, and the lockfile's workspace entry, across differently named checkouts.

### What did you expect

The generated internal workspace is non-publishable (`"private": true`) and has a stable, project-controlled default name rather than the checkout directory's basename. Ideally the default is scoped: a bare name can be claimed on the registry by anyone, a scoped one only by the scope owner.

### Workaround

 follows each pack invocation with a single `npm pkg set` line restoring a scoped name and `private`.

Happy to send a PR for the `private` field (and for the name default, if you have a preference for what it should be).

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `166d3ee1ce94` and running the modified tests.