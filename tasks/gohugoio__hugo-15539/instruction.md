# Issue

**Title:** snap: Failure to resolve media type with resources.GetRemote

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.119.0-+extended linux/amd64 BuildDate=2023-09-24T15:20:17Z VendorInfo=snap:0.119.0
</pre>

### Does this issue reproduce with the latest release?
yes

### Steps to reproduce

1. Create a new repo
2. Add `config.yaml` with the following contents
```
# config.yaml
disableKinds:
- sitemap
- taxonomy
- term
outputs:
  home:
  - html
```
3. Add `layouts\index.html` with the following contents
```
{{/* prebuild/layouts/index.html */}}
<ul>
{{ with resources.GetRemote "https://blog.arb.dev/feed/?t=1698195621" | transform.Unmarshal }}
  {{ range .channel.item }}
    {{ $timestamp := time .pubDate }}
    {{ $link := .link | plainify | htmlUnescape }}
    {{ $postID := replace $link "https://blog.arb.dev/" "" }}
    {{ $postID := replace $postID "/" "-" }}
    {{/* 1. */}} {{ $string := printf "<h1>%s</h1>%s" .title .description }} 
    {{/* 2. */}} {{ $filename := printf "post/%s/%s.md" (urlize $timestamp.Year) (urlize $postID) }} 
    {{/* 3. */}} {{ $resource := resources.FromString $filename $string }} 
    {{/* 4. */}} {{ $file := $resource.RelPermalink }}
    <li><a href="{{$filename}}">{{$filename}}</a></li>
  {{ end }}
{{ end }}
</ul>
```
4. Run `hugo server` and you will see a successfully generated page with links to all of files that have been generated
![image](https://github.com/gohugoio/hugo/assets/20059577/fb0bae18-0870-4861-a52a-0735e0c321dd)

5. Run `hugo` and no child files will be generated and the resulting `index.html` page will be blank

Additional info:
If you print the output of `resources.GetRemote "https://proton.me/blog/feed"  | transform.Unmarshal` on build it generates the following error.
```
map[error calling resources.GetRemote:failed to resolve media type for remote resource "https://blog.arb.dev/feed/?t=1698195621"] 
```

Please note, I'm using `https://blog.arb.dev/feed/?t=1698195621` as a stand in for the this example.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `fa5a3d48b8dc` and running the modified tests.