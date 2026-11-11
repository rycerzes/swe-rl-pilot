# Issue

**Title:** Auto heading ID falls back to `heading`/`heading-N` when a heading's link text begins with `[`

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.168.0- darwin/arm64 BuildDate=2026-10-13T17:24:15Z VendorInfo=gohugoio
</pre>

### Does this issue reproduce with the latest release?

Yes, also with 0.158 and 0.164.

### Description

I have a blog where link articles as H2/H3 headings, and then the body provides a synopsis of that article.
When a heading is a link whose text begins with `[` (which is common for arXiv.org links -- `[2603.24477] Title`), Hugo generates an empty auto heading ID and falls back to `heading`, `heading-1`, and so on. The same text without the link gets a normal ID. 

In a render hook for the same heading, `.Anchor` is `heading` and `.PlainText` is just `[`. `.Fragments` reports the full title (`[2603.24477] Composer 2 Technical Report`), but with the fallback ID.

### Replication

`hugo.toml`:

```toml
baseURL = "https://example.org/"
disableKinds = ["taxonomy", "term", "rss", "sitemap", "robotsTXT", "404"]
```

`content/post.md`:

```markdown
---
title: Repro
---

## [[2603.24477] Composer 2 Technical Report](https://arxiv.org/abs/2603.24477)

## [Plain link heading](https://example.com)

## [2603.24477] Bracketed text, no link

## [[2504.18425] Kimi-Audio Technical Report](https://arxiv.org/abs/2504.18425)
```

`layouts/single.html`:

```go-html-template
{{ .Content }}
```

Run `hugo` and inspect `public/post/index.html`:

```html
<h2 id="heading">…</h2>
<h2 id="plain-link-heading">…</h2>
<h2 id="260324477-bracketed-text-no-link">…</h2>
<h2 id="heading-1">…</h2>
```

Instead of the generic `heading` and `heading-1`, i would expect an ID derived from the heading text.
For the first `heading`, this might look like `260324477-composer-2-technical-report`, as suggested by the third heading transformation.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `ed22b85c192d` and running the modified tests.