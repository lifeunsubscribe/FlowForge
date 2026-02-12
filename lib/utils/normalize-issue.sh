#!/bin/bash
# lib/utils/normalize-issue.sh - Issue title normalization and structured issue generation
#
# Produces two variables for downstream consumers:
#   NORMALIZED_SUBJECT  — Git subject line (<=50 chars, imperative, conventional commit prefix)
#   WORK_DESCRIPTION    — Full context for Claude dev prompt and PR body
#
# Two paths:
#   normalize_piped_input "$text"  — Generate structured issue from freeform text via Claude
#   normalize_existing_issue       — Bash-only cleanup of existing issue title
#
# Both paths always prompt for approval (interactive read -p), even in --auto mode.

# Source colors if not already loaded
if ! declare -f print_info &>/dev/null; then
  if [ -n "${RITE_LIB_DIR:-}" ]; then
    source "$RITE_LIB_DIR/utils/colors.sh"
  fi
fi

# Detect Claude CLI (consistent with claude-workflow.sh)
_detect_claude_cmd() {
  if command -v claude &>/dev/null; then
    echo "claude"
  elif command -v claude-code &>/dev/null; then
    echo "claude-code"
  elif [ -f "$HOME/.claude/claude" ]; then
    echo "$HOME/.claude/claude"
  else
    echo ""
  fi
}

# Truncate a string to max_len at a word boundary.
# Usage: _truncate_at_word_boundary "$string" max_len
_truncate_at_word_boundary() {
  local str="$1"
  local max_len="$2"

  if [ ${#str} -le "$max_len" ]; then
    echo "$str"
    return
  fi

  # Cut to max_len, then remove the last partial word
  local cut
  cut=$(echo "$str" | cut -c1-"$max_len")
  # If the cut lands mid-word, remove the trailing fragment
  if [ "${str:$max_len:1}" != " " ] && [ "${str:$max_len:1}" != "" ]; then
    cut=$(echo "$cut" | sed 's/ [^ ]*$//')
  fi
  echo "$cut"
}

# ===================================================================
# PATH A: Piped text instructions (rite "fix the rate limiter")
# ===================================================================
#
# Uses Claude to generate a structured GitHub issue from freeform text.
# Sets: NORMALIZED_SUBJECT, WORK_DESCRIPTION, ISSUE_NUMBER (after gh issue create)
# Returns: 0 on approval, 1 on rejection
normalize_piped_input() {
  local input_text="$1"

  local claude_cmd
  claude_cmd=$(_detect_claude_cmd)

  # Build the Claude prompt
  local prompt
  prompt="You are preparing a GitHub issue for an automated development workflow.

Given this task description:
---
${input_text}
---

Generate a structured GitHub issue. Make reasonable assumptions about implementation approach — the user will review and approve before work begins.

Output format (follow EXACTLY):

TITLE: <imperative mood, conventional commit prefix, <=50 chars>
BODY:
<2-3 sentence description of the problem/task scope>

### Approach
<1-3 bullet points describing the intended implementation fix/strategy>

### Done when
<2-4 bullet points of concrete acceptance criteria — how to verify the issue is resolved>

### Assumptions
<bulleted list of assumptions made about scope, boundaries, or implementation details>

Rules:
- Title MUST be <=50 characters (this is a hard limit for git subject lines)
- Title MUST start with a conventional commit prefix: fix:, feat:, docs:, test:, refactor:, chore:
- Title MUST use imperative mood (\"fix bug\" not \"fixes bug\" or \"fixed bug\")
- Title should describe WHAT to do, not HOW
- Approach should describe the intended fix strategy concisely
- Done criteria should be verifiable (testable assertions, not vague \"works correctly\")
- Assumptions should capture scope boundaries (what's in/out of this issue)
- Do NOT use markdown formatting in the title (no **, *, \`, #)
- Do NOT ask questions — make reasonable assumptions and list them"

  local generated_title=""
  local generated_body=""

  if [ -n "$claude_cmd" ]; then
    # Write prompt to temp file for stdin passing
    local prompt_file
    prompt_file=$(mktemp)
    echo "$prompt" > "$prompt_file"

    print_info "Generating structured issue from description..." >&2

    local claude_output
    claude_output=$($claude_cmd --print < "$prompt_file" 2>/dev/null) || true
    rm -f "$prompt_file"

    if [ -n "$claude_output" ]; then
      # Parse TITLE: and BODY: markers
      generated_title=$(echo "$claude_output" | sed -n 's/^TITLE: *//p' | head -1)
      # Everything after the BODY: line
      generated_body=$(echo "$claude_output" | sed -n '/^BODY:/,$p' | tail -n +2)
    fi
  fi

  # Fallback if Claude failed or unavailable: bash-only cleanup
  if [ -z "$generated_title" ]; then
    if [ -n "$claude_cmd" ]; then
      print_warning "Claude generation failed — falling back to bash cleanup" >&2
    else
      print_warning "Claude CLI not found — falling back to bash cleanup" >&2
    fi

    generated_title=$(_bash_cleanup_title "$input_text")
    generated_body="$input_text"
  fi

  # Strip markdown from title (safety net)
  generated_title=$(echo "$generated_title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')

  # Validate title length
  if [ ${#generated_title} -gt 50 ]; then
    local original_title="$generated_title"
    generated_title=$(_truncate_at_word_boundary "$generated_title" 50)
    print_warning "Title was truncated to 50 chars (git subject line limit)" >&2
    print_info "  Original: $original_title" >&2
    print_info "  Truncated: $generated_title" >&2
  fi

  # Display for approval (always interactive, even in --auto)
  echo "" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo -e "${BLUE} Generated Issue${NC}" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo "" >&2
  echo -e "Title: ${GREEN}${generated_title}${NC}" >&2
  echo "" >&2
  if [ -n "$generated_body" ]; then
    echo "$generated_body" >&2
  fi
  echo "" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

  # Approval loop
  while true; do
    read -p "Approve and create issue? (y/n/e to edit title) " -n 1 -r </dev/tty
    echo >&2

    if [[ $REPLY =~ ^[Yy]$ ]]; then
      break
    elif [[ $REPLY =~ ^[Nn]$ ]]; then
      print_info "Aborted. No issue was created." >&2
      return 1
    elif [[ $REPLY =~ ^[Ee]$ ]]; then
      echo -n "Enter new title: " >&2
      read -r generated_title </dev/tty
      # Validate edited title
      generated_title=$(echo "$generated_title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')
      if [ ${#generated_title} -gt 50 ]; then
        generated_title=$(_truncate_at_word_boundary "$generated_title" 50)
        print_warning "Title truncated to 50 chars: $generated_title" >&2
      fi
      echo "" >&2
      echo -e "New title: ${GREEN}${generated_title}${NC}" >&2
      echo "" >&2
    fi
  done

  # Create the issue on GitHub
  print_info "Creating GitHub issue..." >&2
  local issue_url
  local _gh_exit=0
  if [ -n "$generated_body" ]; then
    issue_url=$(gh issue create --title "$generated_title" --body "$generated_body" 2>&1) || _gh_exit=$?
  else
    issue_url=$(gh issue create --title "$generated_title" --body "Created by rite from CLI description." 2>&1) || _gh_exit=$?
  fi

  if [ $_gh_exit -ne 0 ]; then
    print_error "Failed to create GitHub issue: $issue_url" >&2
    return 1
  fi

  local issue_number
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_number" ]; then
    print_error "Could not extract issue number from: $issue_url" >&2
    return 1
  fi

  print_success "Created issue #${issue_number}: ${generated_title}" >&2

  # Set variables in calling scope
  ISSUE_NUMBER="$issue_number"
  ISSUE_DESC="$generated_title"
  NORMALIZED_SUBJECT="$generated_title"
  WORK_DESCRIPTION="${generated_title}

${generated_body}"
  GENERATED_ISSUE_BODY="$generated_body"

  return 0
}

# ===================================================================
# PATH B: Pre-existing GitHub issues (rite 42)
# ===================================================================
#
# Applies bash-only cleanup to the existing issue title.
# Expects: ISSUE_NUMBER, ISSUE_DESC, ISSUE_BODY to be set in calling scope.
# Sets: NORMALIZED_SUBJECT, WORK_DESCRIPTION
# Returns: 0 (always succeeds)
normalize_existing_issue() {
  local original_title="$ISSUE_DESC"

  local cleaned
  cleaned=$(_bash_cleanup_title "$original_title")

  # Build WORK_DESCRIPTION from full issue content
  if [ -n "${ISSUE_BODY:-}" ] && [ "$ISSUE_BODY" != "null" ]; then
    WORK_DESCRIPTION="${ISSUE_DESC}

${ISSUE_BODY}"
  else
    WORK_DESCRIPTION="$ISSUE_DESC"
  fi

  # If title changed, prompt for approval (unless RITE_SKIP_APPROVAL is set)
  if [ "$cleaned" != "$original_title" ] && [ "${RITE_SKIP_APPROVAL:-false}" != "true" ]; then
    echo "" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE} Issue #${ISSUE_NUMBER} — Title Cleanup${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo "" >&2
    echo -e "Original: ${YELLOW}${original_title}${NC}" >&2
    echo -e "Cleaned:  ${GREEN}${cleaned}${NC}" >&2
    echo "" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

    while true; do
      read -p "Accept cleaned title? (y/n/e to edit) " -n 1 -r </dev/tty
      echo >&2

      if [[ $REPLY =~ ^[Yy]$ ]]; then
        break
      elif [[ $REPLY =~ ^[Nn]$ ]]; then
        # Use original title
        cleaned="$original_title"
        # Still apply essential cleanup (prefix) but keep length as-is
        if ! echo "$cleaned" | grep -qE '^(fix|feat|docs|test|refactor|chore|build|ci|perf|style)(\(.*\))?:'; then
          local prefix
          prefix=$(_detect_commit_prefix "$cleaned")
          cleaned="${prefix}: ${cleaned}"
        fi
        print_info "Using original title (with prefix if needed): $cleaned" >&2
        break
      elif [[ $REPLY =~ ^[Ee]$ ]]; then
        echo -n "Enter new title: " >&2
        read -r cleaned </dev/tty
        cleaned=$(echo "$cleaned" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')
        if [ ${#cleaned} -gt 50 ]; then
          cleaned=$(_truncate_at_word_boundary "$cleaned" 50)
          print_warning "Title truncated to 50 chars: $cleaned" >&2
        fi
        echo -e "New title: ${GREEN}${cleaned}${NC}" >&2
        break
      fi
    done
  fi

  NORMALIZED_SUBJECT="$cleaned"
  return 0
}

# ===================================================================
# INTERNAL HELPERS
# ===================================================================

# Detect conventional commit prefix from keywords in the title.
# Same logic as claude-workflow.sh:670-682.
_detect_commit_prefix() {
  local text="$1"
  local prefix="feat"

  if echo "$text" | grep -iqE '(fix|bug|issue|error)'; then
    prefix="fix"
  elif echo "$text" | grep -iqE '(docs|documentation|readme)'; then
    prefix="docs"
  elif echo "$text" | grep -iqE '(test|testing|spec)'; then
    prefix="test"
  elif echo "$text" | grep -iqE '(refactor|cleanup|improve)'; then
    prefix="refactor"
  elif echo "$text" | grep -iqE '(chore|setup|config)'; then
    prefix="chore"
  fi

  echo "$prefix"
}

# Bash-only title cleanup (deterministic, no Claude needed).
# Used for Path B and as fallback for Path A on Claude failure.
_bash_cleanup_title() {
  local title="$1"

  # 1. Strip markdown artifacts
  local cleaned
  cleaned=$(echo "$title" | sed 's/\*\*//g; s/\*//g; s/`//g; s/^#\+ //')

  # 2. Ensure conventional commit prefix
  if ! echo "$cleaned" | grep -qE '^(fix|feat|docs|test|refactor|chore|build|ci|perf|style)(\(.*\))?:'; then
    local prefix
    prefix=$(_detect_commit_prefix "$cleaned")
    cleaned="${prefix}: ${cleaned}"
  fi

  # 3. Truncate to 50 chars at word boundary
  if [ ${#cleaned} -gt 50 ]; then
    cleaned=$(_truncate_at_word_boundary "$cleaned" 50)
  fi

  echo "$cleaned"
}
