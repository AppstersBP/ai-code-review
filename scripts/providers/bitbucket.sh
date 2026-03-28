#!/usr/bin/env bash
# =============================================================================
# providers/bitbucket.sh — Bitbucket Pipelines provider for ci-review.sh
#
# Sourced by ci-review.sh when BITBUCKET_BUILD_NUMBER is set.
# Reads: BITBUCKET_TOKEN, BITBUCKET_USERNAME, BITBUCKET_REPO_FULL_NAME,
#        BITBUCKET_BRANCH, BITBUCKET_BUILD_NUMBER, BITBUCKET_PR_ID,
#        BITBUCKET_PR_DESTINATION_BRANCH, BITBUCKET_PR_TITLE,
#        BITBUCKET_GIT_HTTP_ORIGIN (all injected by Bitbucket Pipelines)
# =============================================================================

provider_validate_env() {
  : "${BITBUCKET_TOKEN:?Required variable BITBUCKET_TOKEN is not set}"
  : "${BITBUCKET_USERNAME:?Required variable BITBUCKET_USERNAME is not set}"
}

provider_detect_context() {
  IS_PR=false
  CI_BRANCH="${BITBUCKET_BRANCH:-unknown}"
  CI_REPO_FULL_NAME="${BITBUCKET_REPO_FULL_NAME:-}"
  CI_REPO_SLUG="$(basename "${BITBUCKET_REPO_FULL_NAME:-unknown-repo}")"
  CI_BUILD_NUMBER="${BITBUCKET_BUILD_NUMBER:-}"
  PIPELINE_URL=""
  if [ -n "${BITBUCKET_BUILD_NUMBER:-}" ] && [ -n "${BITBUCKET_REPO_FULL_NAME:-}" ]; then
    PIPELINE_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pipelines/results/${BITBUCKET_BUILD_NUMBER}"
  fi

  if [ -n "${BITBUCKET_PR_ID:-}" ]; then
    IS_PR=true
    PR_ID="${BITBUCKET_PR_ID}"
    PR_DESTINATION="${BITBUCKET_PR_DESTINATION_BRANCH:-}"
    PR_TITLE="${BITBUCKET_PR_TITLE:-}"
    PR_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pull-requests/${BITBUCKET_PR_ID}"
  else
    PR_ID=""
    PR_DESTINATION=""
    PR_TITLE=""
    PR_URL=""
  fi
}

provider_fix_remote_url() {
  if [ -n "${BITBUCKET_GIT_HTTP_ORIGIN:-}" ]; then
    git remote set-url origin "$BITBUCKET_GIT_HTTP_ORIGIN" 2>/dev/null || true
    log "Remote URL set to BITBUCKET_GIT_HTTP_ORIGIN for authenticated fetches"
  fi
}

provider_check_open_pr() {
  local branch="$1"
  curl -s \
    "https://api.bitbucket.org/2.0/repositories/${CI_REPO_FULL_NAME}/pullrequests?state=OPEN&pagelen=50" \
    -u "${BITBUCKET_USERNAME}:${BITBUCKET_TOKEN}" \
    | jq --arg branch "$branch" \
         '[.values[] | select(.source.branch.name == $branch)] | length' \
    2>/dev/null || echo "0"
}

provider_post_pr_comment() {
  local review="$1"
  local comment_body="### 🤖 Claude Code Review

${review}

---
*Automated review by [Claude Code](https://claude.ai/code) · $(date -u '+%Y-%m-%d %H:%M UTC')*"

  local payload
  payload=$(jq -n --arg body "$comment_body" '{content: {raw: $body}}')

  local api_url="https://api.bitbucket.org/2.0/repositories/${CI_REPO_FULL_NAME}/pullrequests/${PR_ID}/comments"

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${api_url}" \
    -u "${BITBUCKET_USERNAME}:${BITBUCKET_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    echo "[provider] Posted Bitbucket PR comment (HTTP ${http_status})"
  else
    echo "[provider] Failed to post Bitbucket PR comment (HTTP ${http_status})" >&2
    return 1
  fi
}

provider_compare_url() {
  local base_sha="$1"
  local head_sha="$2"
  echo "https://bitbucket.org/${CI_REPO_FULL_NAME}/branches/compare/${head_sha}%0D${base_sha}#diff"
}
