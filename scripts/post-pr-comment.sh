#!/usr/bin/env bash
# =============================================================================
# post-pr-comment.sh — Posts the Claude review as a Bitbucket PR comment
#
# Usage: bash scripts/post-pr-comment.sh "<review text>"
#
# Required env vars (inherited from ci-review.sh):
#   BITBUCKET_USERNAME, BITBUCKET_TOKEN,
#   BITBUCKET_REPO_FULL_NAME, BITBUCKET_PR_ID
# =============================================================================
set -euo pipefail

REVIEW="${1:-No review output.}"

API_URL="https://api.bitbucket.org/2.0/repositories/${BITBUCKET_REPO_FULL_NAME}/pullrequests/${BITBUCKET_PR_ID}/comments"

# Wrap in a collapsible markdown block for cleaner PR view
COMMENT_BODY="### 🤖 Claude Code Review

${REVIEW}

---
*Automated review by [Claude Code](https://claude.ai/code) · $(date -u '+%Y-%m-%d %H:%M UTC')*"

# Bitbucket API expects JSON with a content.raw field
PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{content: {raw: $body}}')

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${API_URL}" \
  -u "${BITBUCKET_USERNAME}:${BITBUCKET_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "[post-pr-comment] Posted PR comment (HTTP ${HTTP_STATUS})"
else
  echo "[post-pr-comment] Failed to post PR comment (HTTP ${HTTP_STATUS})" >&2
  exit 1
fi
