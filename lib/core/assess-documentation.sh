#!/bin/bash

# assess-documentation.sh - Pre-merge documentation completeness check
# Extracts doc-related items from Sharkrite review and applies updates directly
#
# Usage:
#   assess-documentation.sh <PR_NUMBER> [--auto]
#
# This script:
# 1. Checks for existing Sharkrite review on the PR
# 2. Extracts any documentation-related findings from the review
# 3. If doc items found, applies updates directly
# 4. If no review exists, performs standalone doc assessment

set -euo pipefail

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

PR_NUMBER="$1"
AUTO_MODE="${2:-}"

if [ -z "$PR_NUMBER" ]; then
  print_error "Usage: $0 <pr_number> [--auto]"
  exit 1
fi

# Check Claude CLI availability
if ! command -v claude &> /dev/null; then
  print_error "❌ Claude CLI not found"
  print_warning "Install: npm install -g @anthropic-ai/claude-cli"
  print_warning "Setup: claude setup-token"
  exit 1
fi

# Test Claude CLI
if ! echo "test" | claude --print --dangerously-skip-permissions &> /dev/null; then
  print_error "❌ Claude CLI not authenticated or not working"
  print_warning "Run: claude setup-token"
  exit 1
fi

# =============================================================================
# STATIC OUTPUT HEADER
# =============================================================================

print_header "📚 Documentation Assessment"
echo ""

# Get PR details
PR_DATA=$(gh pr view "$PR_NUMBER" --json title,body,files,commits,reviews,comments)
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body // ""')

echo "PR #$PR_NUMBER: $PR_TITLE"
echo ""

# =============================================================================
# EXTRACT DOC ITEMS FROM SHARKRITE REVIEW
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Review Context"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Look for Sharkrite review in formal reviews first, then comments
SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r '[.reviews[] | select(.body | contains("sharkrite-local-review") or contains("sharkrite-review-data"))] | .[-1] | .body // ""' 2>/dev/null)

if [ -z "$SHARKRITE_REVIEW" ] || [ "$SHARKRITE_REVIEW" = "null" ]; then
  SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r '[.comments[] | select(.body | contains("sharkrite-local-review") or contains("sharkrite-review-data"))] | .[-1] | .body // ""' 2>/dev/null)
fi

# Extract documentation-related items from review
DOC_ITEMS_FROM_REVIEW=""
REVIEW_HAS_DOC_ITEMS=false

if [ -n "$SHARKRITE_REVIEW" ] && [ "$SHARKRITE_REVIEW" != "null" ]; then
  print_success "  Found Sharkrite review"

  # Extract doc-related mentions (look for documentation, docs, README, CLAUDE.md patterns)
  DOC_ITEMS_FROM_REVIEW=$(echo "$SHARKRITE_REVIEW" | grep -iE "(documentation|docs/|README|CLAUDE\.md|update.*doc|missing.*doc|add.*doc)" | head -20 || echo "")

  if [ -n "$DOC_ITEMS_FROM_REVIEW" ]; then
    REVIEW_HAS_DOC_ITEMS=true
    DOC_ITEM_COUNT=$(echo "$DOC_ITEMS_FROM_REVIEW" | wc -l | tr -d ' ')
    print_info "  Found $DOC_ITEM_COUNT documentation-related items in review"
  else
    print_info "  No documentation items flagged in review"
  fi
else
  print_warning "  No Sharkrite review found - will perform standalone assessment"
fi

echo ""

# =============================================================================
# GATHER CONTEXT
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 Changed Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get changed files
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.files[].path' | grep -v '^docs/' | head -20 || true)
FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | xargs)

echo "  Code files changed: $FILE_COUNT"

# Get commit messages for context
COMMIT_MESSAGES=$(echo "$PR_DATA" | jq -r '.commits[].messageHeadline' | head -10)

# Get current documentation structure
DOC_FILES=$(find docs/ -name "*.md" 2>/dev/null | sort || echo "")

# Get CLAUDE.md sections if it exists
CLAUDE_MD_SECTIONS=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_SECTIONS=$(grep "^##" CLAUDE.md | head -30 || true)
fi

# Get project README sections if available (configurable per project)
README_SECTIONS=""
if [ -n "${RITE_SCRIPTS_README:-}" ] && [ -f "$RITE_SCRIPTS_README" ]; then
  README_SECTIONS=$(grep "^##" "$RITE_SCRIPTS_README" | head -20 || true)
elif [ -f "README.md" ]; then
  README_SECTIONS=$(grep "^##" README.md | head -20 || true)
fi

# Get table of contents from each major doc to understand coverage
ARCHITECTURE_DOCS=""
for doc in docs/architecture/*.md; do
  if [ -f "$doc" ]; then
    ARCHITECTURE_DOCS="$ARCHITECTURE_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

PROJECT_DOCS=""
for doc in docs/project/*.md; do
  if [ -f "$doc" ]; then
    PROJECT_DOCS="$PROJECT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

WORKFLOW_DOCS=""
for doc in docs/workflows/*.md; do
  if [ -f "$doc" ]; then
    WORKFLOW_DOCS="$WORKFLOW_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

SECURITY_DOCS=""
for doc in docs/security/*.md; do
  if [ -f "$doc" ]; then
    SECURITY_DOCS="$SECURITY_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

DEVELOPMENT_DOCS=""
for doc in docs/development/*.md; do
  if [ -f "$doc" ]; then
    DEVELOPMENT_DOCS="$DEVELOPMENT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

# =============================================================================
# DOCUMENTATION ASSESSMENT
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Assessment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Build assessment prompt - include review context if available
REVIEW_CONTEXT_SECTION=""
if [ "$REVIEW_HAS_DOC_ITEMS" = true ]; then
  REVIEW_CONTEXT_SECTION="
**Documentation Items from Sharkrite Review:**
The code review already identified these documentation-related items. Use these as your primary guide:
\`\`\`
$DOC_ITEMS_FROM_REVIEW
\`\`\`

Focus on addressing the specific items mentioned in the review.
"
fi

# Pre-compute doc structure (avoid nested $() inside heredoc)
CLAUDE_MD_INLINE=$(echo "$CLAUDE_MD_SECTIONS" | head -10 | tr '\n' ';')
README_INLINE=""
if [ -n "$README_SECTIONS" ]; then
  README_INLINE="- README.md (project overview): $(echo "$README_SECTIONS" | head -10 | tr '\n' ';')"
fi

# Build assessment prompt in temp file (heredoc inside $() is fragile —
# PR body content can contain shell metacharacters that break parsing)
ASSESS_PROMPT_FILE=$(mktemp)
cat > "$ASSESS_PROMPT_FILE" <<ASSESS_PROMPT_EOF
You are reviewing a pull request to assess if documentation needs updating.

**PR Title:** $PR_TITLE

**PR Description:**
$PR_BODY
$REVIEW_CONTEXT_SECTION
**Changed Files (excluding docs/):**
$CHANGED_FILES

**Recent Commits:**
$COMMIT_MESSAGES

**Existing Documentation Structure:**

Root-level docs:
- CLAUDE.md (main architecture guide): $CLAUDE_MD_INLINE
$README_INLINE

docs/architecture/ (system design, infrastructure, database):
$(echo -e "$ARCHITECTURE_DOCS")

docs/project/ (business requirements, roadmap, pricing):
$(echo -e "$PROJECT_DOCS")

docs/workflows/ (CI/CD, automation, GitHub Actions):
$(echo -e "$WORKFLOW_DOCS")

docs/security/ (security patterns, vulnerabilities):
$(echo -e "$SECURITY_DOCS")

docs/development/ (dev guides, testing, setup):
$(echo -e "$DEVELOPMENT_DOCS")

**Your Task:**
Assess whether ANY documentation needs to be updated based on these code changes.

**Check ALL documentation categories:**
1. **New scripts or automation** → project README or workflow docs
2. **New architectural patterns** → CLAUDE.md
3. **New workflows or CI/CD** → docs/workflows/
4. **Security patterns/vulnerabilities** → docs/security/
5. **New functions/resources** → CLAUDE.md or docs/architecture/
6. **Infrastructure changes** → docs/architecture/
7. **Database schema changes** → docs/architecture/
8. **New configuration/environment variables** → CLAUDE.md or docs/development/
9. **Testing strategy changes** → docs/development/
10. **Business/product changes** → docs/project/
11. **Documentation index changes** → docs/README.md

**Response Format:**
If documentation updates are needed, respond with:
NEEDS_UPDATE: <file1.md>, <file2.md>, <file3.md>
REASON: <Brief explanation of what needs updating>

If no documentation updates needed, respond with:
NO_UPDATE_NEEDED
REASON: <Brief explanation>

**Be strict:** Architectural changes, new patterns, new scripts, infrastructure changes ALWAYS need documentation.

**Examples of what needs docs:**
- New bash scripts → project README or workflow docs
- New error handling patterns → CLAUDE.md
- New rate limiting logic → CLAUDE.md + docs/security/
- New CI/CD workflows → docs/workflows/
- Database schema changes → docs/architecture/
- New AWS resources → docs/architecture/
- New feature tiers or access control → docs/project/
- Product roadmap changes → docs/project/
- Input validation rule changes → docs/api/ or API-REFERENCE.md
- Request/response schema changes → docs/api/ or API-REFERENCE.md
- Zod/validation library updates → API documentation
- Regex pattern changes for user input → API-REFERENCE.md

**Examples of what doesn't need docs:**
- Bug fixes to existing code (no pattern change)
- Updating existing tests (no new testing strategy)
- Refactoring without behavior change
- Minor version bumps
- Comment improvements
ASSESS_PROMPT_EOF

print_info "Analyzing documentation requirements..."

# Run assessment
ASSESSMENT_OUTPUT=$(claude --print --dangerously-skip-permissions < "$ASSESS_PROMPT_FILE" 2>&1)
rm -f "$ASSESS_PROMPT_FILE"

# =============================================================================
# APPLY UPDATES
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Updates"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if echo "$ASSESSMENT_OUTPUT" | grep -q "^NEEDS_UPDATE"; then
  DOCS_TO_UPDATE=$(echo "$ASSESSMENT_OUTPUT" | grep "^NEEDS_UPDATE:" | sed 's/NEEDS_UPDATE: //')
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //')

  echo "  Status: Updates needed"
  echo "  Files: $DOCS_TO_UPDATE"
  echo "  Reason: $REASON"
  echo ""

  # In supervised mode, confirm before applying
  APPLY_UPDATES=true
  if [ "$AUTO_MODE" != "--auto" ]; then
    echo ""
    read -p "Apply documentation updates? (Y/n): " APPLY_DOCS
    if [[ "$APPLY_DOCS" =~ ^[Nn]$ ]]; then
      APPLY_UPDATES=false
      read -p "Continue with merge without doc updates? (y/N): " CONTINUE
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        print_info "Merge cancelled - update documentation first"
        exit 2
      fi
    fi
  fi

  if [ "$APPLY_UPDATES" = true ]; then
    # Get PR diff for context
    PR_DIFF=$(gh pr diff $PR_NUMBER | head -300)

    # For each file that needs updating, read current content and generate update
    IFS=',' read -ra FILES_ARRAY <<< "$DOCS_TO_UPDATE"
    UPDATED_FILES=()
    SKIPPED_FILES=()

    for doc_file in "${FILES_ARRAY[@]}"; do
      doc_file=$(echo "$doc_file" | xargs)  # trim whitespace

      if [ ! -f "$doc_file" ]; then
        SKIPPED_FILES+=("$doc_file (not found)")
        continue
      fi

      echo "  Updating: $doc_file"

      CURRENT_CONTENT=$(cat "$doc_file")

      UPDATE_PROMPT_FILE=$(mktemp)
      cat > "$UPDATE_PROMPT_FILE" <<UPDATE_PROMPT_EOF
You are updating documentation to reflect code changes from a PR.

**Documentation Update Rule:**
- If pertinent topic exists: expand section as necessary with new information
- If topic doesn't exist: add new section in appropriate location
- Keep updates minimal and focused on the actual changes
- Consider PR scope - don't over-document minor changes
- Match existing documentation style and format

**PR Context:**
- PR #$PR_NUMBER: $PR_TITLE
- Reason for doc update: $REASON

**PR Changes (diff):**
\`\`\`
$PR_DIFF
\`\`\`

**Current Documentation Content:**
\`\`\`markdown
$CURRENT_CONTENT
\`\`\`

**Your Task:**
Update this documentation file to reflect the PR changes. Output the COMPLETE updated file.

**Guidelines:**
- Maintain all existing content unless it contradicts new changes
- Add new sections only if substantive new functionality was added
- Expand existing sections if the topic is already covered
- Use consistent markdown formatting
- Keep the same structure and organization
- Update timestamps if present (format: YYYY-MM-DD)

Output ONLY the complete updated markdown file, nothing else.
UPDATE_PROMPT_EOF

      CLAUDE_EXIT=0
      UPDATED_CONTENT=$(claude --print --dangerously-skip-permissions < "$UPDATE_PROMPT_FILE" 2>&1) || CLAUDE_EXIT=$?
      rm -f "$UPDATE_PROMPT_FILE"

      if [ $CLAUDE_EXIT -eq 0 ] && [ -n "$UPDATED_CONTENT" ]; then
        # Verify update looks reasonable (not truncated)
        ORIGINAL_SIZE=$(echo "$CURRENT_CONTENT" | wc -l)
        NEW_SIZE=$(echo "$UPDATED_CONTENT" | wc -l)
        MIN_SIZE=$((ORIGINAL_SIZE * 80 / 100))

        if [ "$NEW_SIZE" -lt "$MIN_SIZE" ]; then
          SKIPPED_FILES+=("$doc_file (truncated output)")
          continue
        fi

        # Backup original
        cp "$doc_file" "${doc_file}.backup-$(date +%s)"

        # Apply update
        echo "$UPDATED_CONTENT" > "$doc_file"
        UPDATED_FILES+=("$doc_file")
        print_success "    ✓ Updated"
      else
        SKIPPED_FILES+=("$doc_file (generation failed)")
      fi
    done

    echo ""

    # =============================================================================
    # SUMMARY
    # =============================================================================

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
      echo "  Updated: ${#UPDATED_FILES[@]} file(s)"
      for f in "${UPDATED_FILES[@]}"; do
        echo "    ✓ $f"
      done

      # Git add the updated docs
      git add "${UPDATED_FILES[@]}"

      # Commit doc updates
      COMMIT_MSG="docs: update documentation for PR #$PR_NUMBER

Auto-updated by doc assessment:
- Files: ${UPDATED_FILES[*]}
- Reason: $REASON

Related: #$PR_NUMBER"

      if git commit -m "$COMMIT_MSG" 2>/dev/null; then
        echo ""
        echo "  Committed: docs update for PR #$PR_NUMBER"

        # Push doc updates so they're on the PR branch before merge
        if git push 2>/dev/null; then
          echo "  Pushed: doc updates included in PR"
        else
          print_warning "  Could not push doc updates — they will be local-only"
        fi
      else
        echo ""
        echo "  Note: No changes to commit (docs may already be up to date)"
      fi

      # Send Slack notification
      if [ -n "${SLACK_WEBHOOK:-}" ]; then
        SLACK_MESSAGE=$(cat <<EOF
{
  "text": "📚 *Documentation Auto-Updated*",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*PR #$PR_NUMBER*: $PR_TITLE\\n\\n*Files updated:* \\\`${UPDATED_FILES[*]}\\\`\\n\\n*Reason:* $REASON\\n\\nDocumentation committed and merge proceeding."
      }
    }
  ]
}
EOF
)
        curl -X POST "$SLACK_WEBHOOK" \
          -H "Content-Type: application/json" \
          -d "$SLACK_MESSAGE" \
          --silent --output /dev/null
      fi
    else
      echo "  Updated: 0 files"
    fi

    if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
      echo ""
      echo "  Skipped: ${#SKIPPED_FILES[@]} file(s)"
      for f in "${SKIPPED_FILES[@]}"; do
        echo "    ⚠ $f"
      done
    fi

    echo ""

    # Don't block merge - docs are updated (or attempted)
    exit 0
  fi
else
  echo "  Status: No updates needed"
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //' || echo "Documentation is current")
  echo "  Reason: $REASON"
  echo ""

  # Still show summary for consistency
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Documentation is up to date"
  echo ""
fi

exit 0
