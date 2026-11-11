# Issue

**Title:** Improve the return keyword in templates

## Description

There's a long-living upstream issue about this ( which I don't think is going to be fixed in Go anytime soon.

We do have some patches to Go's template execution package, so if the fix I have in mind for this isn't too intrusive in that package (as in: it makes it very hard to maintain the fork), I think it's worth to improve this situation.

We have added a `return` keyword, but it currently have some limiations:

* It only works in partials.
* It must be the last command in the template.
* The current implementation, with its template transformations, has some complexities that would be great to rid of.

I have often wanted to return early, even from regular templates, which often avoids wrapping large block of templates in conditionals.

So, I suggest we have a look if it's feasible to introduce a sentinel error with an optional value (used in partials), so the template func (with the `return` alias) would be something ala:

```go
func (ns *Namespace) Return(args ...any) ReturnErr {
  var val any = nil
   if len(args) > 0 {
      val = args[0]
   }
   return &ReturnErr(val: val}}
}
```

And then somehow trapped in the template execution.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `49dceb19f546` and running the modified tests.