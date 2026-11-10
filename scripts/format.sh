#!/bin/sh
# Format the Luau sources with StyLua (config: .stylua.toml). `--check` only reports differences.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sh scripts/fetch-tools.sh

case "${1:-}" in
"") mode= ;;
--check) mode=--check ;;
*)
	echo "usage: format.sh [--check]" >&2
	exit 2
	;;
esac

# shellcheck disable=SC2086 # $mode is empty or a single flag
exec .cache/bin/stylua $mode host.luau lib test/unit
