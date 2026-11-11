# Issue

**Title:** time.Format and time.AsTime may change the time zone name

## Description

`time.Format` and `time.AsTime` may change the zone name of a `time.Time` value. The result depends on the time zone of the system running Hugo.

- If the system zone has a different offset, the offset replaces the name, for example `-0800` instead of `PST`. The `:time_long` and `:time_full` layouts show no zone.
- If the system zone has the same offset, the system zone name replaces the name, for example `KST` instead of `JST` when `TZ` is `Asia/Seoul`.
- A zone with a zero offset always shows as `UTC`, for example `UTC` instead of `GMT`.

This also affects page dates when `timeZone` is set in the project configuration. A front matter date without an offset gets its zone from `timeZone`, and `time.Format` then changes it. For example, with `timeZone = 'America/Los_Angeles'` and a build server set to UTC, `{{ time.Format "15:04 MST" .Date }}` shows `-0800` instead of `PST`.

The `.Format` method is not affected.

With the system time zone set to `America/Los_Angeles`:

```go-html-template
{{ $t := time.AsTime "2023-01-28T07:44:58Z" | time.In "America/New_York" }}
{{ $t.Format "15:04 MST" }} → 02:44 EST
{{ time.Format "15:04 MST" $t }} → 02:44 -0500
```

The cause is a workaround for #8895. Hugo converts every `time.Time` value to RFC 3339 text and parses it again, but the text keeps only the offset, not the zone name. The fix returns values that already have a zone name unchanged, and still converts values without one, such as TOML datetimes with an offset.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `bdde5aa5155c` and running the modified tests.