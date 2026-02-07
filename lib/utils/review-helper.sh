#!/bin/bash
# lib/utils/review-helper.sh
# Shared review helper functions for consistent behavior across workflow scripts
#
# Config: RITE_REVIEW_METHOD = "app" | "local" | "auto" (default: auto)
#   - "app": Use Claude for GitHub app only (fail if not installed)
#   - "local": Use local Claude Code review only (never wait for app)
#   - "auto": Try app first, fallback to local if not available or stale
#
# Usage:
#   source "$RITE_LIB_DIR/utils/review-helper.sh"
#   get_review_for_pr <pr_number> [--auto]
#   trigger_local_review <pr_number> [--auto]
#   check_review_app_available

# Ensure config is loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  echo "ERROR: review-helper.sh must be sourced after config.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# Colors for output (if not already defined)
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

# =============================================================================
# HELPER: Log review method decision
# =============================================================================
_log_review_method() {
  local method="$1"
  local reason="$2"
  local is_fallback="${3:-false}"

  case "$method" in
    app)
      echo -e "${BLUE}ℹ️  Review method: GitHub App${NC}"
      ;;
    local)
      if [ "$is_fallback" = "true" ]; then
        echo -e "${YELLOW}ℹ️  Review method: Local Claude Code (fallback)${NC}"
      else
        echo -e "${BLUE}ℹ️  Review method: Local Claude Code${NC}"
      fi
      ;;
    *)
      echo -e "${BLUE}ℹ️  Review method: $method${NC}"
      ;;
  esac

  if [ -n "$reason" ]; then
    echo -e "${BLUE}   Reason: $reason${NC}"
  fi
}

# =============================================================================
# Check if Claude for GitHub app is available on this repo
# Returns: 0 = available, 1 = not available
# =============================================================================
check_review_app_available() {
  # Look for recent comments from known review bots on any PR
  local recent_bot_comment
  recent_bot_comment=$(gh api "repos/{owner}/{repo}/issues/comments?per_page=30&sort=created&direction=desc" \
    --jq '[.[] | select(.user.login == "claude[bot]" or .user.login == "claude" or .user.login == "github-actions[bot]" and (.body | test("review|CRITICAL|WARNING|MINOR"; "i")))] | length' \
    2>/dev/null || echo "0")

  if [ "${recent_bot_comment:-0}" -gt 0 ]; then
    return 0  # App available
  else
    return 1  # App not available
  fi
}

# =============================================================================
# Trigger a local Claude Code review
# Usage: trigger_local_review <pr_number> [--auto]
# Returns: 0 = success, 1 = failure
# =============================================================================
trigger_local_review() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  local local_review_script="$RITE_LIB_DIR/core/local-review.sh"

  if [ ! -f "$local_review_script" ]; then
    echo -e "${YELLOW}⚠️  local-review.sh not found at $local_review_script${NC}" >&2
    return 1
  fi

  _log_review_method "local" "Generating review with local Claude Code"

  if [ "$auto_mode" = true ]; then
    "$local_review_script" "$pr_number" --post --auto 2>&1
  else
    "$local_review_script" "$pr_number" --post 2>&1
  fi

  return $?
}

# =============================================================================
# Get a review for a PR (respects RITE_REVIEW_METHOD config)
# Usage: get_review_for_pr <pr_number> [--auto]
# Outputs: Logs which method is being used
# Returns: 0 = review obtained, 1 = no review
# =============================================================================
get_review_for_pr() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  local method="${RITE_REVIEW_METHOD:-auto}"

  case "$method" in
    local)
      # Always use local review
      _log_review_method "local" "RITE_REVIEW_METHOD=local (config preference)"
      if [ "$auto_mode" = true ]; then
        trigger_local_review "$pr_number" --auto
      else
        trigger_local_review "$pr_number"
      fi
      return $?
      ;;

    app)
      # Only use GitHub app (fail if not available)
      if check_review_app_available; then
        _log_review_method "app" "RITE_REVIEW_METHOD=app (config preference)"
        echo -e "${BLUE}ℹ️  Waiting for Claude for GitHub app review...${NC}"
        return 0  # Caller should wait for app review
      else
        echo -e "${YELLOW}⚠️  RITE_REVIEW_METHOD=app but no review bot detected${NC}" >&2
        echo -e "${YELLOW}   Install Claude for GitHub: https://github.com/apps/claude${NC}" >&2
        return 1
      fi
      ;;

    auto|*)
      # Auto: try app first, fallback to local
      if check_review_app_available; then
        _log_review_method "app" "RITE_REVIEW_METHOD=auto (default: app detected)"
        echo -e "${BLUE}ℹ️  Waiting for Claude for GitHub app review...${NC}"
        return 0  # Caller should wait for app review
      else
        _log_review_method "local" "RITE_REVIEW_METHOD=auto (fallback: no app detected)" "true"
        if [ "$auto_mode" = true ]; then
          trigger_local_review "$pr_number" --auto
        else
          trigger_local_review "$pr_number"
        fi
        return $?
      fi
      ;;
  esac
}

# =============================================================================
# Handle stale review (respects RITE_REVIEW_METHOD config)
# Usage: handle_stale_review <pr_number> [--auto]
# Returns: 0 = fresh review obtained, 1 = failed
# =============================================================================
handle_stale_review() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  local method="${RITE_REVIEW_METHOD:-auto}"

  # Note: Caller (assess-and-resolve.sh) already printed stale warning, don't duplicate

  case "$method" in
    local)
      # Always use local review for refresh
      _log_review_method "local" "RITE_REVIEW_METHOD=local (config preference, triggering fresh review)"
      ;;

    app)
      # For app-only mode, user needs to trigger manually
      echo -e "${YELLOW}⚠️  RITE_REVIEW_METHOD=app - cannot auto-refresh review${NC}"
      echo -e "${BLUE}ℹ️  Trigger new review manually: gh pr comment $pr_number --body '@claude-code please review'${NC}"
      return 1
      ;;

    auto|*)
      # Auto mode: use local review for refresh (this is fallback behavior since app can't re-review)
      _log_review_method "local" "RITE_REVIEW_METHOD=auto (fallback: app cannot auto-refresh stale reviews)" "true"
      ;;
  esac

  # Trigger local review
  if [ "$auto_mode" = true ]; then
    trigger_local_review "$pr_number" --auto
  else
    trigger_local_review "$pr_number"
  fi

  return $?
}

# =============================================================================
# Determine if we should wait for app review or use local immediately
# Usage: should_wait_for_app_review
# Returns: 0 = wait for app, 1 = use local immediately
# =============================================================================
should_wait_for_app_review() {
  local method="${RITE_REVIEW_METHOD:-auto}"

  case "$method" in
    local)
      # Never wait for app
      return 1
      ;;
    app)
      # Always wait for app (even if not available - will fail later)
      return 0
      ;;
    auto|*)
      # Only wait if app is available
      if check_review_app_available; then
        return 0
      else
        return 1
      fi
      ;;
  esac
}

# Export functions
export -f check_review_app_available
export -f trigger_local_review
export -f get_review_for_pr
export -f handle_stale_review
export -f should_wait_for_app_review
