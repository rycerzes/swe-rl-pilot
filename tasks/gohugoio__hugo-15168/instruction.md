# Issue

**Title:** Add classDark and classLight to css.ChromaStyles and "gen chromastyles" (default dark/light)

## Description

I argued with @jmooring that it would be very unlikely that e.g. the CSS `dark` class would collide with existing classes in a project. After thinking a little, I still don't think that is a likely issue, but:

1. I suspect there are JS/CSS frameworks with other naming standards for these mode classes (e.g. `theme-dark`)
2. I would be an annoyed Hugo user if I needed to customise this class and had to do ugly string replacements.
3. The cost for us adding these 2 new options is small.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `64da6d7c62a2` and running the modified tests.