# Issue

**Title:** Upper case letters in path causing match to fail

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
Hugo Static Site Generator v0.74.3-DA0437B4/extended linux/amd64 BuildDate: 2020-07-23T16:30:30Z
</pre>

### Does this issue reproduce with the latest release?
yes

Probably easiest to read jmoorings comment on the forum:
https://discourse.gohugo.io/t/upper-case-letters-in-path-causing-match-to-fail/28069

Basically there seems to be an issue when matching folder names that have upper case letters in. jmooring suggests it is because case normalisation is being done on the pattern, rather than on the directory path.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `d2010fcc9cd3` and running the modified tests.