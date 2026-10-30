#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_binary=$(mktemp -t beanbao-policy.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
clang -fobjc-arc -framework Foundation "$repo_dir/tests/native_policy.m" -o "$test_binary"
"$test_binary"
