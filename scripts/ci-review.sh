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
# Optional repository variables:
#   REVIEW_WEBHOOK_URL      If set, the full review-raw.json is POSTed here
#                           after the review completes. Webhook errors are
#                           logged but never fail the pipeline.
#   DEFAULT_BRANCH          Override auto-detected default branch
#   CLAUDE_MAX_TURNS        Max Claude turns per review (default: 30)
#
# =============================================================================
set -euo pipefail

# ─── Script location (skills are resolved relative to this script) ───────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SCRIPT_DIR}/../skills"
# shellcheck source=scripts/parse-review.sh
source "${SCRIPT_DIR}/parse-review.sh"

# ─── 0. Detect CI platform and source provider ────────────────────────────────
if [ -n "${BITBUCKET_BUILD_NUMBER:-}" ]; then
  CI_PLATFORM="bitbucket"
elif [ -n "${GITLAB_CI:-}" ]; then
  CI_PLATFORM="gitlab"
else
  fail "Unsupported CI platform — could not detect Bitbucket or GitLab environment"
fi
log "CI platform: ${CI_PLATFORM}"
source "${SCRIPT_DIR}/providers/${CI_PLATFORM}.sh"

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
provider_validate_env
provider_detect_context
log "Context: IS_PR=${IS_PR} CI_BRANCH=${CI_BRANCH}"

# Optional: allow manual override of default branch via repository variable.
# If not set, it will be auto-detected from the remote.
MANUAL_DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"

# Optional: if set, the full review-raw.json is POSTed to this URL after the
# review completes. The pipeline never fails due to webhook errors.
REVIEW_WEBHOOK_URL="${REVIEW_WEBHOOK_URL:-}"

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

# ─── 3. Log pipeline context ─────────────────────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Context: Pull Request #${PR_ID} → ${PR_DESTINATION}"
else
  log "Context: Push to branch ${CI_BRANCH}"
fi

# ─── 3b. Skip push pipeline if an open PR exists for this branch ─────────────
# When a developer pushes to a branch that already has an open PR, Bitbucket
# triggers both the branches pipeline and the pull-requests pipeline. The PR
# pipeline posts a richer review (with PR comment), so the push pipeline skips
# itself to avoid duplicate reviews running simultaneously.
# If the API call fails for any reason, we proceed with the review rather than
# silently skipping it.
if [ "$IS_PR" = false ]; then
  log "Checking for open PRs on branch ${CI_BRANCH}..."
  OPEN_PR_COUNT=$(provider_check_open_pr "${CI_BRANCH}" 2>/dev/null || echo "0")
  if [ "${OPEN_PR_COUNT:-0}" -gt 0 ]; then
    log "Open PR found for branch ${CI_BRANCH} — skipping push review (PR pipeline will run)."
    touch review-output.txt review-raw.json review-stderr.txt
    echo "0" > review-exit-code.txt
    exit 0
  fi
fi

# ─── 4. Resolve commit range (merge-base with default branch) ────────────────
log "Resolving commit range..."

# Bitbucket rewrites the remote URL to a plain http:// address, but its
# authentication proxy is only configured for BITBUCKET_GIT_HTTP_ORIGIN
# (https://...).  Reset the remote so subsequent fetches go through the
# authenticated proxy and succeed.
provider_fix_remote_url

HEAD_SHA=$(git rev-parse HEAD)

_merge_base_via_fetch_head() {
  # Try merge-base with current (possibly shallow) history.
  # If it fails, unshallow the feature branch and retry.
  # This handles both short-lived branches (fast path) and long-lived
  # branches with more commits than the initial clone depth (slow path).
  local label="$1"
  if BASE_SHA=$(git merge-base HEAD FETCH_HEAD 2>/dev/null); then
    log "${label}: base is merge-base (via FETCH_HEAD) = ${BASE_SHA:0:8}"
  else
    warn "Merge-base not in shallow history — unshallowing feature branch"
    git fetch --unshallow 2>/dev/null || true
    BASE_SHA=$(git merge-base HEAD FETCH_HEAD 2>/dev/null) \
      || { warn "Merge-base failed after unshallow — falling back to HEAD~1"; \
           BASE_SHA=$(git rev-parse HEAD~1); }
    log "${label}: base after unshallow = ${BASE_SHA:0:8}"
  fi
}

if [ "$IS_PR" = true ]; then
  # PR mode: compare against the destination branch.
  # Fetch full history (no --depth) so the merge-base is always reachable.
  # Use FETCH_HEAD — a depth clone sets a single-branch refspec so fetching
  # another branch does not create origin/<branch>.
  DEST_BRANCH="${PR_DESTINATION:-main}"
  git fetch origin "${DEST_BRANCH}" 2>/dev/null || true
  _merge_base_via_fetch_head "PR vs ${DEST_BRANCH}"

else
  # Push mode: find the default branch, then choose the right base strategy.
  # This is reliable and platform-agnostic — no dependency on
  # BITBUCKET_PREVIOUS_COMMIT, which Bitbucket does not always set.

  if [ -n "${MANUAL_DEFAULT_BRANCH}" ]; then
    DEFAULT_BRANCH="${MANUAL_DEFAULT_BRANCH}"
    log "Using manually configured default branch: ${DEFAULT_BRANCH}"
  else
    # Auto-detect from remote
    DEFAULT_BRANCH=$(git remote show origin 2>/dev/null \
      | grep 'HEAD branch' | awk '{print $NF}')

    if [ -z "$DEFAULT_BRANCH" ]; then
      warn "Could not auto-detect default branch — trying main, then master"
      DEFAULT_BRANCH="main"
    else
      log "Auto-detected default branch: ${DEFAULT_BRANCH}"
    fi
  fi

  if [ "${CI_BRANCH}" = "$DEFAULT_BRANCH" ]; then
    # Pushing directly to the default branch (e.g. a merge commit landing on
    # master). merge-base(HEAD, fetch(master)) would equal HEAD itself,
    # producing an empty range. Use HEAD^1 instead: for a merge commit that is
    # the previous tip of master; for a direct commit it is the prior commit.
    BASE_SHA=$(git rev-parse HEAD^1 2>/dev/null) \
      || { warn "HEAD^1 not available — falling back to HEAD"; BASE_SHA=$(git rev-parse HEAD); }
    log "Push to default branch: base = HEAD^1 = ${BASE_SHA:0:8}"
  else
    # Feature branch push: use merge-base with the default branch so the range
    # covers exactly the commits on this branch and nothing from master.
    # Fetch full history (no --depth) so the merge-base is always reachable.
    # Use FETCH_HEAD — a depth clone sets a single-branch refspec so fetching
    # another branch does not create origin/<branch>.
    git fetch origin "${DEFAULT_BRANCH}" 2>/dev/null || \
      git fetch origin master 2>/dev/null || true

    if git rev-parse FETCH_HEAD &>/dev/null; then
      _merge_base_via_fetch_head "Push vs ${DEFAULT_BRANCH}"
    else
      BASE_SHA=$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)
      warn "Could not fetch default branch — falling back to HEAD~1"
    fi
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
REPO_NAME="${CI_REPO_SLUG}"

log "Author: ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"

# ─── 8. Run Claude Code review ───────────────────────────────────────────────
log "Starting Claude Code review..."

PROMPT="You are running as an automated CI code reviewer. There is no human present.
Do not ask any questions. Complete the full review and output only the structured
review in the format specified by the skill.

CONTEXT:
- Repository: ${CI_REPO_FULL_NAME:-unknown}
- Branch: ${CI_BRANCH:-unknown}
- Platform: ${PLATFORM}
- Commit range: BASE_SHA=${BASE_SHA} HEAD_SHA=${HEAD_SHA}
- Primary author name: ${AUTHOR_NAME}
- Primary author email: ${AUTHOR_EMAIL}
- Latest commit: ${COMMIT_MSG}
- Commit range context: this range may include commits by other developers
  that form the base of this branch. Apply the multi-author review rules
  defined in the skill instructions below.

$(if [ "$IS_PR" = true ]; then
  echo "- This is Pull Request #${PR_ID}: ${PR_DESTINATION} ← ${CI_BRANCH}"
  echo "- PR Title: ${PR_TITLE:-}"
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

# Optional: allow the number of Claude turns to be tuned via a repository
# variable. Higher values give more thorough reviews on large diffs but
# consume more pipeline minutes and API spend.
MAX_TURNS="${CLAUDE_MAX_TURNS:-30}"
log "Max turns: ${MAX_TURNS}"

# Runner script executed as the non-root reviewer user.
# git requires safe.directory when the repo is owned by a different user.
# $1 = api key env file, $2 = build dir, $3 = prompt file, $4 = max turns
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
  --max-turns "$4" \
  --output-format json
RUNNER_EOF
chmod 755 "$RUNNER"
chown reviewer "$RUNNER"

su -s /bin/bash reviewer -c "$RUNNER $APIKEY_FILE $BUILD_DIR $PROMPT_FILE $MAX_TURNS" \
  > review-raw.json 2>review-stderr.txt || true

rm -f "$RUNNER" "$PROMPT_FILE" "$APIKEY_FILE"

# ─── Extract review text and log usage stats ─────────────────────────────────
_log_claude_debug() {
  # Print stderr and the non-result fields from the raw JSON to the CI log.
  # Both review-stderr.txt and review-raw.json are also saved as artifacts.
  warn "=== review-stderr.txt ==="
  cat review-stderr.txt >&2 || true
  if [ -s review-raw.json ]; then
    warn "=== review-raw.json (excluding .result) ==="
    jq 'del(.result)' review-raw.json >&2 || cat review-raw.json >&2 || true
  fi
}

REVIEW_EXIT=0
FAIL_REASON=""
if [ ! -s review-raw.json ]; then
  warn "Claude produced no output"
  _log_claude_debug
  echo "❌ Code review failed to produce output. Check CI logs." > review-output.txt
  REVIEW_EXIT=1
  FAIL_REASON="Claude produced no output"
else
  REVIEW_TEXT=$(jq -r '.result // ""' review-raw.json)

  INPUT_TOKENS=$(jq -r '.usage.input_tokens          // 0' review-raw.json)
  OUTPUT_TOKENS=$(jq -r '.usage.output_tokens         // 0' review-raw.json)
  CACHE_READ=$(jq -r  '.usage.cache_read_input_tokens // 0' review-raw.json)
  CACHE_WRITE=$(jq -r '.usage.cache_creation_input_tokens // 0' review-raw.json)
  COST=$(jq -r        '.total_cost_usd                // 0' review-raw.json)

  log "Token usage — input: ${INPUT_TOKENS} | cache_read: ${CACHE_READ} | cache_write: ${CACHE_WRITE} | output: ${OUTPUT_TOKENS}"
  log "Estimated cost: \$$(printf '%.4f' "${COST}")"

  if [ -z "$REVIEW_TEXT" ]; then
    warn "Claude returned JSON but .result is empty (turn limit reached or API error)"
    _log_claude_debug
    echo "❌ Code review failed to produce output. Check CI logs." > review-output.txt
    REVIEW_EXIT=1
    FAIL_REASON="Claude returned no review content"
  else
    echo "$REVIEW_TEXT" > review-output.txt
  fi
fi

REVIEW=$(cat review-output.txt)
log "Review complete. $(wc -l < review-output.txt) lines of output."
echo "─────────────────────────────────────────────────────────"
echo "${REVIEW}"
echo "─────────────────────────────────────────────────────────"

# ─── 9. Detect Critical issues and set exit code ─────────────────────────────
if has_critical_findings "$REVIEW"; then
  warn "Critical issues found — pipeline will fail after notifications are sent"
  REVIEW_EXIT=1
  FAIL_REASON="Review found Critical issues"
fi
echo "$REVIEW_EXIT" > review-exit-code.txt

# ─── 10. Post PR comment (if PR context) ─────────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Posting review as PR comment..."
  provider_post_pr_comment "${REVIEW}" || warn "Failed to post PR comment"
fi

# ─── 11. Post to Slack ────────────────────────────────────────────────────────
log "Sending Slack notification..."
COMPARE_URL=""
if [ "$IS_PR" = false ]; then
  COMPARE_URL="$(provider_compare_url "${BASE_SHA:0:8}" "${HEAD_SHA:0:8}")"
fi
bash "${SCRIPT_DIR}/post-slack.sh" \
  "${REVIEW}" \
  "${IS_PR}" \
  "${AUTHOR_NAME}" \
  "${AUTHOR_EMAIL}" \
  "${REPO_NAME}" \
  "${CI_BRANCH}" \
  "${HEAD_SHA:0:8}" \
  "${REVIEW_EXIT}" \
  "${BASE_SHA:0:8}..${HEAD_SHA:0:8}" \
  "${CHANGED_FILES}" \
  "${PLATFORM}" \
  "${PR_URL:-}" \
  "${PIPELINE_URL:-}" \
  "${COMPARE_URL}" \
  "${PR_ID:-}" || warn "Failed to send Slack message"

# ─── 12. Post raw JSON to webhook (optional) ─────────────────────────────────
if [ -n "${REVIEW_WEBHOOK_URL}" ]; then
  log "Posting raw review JSON to webhook..."
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    -X POST "${REVIEW_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    --data-binary @review-raw.json || echo "000")
  if [ "${HTTP_STATUS}" -ge 200 ] && [ "${HTTP_STATUS}" -lt 300 ]; then
    log "Webhook POST succeeded (HTTP ${HTTP_STATUS})"
  else
    warn "Webhook POST failed (HTTP ${HTTP_STATUS}) — continuing"
  fi
fi

# ─── 13. Exit with correct code ──────────────────────────────────────────────
if [ "$REVIEW_EXIT" -eq 1 ]; then
  fail "${FAIL_REASON:-Claude failed to produce a review} — failing the build."
fi

log "Review completed successfully."
