#!/usr/bin/env bash
# A trivially-passing test that exists only to be ALIASED by `ci_job(test = ...)`.
# Its `tags = ["unit"]` is the point: those tags are what a tagged job suite
# filtered against, dropping it and leaving an empty gate.
echo ok
