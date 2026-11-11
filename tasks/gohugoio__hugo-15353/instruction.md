# Issue

**Title:** Automatic summary may generate invalid HTML with blockquotes and lists

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.151.0+extended+withdeploy darwin/arm64 BuildDate=2025-10-02T13:30:36Z VendorInfo=brew
</pre>

### Does this issue reproduce with the latest release?

Yes

## Issue

Using a blockquote that extends past the `.Summary` cutoff causes the content below `{{ .Summary }}` to be treated as part of the blockquote until the end of the parent tag. [Reproduction repo](https://github.com/imomaliev/hugo-blockquote-summary-leak)

<img width="848" height="652" alt="Image" src="https://github.com/user-attachments/assets/212f747c-af3c-4af5-89fe-78fe9dc04ebd" />

Hugo's `.Summary` may lead to `blockquote` end tag be below cutoff point

## Explanation

In most modern browsers this html code will be parsed and rendered without errors

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
</head>
<body>
  <main>
    <blockquote>
      <p>1</p>
  </main>
</body>
</html>
```

Leading to shown in browser as a source

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
</head>
<body>
  <main>
    <blockquote>
      <p>1</p>
      
    </blockquote>
  </main>
</body>
</html>
```

This is due to [these parsing rules](html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody#:~:text=An%20end%20tag%20whose%20tag%20name%20is%20one%20of%3A%20%22address%22%2C%20%22article%22%2C%20%22aside%22%2C%20%22blockquote%22)

> An end tag whose tag name is one of: "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search", "section", "select", "summary", "ul"
> 
>     If the stack of open elements does not have an element in scope that is an HTML element with the same tag name as that of the token, then this is a parse error; ignore the token.
> 
>     Otherwise, run these steps:
> 
>         Generate implied end tags.
> 
>         If the current node is not an HTML element with the same tag name as that of the token, then this is a parse error.
> 
>         Pop elements from the stack of open elements until an HTML element with the same tag name as the token has been popped from the stack.

## To Discuss

I think the best case scenario is for `.Summary` to handle generation of implied tags. But I am not sure how to do that myself.

For now I plan to provide a PR with fixes for a theme and docs, to avoid confusion and errors

- 
-

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `ec57bb7d3489` and running the modified tests.