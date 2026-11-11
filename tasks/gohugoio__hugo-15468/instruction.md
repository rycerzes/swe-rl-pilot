# Issue

**Title:** images.Overlay and images.Mask output name changes depending on whether the overlaid image came from the file cache

## Description

This issue report was written by Claude Opus 5.5, and checked against Hugo v0.168.0.

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.168.0-+extended linux/amd64 BuildDate=2026-10-13T16:42:50Z VendorInfo=gohugoio
</pre>

### Does this issue reproduce with the latest release?

Yes. It also reproduces with v0.167.0, and the code involved is unchanged on master (77230eb).

### Description

When the image passed to `images.Overlay` (or `images.Mask`) was itself processed, the filtered image's file name depends on whether that processed image was created in this build or read from the file cache. With an empty resource cache, build 1 publishes the overlay under one name and build 2 under another. The bytes are identical. From build 2 onwards the name stays the same.

Expected: the same name in every build.
Actual: one name in the first build after the overlaid image is (re)processed, and a different name in later builds.

### Reproduction

```sh
#!/usr/bin/env bash
# Usage: ./repro.sh [extra hugo flags, e.g. --gc]
set -euo pipefail
cd "$(mktemp -d)"
mkdir -p assets layouts
# 64x64 solid-colour PNG
echo 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAATklEQVR42u3PQQkAAAgEsIt20Y1mBN/CYAWWaV+LgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgMBlAXfcAS0jwTZyAAAAAElFTkSuQmCC' | base64 -d > assets/a.png
echo "disableKinds = ['page', 'rss', 'section', 'sitemap', 'taxonomy', 'term']" > hugo.toml
cat > layouts/home.html <<'HTML'
{{- $a := resources.Get "a.png" -}}
{{- $s := $a.Process "resize 32x" -}}
overlay={{ ($a | images.Filter (images.Overlay $s 0 0)).RelPermalink }} key={{ $s.Key }}
HTML
for i in 1 2 3; do
  ${HUGO:-hugo} --quiet "$@"
  echo "build $i: $(cat public/index.html)"
  echo "  resources/_gen/images: $(ls resources/_gen/images | tr '\n' ' ')"
done
(cd public && md5sum a_hu_*.png)
```

Output with v0.168.0:

```
$ ./repro.sh
build 1: overlay=/a_hu_41f8c20fc0cc13b7.png key=/a_hu_498f860d9a6e2307.png_2100844135326038661
  resources/_gen/images: a_hu_41f8c20fc0cc13b7.png a_hu_498f860d9a6e2307.png
build 2: overlay=/a_hu_2068adca79b7981a.png key=/a_hu_498f860d9a6e2307.png
  resources/_gen/images: a_hu_2068adca79b7981a.png a_hu_41f8c20fc0cc13b7.png a_hu_498f860d9a6e2307.png
build 3: overlay=/a_hu_2068adca79b7981a.png key=/a_hu_498f860d9a6e2307.png
  resources/_gen/images: a_hu_2068adca79b7981a.png a_hu_41f8c20fc0cc13b7.png a_hu_498f860d9a6e2307.png
afcf7e427a895667f311c7877366ee4a  a_hu_2068adca79b7981a.png
afcf7e427a895667f311c7877366ee4a  a_hu_41f8c20fc0cc13b7.png

$ ./repro.sh --gc
build 1: overlay=/a_hu_41f8c20fc0cc13b7.png key=/a_hu_498f860d9a6e2307.png_2100844135326038661
  resources/_gen/images: a_hu_41f8c20fc0cc13b7.png a_hu_498f860d9a6e2307.png
build 2: overlay=/a_hu_2068adca79b7981a.png key=/a_hu_498f860d9a6e2307.png
  resources/_gen/images: a_hu_2068adca79b7981a.png a_hu_498f860d9a6e2307.png
build 3: overlay=/a_hu_2068adca79b7981a.png key=/a_hu_498f860d9a6e2307.png
  resources/_gen/images: a_hu_2068adca79b7981a.png a_hu_498f860d9a6e2307.png
afcf7e427a895667f311c7877366ee4a  a_hu_2068adca79b7981a.png
afcf7e427a895667f311c7877366ee4a  a_hu_41f8c20fc0cc13b7.png
```

`$s.Key` has a `_<hash>` suffix in build 1 and none in build 2. Both overlay files in `public/` have the same MD5. Replacing `images.Overlay $s 0 0` with `images.Mask $s` gives the same pattern: two names, identical bytes.

### Cause

- On a file cache hit, `ImageCache.getOrCreate` marks the image with `setSourceFilenameIsHash(true)`. The `create` path just below it does not:
  https://github.com/gohugoio/hugo/blob//resources/image_cache.go#L67
- `genericResource.Key()` appends `_<hash>` only when `!l.sourceFilenameIsHash` (`includeHashInKey` is always true for images, [resource_spec.go#L204](https://github.com/gohugoio/hugo/blob//resources/resource_spec.go#L204)):
  https://github.com/gohugoio/hugo/blob//resources/resource.go#L465
- `Overlay` and `Mask` put the other image's `Key()` into the filter options, and

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `77230eba0469` and running the modified tests.