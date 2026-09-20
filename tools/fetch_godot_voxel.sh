#!/usr/bin/env bash
# Downloads the Godot editor build that ships Zylann's Voxel Tools module into ./bin.
#
#   tools/fetch_godot_voxel.sh [version]
#
# Voxel Tools is a C++ module, not an addon: it only exists in a custom Godot
# build. Release binaries are published on the module's repository.
set -euo pipefail

VERSION="${1:-v1.7}"
REPO="Zylann/godot_voxel"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"

case "$(uname -s)" in
	Linux) ASSET="godot.linuxbsd.editor.x86_64.zip" ;;
	Darwin) ASSET="godot.macos.editor.app.zip" ;;
	*) echo "Unsupported platform; download $ASSET manually from https://github.com/$REPO/releases" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
echo "Downloading $URL"
curl -fsSL -o "$BIN_DIR/$ASSET" "$URL"
unzip -o "$BIN_DIR/$ASSET" -d "$BIN_DIR"
rm "$BIN_DIR/$ASSET"
chmod +x "$BIN_DIR"/godot.* 2>/dev/null || true
echo "Editor ready in $BIN_DIR"
