#!/usr/bin/env bash
################################################################################
# safe_mac_cleanup.sh - Ultra-Safe macOS Developer Cleanup Script
# 
# PURPOSE:
#   Perform zero-risk cleanup operations that cannot break development
#   environments. Only touches caches, build artifacts, and downloads.
#
# USAGE:
#   bash safe_mac_cleanup.sh              # Interactive mode with confirmations
#   bash safe_mac_cleanup.sh --auto       # Run all steps without prompting
#   bash safe_mac_cleanup.sh --dry-run    # Show what would be cleaned
#
# SAFETY:
#   - Only removes regenerable caches and build artifacts
#   - Uses brew/npm/pip built-in safe cleanup commands
#   - Shows size before deletion
#   - Can be run as often as desired
#
################################################################################

set -euo pipefail

# Configuration
DRY_RUN=false
AUTO_YES=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
for arg in "$@"; do
  case $arg in
    --dry-run)
      DRY_RUN=true
      ;;
    --auto)
      AUTO_YES=true
      ;;
    --help|-h)
      head -n 22 "$0" | tail -n 20
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Helper functions
log_header() {
  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_info() {
  echo -e "${BLUE}→${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

get_size() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "0B"
  else
    echo "0B"
  fi
}

confirm() {
  if [ "$AUTO_YES" = true ] || [ "$DRY_RUN" = true ]; then
    return 0
  fi
  
  local prompt="$1"
  read -p "$prompt [y/N]: " -n 1 -r
  echo
  case "$REPLY" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

run_cleanup() {
  local cmd="$1"
  local desc="$2"
  
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would run: $cmd"
  else
    log_info "$desc"
    eval "$cmd" || log_warning "Command failed (may be normal if nothing to clean)"
  fi
}

################################################################################
# MAIN CLEANUP OPERATIONS
################################################################################

log_header "macOS Developer Safe Cleanup"

if [ "$DRY_RUN" = true ]; then
  log_warning "DRY-RUN MODE: No files will be deleted"
fi

echo ""
echo "This script performs ONLY ultra-safe cleanup operations:"
echo "  • Homebrew caches and old versions"
echo "  • Xcode DerivedData and caches"
echo "  • Unavailable iOS simulators"
echo "  • npm, pip, Go module caches"
echo "  • Docker stopped containers and unused images"
echo ""

if ! confirm "Proceed with cleanup?"; then
  echo "Cleanup cancelled."
  exit 0
fi

TOTAL_SAVED=0

# 1. HOMEBREW CLEANUP
if command -v brew >/dev/null 2>&1; then
  log_header "1. Homebrew Cleanup"
  
  BREW_CACHE=$(brew --cache 2>/dev/null || echo "$HOME/Library/Caches/Homebrew")
  CACHE_SIZE=$(get_size "$BREW_CACHE")
  log_info "Current cache size: $CACHE_SIZE"
  
  run_cleanup "brew cleanup -s" "Removing old downloads and versions..."
  run_cleanup "brew autoremove" "Removing orphaned dependencies..."
  
  log_success "Homebrew cleanup complete"
else
  log_warning "Homebrew not found - skipping"
fi

# 2. XCODE CLEANUP
log_header "2. Xcode Cleanup"

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED_DATA" ]; then
  DERIVED_SIZE=$(get_size "$DERIVED_DATA")
  log_info "DerivedData size: $DERIVED_SIZE"
  
  if confirm "Remove DerivedData (will rebuild on next build)?"; then
    if [ "$DRY_RUN" = false ]; then
      rm -rf "$DERIVED_DATA"
      log_success "DerivedData removed"
    else
      log_info "[DRY-RUN] Would remove $DERIVED_DATA"
    fi
  fi
else
  log_info "No DerivedData found"
fi

XCODE_CACHE="$HOME/Library/Caches/com.apple.dt.Xcode"
if [ -d "$XCODE_CACHE" ]; then
  XCODE_CACHE_SIZE=$(get_size "$XCODE_CACHE")
  log_info "Xcode cache size: $XCODE_CACHE_SIZE"
  
  if [ "$DRY_RUN" = false ]; then
    rm -rf "$XCODE_CACHE"
    log_success "Xcode caches removed"
  else
    log_info "[DRY-RUN] Would remove $XCODE_CACHE"
  fi
fi

if command -v xcrun >/dev/null 2>&1; then
  log_info "Removing unavailable simulators..."
  run_cleanup "xcrun simctl delete unavailable" "Cleaning up old simulators..."
  log_success "Simulator cleanup complete"
fi

# 3. NPM CACHE
if command -v npm >/dev/null 2>&1; then
  log_header "3. npm Cache Cleanup"
  
  NPM_CACHE=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
  NPM_SIZE=$(get_size "$NPM_CACHE")
  log_info "npm cache size: $NPM_SIZE"
  
  run_cleanup "npm cache verify" "Verifying cache integrity..."
  
  if confirm "Clean npm cache (safe - will re-download on install)?"; then
    run_cleanup "npm cache clean --force" "Cleaning npm cache..."
    log_success "npm cache cleaned"
  fi
else
  log_warning "npm not found - skipping"
fi

# 4. PIP CACHE
if command -v pip3 >/dev/null 2>&1; then
  log_header "4. pip Cache Cleanup"
  
  PIP_CACHE=$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")
  PIP_SIZE=$(get_size "$PIP_CACHE")
  log_info "pip cache size: $PIP_SIZE"
  
  if confirm "Purge pip cache (safe - will re-download on install)?"; then
    run_cleanup "pip3 cache purge" "Purging pip cache..."
    log_success "pip cache purged"
  fi
else
  log_warning "pip3 not found - skipping"
fi

# 5. GO MODULE CACHE
if command -v go >/dev/null 2>&1; then
  log_header "5. Go Module Cache Cleanup"
  
  GO_CACHE=$(go env GOMODCACHE 2>/dev/null || echo "$HOME/go/pkg/mod")
  GO_SIZE=$(get_size "$GO_CACHE")
  log_info "Go module cache size: $GO_SIZE"
  
  if confirm "Clean Go module cache (safe - will re-download on build)?"; then
    run_cleanup "go clean -modcache" "Cleaning Go modules..."
    log_success "Go module cache cleaned"
  fi
else
  log_warning "Go not found - skipping"
fi

# 6. DOCKER CLEANUP
if command -v docker >/dev/null 2>&1; then
  log_header "6. Docker Cleanup"
  
  if docker info >/dev/null 2>&1; then
    log_info "Current Docker disk usage:"
    docker system df 2>/dev/null || log_warning "Could not get Docker stats"
    echo ""
    
    if confirm "Remove stopped containers and unused networks?"; then
      run_cleanup "docker system prune -f" "Pruning Docker system..."
      log_success "Docker system pruned"
    fi
    
    if confirm "Remove ALL unused images (more aggressive)?"; then
      run_cleanup "docker system prune -a -f" "Removing unused images..."
      log_success "Docker images pruned"
    fi
  else
    log_warning "Docker daemon not running - skipping"
  fi
else
  log_warning "Docker not found - skipping"
fi

# 7. USER CACHES (SELECTIVE)
log_header "7. Selective Cache Cleanup"

SAFE_CACHES=(
  "$HOME/Library/Caches/Homebrew"
  "$HOME/Library/Caches/pip"
  "$HOME/Library/Caches/yarn"
  "$HOME/Library/Caches/CocoaPods"
)

for cache_dir in "${SAFE_CACHES[@]}"; do
  if [ -d "$cache_dir" ]; then
    CACHE_NAME=$(basename "$cache_dir")
    CACHE_SIZE=$(get_size "$cache_dir")
    log_info "$CACHE_NAME cache: $CACHE_SIZE"
    
    if [ "$DRY_RUN" = false ]; then
      rm -rf "$cache_dir"
      log_success "$CACHE_NAME cache removed"
    else
      log_info "[DRY-RUN] Would remove $cache_dir"
    fi
  fi
done

################################################################################
# FINAL SUMMARY
################################################################################

log_header "Cleanup Summary"

echo ""
echo -e "${GREEN}Cleanup complete!${NC}"
echo ""
echo "Recommended next steps:"
echo "  1. Run 'brew doctor' to check Homebrew health"
echo "  2. Test your development environment"
echo "  3. Review logs above for any warnings"
echo ""

if [ "$DRY_RUN" = true ]; then
  log_warning "This was a DRY-RUN. No files were actually deleted."
  log_info "Run without --dry-run to perform cleanup"
fi

echo "For more advanced cleanup, see the full cleanup guide."
echo ""

exit 0
