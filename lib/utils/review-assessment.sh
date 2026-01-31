#!/bin/bash
# lib/utils/review-assessment.sh
# Simplified review extraction for Claude to assess
# Sources this file to use assess_pr_review() function
#
# Expects config.sh to be already loaded

# Function: assess_pr_review
# Extracts latest review and saves it for Claude assessment
# Usage: assess_pr_review <pr-number>
# Returns: 0=success, 1=error, 2=no review, 3=invalid format
assess_pr_review() {
  local PR_NUMBER=$1

  if [ -z "$PR_NUMBER" ]; then
    echo "❌ PR number required"
    return 1
  fi

  # Validate PR_NUMBER is numeric to prevent injection
  if [[ ! $PR_NUMBER =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid PR number: must be numeric"
    return 1
  fi

  # Colors
  local GREEN='\033[0;32m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}📊 Review Assessment - PR #${PR_NUMBER}${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Get the LATEST review only (use jq array indexing, not tail)
  local LATEST_REVIEW=$(gh pr view "$PR_NUMBER" --json comments \
    --jq '[.comments[] | select(.author.login == "claude" or .author.login == "claude-code" or .author.login == "github-actions[bot]")] | .[-1] | .body' \
    2>/dev/null)

  # Validate gh CLI returned valid data
  if [ -z "$LATEST_REVIEW" ] || [ "$LATEST_REVIEW" = "null" ]; then
    echo "⚠️  No review found"
    return 2  # Exit code 2: no review available
  fi

  # Validate this is actually a code review (not arbitrary bot comment)
  if ! echo "$LATEST_REVIEW" | grep -qiE "##? Code Review|##+ Overview"; then
    echo "⚠️  Comment found but doesn't appear to be a code review"
    echo "   (Missing 'Code Review' or 'Overview' section markers)"
    return 3  # Exit code 3: invalid format
  fi

  echo -e "${GREEN}✅ Review received${NC}"
  echo ""
  echo "PR #${PR_NUMBER} ready for assessment"
  echo ""

  return 0
}

# Export function if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f assess_pr_review
fi
