#!/usr/bin/env bash
# lib/core/local-review.sh
# Run a local Claude Code review and post it as a PR comment
#
# Usage:
#   local-review.sh <PR_NUMBER> [--post] [--auto]
#
# Options:
#   --post    Post the review as a PR comment (default: preview only)
#   --auto    Use --dangerously-skip-permissions for automation
#
# This replaces Claude for GitHub's auto-review with a local Claude Code session.
# Benefits:
#   - No dependency on external service
#   - Faster (no webhook latency)
#   - Works when Claude for GitHub is down/broken
#   - Same review quality (same Claude model)

set -euo pipefail

# Source config if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$SCRIPT_DIR/../utils/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"

# =============================================================================
# CACHE INVALIDATION: Invalidate cached assessments when new review is posted
# =============================================================================

invalidate_pr_cache() {
  local pr_num="$1"
  local cache_dir="$RITE_PROJECT_ROOT/${RITE_ASSESSMENT_CACHE_DIR:-.rite/assessment-cache}"

  if [ -d "$cache_dir" ]; then
    # Remove any cached assessments tagged with this PR
    local removed=0
    while IFS= read -r meta; do
      local base="${meta%.meta}"
      rm -f "$base.json" "$meta" 2>/dev/null
      ((removed++)) || true
    done < <(find "$cache_dir" -name "*.meta" -exec grep -l "\"pr_number\": \"$pr_num\"" {} \; 2>/dev/null)

    if [ "$removed" -gt 0 ]; then
      print_info "Invalidated $removed cached assessments for PR #$pr_num"
    fi
  fi
}

# Parse arguments
PR_NUMBER="${1:-}"
POST_REVIEW=false
AUTO_MODE=false

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --post)
      POST_REVIEW=true
      ;;
    --auto)
      AUTO_MODE=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <PR_NUMBER> [--post] [--auto]"
  echo ""
  echo "Options:"
  echo "  --post    Post the review as a PR comment (default: preview only)"
  echo "  --auto    Use non-interactive mode for automation"
  echo ""
  echo "Examples:"
  echo "  $0 59           # Preview review for PR #59"
  echo "  $0 59 --post    # Generate and post review to PR #59"
  exit 1
fi

# Validate PR number
if [[ ! $PR_NUMBER =~ ^[0-9]+$ ]]; then
  print_error "Invalid PR number: must be numeric"
  exit 1
fi

print_header "Local Claude Code Review - PR #$PR_NUMBER"
echo ""

# Get PR info
print_info "Fetching PR information..."
PR_INFO=$(gh pr view "$PR_NUMBER" --json title,baseRefName,headRefName,url 2>&1) || {
  print_error "Failed to fetch PR #$PR_NUMBER"
  echo "$PR_INFO"
  exit 1
}

PR_TITLE=$(echo "$PR_INFO" | jq -r '.title')
PR_BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_INFO" | jq -r '.headRefName')
PR_URL=$(echo "$PR_INFO" | jq -r '.url')

echo "  Title: $PR_TITLE"
echo "  Branch: $PR_HEAD -> $PR_BASE"
echo "  URL: $PR_URL"
echo ""

# Get the diff
print_info "Fetching PR diff..."
PR_DIFF=$(gh pr diff "$PR_NUMBER" 2>&1) || {
  print_error "Failed to fetch diff for PR #$PR_NUMBER"
  echo "$PR_DIFF"
  exit 1
}

DIFF_LINES=$(echo "$PR_DIFF" | wc -l | tr -d ' ')
DIFF_FILES=$(echo "$PR_DIFF" | grep -c "^diff --git" || echo "0")
print_info "Diff size: $DIFF_FILES files, $DIFF_LINES lines"
echo ""

# Load review instructions template
# Priority: 1. Repo-specific (.github/claude-code/), 2. Forge default, 3. Embedded fallback
# Use absolute path from RITE_PROJECT_ROOT to avoid CWD dependency
REPO_TEMPLATE="$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md"
FORGE_TEMPLATE="$RITE_INSTALL_DIR/templates/github/claude-code/pr-review-instructions.md"

if [ -f "$REPO_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$REPO_TEMPLATE"
  TEMPLATE_LINES=$(wc -l < "$REPO_TEMPLATE" | tr -d ' ')
  print_info "Using repo-specific review instructions ($TEMPLATE_LINES lines)"
elif [ -f "$FORGE_TEMPLATE" ]; then
  REVIEW_TEMPLATE="$FORGE_TEMPLATE"
  print_info "Using forge default review instructions"
else
  REVIEW_TEMPLATE=""
  print_warning "No review template found"
  print_info "Using embedded review instructions"
fi

if [ -z "$REVIEW_TEMPLATE" ]; then
  REVIEW_INSTRUCTIONS="You are a senior engineer conducting a thorough code review.
Analyze all changed files for:
1. Security vulnerabilities (highest priority)
2. Bug detection
3. Code quality
4. Performance issues
5. Test coverage

Classify findings as CRITICAL, HIGH, MEDIUM, or LOW.
Output your review in markdown format with clear sections."
else
  REVIEW_INSTRUCTIONS=$(cat "$REVIEW_TEMPLATE")
fi

# Load project context if available
PROJECT_CONTEXT=""
if [ -f "$RITE_PROJECT_ROOT/CLAUDE.md" ]; then
  PROJECT_CONTEXT="

## Project Context (from CLAUDE.md)

$(head -200 "$RITE_PROJECT_ROOT/CLAUDE.md")"
  print_info "Loaded project context from CLAUDE.md"
fi

# Build the full prompt
REVIEW_PROMPT="$REVIEW_INSTRUCTIONS
$PROJECT_CONTEXT

---

## PR Information

**Title:** $PR_TITLE
**Branch:** $PR_HEAD -> $PR_BASE
**PR Number:** #$PR_NUMBER

---

## Code Changes (Diff)

\`\`\`diff
$PR_DIFF
\`\`\`

---

Please provide your code review following the output format specified above."

# Estimate review time based on diff size
if [ "$DIFF_LINES" -lt 100 ]; then
  ESTIMATE="30-60 seconds"
elif [ "$DIFF_LINES" -lt 500 ]; then
  ESTIMATE="1-2 minutes"
else
  ESTIMATE="2-4 minutes"
fi

print_info "Running Claude Code review (estimated: $ESTIMATE)..."
echo ""

# Run Claude to generate the review
CLAUDE_STDERR=$(mktemp)

# Use consistent model for reviews (matches assessment model for determinism)
EFFECTIVE_MODEL="${RITE_REVIEW_MODEL:-opus}"

# Build Claude args with model flag
CLAUDE_ARGS="--print"
if [ -n "$EFFECTIVE_MODEL" ]; then
  CLAUDE_ARGS="$CLAUDE_ARGS --model $EFFECTIVE_MODEL"
fi

if [ "$AUTO_MODE" = true ]; then
  # Non-interactive mode
  REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude $CLAUDE_ARGS --dangerously-skip-permissions 2>"$CLAUDE_STDERR")
  REVIEW_EXIT=$?
else
  # Interactive mode (shows Claude's thinking)
  REVIEW_OUTPUT=$(echo "$REVIEW_PROMPT" | claude $CLAUDE_ARGS 2>"$CLAUDE_STDERR")
  REVIEW_EXIT=$?
fi

CLAUDE_ERROR=$(cat "$CLAUDE_STDERR")
rm -f "$CLAUDE_STDERR"

if [ $REVIEW_EXIT -ne 0 ]; then
  print_error "Claude review failed (exit code: $REVIEW_EXIT)"
  if [ -n "$CLAUDE_ERROR" ]; then
    echo "Error output:"
    echo "$CLAUDE_ERROR"
  fi
  exit 1
fi

if [ -z "$REVIEW_OUTPUT" ]; then
  print_error "Claude returned empty review"
  exit 1
fi

print_success "Review generated successfully"
echo ""

# Add marker with model metadata for assessment consistency
REVIEW_COMMENT="<!-- sharkrite-local-review model:${EFFECTIVE_MODEL} timestamp:$(date -u +"%Y-%m-%dT%H:%M:%SZ") -->

$REVIEW_OUTPUT"

if [ "$POST_REVIEW" = true ]; then
  # Post the review as a comment
  print_info "Posting review to PR #$PR_NUMBER..."

  COMMENT_URL=$(gh pr comment "$PR_NUMBER" --body "$REVIEW_COMMENT" 2>&1) || {
    print_error "Failed to post review comment"
    echo "$COMMENT_URL"
    echo ""
    echo "Review content (not posted):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$REVIEW_OUTPUT"
    exit 1
  }

  echo ""
  print_success "Review posted successfully!"
  echo "  $COMMENT_URL"
  echo ""

  # Invalidate cached assessments for this PR (new review = old assessment is stale)
  invalidate_pr_cache "$PR_NUMBER"

  # Output summary
  CRITICAL_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### CRITICAL|CRITICAL:" || echo "0")
  HIGH_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### HIGH|HIGH:" || echo "0")
  MEDIUM_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### MEDIUM|MEDIUM:" || echo "0")
  LOW_COUNT=$(echo "$REVIEW_OUTPUT" | grep -ciE "^### LOW|LOW:" || echo "0")

  echo "Review Summary:"
  echo "  CRITICAL: $CRITICAL_COUNT"
  echo "  HIGH: $HIGH_COUNT"
  echo "  MEDIUM: $MEDIUM_COUNT"
  echo "  LOW: $LOW_COUNT"

  # Extract overall verdict if present
  VERDICT=$(echo "$REVIEW_OUTPUT" | grep -oE "Overall:.*$" | head -1 || echo "")
  if [ -n "$VERDICT" ]; then
    echo ""
    echo "  $VERDICT"
  fi
else
  # Preview mode - just display the review
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "REVIEW PREVIEW (not posted)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "$REVIEW_OUTPUT"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  print_info "To post this review, run:"
  echo "  $0 $PR_NUMBER --post"
fi
