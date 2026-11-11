# Issue

**Title:** hugo server: page cut at its previous length when another content file changes in the same batch

## Description

Hi,

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.165.0-+extended linux/amd64 BuildDate=2026-08-12T14:26:28Z VendorInfo=gohugoio
</pre>

### Does this issue reproduce with the latest release?

Yes (v0.166.0).

### Steps to reproduce

```sh
hugo new site repro && cd repro
mkdir -p layouts/_default && printf '{{ .Content }}' > layouts/_default/single.html
printf -- '---\ntitle: a\n---\npage a\n' > content/a.md
printf -- '---\ntitle: c\n---\npage c\n' > content/c.md
hugo server &
sleep 3
printf -- '---\ntitle: a\n---\npage a\n' > content/a.md   # same content
printf 'appended line\n' >> content/c.md                   # same event batch
sleep 2
curl -s http://localhost:1313/c/
```

### What did you expect to see?

`<p>page c appended line</p>`

### What did you see instead?

`<p>page c</p>`. The page is rendered from the new bytes but cut at the old length. Shrinking `c.md` instead yields U+FFFD past the end, or `.Summary: slice bounds out of range [:650] with capacity 640`. Changing `c.md` alone renders correctly. Only reproduces when the rewritten file sorts before the changed one.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `881c0ec70d74` and running the modified tests.