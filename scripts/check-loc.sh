#!/bin/sh
# Fails if any Zig source file exceeds the project's per-file line limit.
limit="${1:-500}"
status=0
for f in $(find src -name '*.zig' | sort); do
    n=$(wc -l < "$f")
    if [ "$n" -gt "$limit" ]; then
        echo "$f: $n lines (limit $limit)" >&2
        status=1
    fi
done
exit $status
