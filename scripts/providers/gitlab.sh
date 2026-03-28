#!/usr/bin/env bash
# =============================================================================
# providers/gitlab.sh — GitLab CI provider for ci-review.sh
#
# Sourced by ci-review.sh when GITLAB_CI is set.
# Authentication: uses CI_JOB_TOKEN by default (automatically injected by
# GitLab CI, sufficient for listing MRs and posting MR comments on the same
# project). Set GITLAB_TOKEN to a personal/project access token to override
# (only needed for self-hosted instances with restricted job token policies).
# Set GITLAB_API_URL to override the default https://gitlab.com/api/v4
# (self-hosted instances only).
# =============================================================================

_gitlab_api_url() {
  echo "${GITLAB_API_URL:-https://gitlab.com/api/v4}"
}

_gitlab_auth_header() {
  if [ -n "${GITLAB_TOKEN:-}" ]; then
    echo "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
  else
    echo "JOB-TOKEN: ${CI_JOB_TOKEN:-}"
  fi
}

provider_validate_env() {
  : # No required vars — CI_JOB_TOKEN is injected automatically by GitLab CI
}

provider_detect_context() {
  IS_PR=false
  CI_BRANCH="${CI_COMMIT_REF_NAME:-unknown}"
  CI_REPO_FULL_NAME="${CI_PROJECT_PATH:-}"
  CI_REPO_SLUG="$(basename "${CI_PROJECT_PATH:-unknown-repo}")"
  CI_BUILD_NUMBER="${CI_PIPELINE_ID:-}"
  PIPELINE_URL="${CI_PIPELINE_URL:-}"

  if [ -n "${CI_MERGE_REQUEST_IID:-}" ]; then
    IS_PR=true
    PR_ID="${CI_MERGE_REQUEST_IID}"
    PR_DESTINATION="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"
    PR_TITLE="${CI_MERGE_REQUEST_TITLE:-}"
    PR_URL="${CI_PROJECT_URL}/-/merge_requests/${CI_MERGE_REQUEST_IID}"
  else
    PR_ID=""
    PR_DESTINATION=""
    PR_TITLE=""
    PR_URL=""
  fi
}

provider_fix_remote_url() {
  : # No-op — GitLab injects CI_REPOSITORY_URL as the authenticated clone URL
}

provider_check_open_pr() {
  local branch="$1"
  local api_url
  api_url="$(_gitlab_api_url)/projects/${CI_PROJECT_ID}/merge_requests"
  local auth_header
  auth_header="$(_gitlab_auth_header)"

  curl -s --get \
    --data-urlencode "state=opened" \
    --data-urlencode "source_branch=${branch}" \
    "${api_url}" \
    -H "${auth_header}" \
    | jq 'length' \
    2>/dev/null || echo "0"
}

provider_post_pr_comment() {
  local review="$1"
  local comment_body="### 🤖 Claude Code Review

${review}

---
*Automated review by [Claude Code](https://claude.ai/code) · $(date -u '+%Y-%m-%d %H:%M UTC')*"

  local api_url
  api_url="$(_gitlab_api_url)/projects/${CI_PROJECT_ID}/merge_requests/${PR_ID}/notes"
  local auth_header
  auth_header="$(_gitlab_auth_header)"

  local payload
  payload=$(jq -n --arg body "$comment_body" '{body: $body}')

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${api_url}" \
    -H "${auth_header}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    echo "[provider] Posted GitLab MR comment (HTTP ${http_status})"
  else
    echo "[provider] Failed to post GitLab MR comment (HTTP ${http_status})" >&2
    return 1
  fi
}

provider_compare_url() {
  local base_sha="$1"
  local head_sha="$2"
  echo "${CI_PROJECT_URL}/-/compare/${base_sha}...${head_sha}"
}
