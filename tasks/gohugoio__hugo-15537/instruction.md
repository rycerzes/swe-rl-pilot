# Issue

**Title:** Shortcode with a custom layout is used in RSS output instead of the default shortcode

## Description

This came up while updating the lookup order docs. 

```go
// See issue #15536.
func TestShortcodeCustomLayoutInOtherOutputFormat(t *testing.T) {
	t.Parallel()

	files := `
-- hugo.toml --
disableKinds = ['page','section','taxonomy','term']
-- content/_index.md --
---
title: home
---
[a](/b) {{< sc >}}
-- layouts/home.html --
{{ .Content }}
-- layouts/home.rss.xml --
{{ .Content }}
-- layouts/_markup/render-link.rss.xml --
render-link.rss.xml
-- layouts/_shortcodes/sc.html --
sc.html
-- layouts/_shortcodes/sc.contact.html --
sc.contact.html
`

	b := hugolib.Test(t, files)

	b.AssertFileContent("public/index.html", "sc.html", "! sc.contact.html")
	b.AssertFileContent("public/index.xml", "sc.html", "! sc.contact.html") // fails
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fa5a3d48b8dc` and running the modified tests.