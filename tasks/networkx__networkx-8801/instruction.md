# Issue

**Title:** Allow spectral_layout to handle dim>=len(G). Added dim tests.

## Description

Added a check for the shape of the `spectral_layout` output to match the given `dim`, and pad the array with zeroes if necessary. This doesn't affect the general result but it creates a more consistent output from layout methods with the dimensions that the user is expecting.

Another option would be to raise a `ValueError` when `dim>len(G)` for this layout method, but it would mean a different behaviour compared to the other layout methods that do allow that range of `dim`.

Without the modification the new tests would fail for `spectral_layout` but not for any other of the 'unrestricted' layout methods, and the error raised internally is a broadcast error when `center` is added, which is not very informative.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `f884a12db34c` and running the modified tests.