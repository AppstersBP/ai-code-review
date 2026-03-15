#!/usr/bin/env bash
# =============================================================================
# post-slack.sh — Posts the Claude review to a Slack private channel
#
# Usage:
#   bash scripts/post-slack.sh \
#     "<review text>" \
#     "<is_pr: true|false>" \
#     "<author name>" \
#     "<author email>" \
#     "<repo name>" \
#     "<branch>" \
#     "<short sha>" \
#     "<exit code: 0|1>"
#
# Required env vars:
#   SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
#   BITBUCKET_REPO_FULL_NAME, BITBUCKET_PR_ID (if PR)
#   BITBUCKET_WORKSPACE, BITBUCKET_REPO_SLUG
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/parse-review.sh
source "${SCRIPT_DIR}/parse-review.sh"

REVIEW="${1:-No review output.}"
IS_PR="${2:-false}"
AUTHOR_NAME="${3:-Unknown}"
AUTHOR_EMAIL="${4:-}"
REPO_NAME="${5:-repo}"
BRANCH="${6:-unknown}"
SHORT_SHA="${7:-unknown}"
REVIEW_EXIT="${8:-0}"

# ─── Determine status emoji and colour ───────────────────────────────────────
if [ "$REVIEW_EXIT" -eq 1 ]; then
  STATUS_EMOJI="🔴"
  STATUS_TEXT="Critical issues found — build failed"
  COLOUR="danger"
elif has_important_findings "$REVIEW"; then
    STATUS_EMOJI="🟡"
    STATUS_TEXT="Important issues found"
    COLOUR="warning"
else
  STATUS_EMOJI="✅"
  STATUS_TEXT="Approved"
  COLOUR="good"
fi

# ─── Build context line ───────────────────────────────────────────────────────
if [ "$IS_PR" = true ]; then
  PR_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pull-requests/${BITBUCKET_PR_ID}"
  CONTEXT_LINE="PR #${BITBUCKET_PR_ID} — <${PR_URL}|View Pull Request>"
  EVENT_TYPE="Pull Request"
else
  COMMIT_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/commits/${SHORT_SHA}"
  CONTEXT_LINE="Branch \`${BRANCH}\` — <${COMMIT_URL}|View Commit ${SHORT_SHA}>"
  EVENT_TYPE="Push"
fi

# ─── Build main message payload ───────────────────────────────────────────────
# The top-level `text` is used as the notification/preview text only.
# The attachment holds the coloured summary card (no header block — avoids
# duplicating the title that already appears in the notification text).
MAIN_PAYLOAD=$(jq -n \
  --arg channel "$SLACK_CHANNEL_ID" \
  --arg status_emoji "$STATUS_EMOJI" \
  --arg status_text "$STATUS_TEXT" \
  --arg repo "$REPO_NAME" \
  --arg event_type "$EVENT_TYPE" \
  --arg context_line "$CONTEXT_LINE" \
  --arg author "$AUTHOR_NAME" \
  --arg colour "$COLOUR" \
  '{
    channel: $channel,
    text: ($status_emoji + " Code Review · " + $repo + " — " + $status_text),
    attachments: [{
      color: $colour,
      blocks: [
        {
          type: "section",
          fields: [
            { type: "mrkdwn", text: ("*Event:*\n" + $event_type) },
            { type: "mrkdwn", text: ("*Author:*\n" + $author) },
            { type: "mrkdwn", text: ("*Status:*\n" + $status_text) },
            { type: "mrkdwn", text: ("*Context:*\n" + $context_line) }
          ]
        }
      ]
    }]
  }')

# ─── Post main message ────────────────────────────────────────────────────────
RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${MAIN_PAYLOAD}")

OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null || echo "false")
if [ "$OK" != "true" ]; then
  ERROR=$(echo "$RESPONSE" | jq -r '.error' 2>/dev/null || echo "unknown")
  echo "[post-slack] Failed to send Slack message: ${ERROR}" >&2
  echo "[post-slack] Full response: ${RESPONSE}" >&2
  exit 1
fi

THREAD_TS=$(echo "$RESPONSE" | jq -r '.ts')
echo "[post-slack] Main message sent to channel ${SLACK_CHANNEL_ID} (ts: ${THREAD_TS})"

# ─── Post full review as thread reply ────────────────────────────────────────
# Slack places no meaningful character limit on the `text` field of a plain
# message — long text gets a "Show more" expander. No truncation needed.
THREAD_PAYLOAD=$(jq -n \
  --arg channel "$SLACK_CHANNEL_ID" \
  --arg thread_ts "$THREAD_TS" \
  --arg review "$REVIEW" \
  '{
    channel: $channel,
    thread_ts: $thread_ts,
    text: $review
  }')

THREAD_RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${THREAD_PAYLOAD}")

OK=$(echo "$THREAD_RESPONSE" | jq -r '.ok' 2>/dev/null || echo "false")
if [ "$OK" = "true" ]; then
  echo "[post-slack] Review posted to thread"
else
  ERROR=$(echo "$THREAD_RESPONSE" | jq -r '.error' 2>/dev/null || echo "unknown")
  echo "[post-slack] Failed to post review thread: ${ERROR}" >&2
  echo "[post-slack] Full response: ${THREAD_RESPONSE}" >&2
  exit 1
fi
