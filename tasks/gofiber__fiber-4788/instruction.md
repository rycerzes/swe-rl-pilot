# Issue

**Title:** 🚀 [Feature]: Add map support to QueryParser

## Description

### Feature Description

It would be handy to be able to use fields with type map[string]<any> with gofiber's QueryParser for queries where we don't know an exhaustive list of valid values.

### Additional Context (optional)

_No response_

### Code Snippet (optional)

```go
// An example of using go's maps for filtering products from an API.
// A map is more useful than a struct here because it does not have to provide an exhaustive list of all valid queries. 

type Product struct {
    PriceMin int `query:"price_min"`
    PriceMax int `query:"price_max"`
    Attributes map[string]string `query:"attributes"`
}

app.Get("/", func(c *fiber.Ctx) error {
        p := new(Product)

        if err := c.QueryParser(p); err != nil {
            return err
        }
})

// http://localhost:3000/?price_min=1&price_max=1000&attributes[colour]=red&attributes[screensize]=1000x500
```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `9122a279a5f0` and running the modified tests.