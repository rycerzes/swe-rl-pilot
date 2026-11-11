# Issue

**Title:** Support relative path calls in partials

## Description

Right now partial calls only supports path relative to `layout/partials` and `themes/<THEME>/layouts/partials/*<PARTIALNAME>` (taken from the documentation).

This is fine when we have few partials but can become a pain if we need to organize them in subdirectories.

What i propose is to add support for relative paths like in this example : 

```
{{ partial "./foo" ... }}
{{ partial "../bah" ... }}
```

## Why ?

Having this feature could be beneficial in a lot or ways : 
- it avoid us having to remember and write the full partial path when it's not needed (for example utility partials that are only called and only used by a on partial)
- It could allow us to reorganize partials way more easily, as relative paths would full path independent

## How to implement

If the path in a partial call starts with "./" or "../", it's a relative path. Otherwise it's an "absolute" path (relative to `layout/partials`).

I'm against adding the current directory of the current partial to the lookup search directly though, as theme and site authors currently assume this would call to the partial root directory. Perhaps we could add this to the future, if my proposal is adopted by the community.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9e4059cfca84` and running the modified tests.