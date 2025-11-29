#!/usr/bin/env bash
################################################################################
# find_app_leftovers.sh - Detect Leftover Application Files
# 
# PURPOSE:
#   Scan ~/Library for files/folders from potentially uninstalled applications.
#   Helps identify what can be safely removed.
#
# USAGE:
#   bash find_app_leftovers.sh
#   bash find_app_leftovers.sh --detailed    # Show more information
#
# OUTPUT:
#   Lists folders in Application Support, Preferences, Caches that may be
#   from uninstalled apps, sorted by size.
#
################################################################################

set -euo pipefail

# Disable pipefail for while read loops (they can cause early exit)
set +o pipefail

DETAILED=false

for arg in "$@"; do
  case $arg in
    --detailed)
      DETAILED=true
      ;;
    --help|-h)
      head -n 16 "$0" | tail -n 14
      exit 0
      ;;
  esac
done

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Application Leftover Detection${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Scanning for potential leftover application files..."
echo ""

# Create temporary file to store installed app names
INSTALLED_APPS=$(mktemp)
trap 'rm -f "$INSTALLED_APPS"' EXIT

# Build list of installed application bundles (just the names without .app)
{
  ls /Applications 2>/dev/null | sed 's/\.app$//'
  ls ~/Applications 2>/dev/null | sed 's/\.app$//'
  ls /System/Applications 2>/dev/null | sed 's/\.app$//'
} | sort -u > "$INSTALLED_APPS"

echo "Found $(wc -l < "$INSTALLED_APPS" | tr -d ' ') installed applications"
echo ""

# Function to check if a folder name matches any installed app
is_likely_leftover() {
  local folder_name="$1"
  local base_name=$(basename "$folder_name")
  
  # Remove common prefixes/suffixes
  local cleaned_name=$(echo "$base_name" | sed -E 's/^(com\.|org\.|io\.|net\.)//; s/\.[^.]+$//')
  
  # Check if any installed app name is in the folder name
  if grep -qi "$cleaned_name" "$INSTALLED_APPS" 2>/dev/null; then
    return 1  # Not a leftover (app is installed)
  else
    return 0  # Likely leftover
  fi
}

# Scan Application Support
echo -e "${BLUE}=== Application Support (~/ Library/Application Support) ===${NC}"
if [ -d "$HOME/Library/Application Support" ]; then
  echo "Largest folders (top 30):"
  du -sh "$HOME/Library/Application Support"/* 2>/dev/null | sort -hr | head -30 | while read size path; do
    folder_name=$(basename "$path")
    
    # Try to determine if leftover
    if [ "$DETAILED" = true ]; then
      last_modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$path" 2>/dev/null || echo "unknown")
      echo "  $size  $folder_name (last modified: $last_modified)"
    else
      echo "  $size  $folder_name"
    fi
  done
  echo ""
fi

# Scan Caches
echo -e "${BLUE}=== Caches (~/Library/Caches) ===${NC}"
if [ -d "$HOME/Library/Caches" ]; then
  echo "Largest cache folders (top 20):"
  du -sh "$HOME/Library/Caches"/* 2>/dev/null | sort -hr | head -20 | while read size path; do
    folder_name=$(basename "$path")
    echo "  $size  $folder_name"
  done
  echo ""
fi

# Scan Preferences
echo -e "${BLUE}=== Preferences (~/Library/Preferences) ===${NC}"
if [ -d "$HOME/Library/Preferences" ]; then
  echo "Recent .plist files (count: $(ls ~/Library/Preferences/*.plist 2>/dev/null | wc -l | tr -d ' '))"
  if [ "$DETAILED" = true ]; then
    echo "Modified in last 30 days:"
    find "$HOME/Library/Preferences" -name "*.plist" -mtime -30 -exec basename {} \; 2>/dev/null | head -20
  fi
  echo ""
fi

# Scan Containers (sandboxed apps)
echo -e "${BLUE}=== Containers (~/Library/Containers) ===${NC}"
if [ -d "$HOME/Library/Containers" ]; then
  CONTAINER_COUNT=$(ls "$HOME/Library/Containers" 2>/dev/null | wc -l | tr -d ' ')
  echo "Total containers: $CONTAINER_COUNT"
  echo "Largest containers (top 15):"
  du -sh "$HOME/Library/Containers"/* 2>/dev/null | sort -hr | head -15 | while read size path; do
    folder_name=$(basename "$path")
    echo "  $size  $folder_name"
  done
  echo ""
fi

# Old Application States
echo -e "${BLUE}=== Saved Application States ===${NC}"
if [ -d "$HOME/Library/Saved Application State" ]; then
  STATE_SIZE=$(du -sh "$HOME/Library/Saved Application State" 2>/dev/null | awk '{print $1}')
  STATE_COUNT=$(ls "$HOME/Library/Saved Application State" 2>/dev/null | wc -l | tr -d ' ')
  echo "Total size: $STATE_SIZE ($STATE_COUNT items)"
  echo -e "${GREEN}ℹ${NC}  Safe to delete entire folder (apps will recreate on launch)"
  echo ""
fi

# Summary and recommendations
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Detection Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. For each suspicious folder, Google the name to identify the parent app"
echo "  2. Verify the app is not installed: mdfind -name 'AppName.app'"
echo "  3. Check last modified date to see if still in use"
echo "  4. MOVE to Trash (don't rm) and test for a few days"
echo ""
echo -e "${YELLOW}⚠${NC}  Never bulk-delete without verifying each folder individually"
echo -e "${YELLOW}⚠${NC}  Some apps store critical data in Application Support"
echo ""
echo "For safer uninstallation in the future, use AppCleaner:"
echo "  brew install --cask appcleaner"
echo ""
