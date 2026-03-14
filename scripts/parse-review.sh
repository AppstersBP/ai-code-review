#!/usr/bin/env bash
# =============================================================================
# parse-review.sh — Shared helpers for inspecting Claude review output.
# Sourced by ci-review.sh and post-slack.sh.
# =============================================================================

# Extract a named section from a review, stripping headings, --- separators,
# and blank lines so only the actual content lines remain.
#
# Usage: _review_section "$REVIEW" "### 🔴 Critical" "### 🟡"
_review_section() {
  local review="$1" start="$2" end="$3"
  echo "$review" \
    | awk "/$start/,/$end/" \
    | grep -v "^###" \
    | grep -v "^---" \
    | grep -v "^$" \
    || true
}

# Returns 0 if the 🔴 Critical section contains at least one finding.
# Returns 1 if the section is absent or contains only "None."
has_critical_findings() {
  local review="$1"
  echo "$review" | grep -q "### 🔴 Critical" || return 1
  _review_section "$review" "### 🔴 Critical" "### 🟡" | grep -qv "None\."
}

# Returns 0 if the 🟡 Important section contains at least one finding.
# Returns 1 if the section is absent or contains only "None."
has_important_findings() {
  local review="$1"
  echo "$review" | grep -q "### 🟡 Important" || return 1
  _review_section "$review" "### 🟡 Important" "### 🟢" | grep -qv "None\."
}
