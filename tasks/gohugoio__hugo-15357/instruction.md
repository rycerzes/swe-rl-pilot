# Issue

**Title:** tpl/transform: Strip BOM prior to unmarshaling a resource or string

## Description

Reference: <https://discourse.gohugo.io/t/57561>

Although the forum topic above is about CSV data, I think we'd have the same/similar problem with JSON, XML, and TOML data.

Failing example:

```text
git clone --single-branch -b hugo-github-issue-15335 https://github.com/jmooring/hugo-testing hugo-github-issue-15335
cd hugo-github-issue-15335
hugo --ignoreCache && cat public/index.html
```

Expected:

```text
city: tokyo|country: japan|
fruit: apple|color: red|
id: 1234|role: developer|
vehicle: car|type: sedan|
name: laptop|price: 999.99|
```

Actual:

```text
city: |country: japan|
fruit: |color: red|
id: |role: developer|
vehicle: |type: sedan|
name: |price: 999.99|
```

---

```go
// See issue 15355
func TestUnmarshalCSVWithBOM(t *testing.T) {
	t.Parallel()

	bom := "\xef\xbb\xbf"

	files := `
-- hugo.toml --
disableKinds = ['page','rss','section','sitemap','taxonomy','term']
-- layouts/home.html --
{{ $r := resources.Get "a.csv" }}
{{ $opts := dict "targetType" "map" "format" "csv" }}
{{ $data := transform.Unmarshal $opts $r }}
{{ range $data }}
column_a: {{ .column_a }}|column_b: {{ .column_b }}|
{{ end }}
-- assets/a.csv --
` + bom + `column_a,column_b
foo,bar
`

	b := hugolib.Test(t, files)

	b.AssertFileContent("public/index.html", "column_a: foo|column_b: bar|")
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `5698de946837` and running the modified tests.