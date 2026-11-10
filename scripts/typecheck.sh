#!/bin/sh
# Type-check the plugin's host and lib modules against the installed Tern's API definitions.
# test/unit is plain Luau and runs under the luau CLI instead (see unit.sh).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sh scripts/fetch-tools.sh

if ! command -v tern >/dev/null 2>&1; then
	echo "typecheck: the 'tern' CLI is required to generate API definitions (tern plugin types); install Tern first." >&2
	exit 1
fi
tern plugin types .cache >/dev/null

# --platform=standard: no Roblox globals. `tern` comes from the generated definitions file.
exec .cache/bin/luau-lsp analyze \
	--platform=standard \
	--definitions=@tern=.cache/tern.d.luau \
	host.luau lib/*.luau
