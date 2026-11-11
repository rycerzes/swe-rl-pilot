# Issue

**Title:** templates.Defer: identical block bodies in different output formats share one escaping mode, chosen non-deterministically per build

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.164.0-+extended windows/amd64 BuildDate=2026-07-06T16:39:30Z VendorInfo=gohugoio
</pre>

### Does this issue reproduce with the latest release?

Yes.

```text
hugo v0.165.0-+extended windows/amd64 BuildDate=2026-08-12T14:26:28Z VendorInfo=gohugoio
```

Over one run of 40 consecutive builds of the unchanged reproduction site below with that binary, 28 builds published the wrong value in `public/index.html` and 12 published the wrong value in `public/index.txt`. All 40 exited 0, and none printed a warning or an error.

### Summary

When two templates belonging to different output formats contain byte-identical `templates.Defer` block bodies, both blocks do execute, each with its own correct output-format context. What they share is the escaping applied inside the block, and which of the two escaping modes survives changes from build to build of an unchanged site. On every build exactly one of the two outputs is therefore wrong: either an HTML page publishes a value raw that it escapes correctly a few characters earlier outside the block, or a plain-text page receives HTML entities.

### Reproduction

Three files in an empty directory. No content, no modules, no external tooling.

`hugo.toml`:

```toml
baseURL = 'https://example.org/'
title = 'defer probe'
disableKinds = ['page', 'section', 'taxonomy', 'term', 'RSS', 'sitemap', 'robotsTXT']

[outputFormats.probe]
mediaType = 'text/plain'
baseName = 'index'
isPlainText = true

[outputs]
home = ['html', 'probe']
```

`layouts/home.html`:

```go-html-template
{{ $v := "<b>&" }}OUT[{{ $v }}]{{ with (templates.Defer (dict "key" "K" "data" (dict "v" $v))) }}IN[{{ .v }}]{{ end }}
```

`layouts/home.probe.txt`, byte-identical to `layouts/home.html` (both md5 `c921197a9c8637852e38d94a0352359d`):

```go-html-template
{{ $v := "<b>&" }}OUT[{{ $v }}]{{ with (templates.Defer (dict "key" "K" "data" (dict "v" $v))) }}IN[{{ .v }}]{{ end }}
```

`OUT[...]` interpolates the value outside the deferred block, `IN[...]` interpolates the same value inside it. Then run `hugo` several times without changing anything, and look at `public/index.html` and `public/index.txt` after each run.

### What happens

Two consecutive runs of the same command on the unchanged site, pasted verbatim:

```text
$ hugo --logLevel info
Start building sites …
hugo v0.164.0-+extended windows/amd64 BuildDate=2026-07-06T16:39:30Z VendorInfo=gohugoio

INFO  build:  step process substep collect files 0 files_total 0 pagesources_total 0 resourcesources_total 0 duration 0s
INFO  build:  step process duration 0s
INFO  build:  step assemble duration 0s
INFO  build:  step render substep pages site en outputFormat html duration 1.3703ms
INFO  build:  step render substep pages site en outputFormat probe duration 509.5µs
INFO  build:  step render pages 2 content 0 duration 1.8798ms
INFO  build:  step render deferred count 2 duration 1.7766ms
INFO  build:  step postProcess duration 0s
INFO  build:  duration 4.171ms

                  │ EN
──────────────────┼────
 Pages            │  2
 Paginator pages  │  0
 Non-page files   │  0
 Static files     │  0
 Processed images │  0
 Aliases          │  0
 Cleaned          │  0

Total in 12 ms
--- public/index.html ---
OUT[&lt;b&gt;&amp;]IN[<b>&]
--- public/index.txt ---
OUT[<b>&]IN[<b>&]
```

```text
$ hugo --logLevel info
Start building sites …
hugo v0.164.0-+extended windows/amd64 BuildDate=2026-07-06T16:39:30Z VendorInfo=gohugoio

INFO  build:  step process substep collect files 0 files_total 0 pagesources_total 0 resourcesources_total 0 duration 513.8µs
INFO  build:  step process duration 513.8µs
INFO  build:  step assemble duration 0s
INFO  build:  step render substep pages site en outputFormat html duration 517.9µs
INFO  build:  step render substep pages site en outputFormat probe duration 517.2µs
INFO  build:  step render pages 2 content 0 duration 1.0351ms
INFO  build:  step render deferred count 2 du

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d6e6f9e500ee` and running the modified tests.