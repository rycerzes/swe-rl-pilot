# Issue

**Title:** Add importContext to resources.Copy

## Description

The example below (and variations of it) isn't possible in Hugo:

```handlebars
{{ $r := resources.FromString "foo.css" "body { color: blue; }" }}
{{/* How do I get $r to resolve as an import in main.css?  */}}
{{ $css := resources.Get "css/main.css" | css.Build }}
```

And in `assets/css/main.js`:

```css
@import "foo.css" screen;
@import "bar.css" print;
```

The example above uses `css.Build`, but this is also relevant for (at least) `css.Sass`, `js.Build` and `js.Batch`. There are more or less ugly workardounds for the above (e.g. `resources.Concat` or passing in css vars in a map), but it would be nice to have a direct way that worked for all (I have a new proposal in mind that would need this).

I suggest we add [importContext](https://gohugo.io/functions/js/batch/#import-contex) to [resources.Copy](https://gohugo.io/functions/resources/copy/#article) and make the logic that's currently implemented in [js.Batch](https://gohugo.io/functions/js/batch/#article) also work for the other relevant funcs, e.g:

```handlebars
{{ $foo := resources.FromString "foo.css" "body { color: blue; }" }}
{{ $bar := resources.FromString "bar.css" "body { color: green; }" }}
{{ $main := resources.Get "css/main.css" | resources.Copy (dict "importContext" (slice $foo $bar)) }}
{{ $css := $main | css.Build }}
```

The current signature of `resources.Copy` is:

```
resources.Copy TARGETPATH RESOURCE
```

I suggest we 

```
resources.Copy [STRING or MAP] RESOURCE
```

And make it optional (we can determine a path from RESOURCE). So for the MAP options it would look like:

```handlebars
{{ $opts := dict
   "targetPath" "foo.css"
   "importContext" (slice $foo $bar)
}}
```

In the above `importContext` is the same as described in [inputContext](https://gohugo.io/functions/js/batch/#import-context) -- which also allows constructs ala:

```handlebars
{{ $common := resources.Match "/js/headlessui/*.*" }}
{{ $importContext := (slice $.Page ($common.Mount "/js/headlessui" ".")) }}
{{ $opts := dict
   "importContext" $importContext
}}
```

Some implementation hints:

* We would store this new importContext in some unexported field. I suggest we follow the pattern in the funcs `resources.Internal*` to access this internal state.
* `js.Batch` takes `importContext` as an option. That import handling is more advanced than we need here, but we look at that for inspiriation/reuse.
* I suggest that we start with `css.Build` and, once that looks good, implement it in `js.Build/Batch`, `css.Sass` and `css.TailwindCSS`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8a468df065a7` and running the modified tests.