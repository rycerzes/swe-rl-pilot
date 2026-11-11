# Issue

**Title:** i18n: Project translations can lose to module translations

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.168.0+extended+withdeploy darwin/arm64 BuildDate=2026-10-13T16:42:50Z VendorInfo=Homebrew
</pre>

### Does this issue reproduce with the latest release?

Reproduced on v0.168.0 and on `master` at 6b0c89c3c. I did not run the v0.169.0 release itself, but `master` has the same code.

### What happened

Project translations should override the same ID in a module, but with enough translation files in the module graph a module's value can win.

**Reproduction:** a project with `i18n/en.yaml` that imports nine modules, each with `i18n/en.yaml` and `i18n/pt-br.yaml`, all defining the same ID. That makes 19 translation files.

```
Expected: the project's value
Actual:   the value from the fourth module
```

With `de.yaml` in place of `pt-br.yaml`, the project's value wins.

**Cause:** `TranslationProvider.NewResource` sorts the files by the number of hyphens in their name, so that base tags are registered before their variants. It uses `sort.Slice`, which is not stable. Above 12 elements, equal keys can change order, and the last file parsed for an ID wins. The sort therefore decides precedence between same-named files from different modules.

**Fix:** use `sort.SliceStable`, which keeps the order that the filesystem walk produced. With that change and a regression test for the case above, `./check.sh ./langs/i18n` passes. I have a PR ready.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `185a609ec260` and running the modified tests.