# Issue

**Title:** Make .Render take additional data

## Description

See https://gohugo.io/methods/page/render/#article

> PAGE.Render NAME

This has been discussed before. 

* The contract has always been that the templates that `.Renders` gets the data context as e.g. `page.html`, a `page.Page`.
* We can only pass 1 argument to Go's template renderer, which I guess is the blocking reason for not having done this sooner.

So, if we want to do:

> PAGE.Render [DATA] NAME

I'm guessing we have 2 top-level options:

* We say that if `DATA` is set, we use that as the context passed to the templates,. else `PAGE`.
* We somehow (e.g. by embeding it in a `{ DataAdditionalContext, Page }` struct or  putting it into the current `context.Context`) wrap the `Page` so you can do both `.RelPermalink` and `.DataAdditionalContext` (naming of the latter is just picked out of a hat without thinking too hard.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `49dceb19f546` and running the modified tests.