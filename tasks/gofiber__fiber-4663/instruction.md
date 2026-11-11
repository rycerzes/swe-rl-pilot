# Issue

**Title:** 🐛 bug: preserve names for merged multi-method routes

## Description

### Motivation

- A recent change caused multi-method `Add` registrations that merge into existing per-method routes to retain the old route id on the merged entry, so `App.Name` failed to rename every method added by the same registration.  
- The intent is to restore the original behavior where a multi-method registration shares a single id across its per-method copies so naming and hooks observe the whole registration consistently.

### Description

- When merging handlers into an existing tail route, copy the shared registration id into the merged `preRoute` by assigning `preRoute.id = route.id`, so `Name` can match all methods of the same `Add` call.  
- Added `Test_App_Add_MultipleMethods_NameMergedRoutes` to cover the scenario where both `GET` and `POST` already exist and are merged by a subsequent multi-method `Add`, asserting both methods receive the new name.  
- No public API changes; this is a correctness fix that restores prior naming semantics.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `e69f183ffd1b` and running the modified tests.