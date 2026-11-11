# Issue

**Title:** Add ImageResource.FrameCount

## Description

* Returns > 1 for animated images
* Else 1
* For JPEG XL it will currently always return 1 (a technical limitation we may fix in the future) (will be added in #15431)
* All resources where `reflect.IsImageResourceWithMeta` returns true has a `FrameCount`.

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `0732eadd5aea` and running the modified tests.