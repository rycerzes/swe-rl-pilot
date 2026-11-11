# Issue

**Title:** Double mounting content into assets does not live reload content changes

## Description

### What version of Hugo are you using (`hugo version`)?
```
$ hugo version
hugo v0.134.1-+extended windows/amd64 BuildDate=2024-09-05T10:17:50Z VendorInfo=gohugoio
```
I am using Windows 10.

### Does this issue reproduce with the latest release?
Clone and setup my blog.
```
git clone https://github.com/jsmolka/blog
cd blog
npm i
hugo server -F -D
```
Then change the content of any markdown file. Hugo detects the change, but it's not visible in the browser. Even reloading the page doesn't reflect the changes. I doesn't work with Chrome and Firefox. I need to restart hugo to see the changes. I had this issue for a while and stayed on a older hugo version, hoping for the fix. It stopped working when upgrading from v0.122.0 to v0.123.0.

Hope this helps, thanks for the otherwise great library.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `6b3ba3a7e22a` and running the modified tests.