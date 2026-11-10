#!/bin/sh
# Run every test/unit/*.test.luau with the Luau CLI; fail when any exits non-zero.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sh scripts/fetch-tools.sh

failed=0
count=0
for test in test/unit/*.test.luau; do
	[ -e "$test" ] || continue
	count=$((count + 1))
	echo "== $test"
	if ! .cache/bin/luau "$test"; then
		failed=$((failed + 1))
		echo "FAILED: $test" >&2
	fi
done

if [ "$count" -eq 0 ]; then
	echo "unit: no test/unit/*.test.luau files found" >&2
	exit 1
fi
if [ "$failed" -ne 0 ]; then
	echo "unit: $failed of $count test files failed" >&2
	exit 1
fi
echo "unit: $count test files passed"
