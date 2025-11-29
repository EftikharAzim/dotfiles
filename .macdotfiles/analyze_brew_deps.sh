#!/usr/bin/env bash
################################################################################
# analyze_brew_deps.sh - Analyze Homebrew Dependencies
# 
# PURPOSE:
#   Help identify which Homebrew packages you explicitly installed vs
#   auto-dependencies, and which ones are safe to remove.
#
# USAGE:
#   bash analyze_brew_deps.sh
#   bash analyze_brew_deps.sh --candidates    # Show removal candidates only
#
# OUTPUT:
#   Lists leaf packages (nothing depends on them) with installation info
#
################################################################################

set -euo pipefail

SHOW_CANDIDATES_ONLY=false

for arg in "$@"; do
  case $arg in
    --candidates)
      SHOW_CANDIDATES_ONLY=true
      ;;
    --help|-h)
      head -n 16 "$0" | tail -n 14
      exit 0
      ;;
  esac
done

# Check if Homebrew is installed
if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew not found"
  exit 1
fi

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homebrew Dependency Analysis${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Get brew info
TOTAL_FORMULAE=$(brew list --formula | wc -l | tr -d ' ')
TOTAL_CASKS=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')

echo "Total installed:"
echo "  Formulae: $TOTAL_FORMULAE"
echo "  Casks: $TOTAL_CASKS"
echo ""

# Analyze leaf packages
echo -e "${BLUE}=== Leaf Packages (Nothing Depends On Them) ===${NC}"
echo ""

LEAVES=$(brew leaves)
LEAF_COUNT=$(echo "$LEAVES" | wc -l | tr -d ' ')

echo "Found $LEAF_COUNT leaf packages"
echo ""

if [ "$SHOW_CANDIDATES_ONLY" = false ]; then
  echo "Package Details:"
  echo "----------------"
fi

REMOVAL_CANDIDATES=()

for pkg in $LEAVES; do
  # Get package info
  INFO=$(brew info --json=v2 "$pkg" 2>/dev/null || echo '{}')
  
  # Extract details
  DESC=$(echo "$INFO" | jq -r '.formulae[0].desc // "No description"' 2>/dev/null || echo "No description")
  INSTALLED_ON=$(brew info "$pkg" | grep "Poured from bottle on" | sed 's/.*on //' || echo "unknown")
  
  # Check if it's explicitly installed or a dependency
  USES_COUNT=$(brew uses --installed "$pkg" 2>/dev/null | wc -l | tr -d ' ')
  
  # Determine if likely removal candidate
  IS_CANDIDATE=false
  REASON=""
  
  # Check if it's a common tool people forget about
  case "$pkg" in
    tree|wget|htop|tmux|vim|neovim|git|curl|jq)
      IS_CANDIDATE=false
      REASON="Common CLI tool (likely intentional)"
      ;;
    *python*|*node*|*ruby*|*go)
      IS_CANDIDATE=false
      REASON="Language runtime (verify manually)"
      ;;
    automake|autoconf|cmake|pkg-config|libtool)
      IS_CANDIDATE=true
      REASON="Build tool (may be leftover from compilation)"
      ;;
    *)
      # If nothing uses it and description suggests it's a lib
      if echo "$DESC" | grep -qi "library\|lib\|framework"; then
        IS_CANDIDATE=true
        REASON="Library with no dependents"
      fi
      ;;
  esac
  
  if [ "$IS_CANDIDATE" = true ]; then
    REMOVAL_CANDIDATES+=("$pkg")
  fi
  
  # Show output
  if [ "$SHOW_CANDIDATES_ONLY" = true ]; then
    if [ "$IS_CANDIDATE" = true ]; then
      echo -e "${YELLOW}→${NC} $pkg"
      echo "    Description: $DESC"
      echo "    Reason: $REASON"
      echo ""
    fi
  else
    if [ "$IS_CANDIDATE" = true ]; then
      echo -e "${YELLOW}⚠ $pkg${NC} (Removal Candidate)"
    else
      echo -e "${GREEN}✓ $pkg${NC}"
    fi
    echo "    Description: $DESC"
    if [ "$INSTALLED_ON" != "unknown" ]; then
      echo "    Installed: $INSTALLED_ON"
    fi
    if [ "$IS_CANDIDATE" = true ]; then
      echo "    Reason: $REASON"
    fi
    echo ""
  fi
done

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Removal candidates: ${#REMOVAL_CANDIDATES[@]}"

if [ ${#REMOVAL_CANDIDATES[@]} -gt 0 ]; then
  echo ""
  echo "Suggested review list:"
  for pkg in "${REMOVAL_CANDIDATES[@]}"; do
    echo "  - $pkg"
  done
  echo ""
  echo "Before removing any package:"
  echo "  1. Research what it does: brew info <package>"
  echo "  2. Check what uses it: brew uses --installed <package>"
  echo "  3. Try to remove: brew uninstall <package>"
  echo "     (Homebrew will refuse if it breaks dependencies)"
fi

echo ""
echo "To see all explicitly installed packages:"
echo "  brew leaves"
echo ""
echo "To check what depends on a package:"
echo "  brew uses --installed <package-name>"
echo ""
echo "To remove a package safely:"
echo "  brew uninstall <package-name>"
echo "  (Homebrew will prevent removal if it breaks dependencies)"
echo ""

cat <<'EOF'
Common removal workflow:
  1. Review the list above
  2. For each candidate: brew info <package>
  3. If you don't recognize it: Google it
  4. If you don't need it: brew uninstall <package>
  5. Run 'brew autoremove' to clean up newly orphaned deps

⚠️  Never use 'brew uninstall --force' unless you're certain!
EOF

echo ""
