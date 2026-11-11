# Issue

**Title:** Build hangs forever after 10 page render errors: `renderPages` blocks on `pages <- p` after `errorCollator` calls `Stop`

## Description

This report was written by Claude Opus 5.5

## What version of Hugo are you using?

```text
hugo v0.168.0- linux/amd64 BuildDate=2026-10-13T16:42:50Z VendorInfo=gohugoio
```

## Does this issue reproduce with the latest release?

Yes.

## What happened

When a build has 10 or more page render errors, `hugo` sometimes never exits.
It prints no error, uses no CPU, and waits forever. A SIGQUIT dump shows the
page walker in `renderPages` blocked sending to `pages`, and `errorCollator`
blocked on its final send to `errs`. No `pageRenderer` goroutines are left.

The hang is a race. With default settings, the reproducer below hung in 26 of
500 builds on a 16-CPU linux/amd64 machine. With `GOMAXPROCS=1
HUGO_NUMWORKERMULTIPLIER=2` (the script's defaults; they only change
scheduling), it hung in 30 of 30 builds (3 runs of the script, 10 builds each,
about 50 seconds per run).

## Expected

The build fails promptly and prints the collated render errors.

## Reproducer

POSIX shell. It creates a site in `$(mktemp -d)` whose pages all fail to render
(`.Content` on a nil resource), builds it `RUNS` times, treats a build that
doesn't exit within `LIMIT` seconds as hung, and prints the goroutine dump of
the first hung build (`timeout -s QUIT`). It deletes the site when done.

```sh
#!/bin/sh
# Build a site whose pages all fail to render, RUNS times; report builds
# that don't exit within LIMIT seconds and print the first one's goroutines.
HUGO=${HUGO:-hugo}
PAGES=${PAGES:-50}
RUNS=${RUNS:-10}
LIMIT=${LIMIT:-5}
# Scheduling settings that make the race hit almost every time.
# Set both to "" to use Hugo's defaults (the hang is then much rarer).
export GOMAXPROCS="${GOMAXPROCS-1}"
export HUGO_NUMWORKERMULTIPLIER="${HUGO_NUMWORKERMULTIPLIER-2}"

dir=$(mktemp -d) || exit 1
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT TERM

site=$dir/site
mkdir -p "$site/layouts" "$site/content"
printf 'disableKinds = ["taxonomy", "term", "rss", "sitemap"]\n' > "$site/hugo.toml"
# .Content on a nil resource: every page fails to render.
printf '{{ (resources.Get "missing.svg").Content }}\n' > "$site/layouts/single.html"
cp "$site/layouts/single.html" "$site/layouts/list.html"
i=1
while [ "$i" -le "$PAGES" ]; do
  printf -- '---\ntitle: p%s\n---\n' "$i" > "$site/content/p$i.md"
  i=$((i + 1))
done

"$HUGO" version
echo "GOMAXPROCS=$GOMAXPROCS HUGO_NUMWORKERMULTIPLIER=$HUGO_NUMWORKERMULTIPLIER PAGES=$PAGES"
hung=0 n=1
while [ "$n" -le "$RUNS" ]; do
  timeout -s QUIT "$LIMIT" "$HUGO" -s "$site" -d "$dir/public" > "$dir/log" 2>&1
  if [ $? = 124 ]; then
    hung=$((hung + 1))
    echo "build $n: hung (no exit after ${LIMIT}s)"
    [ "$hung" = 1 ] && cp "$dir/log" "$dir/first-hang"
  else
    echo "build $n: exited"
  fi
  n=$((n + 1))
done
echo "hung in $hung of $RUNS builds"
if [ "$hung" -gt 0 ]; then
  echo "--- output of first hung build (SIGQUIT goroutine dump) ---"
  cat "$dir/first-hang"
  exit 1
fi
```

Run it with `HUGO=/path/to/hugo sh repro.sh`. For Hugo's default scheduling,
run `GOMAXPROCS= HUGO_NUMWORKERMULTIPLIER= RUNS=500 sh repro.sh`.

### Example output

From one run of the script above (`HUGO=/path/to/hugo-0.168.0 sh repro.sh`).
The goroutine dump is trimmed to its header and the two blocked goroutines,
with runtime frames and frame addresses removed.

```text
hugo v0.168.0- linux/amd64 BuildDate=2026-10-13T16:42:50Z VendorInfo=gohugoio
GOMAXPROCS=1 HUGO_NUMWORKERMULTIPLIER=2 PAGES=50
build 1: hung (no exit after 5s)
...
build 10: hung (no exit after 5s)
hung in 10 of 10 builds
--- output of first hung build (SIGQUIT goroutine dump) ---
Start building sites … 
hugo v0.168.0- linux/amd64 BuildDate=2026-10-13T16:42:50Z VendorInfo=gohugoio

SIGQUIT: quit
...
goroutine 10 gp=0x11c2c5fce3c0 m=nil [chan send]:
github.com/gohugoio/hugo/hugolib.(*Site).renderPages.func1({0x2fcd600?, 0x11c2c5d48600?}, {0x2fc04c8?, 0x11c2c6789e30?})
	/root/project/hugo/hugolib/site_render.go:98 +0xa9
github.com/gohugoio/hugo/hugolib/doctree.(*NodeShiftTreeWalker[...]).Walk.func

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `683a877f0cce` and running the modified tests.