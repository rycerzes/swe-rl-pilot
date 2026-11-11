# Issue

**Title:** 🔥 feat: Added support for custom binding precedence

## Description

# Description

Currently, Fiber's ctx.Bind().All() method binds values from request sources using a strict, hardcoded precedence (URI params -> Body -> Query -> Headers -> Cookies). If conflicting data exists across these sources, developers have no mechanism to override which source takes priority on a per-struct basis.

This PR introduces support for a new struct tag, binding_source, which allows developers to define a custom precedence order for data binding. For example: binding_source:"query,header,cookie,body,uri".

To maintain Fiber's strict zero-allocation and high-performance standards, this implementation avoids parsing struct tags or splitting strings on the hot path for every request. Instead, it utilizes a highly optimized internal caching layer (bindingPrecedenceCache via sync.Map) to process and store the precedence configuration exactly once per reflect.Type.

Fixes # (issue)

## Changes introduced

List the new features or adjustments introduced in this pull request. Provide details on benchmarks, documentation updates, changelog entries, and if applicable, the migration guide.

- [x] Benchmarks: Describe any performance benchmarks and improvements related to the changes.
- [x] Documentation Update: Detail the updates made to the documentation and links to the changed files.
- [x] Changelog/What's New: Include a summary of the additions for the upcoming release notes.
- [ ] Migration Guide: If necessary, provide a guide or steps for users to migrate their existing code to accommodate these changes.
- [ ] API Alignment with Express: Explain how the changes align with the Express API.
- [ ] API Longevity: Discuss the steps taken to ensure that the new or updated APIs are consistent and not prone to breaking changes.
- [ ] Examples: Provide examples demonstrating the new features or changes in action.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `61997d2ddad8` and running the modified tests.