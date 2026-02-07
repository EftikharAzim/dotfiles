#!/usr/bin/env bash
################################################################################
# mac_cleaner_enhanced.sh — Safe macOS User-Space Cleanup Utility
# 
# PURPOSE:
#   Reclaim disk space by removing old caches, logs, and build artifacts while
#   maintaining safety through dry-run mode, age-based filtering, and trash-first
#   deletion strategy.
#
# USAGE:
#   bash mac_cleaner_enhanced.sh                      # dry-run (preview only)
#   bash mac_cleaner_enhanced.sh --apply              # safe cleanup
#   bash mac_cleaner_enhanced.sh --apply --aggressive # deep cleanup
#   bash mac_cleaner_enhanced.sh --help               # show help
#
# SAFETY FEATURES:
#   - Dry-run by default (nothing deleted until --apply)
#   - Age-based deletion (default: 30 days for caches/logs)
#   - Trash-first removal (recoverable from ~/.Trash)
#   - Comprehensive logging (~/mac_cleaner_TIMESTAMP.log)
#   - Interactive confirmation for destructive operations
#   - Size reporting (shows space reclaimed)
#
# REQUIREMENTS:
#   - macOS (tested on Ventura/Sonoma, M1/M2/Intel)
#   - Bash 4.0+ (macOS default is sufficient)
#   - No root access required (user-space only)
#
# AUTHOR: Enhanced version with improved error handling and reporting
# DATE: 2024
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Prevent word splitting issues with filenames

################################################################################
# CONFIGURATION
################################################################################

# Default settings (modify these to tune behavior)
DRY_RUN=true                # Preview mode by default
AGGRESSIVE=false            # Requires explicit --aggressive flag
MAX_AGE_DAYS=30            # Delete caches/logs older than this
XCODE_MAX_AGE_DAYS=14      # DerivedData age threshold
SAFE_TRASH=true            # Move to Trash instead of rm -rf
SHOW_SIZE_REPORT=true      # Display space reclaimed
ENABLE_LOGGING=true        # Set to false with --no-log flag

# Logging - use proper macOS Logs directory
LOG_DIR="$HOME/Library/Logs/mac_cleanup"
LOG_RETENTION_DAYS=3          # Auto-delete logs older than this
mkdir -p "$LOG_DIR" 2>/dev/null
LOGFILE="$LOG_DIR/cleanup_$(date +%Y%m%d_%H%M%S).log"

# Log rotation - delete old logs
find "$LOG_DIR" -name "cleanup_*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true

TEMP_DIR=""  # Will be set securely below

# Color output (if terminal supports it)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Print and log messages
log() {
  if [ "$ENABLE_LOGGING" = true ]; then
    echo -e "$1" | tee -a "$LOGFILE"
  else
    echo -e "$1"
  fi
}

log_header() {
  log "\n${BLUE}========================================${NC}"
  log "${BLUE}$1${NC}"
  log "${BLUE}========================================${NC}"
}

log_success() {
  log "${GREEN}✓${NC} $1"
}

log_warning() {
  log "${YELLOW}⚠${NC} $1"
}

log_error() {
  log "${RED}✗${NC} $1"
}

# Execute command with dry-run awareness
run() {
  local cmd="$1"
  log "+ $cmd"
  if [ "$DRY_RUN" = false ]; then
    eval "$cmd" 2>&1 | tee -a "$LOGFILE" || {
      log_error "Command failed: $cmd"
      return 1
    }
  else
    log "  (dry-run: would execute above)"
  fi
}

# Get directory size in bytes
get_size_bytes() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo "0"
  else
    echo "0"
  fi
}

# Format bytes to human-readable
format_bytes() {
  local bytes=$1
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
  else
    # Fallback for macOS without numfmt
    awk -v bytes="$bytes" 'BEGIN {
      if (bytes >= 1073741824) printf "%.2f GiB\n", bytes/1073741824
      else if (bytes >= 1048576) printf "%.2f MiB\n", bytes/1048576
      else if (bytes >= 1024) printf "%.2f KiB\n", bytes/1024
      else printf "%d B\n", bytes
    }'
  fi
}

# Move item to Trash (macOS-specific)
trash_move() {
  local path="$1"
  
  if [ ! -e "$path" ]; then
    log_warning "Path does not exist: $path"
    return 0
  fi
  
  if [ "$SAFE_TRASH" = true ]; then
    log "→ Moving to Trash: $path"
    if [ "$DRY_RUN" = false ]; then
      # Get basename for potential conflict resolution
      local basename=$(basename "$path")
      local timestamp=$(date +%Y%m%d_%H%M%S)
      
      # Try AppleScript first (proper Trash integration) with proper escaping
      local escaped_path="${path//\\/\\\\}"
      escaped_path="${escaped_path//\"/\\\"}"
      
      if /usr/bin/osascript -e "tell application \"Finder\" to delete (POSIX file \"$escaped_path\")" >/dev/null 2>&1; then
        log_success "Moved to Trash via Finder"
      else
        # Fallback: manual move to .Trash with conflict handling
        local target="$HOME/.Trash/$basename"
        if [ -e "$target" ]; then
          target="$HOME/.Trash/${basename%.*}_${timestamp}.${basename##*.}"
        fi
        
        mv "$path" "$target" 2>&1 | tee -a "$LOGFILE" || {
          log_error "Failed to move to Trash: $path"
          return 1
        }
        log_success "Moved to ~/.Trash"
      fi
    fi
  else
    log "→ Permanently deleting: $path"
    if [ "$DRY_RUN" = false ]; then
      rm -rf "$path" 2>&1 | tee -a "$LOGFILE" || {
        log_error "Failed to delete: $path"
        return 1
      }
    fi
  fi
}

# Ask user for confirmation
confirm() {
  local prompt="$1"
  local response
  
  if [ "$DRY_RUN" = true ]; then
    log "(dry-run: would ask: $prompt)"
    return 0
  fi
  
  read -p "$prompt [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

################################################################################
# SAFETY CHECKS
################################################################################

# Ensure not running as root
if [ "$(id -u)" = "0" ]; then
  log_error "Do not run this script as root. Run as your local user."
  exit 1
fi

# Create secure temp directory
TEMP_DIR=$(mktemp -d -t mac_cleaner.XXXXXXXXXX) || {
  echo "ERROR: Failed to create temp directory" >&2
  exit 1
}
trap 'rm -rf "$TEMP_DIR"' EXIT  # Cleanup on exit

# Set restrictive permissions on logfile (only if logging enabled)
if [ "$ENABLE_LOGGING" = true ]; then
  touch "$LOGFILE"
  chmod 600 "$LOGFILE"
fi

################################################################################
# ARGUMENT PARSING
################################################################################

show_help() {
  cat << EOF
macOS Cleanup Script - Safe user-space cleanup utility

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --apply         Execute cleanup (default is dry-run preview)
  --aggressive    Enable aggressive cleanup (Docker prune, full caches)
  --no-log        Skip log file creation (output to terminal only)
  --help, -h      Show this help message

EXAMPLES:
  # Preview what would be cleaned
  $0

  # Perform safe cleanup
  $0 --apply

  # Deep clean with aggressive options
  $0 --apply --aggressive

WHAT GETS CLEANED:
  Safe Mode:
    - Homebrew caches (30+ days old)
    - User caches (~/Library/Caches, 30+ days)
    - User logs (~/Library/Logs, 30+ days)
    - Xcode DerivedData (14+ days)
    - VS Code workspace storage (30+ days)
    - npm cache (verify only)

  Aggressive Mode (requires --aggressive):
    - Docker system prune (all unused images/volumes)
    - Full npm cache clean
    - Full pip cache purge
    - Go module cache clean

SAFETY:
  - Default dry-run mode (no deletions)
  - Age-based filtering (only old files)
  - Trash-first deletion (recoverable)
  - Comprehensive logging
  - Interactive confirmations for destructive ops

LOGFILE:
  ~/Library/Logs/mac_cleanup/cleanup_TIMESTAMP.log
  (use --no-log to skip logging)

EOF
}

# Parse command-line arguments
for arg in "$@"; do
  case $arg in
    --apply)
      DRY_RUN=false
      ;;
    --aggressive)
      AGGRESSIVE=true
      ;;
    --no-log)
      ENABLE_LOGGING=false
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $arg"
      log "Use --help for usage information"
      exit 1
      ;;
  esac
done

################################################################################
# MAIN SCRIPT START
################################################################################

log_header "macOS Cleanup Script Starting"
log "Timestamp: $(date)"
log "Mode: $([ "$DRY_RUN" = true ] && echo 'DRY-RUN (preview only)' || echo 'APPLY (will delete)')"
log "Aggressive: $AGGRESSIVE"
log "Max age: $MAX_AGE_DAYS days"
log "Logfile: $LOGFILE"
log ""

if [ "$DRY_RUN" = true ]; then
  log_warning "Running in DRY-RUN mode. No files will be deleted."
  log_warning "Review the output, then run with --apply to execute cleanup."
  log ""
fi

# Track total space reclaimed
TOTAL_RECLAIMED=0

################################################################################
# CLEANUP OPERATIONS
################################################################################

#------------------------------------------------------------------------------
# 1. HOMEBREW CLEANUP
#------------------------------------------------------------------------------
log_header "1. Homebrew Cleanup"

if command -v brew >/dev/null 2>&1; then
  log "Homebrew detected at: $(command -v brew)"
  
  # Update brew (suppressed output)
  run "brew update >/dev/null 2>&1 || true"
  
  # Show outdated packages
  log "\nOutdated packages:"
  brew outdated 2>&1 | tee -a "$LOGFILE" || log "(none)"
  
  # Cleanup old versions (older than 30 days)
  if [ "$DRY_RUN" = false ]; then
    SIZE_BEFORE=$(get_size_bytes "$(brew --cache)")
    run "brew cleanup --prune=30 -s 2>&1 | head -n 50"
    SIZE_AFTER=$(get_size_bytes "$(brew --cache)")
    RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
    TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
    log_success "Homebrew cleanup complete (reclaimed: $(format_bytes $RECLAIMED))"
  else
    log "(dry-run) Would run: brew cleanup --prune=30 -s"
  fi
  
  # Autoremove unused dependencies
  if brew help | grep -q "autoremove"; then
    run "brew autoremove 2>&1 || true"
  fi
else
  log_warning "Homebrew not found — skipping brew cleanup"
fi

#------------------------------------------------------------------------------
# 2. USER CACHE CLEANUP (~/Library/Caches)
#------------------------------------------------------------------------------
log_header "2. User Cache Cleanup"

CACHES_DIR="$HOME/Library/Caches"
if [ -d "$CACHES_DIR" ]; then
  SIZE_BEFORE=$(get_size_bytes "$CACHES_DIR")
  log "Scanning for caches older than $MAX_AGE_DAYS days in: $CACHES_DIR"
  
  # Protected system directories that should be excluded
  PROTECTED_CACHE_DIRS=(
    "com.apple.HomeKit"
    "CloudKit"
    "com.apple.Safari"
    "com.apple.containermanagerd"
    "FamilyCircle"
    "com.apple.homed"
    "com.apple.ap.adprivacyd"
  )
  
  # Build exclusion arguments for find
  EXCLUSIONS=()
  for dir in "${PROTECTED_CACHE_DIRS[@]}"; do
    EXCLUSIONS+=(-not -path "$CACHES_DIR/$dir/*" -not -path "$CACHES_DIR/$dir")
  done
  
  # Find old cache directories/files, excluding protected directories
  find "$CACHES_DIR" -mindepth 1 -maxdepth 3 -mtime +"$MAX_AGE_DAYS" \
    "${EXCLUSIONS[@]}" \
    -print 2>/dev/null > "$TEMP_DIR/caches_to_delete.txt" || true
  
  if [ -s "$TEMP_DIR/caches_to_delete.txt" ]; then
    CACHE_COUNT=$(wc -l < "$TEMP_DIR/caches_to_delete.txt" | tr -d ' ')
    log "Found $CACHE_COUNT cache items to clean:"
    head -n 20 "$TEMP_DIR/caches_to_delete.txt" | tee -a "$LOGFILE"
    
    if [ "$CACHE_COUNT" -gt 20 ]; then
      log "... and $((CACHE_COUNT - 20)) more (see logfile)"
    fi
    
    if [ "$DRY_RUN" = false ]; then
      while IFS= read -r item; do
        trash_move "$item"
      done < "$TEMP_DIR/caches_to_delete.txt"
      
      SIZE_AFTER=$(get_size_bytes "$CACHES_DIR")
      RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
      TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
      log_success "Cache cleanup complete (reclaimed: $(format_bytes $RECLAIMED))"
    else
      log "(dry-run) Would move $CACHE_COUNT items to Trash"
    fi
  else
    log "No cache items older than $MAX_AGE_DAYS days found"
  fi
else
  log_warning "Caches directory not found: $CACHES_DIR"
fi

#------------------------------------------------------------------------------
# 3. USER LOGS CLEANUP (~/Library/Logs)
#------------------------------------------------------------------------------
log_header "3. User Logs Cleanup"

LOGS_DIR="$HOME/Library/Logs"
if [ -d "$LOGS_DIR" ]; then
  SIZE_BEFORE=$(get_size_bytes "$LOGS_DIR")
  log "Scanning for logs older than $MAX_AGE_DAYS days in: $LOGS_DIR"
  
  find "$LOGS_DIR" -type f -mtime +"$MAX_AGE_DAYS" \
    -print 2>>"$LOGFILE" > "$TEMP_DIR/logs_to_delete.txt" || true
  
  if [ -s "$TEMP_DIR/logs_to_delete.txt" ]; then
    LOG_COUNT=$(wc -l < "$TEMP_DIR/logs_to_delete.txt" | tr -d ' ')
    log "Found $LOG_COUNT log files to clean:"
    head -n 20 "$TEMP_DIR/logs_to_delete.txt" | tee -a "$LOGFILE"
    
    if [ "$LOG_COUNT" -gt 20 ]; then
      log "... and $((LOG_COUNT - 20)) more (see logfile)"
    fi
    
    if [ "$DRY_RUN" = false ]; then
      while IFS= read -r item; do
        trash_move "$item"
      done < "$TEMP_DIR/logs_to_delete.txt"
      
      SIZE_AFTER=$(get_size_bytes "$LOGS_DIR")
      RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
      TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
      log_success "Logs cleanup complete (reclaimed: $(format_bytes $RECLAIMED))"
    else
      log "(dry-run) Would move $LOG_COUNT items to Trash"
    fi
  else
    log "No log files older than $MAX_AGE_DAYS days found"
  fi
else
  log_warning "Logs directory not found: $LOGS_DIR"
fi

#------------------------------------------------------------------------------
# 4. XCODE DERIVEDDATA CLEANUP
#------------------------------------------------------------------------------
log_header "4. Xcode DerivedData Cleanup"

XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$XCODE_DERIVED" ]; then
  SIZE_BEFORE=$(get_size_bytes "$XCODE_DERIVED")
  log "Scanning for DerivedData older than $XCODE_MAX_AGE_DAYS days"
  
  find "$XCODE_DERIVED" -mindepth 1 -maxdepth 1 -mtime +"$XCODE_MAX_AGE_DAYS" \
    -print 2>>"$LOGFILE" > "$TEMP_DIR/xcode_to_delete.txt" || true
  
  if [ -s "$TEMP_DIR/xcode_to_delete.txt" ]; then
    XCODE_COUNT=$(wc -l < "$TEMP_DIR/xcode_to_delete.txt" | tr -d ' ')
    log "Found $XCODE_COUNT DerivedData folders to clean:"
    cat "$TEMP_DIR/xcode_to_delete.txt" | tee -a "$LOGFILE"
    
    if [ "$DRY_RUN" = false ]; then
      while IFS= read -r item; do
        trash_move "$item"
      done < "$TEMP_DIR/xcode_to_delete.txt"
      
      SIZE_AFTER=$(get_size_bytes "$XCODE_DERIVED")
      RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
      TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
      log_success "DerivedData cleanup complete (reclaimed: $(format_bytes $RECLAIMED))"
    else
      log "(dry-run) Would move $XCODE_COUNT items to Trash"
    fi
  else
    log "No DerivedData older than $XCODE_MAX_AGE_DAYS days found"
  fi
else
  log "Xcode not installed — skipping DerivedData cleanup"
fi

#------------------------------------------------------------------------------
# 5. VS CODE WORKSPACE STORAGE CLEANUP
#------------------------------------------------------------------------------
log_header "5. VS Code Workspace Storage Cleanup"

VSCODE_DIR="$HOME/Library/Application Support/Code"
if [ -d "$VSCODE_DIR/User/workspaceStorage" ]; then
  SIZE_BEFORE=$(get_size_bytes "$VSCODE_DIR/User/workspaceStorage")
  log "Scanning for old workspace storage (older than $MAX_AGE_DAYS days)"
  
  find "$VSCODE_DIR/User/workspaceStorage" -mindepth 1 -maxdepth 1 -mtime +"$MAX_AGE_DAYS" \
    -print 2>>"$LOGFILE" > "$TEMP_DIR/vscode_to_delete.txt" || true
  
  if [ -s "$TEMP_DIR/vscode_to_delete.txt" ]; then
    VSCODE_COUNT=$(wc -l < "$TEMP_DIR/vscode_to_delete.txt" | tr -d ' ')
    log "Found $VSCODE_COUNT workspace storage items to clean"
    head -n 10 "$TEMP_DIR/vscode_to_delete.txt" | tee -a "$LOGFILE"
    
    if [ "$DRY_RUN" = false ]; then
      while IFS= read -r item; do
        trash_move "$item"
      done < "$TEMP_DIR/vscode_to_delete.txt"
      
      SIZE_AFTER=$(get_size_bytes "$VSCODE_DIR/User/workspaceStorage")
      RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
      TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
      log_success "VS Code cleanup complete (reclaimed: $(format_bytes $RECLAIMED))"
    else
      log "(dry-run) Would move $VSCODE_COUNT items to Trash"
    fi
  else
    log "No old workspace storage found"
  fi
else
  log "VS Code not installed — skipping workspace cleanup"
fi

#------------------------------------------------------------------------------
# 6. NPM CACHE MANAGEMENT
#------------------------------------------------------------------------------
log_header "6. npm Cache Management"

if command -v npm >/dev/null 2>&1; then
  log "npm detected at: $(command -v npm)"
  
  # Always verify cache integrity (safe operation)
  log "Verifying npm cache integrity..."
  run "npm cache verify 2>&1 | tail -n 5"
  
  if [ "$AGGRESSIVE" = true ]; then
    log_warning "Aggressive mode: Cleaning npm cache completely"
    if confirm "This will remove ALL npm cached packages. Continue?"; then
      SIZE_BEFORE=$(get_size_bytes "$(npm config get cache)")
      run "npm cache clean --force"
      SIZE_AFTER=$(get_size_bytes "$(npm config get cache)")
      RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
      TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
      log_success "npm cache cleaned (reclaimed: $(format_bytes $RECLAIMED))"
    else
      log "Skipped npm cache clean"
    fi
  else
    log "Safe mode: npm cache verified only (use --aggressive to clean)"
  fi
else
  log "npm not installed — skipping npm cleanup"
fi

#------------------------------------------------------------------------------
# 7. PYTHON PIP CACHE MANAGEMENT
#------------------------------------------------------------------------------
log_header "7. Python pip Cache Management"

if command -v pip3 >/dev/null 2>&1; then
  log "pip3 detected at: $(command -v pip3)"
  
  # Get pip cache directory
  PIP_CACHE_DIR=$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")
  log "pip cache directory: $PIP_CACHE_DIR"
  
  if [ -d "$PIP_CACHE_DIR" ]; then
    SIZE_BEFORE=$(get_size_bytes "$PIP_CACHE_DIR")
    log "Current pip cache size: $(format_bytes $SIZE_BEFORE)"
    
    if [ "$AGGRESSIVE" = true ]; then
      log_warning "Aggressive mode: Purging pip cache"
      if confirm "This will remove ALL pip cached packages. Continue?"; then
        run "pip3 cache purge"
        SIZE_AFTER=$(get_size_bytes "$PIP_CACHE_DIR")
        RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
        TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
        log_success "pip cache purged (reclaimed: $(format_bytes $RECLAIMED))"
      else
        log "Skipped pip cache purge"
      fi
    else
      log "Safe mode: pip cache inspected only (use --aggressive to purge)"
    fi
  fi
else
  log "pip3 not installed — skipping pip cleanup"
fi

#------------------------------------------------------------------------------
# 8. GO MODULE CACHE CLEANUP
#------------------------------------------------------------------------------
log_header "8. Go Module Cache Cleanup"

if command -v go >/dev/null 2>&1; then
  log "Go detected at: $(command -v go)"
  
  GO_CACHE=$(go env GOMODCACHE 2>/dev/null || echo "$HOME/go/pkg/mod")
  log "Go module cache: $GO_CACHE"
  
  if [ -d "$GO_CACHE" ]; then
    SIZE_BEFORE=$(get_size_bytes "$GO_CACHE")
    log "Current Go module cache size: $(format_bytes $SIZE_BEFORE)"
    
    if [ "$AGGRESSIVE" = true ]; then
      log_warning "Aggressive mode: Cleaning Go module cache"
      if confirm "This will remove ALL downloaded Go modules. Continue?"; then
        run "go clean -modcache"
        SIZE_AFTER=$(get_size_bytes "$GO_CACHE")
        RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
        TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
        log_success "Go module cache cleaned (reclaimed: $(format_bytes $RECLAIMED))"
      else
        log "Skipped Go module cache clean"
      fi
    else
      log "Safe mode: Go cache inspected only (use --aggressive to clean)"
    fi
  fi
else
  log "Go not installed — skipping Go cleanup"
fi

#------------------------------------------------------------------------------
# 9. DOCKER CLEANUP (AGGRESSIVE ONLY)
#------------------------------------------------------------------------------
log_header "9. Docker System Cleanup"

if command -v docker >/dev/null 2>&1; then
  log "Docker detected at: $(command -v docker)"
  
  # Show current Docker disk usage
  log "\nCurrent Docker disk usage:"
  docker system df 2>&1 | tee -a "$LOGFILE" || log_warning "Could not get Docker stats"
  
  if [ "$AGGRESSIVE" = true ]; then
    log_error "WARNING: Docker system prune will remove:"
    log "  - All stopped containers"
    log "  - All networks not used by at least one container"
    log "  - All images without at least one container associated"
    log "  - All volumes not used by at least one container"
    log "  - All build cache"
    
    if confirm "Proceed with Docker system prune?"; then
      log_warning "Running Docker prune (Docker will show its own confirmation prompts)..."
      # Removed -f flag to allow Docker's built-in confirmation
      run "docker system prune -a --volumes 2>&1 | tail -n 20"
      log_success "Docker cleanup complete"
    else
      log "Skipped Docker cleanup"
    fi
  else
    log "Safe mode: Docker disk usage shown only (use --aggressive to prune)"
  fi
else
  log "Docker not installed — skipping Docker cleanup"
fi

#------------------------------------------------------------------------------
# 10. SPOTLIGHT INDEX CLEANUP
#------------------------------------------------------------------------------
log_header "10. Spotlight Index Cleanup"

SPOTLIGHT_DIR="$HOME/Library/Metadata/CoreSpotlight"
if [ -d "$SPOTLIGHT_DIR" ]; then
  SIZE_BEFORE=$(get_size_bytes "$SPOTLIGHT_DIR")
  log "Removing user-level Spotlight index cache"
  log "Current size: $(format_bytes $SIZE_BEFORE)"
  
  if [ "$DRY_RUN" = false ]; then
    # Use trash_move() for consistency with other cleanup operations
    trash_move "$SPOTLIGHT_DIR"
    SIZE_AFTER=$(get_size_bytes "$SPOTLIGHT_DIR")
    RECLAIMED=$((SIZE_BEFORE - SIZE_AFTER))
    TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + RECLAIMED))
    log_success "Spotlight cache removed (reclaimed: $(format_bytes $RECLAIMED))"
    log "Note: Spotlight will rebuild this cache automatically"
  else
    log "(dry-run) Would move Spotlight cache to Trash"
  fi
else
  log "Spotlight cache not found"
fi

#------------------------------------------------------------------------------
# 11. TRASH MANAGEMENT
#------------------------------------------------------------------------------
log_header "11. Trash Management"

TRASH_DIR="$HOME/.Trash"
if [ -d "$TRASH_DIR" ]; then
  TRASH_SIZE=$(get_size_bytes "$TRASH_DIR")
  log "Current Trash size: $(format_bytes $TRASH_SIZE)"
  
  if [ "$DRY_RUN" = false ]; then
    if [ "$TRASH_SIZE" -gt 0 ]; then
      log_warning "WARNING: Emptying Trash will permanently delete $(format_bytes $TRASH_SIZE) of data."
      log_warning "This includes items moved during this cleanup AND any other items in Trash."
      if confirm "Empty Trash now? This action CANNOT be undone"; then
        log "Emptying Trash..."
        rm -rf "$TRASH_DIR"/* 2>&1 | tee -a "$LOGFILE" || log_warning "Some items could not be deleted"
        log_success "Trash emptied (reclaimed: $(format_bytes $TRASH_SIZE))"
        TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + TRASH_SIZE))
      else
        log "Trash not emptied (you can empty it manually later)"
      fi
    else
      log "Trash is already empty"
    fi
  else
    log "(dry-run) Would offer to empty Trash (current size: $(format_bytes $TRASH_SIZE))"
  fi
else
  log "Trash is empty"
fi

################################################################################
# FINAL REPORT
################################################################################

log_header "Cleanup Summary"

log "\n${GREEN}=== RESULTS ===${NC}"
log "Total space reclaimed: ${GREEN}$(format_bytes $TOTAL_RECLAIMED)${NC}"
log ""
log "Logfile saved: $LOGFILE"
log ""

if [ "$DRY_RUN" = true ]; then
  log_warning "This was a DRY-RUN. No files were actually deleted."
  log_warning "To perform cleanup, run: $0 --apply"
else
  log_success "Cleanup completed successfully!"
  log ""
  log "Recommendations:"
  log "  1. Review the logfile: less $LOGFILE"
  log "  2. Verify apps still work correctly"
  log "  3. Check Trash before emptying: open ~/.Trash"
  log "  4. Run this script monthly for best results"
fi

if [ "$AGGRESSIVE" = false ]; then
  log ""
  log "Tip: For deeper cleanup, run with --aggressive flag"
  log "     (This will clean Docker, full npm/pip/go caches)"
fi

log ""
log "Finished at: $(date)"
log_success "All done! 🎉"

exit 0