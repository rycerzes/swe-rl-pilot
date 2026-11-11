# Issue

**Title:** Add .Site.Language.I18n method (or .Translate?)

## Description

Following the support question in [this forum thread](https://discourse.gohugo.io/t/get-i18n-string-from-arbitrary-language-not-current-pages-language/28811): it would be nice to have `site.Translation` method to leverage `i18n` information from the `.Translations` range.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `31f5395d4094` and running the modified tests.