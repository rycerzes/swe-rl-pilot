# Issue

**Title:** config/allconfig: Improve resilience of hugo mod init

## Description

If the project configuration references output formats defined by an imported module, `hugo mod init` fails before it can do its job. For example:

> ERROR failed to create config: unknown output format "print" for kind "section"

The module that defines the output format can't be loaded until the project is initialized, so the command should tolerate unknown output formats rather than refusing to run. Same applies to `defaultOutputFormat`.

Reference: <https://discourse.gohugo.io/t/57512>

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `49835f8fe949` and running the modified tests.