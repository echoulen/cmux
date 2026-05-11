#!/usr/bin/env bash
# cmux installer — clones the repo and symlinks the cmux executable.
#
# Override locations with env vars:
#   CMUX_REPO_URL    git URL to clone from (default: official repo)
#   CMUX_INSTALL_DIR where to keep the source (default: ~/.local/share/cmux)
#   CMUX_BIN_DIR     where to put the symlink (default: ~/.local/bin)

set -euo pipefail

REPO_URL="${CMUX_REPO_URL:-https://github.com/echoulen/cmux.git}"
INSTALL_DIR="${CMUX_INSTALL_DIR:-$HOME/.local/share/cmux}"
BIN_DIR="${CMUX_BIN_DIR:-$HOME/.local/bin}"

echo "cmux installer"
echo "  source repo: $INSTALL_DIR"
echo "  binary link: $BIN_DIR/cmux"
echo

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "==> updating existing checkout"
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "==> cloning $REPO_URL"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

mkdir -p "$BIN_DIR"
ln -sfn "$INSTALL_DIR/cmux" "$BIN_DIR/cmux"

echo
echo "installed: $BIN_DIR/cmux -> $INSTALL_DIR/cmux"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo
        echo "warning: $BIN_DIR is not in your PATH."
        echo "add this to your shell rc (~/.zshrc, ~/.bashrc, ...):"
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac

echo
echo "test:    cmux help"
