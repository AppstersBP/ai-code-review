#!/usr/bin/env bash
# =============================================================================
# tests/test-gitlab-provider.sh — Unit tests for providers/gitlab.sh
# Usage: bash tests/test-gitlab-provider.sh
# Run from the repo root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/providers/gitlab.sh"

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

# ─── provider_detect_context — MR context ─────────────────────────────────────
echo "provider_detect_context (MR)"
export GITLAB_CI="true"
export CI_PROJECT_PATH="mygroup/myproject"
export CI_PROJECT_ID="123"
export CI_PROJECT_URL="https://gitlab.com/mygroup/myproject"
export CI_COMMIT_REF_NAME="feature/test"
export CI_PIPELINE_ID="456"
export CI_PIPELINE_URL="https://gitlab.com/mygroup/myproject/-/pipelines/456"
export CI_MERGE_REQUEST_IID="7"
export CI_MERGE_REQUEST_TARGET_BRANCH_NAME="main"
export CI_MERGE_REQUEST_TITLE="My MR"
provider_detect_context
check "IS_PR is true"                true   [ "$IS_PR" = "true" ]
check "PR_ID is 7"                   true   [ "$PR_ID" = "7" ]
check "PR_DESTINATION is main"       true   [ "$PR_DESTINATION" = "main" ]
check "PR_TITLE is My MR"            true   [ "$PR_TITLE" = "My MR" ]
check "CI_BRANCH is feature/test"    true   [ "$CI_BRANCH" = "feature/test" ]
check "CI_REPO_SLUG is myproject"    true   [ "$CI_REPO_SLUG" = "myproject" ]
check "PR_URL contains merge_requests/7"  true   bash -c "echo '$PR_URL' | grep -q 'merge_requests/7'"
check "PIPELINE_URL is set"          true   [ "$PIPELINE_URL" = "https://gitlab.com/mygroup/myproject/-/pipelines/456" ]

# ─── provider_detect_context — push context ───────────────────────────────────
echo ""
echo "provider_detect_context (push)"
unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME CI_MERGE_REQUEST_TITLE
provider_detect_context
check "IS_PR is false"               true   [ "$IS_PR" = "false" ]
check "CI_BRANCH is feature/test"    true   [ "$CI_BRANCH" = "feature/test" ]
check "PR_ID is empty"               true   [ -z "$PR_ID" ]
check "PR_URL is empty"              true   [ -z "$PR_URL" ]

# ─── provider_compare_url ─────────────────────────────────────────────────────
echo ""
echo "provider_compare_url"
CI_PROJECT_URL="https://gitlab.com/mygroup/myproject"
URL="$(provider_compare_url "abc1234" "def5678")"
check "URL contains base SHA"        true   bash -c "echo '$URL' | grep -q 'abc1234'"
check "URL contains head SHA"        true   bash -c "echo '$URL' | grep -q 'def5678'"
check "URL uses GitLab compare"      true   bash -c "echo '$URL' | grep -q '/-/compare/'"

# ─── provider_check_open_pr — open MR ─────────────────────────────────────────
echo ""
echo "provider_check_open_pr"
CI_PROJECT_ID="123"
export CI_JOB_TOKEN="test-token"
unset GITLAB_TOKEN

curl() { cat "${SCRIPT_DIR}/fixtures/gitlab-mr.json"; }
COUNT="$(provider_check_open_pr "feature/my-branch")"
check "open MR returns 1"            true   [ "$COUNT" = "1" ]

curl() { echo "[]"; }
COUNT="$(provider_check_open_pr "no-mrs-branch")"
check "empty list returns 0"         true   [ "$COUNT" = "0" ]

# ─── provider_post_pr_comment ─────────────────────────────────────────────────
echo ""
echo "provider_post_pr_comment"
CI_PROJECT_ID="123"
PR_ID="7"
export CI_JOB_TOKEN="test-token"
unset GITLAB_TOKEN

# Stub curl to capture the actual command and return 201
_CURL_TMPFILE=$(mktemp)
curl() {
  echo "$@" >> "$_CURL_TMPFILE"
  echo "201"
}
provider_post_pr_comment "Test review content"
_CAPTURED_CURL_CMD=$(cat "$_CURL_TMPFILE")
rm "$_CURL_TMPFILE"
check "URL targets merge_requests/7/notes"  true   bash -c "echo '$_CAPTURED_CURL_CMD' | grep -q 'merge_requests/7/notes'"
check "payload contains review text"        true   bash -c "echo '$_CAPTURED_CURL_CMD' | grep -q 'Test review'"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
