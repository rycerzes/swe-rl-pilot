# Issue

**Title:** Add resources.Publish

## Description

So you can write:

```handlebars
{{ resources.Get "main.js" | js.Build | resources.Publish }}
```

Instead of:

```handlebars
{{ (resources.Get "main.js" | js.Build ).Publish }}
```

The first one reads much nicer in my eyes.

`resources.Publish` would return the `Resource` it gets as input.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0805c734a41b` and running the modified tests.