# Issue

**Title:** Render hook with a custom layout is ignored, or used on pages without that layout

## Description

This came up while updating the lookup order docs.

```go
// See issue #15538.
func TestRenderHookCustomLayout(t *testing.T) {
	t.Parallel()

	files := `
-- hugo.toml --
disableKinds = ['home','rss','section','sitemap','taxonomy','term']
-- content/p1.md --
---
title: p1
layout: contact
---
[a](/b)
-- content/p2.md --
---
title: p2
---
[a](/b)
-- layouts/page.html --
{{ .Content }}
-- layouts/contact.html --
{{ .Content }}
-- layouts/_markup/render-link.html --
render-link.html
-- layouts/_markup/render-link.contact.html --
render-link.contact.html
`

	b := hugolib.Test(t, files)

	b.AssertFileContent("public/p1/index.html", "render-link.contact.html") // fails
	b.AssertFileContent("public/p2/index.html", "render-link.html", "! render-link.contact.html")
}

// See issue #15538.
func TestRenderHookPageKindAndCustomLayout(t *testing.T) {
	t.Parallel()

	files := `
-- hugo.toml --
disableKinds = ['home','rss','section','sitemap','taxonomy','term']
-- content/p1.md --
---
title: p1
layout: contact
---
[a](/b)
-- content/p2.md --
---
title: p2
---
[a](/b)
-- layouts/page.html --
{{ .Content }}
-- layouts/contact.html --
{{ .Content }}
-- layouts/_markup/render-link.html --
render-link.html
-- layouts/_markup/render-link.page.contact.html --
render-link.page.contact.html
`

	b := hugolib.Test(t, files)

	b.AssertFileContent("public/p1/index.html", "render-link.page.contact.html")
	b.AssertFileContent("public/p2/index.html", "render-link.html", "! render-link.page.contact.html") // fails
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b76fde2fbdb2` and running the modified tests.