#!/usr/bin/env bash
# =============================================================================
# tests/test-bitbucket-provider.sh — Unit tests for providers/bitbucket.sh
# Usage: bash tests/test-bitbucket-provider.sh
# Run from the repo root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/providers/bitbucket.sh"

PASS=0
FAIL=0

check() {
  local desc="$1" expect_true="$2"
  shift 2
  if "$@" 2>/dev/null; then actual=true; else actual=false; fi
  if [ "$expect_true" = "$actual" ]; then
    echo "  PASS  $desc"
    ((PASS++)) || true
  else
    echo "  FAIL  $desc  (expected: $expect_true)"
    ((FAIL++)) || true
  fi
}

# Stub log — provider_fix_remote_url calls log which lives in ci-review.sh
log() { :; }

# ─── provider_detect_context — PR context ─────────────────────────────────────
echo "provider_detect_context (PR)"
export BITBUCKET_REPO_FULL_NAME="myworkspace/myrepo"
export BITBUCKET_BRANCH="feature/test"
export BITBUCKET_BUILD_NUMBER="100"
export BITBUCKET_PR_ID="42"
export BITBUCKET_PR_DESTINATION_BRANCH="main"
export BITBUCKET_PR_TITLE="My PR"
provider_detect_context
check "IS_PR is true"              true   [ "$IS_PR" = "true" ]
check "PR_ID is 42"                true   [ "$PR_ID" = "42" ]
check "PR_DESTINATION is main"     true   [ "$PR_DESTINATION" = "main" ]
check "PR_TITLE is My PR"          true   [ "$PR_TITLE" = "My PR" ]
check "CI_BRANCH is feature/test"  true   [ "$CI_BRANCH" = "feature/test" ]
check "CI_REPO_SLUG is myrepo"     true   [ "$CI_REPO_SLUG" = "myrepo" ]
check "PR_URL contains /42"        true   bash -c "echo '$PR_URL' | grep -q '/42'"
check "PIPELINE_URL is set"        true   [ -n "$PIPELINE_URL" ]

# ─── provider_detect_context — push context ───────────────────────────────────
echo ""
echo "provider_detect_context (push)"
unset BITBUCKET_PR_ID BITBUCKET_PR_DESTINATION_BRANCH BITBUCKET_PR_TITLE
provider_detect_context
check "IS_PR is false"             true   [ "$IS_PR" = "false" ]
check "CI_BRANCH is feature/test"  true   [ "$CI_BRANCH" = "feature/test" ]
check "PR_ID is empty"             true   [ -z "$PR_ID" ]
check "PR_URL is empty"            true   [ -z "$PR_URL" ]

# ─── provider_compare_url ─────────────────────────────────────────────────────
echo ""
echo "provider_compare_url"
CI_REPO_FULL_NAME="myworkspace/myrepo"
URL="$(provider_compare_url "abc1234" "def5678")"
check "URL contains base SHA"      true   bash -c "echo '$URL' | grep -q 'abc1234'"
check "URL contains head SHA"      true   bash -c "echo '$URL' | grep -q 'def5678'"
check "URL is bitbucket.org"       true   bash -c "echo '$URL' | grep -q 'bitbucket.org'"

# ─── provider_check_open_pr ───────────────────────────────────────────────────
echo ""
echo "provider_check_open_pr"
CI_REPO_FULL_NAME="myworkspace/myrepo"
BITBUCKET_USERNAME="user@example.com"
BITBUCKET_TOKEN="test-token"

curl() { cat "${SCRIPT_DIR}/fixtures/bitbucket-pr.json"; }
COUNT="$(provider_check_open_pr "feature/my-branch")"
check "matching branch returns 1"     true   [ "$COUNT" = "1" ]
COUNT="$(provider_check_open_pr "different-branch")"
check "non-matching branch returns 0" true   [ "$COUNT" = "0" ]

# ─── provider_post_pr_comment ─────────────────────────────────────────────────
echo ""
echo "provider_post_pr_comment"
CI_REPO_FULL_NAME="myworkspace/myrepo"
PR_ID="42"
BITBUCKET_USERNAME="user@example.com"
BITBUCKET_TOKEN="test-token"

# Stub curl to capture the actual command and return 201
_CURL_TMPFILE=$(mktemp)
curl() {
  echo "$@" >> "$_CURL_TMPFILE"
  echo "201"
}
provider_post_pr_comment "Test review content"
_CAPTURED_CURL_CMD=$(cat "$_CURL_TMPFILE")
rm "$_CURL_TMPFILE"
check "URL targets pullrequests/42/comments"  true   bash -c "echo '$_CAPTURED_CURL_CMD' | grep -q 'pullrequests/42/comments'"
check "payload contains review text"          true   bash -c "echo '$_CAPTURED_CURL_CMD' | grep -q 'Test review'"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
