# Issue

**Title:** Remove libsass

## Description

`libsass` has been deprecated for a long time and it's time to remove it. The upstream library has been deprecated even longer (since 2020?). And since this is the last CGO/extended feature, we can also finally (pheww) remove the extended build harness.

We have a separate issue about the release side of this in #15502. This issue is about removing the use of the `extended` build tag in  the source:

* Return an error when transpiler is set to `libsass` in `css.Sass`.
* Remove all `libsass` related code.
* Have `hugo.IsExtended` always return false.
* Remove all `extended` related code and test flags (e.g. in magefile.go)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `471d0fb3ef05` and running the modified tests.