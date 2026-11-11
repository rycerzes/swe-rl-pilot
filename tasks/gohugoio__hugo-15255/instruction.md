# Issue

**Title:** Title used in permalink does not have forward slash escaped

## Description

I have this permalink set up for posts.

    permalinks:
      post: "/post/:year/:month/:day/:slug"

Characters like a dot and forward slash in the posts title does not get replaced in the generated permalink for the post.

This example title

    Lorem ipsum dolor sit amet/consectetur do example.org

generates the following permalink

    /post/2006/02/02/lorem-ipsum-dolor-sit-amet/consectetur-do-example.org/

I had hoped it would become

    /post/2006/02/02/lorem-ipsum-dolor-sit-amet-consectetur-do-example-org/

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `49835f8fe949` and running the modified tests.