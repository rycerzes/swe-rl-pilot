# Issue

**Title:** Avoid reflect.Value.Call for common signatures

## Description

See 

I did some frequency logging in Hugo Docs repo.  I'm not sure where to draw the line here, but special handling the top 3 here at least I think would make a difference. This would mean pulling the `safeCall` method out into a hugo specific file and disable the original (see the fork script).

```
Function: func(...interface {}) string, Args: 1, Count: 254476
Function: func() string, Args: 0, Count: 141291
Function: func(context.Context, ...interface {}) (interface {}, error), Args: 1, Count: 92073
Function: func(interface {}, ...interface {}) bool, Args: 2, Count: 62729
Function: func() hmaps.Params, Args: 0, Count: 35066
Function: func(interface {}, interface {}) (bool, error), Args: 2, Count: 29134
Function: func(interface {}) (string, error), Args: 1, Count: 28055
Function: func(context.Context, string, ...interface {}) (interface {}, error), Args: 3, Count: 21407
Function: func(reflect.Value) bool, Args: 1, Count: 20014
Function: func() map[string]interface {}, Args: 0, Count: 19612
Function: func(...interface {}) (map[string]interface {}, error), Args: 2, Count: 16795
Function: func() interface {}, Args: 0, Count: 16678
Function: func() bool, Args: 0, Count: 15538
Function: func(string, ...interface {}) string, Args: 3, Count: 11573
Function: func(interface {}, ...interface {}) (interface {}, error), Args: 2, Count: 11372
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `8bac4de7a173` and running the modified tests.