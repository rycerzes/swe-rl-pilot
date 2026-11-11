# Issue

**Title:** Add Resource.Data.Artifacts (or something)

## Description

I'm very unsure about the naming above (it was the first I came up with).

But this is relevant for `css.Build` and `js.Build`. There may be other use cases, but when e.g. 

* loading fonts from `/assets` using `url` and ESBuild's `file`loader.
* the font file gets a hash in its name (ESBuild is doing this) and it get published (copied to `public`) as part of the `css.Build` function execution.
* With the above it's not simple/practical to do font preloading (`<link rel="preload" href="???" as="font" type="font/woff2" crossorigin="anonymous">`), because the output filename is not known.

Ignoring the naming discussion, I suggest that we do:

```handlebars
{{ $css := resources.Get "main.css" | css.Build }}
{{ range $css.Data.Artifacts }}
  {{ if eq .MediaType.MainType "font" }}
    <link rel="preload" href="{{ .RelPermalink }}" as="font" type="{{ .MediaType.Type }}" crossorigin="anonymous">
  {{ end }}
{{ end }}
```

Note that the above construct should be safe to run on older versions of Hugo (`$css.Data.Artifacts` will return `nil`).

The "artifacts" above are already published, so they can only have a sub set of the `Resource` interface, but I guess it makes sense to keep the familiar method names (this way the "dot" can be passed to link partials):

```go
type Artifact interface {
   resource.ResourceLinksProvider
   resource.MediaTypeProvider
}
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `2ffaf1fc1edb` and running the modified tests.