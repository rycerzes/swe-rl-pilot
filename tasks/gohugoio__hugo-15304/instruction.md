# Issue

**Title:** markup/highlight: Escape lineAnchors before passing it to Chroma

## Description

Chroma writes the line anchor prefix verbatim into the id and href
attributes it generates, so a lineAnchors value from a code-fence
attribute could inject markup into the rendered page.

Thanks to @DONG2209 for reporting this issue.

Co-Authored-By: Nguyễn Quốc Đồng <126535119+DONG2209@users.noreply.github.com>
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9c2527f8558e` and running the modified tests.