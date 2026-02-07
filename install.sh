#!/usr/bin/env bash
################################################################################
# install.sh - Dotfiles Installation Script
#
# PURPOSE:
#   Create symlinks from this repo to system locations.
#   Safe to run multiple times (idempotent).
#
# USAGE:
#   ./install.sh           # Interactive install
#   ./install.sh --force   # Overwrite existing without prompting
#
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory (where dotfiles repo lives)
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

FORCE=false
for arg in "$@"; do
  case $arg in
    --force) FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [--force]"
      echo "  --force: Overwrite existing files without prompting"
      exit 0
      ;;
  esac
done

log_info() { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Create symlink with backup
create_symlink() {
  local source="$1"
  local target="$2"
  local target_dir
  target_dir=$(dirname "$target")

  # Ensure target directory exists
  if [[ ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
    log_info "Created directory: $target_dir"
  fi

  # Handle existing file/symlink
  if [[ -e "$target" || -L "$target" ]]; then
    # If it's already a symlink pointing to the right place, skip
    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
      log_success "Already linked: $target → $source"
      return 0
    fi

    if [[ "$FORCE" == true ]]; then
      # Backup existing
      mkdir -p "$BACKUP_DIR"
      mv "$target" "$BACKUP_DIR/"
      log_warning "Backed up existing: $target → $BACKUP_DIR/"
    else
      log_warning "Exists: $target (use --force to overwrite)"
      return 0
    fi
  fi

  # Create symlink
  ln -s "$source" "$target"
  log_success "Linked: $target → $source"
}

################################################################################
# MAIN INSTALLATION
################################################################################

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Dotfiles Installation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Dotfiles directory: $DOTFILES_DIR"
echo ""

# 1. ZSH Configuration
log_info "Installing zsh configuration..."
create_symlink "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"

# 2. Git Configuration
log_info "Installing git configuration..."
create_symlink "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
create_symlink "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"

# 3. Hammerspoon
log_info "Installing Hammerspoon configuration..."
create_symlink "$DOTFILES_DIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"

# 4. Scripts (add to ~/bin for easy access)
log_info "Installing utility scripts..."
mkdir -p "$HOME/bin"
create_symlink "$DOTFILES_DIR/scripts/mac_cleanup.sh" "$HOME/bin/mac_cleanup"
create_symlink "$DOTFILES_DIR/scripts/analyze_brew_deps.sh" "$HOME/bin/analyze_brew_deps"
create_symlink "$DOTFILES_DIR/scripts/find_app_leftovers.sh" "$HOME/bin/find_app_leftovers"

# 5. LaunchAgent (for scheduled cleanup)
if [[ -f "$DOTFILES_DIR/launchd/com.user.mac-cleanup.plist" ]]; then
  log_info "Installing LaunchAgent for scheduled cleanup..."
  mkdir -p "$HOME/Library/LaunchAgents"
  create_symlink "$DOTFILES_DIR/launchd/com.user.mac-cleanup.plist" "$HOME/Library/LaunchAgents/com.user.mac-cleanup.plist"
  
  # Load the agent if not already loaded
  if ! launchctl list | grep -q "com.user.mac-cleanup"; then
    launchctl load "$HOME/Library/LaunchAgents/com.user.mac-cleanup.plist" 2>/dev/null || true
    log_success "LaunchAgent loaded"
  fi
fi

################################################################################
# POST-INSTALL
################################################################################

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if ~/bin is in PATH
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  log_warning "~/bin is not in your PATH. Add this to your .zshrc:"
  echo '  export PATH="$HOME/bin:$PATH"'
  echo ""
fi

echo "Next steps:"
echo "  1. Source your zshrc: source ~/.zshrc"
echo "  2. Reload Hammerspoon (Cmd+Ctrl+Alt+R if hotkey enabled)"
echo "  3. Test scripts: mac_cleanup --help"
echo ""

if [[ -d "$BACKUP_DIR" ]]; then
  log_warning "Backups saved to: $BACKUP_DIR"
fi
