#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=$(mktemp "${TMPDIR:-/tmp}/beanbao-activity.XXXXXX")
trap 'rm -f "$binary"' EXIT
clang -fobjc-arc -framework Foundation "$repo_root/tests/activity_store.m" \
    "$repo_root/app/ActivityStore.m" -o "$binary"
"$binary"
