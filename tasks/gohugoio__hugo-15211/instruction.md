# Issue

**Title:** ReadingTime and FuzzyWordCount have off-by-one errors in their ceiling calculations

## Description

## Summary

Two related integer-arithmetic bugs in `hugolib/page__content.go` (in the plain-content calculation), causing behavior that deviates from documented intent at boundary values.

## 1. `ReadingTime` divides by 213/501 instead of 212/500

```go
if isCJKLanguage {
    result.readingTime = (result.wordCount + 500) / 501
} else {
    result.readingTime = (result.wordCount + 212) / 213
}
```

The intent is a reading speed of 212 words per minute (500 for CJK), rounded up. But the correct ceiling-division idiom is `(n + d - 1) / d`. As written, the expression computes `ceil(wordCount / 213)` and `ceil(wordCount / 501)`, so the effective reading speeds are 213 and 501 wpm.

| wordCount | current: `(wc+212)/213` | expected at 212 wpm: `ceil(wc/212)` |
|---|---|---|
| 212 | 1 | 1 |
| 213 | **1** | **2** |
| 424 | 2 | 2 |
| 425 | **2** | **3** |

Proposed fix:

```go
result.readingTime = (result.wordCount + 211) / 212   // non-CJK
result.readingTime = (result.wordCount + 499) / 500   // CJK
```

## 2. `FuzzyWordCount` overshoots on exact multiples of 100

```go
result.fuzzyWordCount = (result.wordCount + 100) / 100 * 100
```

Documented as the word count "rounded up to the nearest multiple of 100", but adding 100 unconditionally bumps exact multiples to the *next* multiple:

| wordCount | current | expected |
|---|---|---|
| 99 | 100 | 100 |
| 100 | **200** | **100** |
| 101 | 200 | 200 |
| 0 | **100** | **0** |

Proposed fix:

```go
result.fuzzyWordCount = (result.wordCount + 99) / 100 * 100
```

Both changes only affect output at exact boundary values, but they do change rendered output for existing sites (e.g., a 100-word page's `FuzzyWordCount` drops from 200 to 100), so this may warrant a changelog note.

## Integration Test

<details>
<summary>hugolib/page_test.go</summary>

```go
// See issue 15206.
func TestReadingTimeAndFuzzyWordCountBoundaries(t *testing.T) {
	t.Parallel()

	files := `
-- hugo.toml --
disableKinds = ["home", "section", "taxonomy", "term", "rss", "sitemap"]
-- content/p99.md --
---
title: p99
---
` + strings.Repeat("word ", 99) + `
-- content/p100.md --
---
title: p100
---
` + strings.Repeat("word ", 100) + `
-- content/p101.md --
---
title: p101
---
` + strings.Repeat("word ", 101) + `
-- content/p211.md --
---
title: p211
---
` + strings.Repeat("word ", 211) + `
-- content/p212.md --
---
title: p212
---
` + strings.Repeat("word ", 212) + `
-- content/p213.md --
---
title: p213
---
` + strings.Repeat("word ", 213) + `
-- content/p499.md --
---
title: p499
isCJKLanguage: true
---
` + strings.Repeat("你", 499) + `
-- content/p500.md --
---
title: p500
isCJKLanguage: true
---
` + strings.Repeat("你", 500) + `
-- content/p501.md --
---
title: p501
isCJKLanguage: true
---
` + strings.Repeat("你", 501) + `
-- layouts/page.html --
{{ .WordCount }}|{{ .FuzzyWordCount }}|{{ .ReadingTime }}
`

	b := Test(t, files)

	b.AssertFileContent("public/p99/index.html", "99|100|1")
	b.AssertFileContent("public/p100/index.html", "100|100|1") // fails
	b.AssertFileContent("public/p101/index.html", "101|200|1")

	b.AssertFileContent("public/p211/index.html", "211|300|1")
	b.AssertFileContent("public/p212/index.html", "212|300|1")
	b.AssertFileContent("public/p213/index.html", "213|300|2") // fails

	b.AssertFileContent("public/p499/index.html", "499|500|1")
	b.AssertFileContent("public/p500/index.html", "500|500|1") // fails
	b.AssertFileContent("public/p501/index.html", "501|600|2") // fails
}
```
</details>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0805c734a41b` and running the modified tests.