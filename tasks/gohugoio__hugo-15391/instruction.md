# Issue

**Title:** tpl/tplimpl: HTML table render hook ignored for non-HTML output formats

## Description

Reference: <https://discourse.gohugo.io/t/user-table-render-hook-ignored-for-output-formats-other-than-html/57589>

```go
// See issue 15389.
func TestTableHookHTMLOnlyWithJSONOutput(t *testing.T) {
	t.Parallel()

	files := `
-- hugo.toml --
disableKinds = ['page', 'rss', 'section', 'sitemap', 'taxonomy', 'term']
[outputs]
  home = ['html', 'json']
-- content/_index.md --
---
title: home
---

col_a|col_b
---|---
foo|bar
-- layouts/_markup/render-table.html --
TABLE RENDER HOOK
-- layouts/home.html --
{{ .Content }}
-- layouts/home.json --
{{ .Content }}
`

	b := hugolib.Test(t, files)

	b.AssertFileContent("public/index.html", "TABLE RENDER HOOK")
	b.AssertFileContent("public/index.json", "TABLE RENDER HOOK") // fails, uses embedded table render hook
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fdbba5a6614d` and running the modified tests.