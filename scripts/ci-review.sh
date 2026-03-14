#!/usr/bin/env bash
# =============================================================================
# ci-review.sh — Claude Code Review for Bitbucket Pipelines
#
# Required repository variables (set in Bitbucket → Repository settings →
# Repository variables):
#
#   ANTHROPIC_API_KEY       Your Anthropic API key (mark as secured)
#   SLACK_BOT_TOKEN         Slack bot OAuth token (xoxb-...) (mark as secured)
#   SLACK_CHANNEL_ID        ID of the private Slack channel (e.g. C01234ABCDE)
#   BITBUCKET_TOKEN         Bitbucket API token (starts with ATAT) with scope
#                           write:pullrequest:bitbucket (mark as secured)
#   BITBUCKET_USERNAME      Atlassian account email address for API auth
#
# =============================================================================
set -euo pipefail

# ─── Script location (skills are resolved relative to this script) ───────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SCRIPT_DIR}/../skills"

# ─── Colour helpers (only when running locally with a TTY) ───────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; NC=''
fi

log()  { echo "[ci-review] $*"; }
warn() { echo -e "${YELLOW}[ci-review] WARNING: $*${NC}"; }
fail() { echo -e "${RED}[ci-review] ERROR: $*${NC}" >&2; exit 1; }

# ─── 1. Validate required environment ────────────────────────────────────────
log "Checking required environment variables..."
: "${ANTHROPIC_API_KEY:?Required variable ANTHROPIC_API_KEY is not set}"
: "${SLACK_BOT_TOKEN:?Required variable SLACK_BOT_TOKEN is not set}"
: "${SLACK_CHANNEL_ID:?Required variable SLACK_CHANNEL_ID is not set}"
: "${BITBUCKET_TOKEN:?Required variable BITBUCKET_TOKEN is not set}"
: "${BITBUCKET_USERNAME:?Required variable BITBUCKET_USERNAME is not set}"

# ─── 2. Install dependencies ──────────────────────────────────────────────────
log "Installing dependencies..."
apt-get update -qq && apt-get install -y -qq curl jq

# Install Claude Code CLI
curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
claude --version || fail "Claude Code installation failed"

# --dangerously-skip-permissions is blocked when running as root.
# Create a non-root user and make claude available to it.
useradd -m -s /bin/bash reviewer 2>/dev/null || true
cp "$HOME/.local/bin/claude" /usr/local/bin/claude
log "Non-root reviewer user ready."

# ─── 3. Detect pipeline context ──────────────────────────────────────────────
IS_PR=false
if [ -n "${BITBUCKET_PR_ID:-}" ]; then
  IS_PR=true
  log "Context: Pull Request #${BITBUCKET_PR_ID} → ${BITBUCKET_PR_DESTINATION_BRANCH}"
else
  log "Context: Push to branch ${BITBUCKET_BRANCH}"
fi

# ─── 4. Resolve commit range ─────────────────────────────────────────────────
log "Resolving commit range..."

if [ "$IS_PR" = true ]; then
  git fetch origin "${BITBUCKET_PR_DESTINATION_BRANCH}" --depth=50 2>/dev/null || true
  BASE_SHA=$(git merge-base HEAD "origin/${BITBUCKET_PR_DESTINATION_BRANCH}" 2>/dev/null \
    || git rev-parse HEAD~1)
  HEAD_SHA=$(git rev-parse HEAD)
else
  HEAD_SHA=$(git rev-parse HEAD)
  if [ -n "${BITBUCKET_PREVIOUS_COMMIT:-}" ] && \
     git cat-file -e "${BITBUCKET_PREVIOUS_COMMIT}^{commit}" 2>/dev/null; then
    BASE_SHA="${BITBUCKET_PREVIOUS_COMMIT}"
  else
    git fetch origin main --depth=50 2>/dev/null || \
      git fetch origin master --depth=50 2>/dev/null || true
    BASE_SHA=$(git merge-base HEAD origin/main 2>/dev/null \
      || git merge-base HEAD origin/master 2>/dev/null \
      || git rev-parse HEAD~1)
  fi
fi

if [ "$BASE_SHA" = "$HEAD_SHA" ]; then
  log "No changes detected between $BASE_SHA and $HEAD_SHA. Skipping review."
  echo "✅ Nothing to review — no changes detected." > review-output.txt
  echo "0" > review-exit-code.txt
  exit 0
fi

CHANGED_FILES=$(git diff --name-only "${BASE_SHA}..${HEAD_SHA}" | wc -l | tr -d ' ')
COMMIT_COUNT=$(git log --oneline "${BASE_SHA}..${HEAD_SHA}" | wc -l | tr -d ' ')
log "Reviewing ${COMMIT_COUNT} commit(s) touching ${CHANGED_FILES} file(s)"
log "Range: ${BASE_SHA:0:8}..${HEAD_SHA:0:8}"

# ─── 5. Detect platform (Android / iOS / generic) ────────────────────────────
PLATFORM="generic"
if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "settings.gradle" ] || \
   [ -f "settings.gradle.kts" ]; then
  PLATFORM="android"
elif [ -f "Podfile" ] || [ -f "*.xcworkspace" ] || ls ./*.xcodeproj 2>/dev/null | head -1; then
  PLATFORM="ios"
fi
log "Detected platform: ${PLATFORM}"

# ─── 6. Select skill file ─────────────────────────────────────────────────────
SKILL_FILE="${SKILL_DIR}/ci-code-review.md"
if [ "$PLATFORM" = "android" ] || [ "$PLATFORM" = "ios" ]; then
  MOBILE_SKILL="${SKILL_DIR}/ci-code-review-mobile.md"
  if [ -f "$MOBILE_SKILL" ]; then
    SKILL_FILE="$MOBILE_SKILL"
    log "Using mobile skill: $MOBILE_SKILL"
  else
    warn "Mobile skill not found at $MOBILE_SKILL, falling back to generic"
  fi
fi

[ -f "$SKILL_FILE" ] || fail "Skill file not found: $SKILL_FILE"
SKILL=$(cat "$SKILL_FILE")

# ─── 6b. Apply project-local skill extension if present ──────────────────────
SKILL_BASENAME="$(basename "${SKILL_FILE}" .md)"
EXT_FILE=".claude/skills/${SKILL_BASENAME}.ext.md"
if [ -f "$EXT_FILE" ]; then
  log "Applying local skill extension: $EXT_FILE"
  SKILL="${SKILL}

---

## Project-Specific Extensions

$(cat "$EXT_FILE")"
fi

# ─── 7. Get commit author info for Slack ─────────────────────────────────────
AUTHOR_NAME=$(git log -1 --format="%an" "${HEAD_SHA}")
AUTHOR_EMAIL=$(git log -1 --format="%ae" "${HEAD_SHA}")
COMMIT_MSG=$(git log -1 --format="%s" "${HEAD_SHA}")
REPO_NAME=$(basename "${BITBUCKET_REPO_FULL_NAME:-unknown-repo}")

log "Author: ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"

# ─── 8. Run Claude Code review ───────────────────────────────────────────────
log "Starting Claude Code review..."

PROMPT="You are running as an automated CI code reviewer. There is no human present.
Do not ask any questions. Complete the full review and output only the structured
review in the format specified by the skill.

CONTEXT:
- Repository: ${BITBUCKET_REPO_FULL_NAME:-unknown}
- Branch: ${BITBUCKET_BRANCH:-unknown}
- Platform: ${PLATFORM}
- Commit range: BASE_SHA=${BASE_SHA} HEAD_SHA=${HEAD_SHA}
- Author: ${AUTHOR_NAME}
- Latest commit: ${COMMIT_MSG}

$(if [ "$IS_PR" = true ]; then
  echo "- This is Pull Request #${BITBUCKET_PR_ID}: ${BITBUCKET_PR_DESTINATION_BRANCH} ← ${BITBUCKET_BRANCH}"
  echo "- PR Title: ${BITBUCKET_PR_TITLE:-}"
fi)

---
SKILL INSTRUCTIONS (follow exactly):

${SKILL}"

# Write prompt and API key to temp files for the non-root runner
PROMPT_FILE=$(mktemp /tmp/prompt.XXXXXX)
printf '%s' "$PROMPT" > "$PROMPT_FILE"

APIKEY_FILE=$(mktemp /tmp/.apikey.XXXXXX)
printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$APIKEY_FILE"
chmod 600 "$APIKEY_FILE"
chown reviewer "$APIKEY_FILE" "$PROMPT_FILE"

# Runner script executed as the non-root reviewer user.
# git requires safe.directory when the repo is owned by a different user.
BUILD_DIR="$(pwd)"
RUNNER=$(mktemp /tmp/runner.XXXXXX.sh)
cat > "$RUNNER" << 'RUNNER_EOF'
#!/bin/bash
set -a; source "$1"; set +a
export HOME=/home/reviewer
git config --global --add safe.directory "$2" 2>/dev/null || true
claude -p "$(cat "$3")" \
  --allowedTools 'Bash(git *)' 'Read' 'Grep' 'Glob' \
  --dangerously-skip-permissions \
  --max-turns 30 \
  --output-format json
RUNNER_EOF
chmod 755 "$RUNNER"
chown reviewer "$RUNNER"

su -s /bin/bash reviewer -c "$RUNNER $APIKEY_FILE $BUILD_DIR $PROMPT_FILE" \
  > review-raw.json 2>review-stderr.txt || true

rm -f "$RUNNER" "$PROMPT_FILE" "$APIKEY_FILE"

# ─── Extract review text and log usage stats ─────────────────────────────────
REVIEW_EXIT=0
FAIL_REASON=""
if [ ! -s review-raw.json ]; then
  warn "Claude produced no output — check review-stderr.txt"
  cat review-stderr.txt >&2 || true
  echo "❌ Code review failed to produce output. Check CI logs." > review-output.txt
  REVIEW_EXIT=1
else
  jq -r '.result // "❌ Code review failed to produce output. Check CI logs."' \
    review-raw.json > review-output.txt

  INPUT_TOKENS=$(jq -r '.usage.input_tokens          // 0' review-raw.json)
  OUTPUT_TOKENS=$(jq -r '.usage.output_tokens         // 0' review-raw.json)
  CACHE_READ=$(jq -r  '.usage.cache_read_input_tokens // 0' review-raw.json)
  CACHE_WRITE=$(jq -r '.usage.cache_creation_input_tokens // 0' review-raw.json)
  COST=$(jq -r        '.total_cost_usd                // 0' review-raw.json)

  log "Token usage — input: ${INPUT_TOKENS} | cache_read: ${CACHE_READ} | cache_write: ${CACHE_WRITE} | output: ${OUTPUT_TOKENS}"
  log "Estimated cost: \$$(printf '%.4f' "${COST}")"
fi

REVIEW=$(cat review-output.txt)
log "Review complete. $(wc -l < review-output.txt) lines of output."

# ─── 9. Detect Critical issues and set exit code ─────────────────────────────
if echo "$REVIEW" | grep -q "### 🔴 Critical"; then
  CRITICAL_SECTION=$(echo "$REVIEW" | \
    awk '/### 🔴 Critical/,/### 🟡/' | grep -v "^###" | grep -v "^---" | grep -v "^$" || true)
  if echo "$CRITICAL_SECTION" | grep -qv "None\."; then
    warn "Critical issues found — pipeline will fail after notifications are sent"
    REVIEW_EXIT=1
    FAIL_REASON="Review found Critical issues"
  fi
fi
echo "$REVIEW_EXIT" > review-exit-code.txt

# ─── 10. Post to Bitbucket PR (if PR context) ────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Posting review as PR comment..."
  bash "${SCRIPT_DIR}/post-pr-comment.sh" "${REVIEW}" || warn "Failed to post PR comment"
fi

# ─── 11. Post to Slack ────────────────────────────────────────────────────────
log "Sending Slack notification..."
bash "${SCRIPT_DIR}/post-slack.sh" \
  "${REVIEW}" \
  "${IS_PR}" \
  "${AUTHOR_NAME}" \
  "${AUTHOR_EMAIL}" \
  "${REPO_NAME}" \
  "${BITBUCKET_BRANCH:-unknown}" \
  "${HEAD_SHA:0:8}" \
  "${REVIEW_EXIT}" || warn "Failed to send Slack message"

# ─── 12. Exit with correct code ──────────────────────────────────────────────
if [ "$REVIEW_EXIT" -eq 1 ]; then
  fail "${FAIL_REASON:-Claude failed to produce a review} — failing the build."
fi

log "Review completed successfully."
