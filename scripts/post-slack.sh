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
#     "<exit code: 0|1>" \
#     "<commit range, e.g. abc1234..def5678>" \
#     "<files changed count>" \
#     "<platform: android|ios|generic>" \
#     "<pr_url (if PR, else empty)>" \
#     "<pipeline_url (or empty)>" \
#     "<compare_url (if push, else empty)>" \
#     "<pr_id (if PR, else empty)>"
#
# Required env vars:
#   SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
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
COMMIT_RANGE="${9:-}"
FILES_CHANGED="${10:-}"
PLATFORM="${11:-generic}"
PR_URL="${12:-}"
PIPELINE_URL_ARG="${13:-}"
COMPARE_URL="${14:-}"
PR_ID="${15:-}"

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
  CONTEXT_LINE="PR #${PR_ID} — <${PR_URL}|View Pull Request>"
  EVENT_TYPE="Pull Request"
else
  if [ -n "$COMPARE_URL" ]; then
    CONTEXT_LINE="Branch \`${BRANCH}\` — <${COMPARE_URL}|${COMMIT_RANGE}>"
  else
    CONTEXT_LINE="Branch \`${BRANCH}\` — ${SHORT_SHA}"
  fi
  EVENT_TYPE="Push"
fi

# ─── Resolve author mention ───────────────────────────────────────────────────
# Try to look up the author's Slack user ID by email. Falls back to @here if
# the email is not found or if the users:read.email scope is not granted.
# The script never fails due to a lookup error.
MENTION="<!here>"
if [ -n "${AUTHOR_EMAIL:-}" ]; then
  LOOKUP=$(curl -s \
    "https://slack.com/api/users.lookupByEmail?email=${AUTHOR_EMAIL}" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" || true)
  SLACK_USER_ID=$(echo "$LOOKUP" | jq -r 'if .ok then .user.id else "" end' 2>/dev/null || true)
  if [ -n "$SLACK_USER_ID" ]; then
    MENTION="<@${SLACK_USER_ID}>"
    echo "[post-slack] Resolved ${AUTHOR_EMAIL} → ${SLACK_USER_ID}"
  else
    echo "[post-slack] Could not resolve ${AUTHOR_EMAIL} to a Slack user — using @here"
  fi
fi

# ─── Build pipeline link ─────────────────────────────────────────────────────
PIPELINE_LINK=""
if [ -n "${PIPELINE_URL_ARG}" ]; then
  PIPELINE_LINK="<${PIPELINE_URL_ARG}|View Pipeline>"
fi

# ─── Build main message payload ───────────────────────────────────────────────
# The top-level `text` carries the mention (triggers the notification) and is
# visible above the card. It does not repeat the status — that lives in the
# Status field with its coloured circle.
# Fields: Event, Author, Status (with emoji), Context, Commits, Files Changed,
# Platform (only for android/ios, omitted for generic), Pipeline (if available).
MAIN_PAYLOAD=$(jq -n \
  --arg channel "$SLACK_CHANNEL_ID" \
  --arg status_emoji "$STATUS_EMOJI" \
  --arg status_text "$STATUS_TEXT" \
  --arg repo "$REPO_NAME" \
  --arg event_type "$EVENT_TYPE" \
  --arg context_line "$CONTEXT_LINE" \
  --arg author "$AUTHOR_NAME" \
  --arg colour "$COLOUR" \
  --arg mention "$MENTION" \
  --arg commit_range "$COMMIT_RANGE" \
  --arg files_changed "$FILES_CHANGED" \
  --arg platform "$PLATFORM" \
  --arg pipeline_link "$PIPELINE_LINK" \
  '{
    channel: $channel,
    text: ("Code Review · " + $repo + "\n" + $mention),
    attachments: [{
      color: $colour,
      blocks: [
        {
          type: "section",
          fields: (
            [
              { type: "mrkdwn", text: ("*Event:*\n" + $event_type) },
              { type: "mrkdwn", text: ("*Author:*\n" + $author) },
              { type: "mrkdwn", text: ("*Status:*\n" + $status_emoji + " " + $status_text) },
              { type: "mrkdwn", text: ("*Context:*\n" + $context_line) }
            ]
            + (if $commit_range != "" then [{ type: "mrkdwn", text: ("*Commits:*\n" + $commit_range) }] else [] end)
            + (if $files_changed != "" then [{ type: "mrkdwn", text: ("*Files changed:*\n" + $files_changed) }] else [] end)
            + (if $platform != "" and $platform != "generic" then [{ type: "mrkdwn", text: ("*Platform:*\n" + $platform) }] else [] end)
            + (if $pipeline_link != "" then [{ type: "mrkdwn", text: ("*Pipeline:*\n" + $pipeline_link) }] else [] end)
          )
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

# ─── Convert Markdown to Slack mrkdwn ────────────────────────────────────────
# Slack does not render GitHub-flavoured Markdown. Convert the subset the
# review uses: ## / ### headings → *bold*, **bold** → *bold*, strip --- lines.
REVIEW_SLACK=$(printf '%s' "$REVIEW" \
  | sed -e 's/^## \(.*\)$/*\1*/' \
        -e 's/^### \(.*\)$/*\1*/' \
        -e 's/\*\*\([^*]*\)\*\*/*\1*/g' \
        -e '/^---$/d')

# ─── Post full review as thread reply ────────────────────────────────────────
# Slack places no meaningful character limit on the `text` field of a plain
# message — long text gets a "Show more" expander. No truncation needed.
THREAD_PAYLOAD=$(jq -n \
  --arg channel "$SLACK_CHANNEL_ID" \
  --arg thread_ts "$THREAD_TS" \
  --arg review "$REVIEW_SLACK" \
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
