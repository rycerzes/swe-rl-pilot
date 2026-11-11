# Issue

**Title:** 🐛 bug: equalize basicauth verification time across mixed hash algorithms

## Description

## Summary

With `Users` mixing hash tiers (algorithms such as bcrypt and SHA-256, or different bcrypt costs during a migration), a known user of a cheaper tier answered faster than an unknown user, who paid the strongest hash, so response time revealed which usernames exist. Every attempt now runs one check per configured tier, the user's own in its tier and a stand-in in each other, so known and unknown users do the same work. A single-tier setup still runs exactly one check.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `11954d103387` and running the modified tests.