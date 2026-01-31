#!/usr/bin/env bash
# uninstall.sh - Uninstall Forge CLI
# Removes runtime and optionally config. Never touches project .forge/ directories.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

INSTALL_DIR="$HOME/.forge"
CONFIG_DIR="$HOME/.config/forge"
BIN_DIR="${FORGE_BIN_DIR:-$HOME/.local/bin}"

echo ""
echo "Forge Uninstaller"
echo "================="
echo ""

# Step 1: Remove symlink
if [ -L "$BIN_DIR/forge" ]; then
  rm "$BIN_DIR/forge"
  print_success "Removed symlink: $BIN_DIR/forge"
elif [ -f "$BIN_DIR/forge" ]; then
  rm "$BIN_DIR/forge"
  print_success "Removed binary: $BIN_DIR/forge"
else
  print_info "No symlink found at $BIN_DIR/forge"
fi

# Step 2: Remove installation directory
if [ -d "$INSTALL_DIR" ]; then
  echo ""
  read -p "Remove Forge runtime at $INSTALL_DIR? (y/N): " REMOVE_INSTALL
  if [[ "$REMOVE_INSTALL" =~ ^[Yy]$ ]]; then
    rm -rf "$INSTALL_DIR"
    print_success "Removed $INSTALL_DIR"
  else
    print_info "Kept $INSTALL_DIR"
  fi
else
  print_info "No installation found at $INSTALL_DIR"
fi

# Step 3: Remove config directory
if [ -d "$CONFIG_DIR" ]; then
  echo ""
  read -p "Remove Forge config at $CONFIG_DIR? (y/N): " REMOVE_CONFIG
  if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    print_success "Removed $CONFIG_DIR"
  else
    print_info "Kept $CONFIG_DIR (your settings are preserved)"
  fi
else
  print_info "No config found at $CONFIG_DIR"
fi

echo ""
print_success "Forge uninstalled"
print_info "Project .forge/ directories were NOT removed (they belong to each project)"
echo ""
