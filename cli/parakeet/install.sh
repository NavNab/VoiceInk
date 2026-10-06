#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/share/voiceink-cli/bin}"

swift build -c release --package-path "$PACKAGE_DIR"
BIN_PATH="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)/voiceink-cli"

mkdir -p "$TARGET_DIR"
install -m 0755 "$BIN_PATH" "$TARGET_DIR/voiceink-cli.new"
mv -f "$TARGET_DIR/voiceink-cli.new" "$TARGET_DIR/voiceink-cli"

"$TARGET_DIR/voiceink-cli" --version
echo "Installed $TARGET_DIR/voiceink-cli"
