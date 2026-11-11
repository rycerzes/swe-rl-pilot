# Issue

**Title:** navigation: Escape pre/post in front matter menu entries

## Description

Front matter is content, which is not trusted, but the `pre` and `post` values of menu entries defined there were rendered as unescaped `template.HTML`.

These are now HTML escaped unless `text/html` is allowed in `security.allowContent`, which already marks HTML from `/content` as trusted. A warning (`warning-menu-pre-post-html-escaped`) is logged when a value containing HTML markup is escaped.

Menu entries defined in the project configuration are not affected.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `b86e0caa279a` and running the modified tests.