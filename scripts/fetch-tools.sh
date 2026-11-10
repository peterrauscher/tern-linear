#!/bin/sh
# Download the dev tooling into .cache/ (gitignored). Idempotent: anything already present is kept.
#   .cache/bin/luau-lsp          type checker (pinned)
#   .cache/bin/stylua            formatter (pinned)
#   .cache/bin/luau              Luau CLI that runs test/unit (latest release)
#   .cache/linear-schema.graphql Linear's public SDL for test/validate-queries.mjs
set -eu

LUAU_LSP_VERSION=1.70.1
STYLUA_VERSION=v2.6.0

root=$(cd "$(dirname "$0")/.." && pwd)
bin="$root/.cache/bin"
dl="$root/.cache/dl"
mkdir -p "$bin" "$dl"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
Darwin)
	lsp_asset=luau-lsp-macos.zip
	luau_asset=luau-macos.zip
	case "$arch" in
	arm64 | aarch64) stylua_asset=stylua-macos-aarch64.zip ;;
	*) stylua_asset=stylua-macos-x86_64.zip ;;
	esac
	;;
Linux)
	luau_asset=luau-ubuntu.zip
	case "$arch" in
	aarch64 | arm64)
		lsp_asset=luau-lsp-linux-arm64.zip
		stylua_asset=stylua-linux-aarch64.zip
		;;
	*)
		lsp_asset=luau-lsp-linux-x86_64.zip
		stylua_asset=stylua-linux-x86_64.zip
		;;
	esac
	;;
*)
	echo "fetch-tools: unsupported OS '$os' (macOS and Linux only)" >&2
	exit 1
	;;
esac

# download REPO TAG ASSET: save a release asset into $dl; TAG "latest" selects the newest release.
download() {
	repo=$1
	tag=$2
	asset=$3
	rm -f "$dl/$asset"
	if command -v gh >/dev/null 2>&1; then
		if [ "$tag" = latest ]; then
			gh release download --repo "$repo" -p "$asset" -D "$dl"
		else
			gh release download "$tag" --repo "$repo" -p "$asset" -D "$dl"
		fi
	else
		if [ "$tag" = latest ]; then
			url="https://github.com/$repo/releases/latest/download/$asset"
		else
			url="https://github.com/$repo/releases/download/$tag/$asset"
		fi
		curl -fsSL -o "$dl/$asset" "$url"
	fi
}

# install_zip ASSET MEMBER: extract MEMBER from the downloaded zip into $bin.
install_zip() {
	unzip -oq "$dl/$1" "$2" -d "$bin"
	chmod +x "$bin/$2"
}

if ! { [ -x "$bin/luau-lsp" ] && "$bin/luau-lsp" --version 2>/dev/null | grep -q "$LUAU_LSP_VERSION"; }; then
	echo "fetch-tools: luau-lsp $LUAU_LSP_VERSION"
	download JohnnyMorganz/luau-lsp "$LUAU_LSP_VERSION" "$lsp_asset"
	install_zip "$lsp_asset" luau-lsp
fi

if ! { [ -x "$bin/stylua" ] && "$bin/stylua" --version 2>/dev/null | grep -q "${STYLUA_VERSION#v}"; }; then
	echo "fetch-tools: StyLua $STYLUA_VERSION"
	download JohnnyMorganz/StyLua "$STYLUA_VERSION" "$stylua_asset"
	install_zip "$stylua_asset" stylua
fi

if [ ! -x "$bin/luau" ]; then
	echo "fetch-tools: luau (latest)"
	download luau-lang/luau latest "$luau_asset"
	install_zip "$luau_asset" luau
fi

if [ ! -s "$root/.cache/linear-schema.graphql" ]; then
	echo "fetch-tools: Linear schema"
	curl -fsSL -o "$root/.cache/linear-schema.graphql.tmp" \
		https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql
	mv "$root/.cache/linear-schema.graphql.tmp" "$root/.cache/linear-schema.graphql"
fi
