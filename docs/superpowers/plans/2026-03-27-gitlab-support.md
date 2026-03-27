# GitLab Pipeline Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the tool from Bitbucket-only to a provider pattern supporting both Bitbucket and GitLab, with zero changes required to existing Bitbucket configurations.

**Architecture:** Platform-specific logic lives in `scripts/providers/{bitbucket,gitlab}.sh`. `ci-review.sh` auto-detects the platform from env vars, sources the matching provider, then executes a generic orchestration flow using only normalised variables and provider hook functions. `post-slack.sh` becomes fully platform-agnostic by receiving URLs as arguments instead of constructing them from `BITBUCKET_*` vars.

**Tech Stack:** Bash, `curl`, `jq`, GitLab REST API v4, Bitbucket REST API v2

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Create | `scripts/providers/bitbucket.sh` | All Bitbucket-specific logic extracted from existing scripts |
| Create | `scripts/providers/gitlab.sh` | New GitLab provider |
| Modify | `scripts/ci-review.sh` | Platform detection, source provider, use normalised vars |
| Modify | `scripts/post-slack.sh` | Accept PR/pipeline/compare URLs as args; remove `BITBUCKET_*` references |
| Delete | `scripts/post-pr-comment.sh` | Dissolved — logic moved into each provider |
| Create | `tests/test-bitbucket-provider.sh` | Unit tests for `bitbucket.sh` |
| Create | `tests/test-gitlab-provider.sh` | Unit tests for `gitlab.sh` |
| Create | `tests/fixtures/bitbucket-pr.json` | Fake Bitbucket open-PR API response for tests |
| Create | `tests/fixtures/gitlab-mr.json` | Fake GitLab open-MR API response for tests |
| Modify | `README.md` | Add GitLab setup section |

---

## Task 1: Create feature branch

- [ ] **Step 1: Create and switch to feature branch**

```bash
git checkout -b feature/gitlab-support
```

- [ ] **Step 2: Verify you are on the new branch**

```bash
git branch --show-current
```
Expected output: `feature/gitlab-support`

---

## Task 2: Bitbucket provider (TDD)

**Files:**
- Create: `tests/fixtures/bitbucket-pr.json`
- Create: `tests/test-bitbucket-provider.sh`
- Create: `scripts/providers/bitbucket.sh`

- [ ] **Step 1: Create test fixtures directory and Bitbucket fixture**

```bash
mkdir -p tests/fixtures
```

Create `tests/fixtures/bitbucket-pr.json`:

```json
{
  "pagelen": 10,
  "values": [
    {
      "id": 42,
      "source": {
        "branch": {
          "name": "feature/my-branch"
        }
      },
      "state": "OPEN",
      "title": "My PR"
    }
  ],
  "size": 1
}
```

- [ ] **Step 2: Write the failing test file**

Create `tests/test-bitbucket-provider.sh`:

```bash
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
check "PR_URL contains /42"        true   echo "$PR_URL" | grep -q "/42"
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
check "URL contains base SHA"      true   echo "$URL" | grep -q "abc1234"
check "URL contains head SHA"      true   echo "$URL" | grep -q "def5678"
check "URL is bitbucket.org"       true   echo "$URL" | grep -q "bitbucket.org"

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

CAPTURED_URL=""
CAPTURED_PAYLOAD=""
curl() {
  local prev=""
  for arg in "$@"; do
    if [ "$prev" = "-d" ]; then CAPTURED_PAYLOAD="$arg"; fi
    case "$arg" in https://*) CAPTURED_URL="$arg" ;; esac
    prev="$arg"
  done
  echo "201"
}
provider_post_pr_comment "Test review content"
check "URL targets pullrequests/42/comments"  true   echo "$CAPTURED_URL" | grep -q "pullrequests/42/comments"
check "payload contains review text"          true   echo "$CAPTURED_PAYLOAD" | grep -q "Test review"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run the test — verify it fails**

```bash
bash tests/test-bitbucket-provider.sh
```
Expected: error like `scripts/providers/bitbucket.sh: No such file or directory`

- [ ] **Step 4: Create the providers directory and implement `bitbucket.sh`**

```bash
mkdir -p scripts/providers
```

Create `scripts/providers/bitbucket.sh`:

```bash
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
```

- [ ] **Step 5: Run the test — verify it passes**

```bash
bash tests/test-bitbucket-provider.sh
```
Expected: all tests `PASS`, final line `N passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add scripts/providers/bitbucket.sh tests/test-bitbucket-provider.sh tests/fixtures/bitbucket-pr.json
git commit -m "feat: add bitbucket provider and unit tests"
```

---

## Task 3: GitLab provider (TDD)

**Files:**
- Create: `tests/fixtures/gitlab-mr.json`
- Create: `tests/test-gitlab-provider.sh`
- Create: `scripts/providers/gitlab.sh`

- [ ] **Step 1: Create GitLab fixture**

Create `tests/fixtures/gitlab-mr.json`:

```json
[
  {
    "id": 101,
    "iid": 7,
    "source_branch": "feature/my-branch",
    "state": "opened",
    "title": "My MR"
  }
]
```

- [ ] **Step 2: Write the failing test file**

Create `tests/test-gitlab-provider.sh`:

```bash
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
check "PR_URL contains /7"           true   echo "$PR_URL" | grep -q "merge_requests/7"
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
check "URL contains base SHA"        true   echo "$URL" | grep -q "abc1234"
check "URL contains head SHA"        true   echo "$URL" | grep -q "def5678"
check "URL uses GitLab compare"      true   echo "$URL" | grep -q "/-/compare/"

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

CAPTURED_URL=""
CAPTURED_PAYLOAD=""
curl() {
  local prev=""
  for arg in "$@"; do
    if [ "$prev" = "-d" ]; then CAPTURED_PAYLOAD="$arg"; fi
    case "$arg" in https://*) CAPTURED_URL="$arg" ;; esac
    prev="$arg"
  done
  echo "201"
}
provider_post_pr_comment "Test review content"
check "URL targets merge_requests/7/notes"  true   echo "$CAPTURED_URL" | grep -q "merge_requests/7/notes"
check "payload contains review text"        true   echo "$CAPTURED_PAYLOAD" | grep -q "Test review"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run the test — verify it fails**

```bash
bash tests/test-gitlab-provider.sh
```
Expected: error like `scripts/providers/gitlab.sh: No such file or directory`

- [ ] **Step 4: Implement `gitlab.sh`**

Create `scripts/providers/gitlab.sh`:

```bash
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

  curl -s \
    "${api_url}?state=opened&source_branch=${branch}" \
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
```

- [ ] **Step 5: Run the test — verify it passes**

```bash
bash tests/test-gitlab-provider.sh
```
Expected: all tests `PASS`, final line `N passed, 0 failed`

- [ ] **Step 6: Run existing tests to confirm nothing broken**

```bash
bash tests/test-parsing.sh
```
Expected: all tests `PASS`

- [ ] **Step 7: Commit**

```bash
git add scripts/providers/gitlab.sh tests/test-gitlab-provider.sh tests/fixtures/gitlab-mr.json
git commit -m "feat: add gitlab provider and unit tests"
```

---

## Task 4: Refactor `ci-review.sh`

**Files:**
- Modify: `scripts/ci-review.sh`

The existing script has 13 numbered sections. Changes are surgical: add platform detection before section 1, update sections 1–4 and 7–8 to use normalised vars, update sections 10–11 to call provider functions.

- [ ] **Step 1: Add platform detection block after the `source parse-review.sh` line**

Find this line (around line 29):
```bash
source "${SCRIPT_DIR}/parse-review.sh"
```

Add immediately after it:
```bash

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
```

- [ ] **Step 2: Replace section 1 (validate env) — remove Bitbucket-specific vars, add provider hooks**

Find and replace this block:
```bash
# ─── 1. Validate required environment ────────────────────────────────────────
log "Checking required environment variables..."
: "${ANTHROPIC_API_KEY:?Required variable ANTHROPIC_API_KEY is not set}"
: "${SLACK_BOT_TOKEN:?Required variable SLACK_BOT_TOKEN is not set}"
: "${SLACK_CHANNEL_ID:?Required variable SLACK_CHANNEL_ID is not set}"
: "${BITBUCKET_TOKEN:?Required variable BITBUCKET_TOKEN is not set}"
: "${BITBUCKET_USERNAME:?Required variable BITBUCKET_USERNAME is not set}"
```

With:
```bash
# ─── 1. Validate required environment ────────────────────────────────────────
log "Checking required environment variables..."
: "${ANTHROPIC_API_KEY:?Required variable ANTHROPIC_API_KEY is not set}"
: "${SLACK_BOT_TOKEN:?Required variable SLACK_BOT_TOKEN is not set}"
: "${SLACK_CHANNEL_ID:?Required variable SLACK_CHANNEL_ID is not set}"
provider_validate_env
provider_detect_context
log "Context: IS_PR=${IS_PR} CI_BRANCH=${CI_BRANCH}"
```

- [ ] **Step 3: Replace section 3 (detect pipeline context) with a logging-only block**

Find and replace:
```bash
# ─── 3. Detect pipeline context ──────────────────────────────────────────────
IS_PR=false
if [ -n "${BITBUCKET_PR_ID:-}" ]; then
  IS_PR=true
  log "Context: Pull Request #${BITBUCKET_PR_ID} → ${BITBUCKET_PR_DESTINATION_BRANCH}"
else
  log "Context: Push to branch ${BITBUCKET_BRANCH}"
fi
```

With:
```bash
# ─── 3. Log pipeline context ─────────────────────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Context: Pull Request #${PR_ID} → ${PR_DESTINATION}"
else
  log "Context: Push to branch ${CI_BRANCH}"
fi
```

- [ ] **Step 4: Replace section 3b (check open PRs) — use provider function**

Find and replace:
```bash
if [ "$IS_PR" = false ]; then
  log "Checking for open PRs on branch ${BITBUCKET_BRANCH}..."
  OPEN_PR_COUNT=$(curl -s \
    "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_REPO_FULL_NAME}/pullrequests?state=OPEN&pagelen=50" \
    -u "${BITBUCKET_USERNAME}:${BITBUCKET_TOKEN}" \
    | jq --arg branch "${BITBUCKET_BRANCH}" \
         '[.values[] | select(.source.branch.name == $branch)] | length' \
    2>/dev/null || echo "0")
  if [ "${OPEN_PR_COUNT:-0}" -gt 0 ]; then
    log "Open PR found for branch ${BITBUCKET_BRANCH} — skipping push review (PR pipeline will run)."
    touch review-output.txt review-raw.json review-stderr.txt
    echo "0" > review-exit-code.txt
    exit 0
  fi
fi
```

With:
```bash
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
```

- [ ] **Step 5: Replace section 4 — remove BITBUCKET_GIT_HTTP_ORIGIN block, use normalised vars**

Find and replace the remote URL fix block:
```bash
if [ -n "${BITBUCKET_GIT_HTTP_ORIGIN:-}" ]; then
  git remote set-url origin "$BITBUCKET_GIT_HTTP_ORIGIN" 2>/dev/null || true
  log "Remote URL set to BITBUCKET_GIT_HTTP_ORIGIN for authenticated fetches"
fi
```

With:
```bash
provider_fix_remote_url
```

Then find and replace:
```bash
DEST_BRANCH="${BITBUCKET_PR_DESTINATION_BRANCH:-main}"
```

With:
```bash
DEST_BRANCH="${PR_DESTINATION:-main}"
```

Then find and replace:
```bash
if [ "${BITBUCKET_BRANCH:-}" = "$DEFAULT_BRANCH" ]; then
```

With:
```bash
if [ "${CI_BRANCH}" = "$DEFAULT_BRANCH" ]; then
```

- [ ] **Step 6: Replace section 7 — use normalised REPO_NAME**

Find and replace:
```bash
REPO_NAME=$(basename "${BITBUCKET_REPO_FULL_NAME:-unknown-repo}")
```

With:
```bash
REPO_NAME="${CI_REPO_SLUG}"
```

- [ ] **Step 7: Replace section 8 — update PROMPT to use normalised vars**

Find and replace in the PROMPT variable:
```bash
- Repository: ${BITBUCKET_REPO_FULL_NAME:-unknown}
- Branch: ${BITBUCKET_BRANCH:-unknown}
```

With:
```bash
- Repository: ${CI_REPO_FULL_NAME:-unknown}
- Branch: ${CI_BRANCH:-unknown}
```

Find and replace the PR context block inside the PROMPT:
```bash
$(if [ "$IS_PR" = true ]; then
  echo "- This is Pull Request #${BITBUCKET_PR_ID}: ${BITBUCKET_PR_DESTINATION_BRANCH} ← ${BITBUCKET_BRANCH}"
  echo "- PR Title: ${BITBUCKET_PR_TITLE:-}"
fi)
```

With:
```bash
$(if [ "$IS_PR" = true ]; then
  echo "- This is Pull Request #${PR_ID}: ${PR_DESTINATION} ← ${CI_BRANCH}"
  echo "- PR Title: ${PR_TITLE:-}"
fi)
```

- [ ] **Step 8: Replace section 10 — use provider function for PR comment**

Find and replace:
```bash
# ─── 10. Post to Bitbucket PR (if PR context) ────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Posting review as PR comment..."
  bash "${SCRIPT_DIR}/post-pr-comment.sh" "${REVIEW}" || warn "Failed to post PR comment"
fi
```

With:
```bash
# ─── 10. Post PR comment (if PR context) ─────────────────────────────────────
if [ "$IS_PR" = true ]; then
  log "Posting review as PR comment..."
  provider_post_pr_comment "${REVIEW}" || warn "Failed to post PR comment"
fi
```

- [ ] **Step 9: Replace section 11 — build compare URL, pass normalised args to post-slack.sh**

Find and replace:
```bash
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
  "${REVIEW_EXIT}" \
  "${BASE_SHA:0:8}..${HEAD_SHA:0:8}" \
  "${CHANGED_FILES}" \
  "${PLATFORM}" || warn "Failed to send Slack message"
```

With:
```bash
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
```

- [ ] **Step 10: Verify no BITBUCKET_* references remain outside providers**

```bash
grep -n "BITBUCKET_" scripts/ci-review.sh
```
Expected: no output (zero matches)

- [ ] **Step 11: Run existing tests**

```bash
bash tests/test-parsing.sh
```
Expected: all tests `PASS`

- [ ] **Step 12: Commit**

```bash
git add scripts/ci-review.sh
git commit -m "refactor: update ci-review.sh to use provider pattern"
```

---

## Task 5: Refactor `post-slack.sh`

**Files:**
- Modify: `scripts/post-slack.sh`

The script currently constructs Bitbucket-specific PR/compare/pipeline URLs internally. We add 4 new positional args (12–15) and use them instead.

- [ ] **Step 1: Add new positional args to the header and argument block**

Find the arg declarations at the top of `post-slack.sh` (after the usage comment):
```bash
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
```

Replace with:
```bash
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
```

Also update the usage comment at the top of the file from:
```bash
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
#     "<platform: android|ios|generic>"
#
# Required env vars:
#   SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
#   BITBUCKET_REPO_FULL_NAME, BITBUCKET_PR_ID (if PR)
#   BITBUCKET_WORKSPACE, BITBUCKET_REPO_SLUG
```

To:
```bash
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
#     "<pr_url (if PR)>" \
#     "<pipeline_url>" \
#     "<compare_url (if push)>" \
#     "<pr_id (if PR)>"
#
# Required env vars:
#   SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
```

- [ ] **Step 2: Replace the context line construction block**

Find and replace:
```bash
# ─── Build context line ───────────────────────────────────────────────────────
if [ "$IS_PR" = true ]; then
  PR_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pull-requests/${BITBUCKET_PR_ID}"
  CONTEXT_LINE="PR #${BITBUCKET_PR_ID} — <${PR_URL}|View Pull Request>"
  EVENT_TYPE="Pull Request"
else
  # For a range of commits, link to Bitbucket's compare view so all changes
  # are visible at once. The %0D separator is Bitbucket's compare URL format.
  # Fall back to a single-commit link if no range is available.
  if [ -n "$COMMIT_RANGE" ]; then
    BASE_SHA_SHORT="${COMMIT_RANGE%..*}"
    HEAD_SHA_SHORT="${COMMIT_RANGE#*..}"
    COMPARE_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/branches/compare/${HEAD_SHA_SHORT}%0D${BASE_SHA_SHORT}#diff"
    CONTEXT_LINE="Branch \`${BRANCH}\` — <${COMPARE_URL}|${COMMIT_RANGE}>"
  else
    COMMIT_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/commits/${SHORT_SHA}"
    CONTEXT_LINE="Branch \`${BRANCH}\` — <${COMMIT_URL}|View Commit ${SHORT_SHA}>"
  fi
  EVENT_TYPE="Push"
fi
```

With:
```bash
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
```

- [ ] **Step 3: Replace the pipeline link construction block**

Find and replace:
```bash
# ─── Build pipeline link ─────────────────────────────────────────────────────
PIPELINE_LINK=""
if [ -n "${BITBUCKET_BUILD_NUMBER:-}" ] && [ -n "${BITBUCKET_REPO_FULL_NAME:-}" ]; then
  PIPELINE_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pipelines/results/${BITBUCKET_BUILD_NUMBER}"
  PIPELINE_LINK="<${PIPELINE_URL}|Build #${BITBUCKET_BUILD_NUMBER}>"
fi
```

With:
```bash
# ─── Build pipeline link ─────────────────────────────────────────────────────
PIPELINE_LINK=""
if [ -n "${PIPELINE_URL_ARG}" ]; then
  PIPELINE_LINK="<${PIPELINE_URL_ARG}|View Pipeline>"
fi
```

- [ ] **Step 4: Verify no BITBUCKET_* references remain in post-slack.sh**

```bash
grep -n "BITBUCKET_" scripts/post-slack.sh
```
Expected: no output (zero matches)

- [ ] **Step 5: Run all tests**

```bash
bash tests/test-parsing.sh && bash tests/test-bitbucket-provider.sh && bash tests/test-gitlab-provider.sh
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add scripts/post-slack.sh
git commit -m "refactor: make post-slack.sh platform-agnostic"
```

---

## Task 6: Delete `post-pr-comment.sh`

**Files:**
- Delete: `scripts/post-pr-comment.sh`

- [ ] **Step 1: Delete the file**

```bash
git rm scripts/post-pr-comment.sh
```

- [ ] **Step 2: Verify no remaining references to it**

```bash
grep -rn "post-pr-comment" scripts/ tests/
```
Expected: no output

- [ ] **Step 3: Run all tests**

```bash
bash tests/test-parsing.sh && bash tests/test-bitbucket-provider.sh && bash tests/test-gitlab-provider.sh
```
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: remove post-pr-comment.sh (dissolved into providers)"
```

---

## Task 7: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the intro paragraph to mention GitLab**

Find:
```
Shared AI code review tooling for Bitbucket Pipelines, powered by
[Claude Code](https://claude.ai/code). Drops into any repository with two lines in
`bitbucket-pipelines.yml`. Posts reviews to Slack on every push and as PR comments
on pull requests. Fails the build on Critical findings.
```

Replace with:
```
Shared AI code review tooling for Bitbucket Pipelines and GitLab CI, powered by
[Claude Code](https://claude.ai/code). Drops into any repository with a few lines of
pipeline config. Posts reviews to Slack on every push and as PR/MR comments
on pull requests. Fails the build on Critical findings.
```

- [ ] **Step 2: Update the Repository Structure section to include providers**

Find the structure block:
```
ai-code-review/
├── skills/
│   ├── ci-code-review.md           # Generic review skill
│   └── ci-code-review-mobile.md    # Android + iOS review skill
└── scripts/
    ├── ci-review.sh                # Main orchestration script
    ├── post-pr-comment.sh          # Posts review to Bitbucket PR
    └── post-slack.sh               # Posts review to Slack channel
```

Replace with:
```
ai-code-review/
├── skills/
│   ├── ci-code-review.md           # Generic review skill
│   └── ci-code-review-mobile.md    # Android + iOS review skill
└── scripts/
    ├── ci-review.sh                # Main orchestration script (auto-detects platform)
    ├── post-slack.sh               # Posts review to Slack channel
    └── providers/
        ├── bitbucket.sh            # Bitbucket Pipelines integration
        └── gitlab.sh               # GitLab CI integration
```

- [ ] **Step 3: Add GitLab setup section after the Bitbucket setup sections**

After the `## Tuning` section, add:

```markdown
---

## Using with GitLab CI

### 1. Add the pipeline job

In your `.gitlab-ci.yml`:

```yaml
code-review:
  image: node:20-slim
  script:
    - apt-get update -qq && apt-get install -y -qq git curl jq
    # Pin to a release tag once you start tagging (--branch v1.0.0)
    - git clone --depth=1 https://github.com/AppstersBP/ai-code-review.git .ai-code-review
    - bash .ai-code-review/scripts/ci-review.sh
  artifacts:
    paths:
      - review-output.txt
      - review-exit-code.txt
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH
```

The `rules` block means the job runs on both MR pipelines (which post an MR comment) and
plain branch pushes (which post to Slack only). The deduplication logic skips the push
pipeline automatically when an MR pipeline is already running for the same branch.

### 2. Create a Slack App

Same as for Bitbucket — follow [steps 2 from above](#2-create-a-slack-app).

### 3. Set CI/CD Variables

GitLab project → **Settings** → **CI/CD** → **Variables**:

| Variable | Value | Masked | Required |
|----------|-------|--------|---------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key | ✅ Yes | Yes |
| `SLACK_BOT_TOKEN` | `xoxb-...` from Slack setup | ✅ Yes | Yes |
| `SLACK_CHANNEL_ID` | Channel ID from Slack setup | No | Yes |
| `GITLAB_TOKEN` | Personal/project access token | ✅ Yes | No — `CI_JOB_TOKEN` is used by default and is sufficient for all required operations |
| `GITLAB_API_URL` | e.g. `https://gitlab.example.com/api/v4` | No | No — only for self-hosted GitLab |
| `DEFAULT_BRANCH` | e.g. `develop` | No | No |
| `CLAUDE_MAX_TURNS` | e.g. `30` | No | No |

> **`CI_JOB_TOKEN` is injected automatically** by GitLab CI into every job. It has
> sufficient permissions to list open MRs and post MR comments on the same project.
> You only need `GITLAB_TOKEN` if your self-hosted instance has restricted job token
> API access policies.
```

- [ ] **Step 4: Run all tests one final time**

```bash
bash tests/test-parsing.sh && bash tests/test-bitbucket-provider.sh && bash tests/test-gitlab-provider.sh
```
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add GitLab CI setup documentation"
```

---

## Self-Review Checklist

- [x] **Provider pattern** (spec §Architecture) — `bitbucket.sh` and `gitlab.sh` in `scripts/providers/`, all platform-specific logic isolated there ✓
- [x] **Backward compatibility** (spec §Backward Compatibility) — `bitbucket.sh` reads same `BITBUCKET_*` vars, zero changes to existing Bitbucket pipeline configs ✓
- [x] **Platform detection** (spec §Platform Detection) — `BITBUCKET_BUILD_NUMBER` → bitbucket, `GITLAB_CI` → gitlab, fail otherwise ✓
- [x] **Provider contract** (spec §Provider Contract) — all 6 functions + 10 normalised vars implemented in both providers ✓
- [x] **Deduplication** (spec §Deduplication) — `provider_check_open_pr` in both providers ✓
- [x] **GitLab auth** (spec §GitLab provider) — defaults to `CI_JOB_TOKEN`, overridable with `GITLAB_TOKEN` ✓
- [x] **`GITLAB_API_URL`** (spec §GitLab provider) — implemented in `_gitlab_api_url()` ✓
- [x] **`post-pr-comment.sh` dissolved** (spec §Architecture) — deleted in Task 6 ✓
- [x] **`post-slack.sh` platform-agnostic** (spec §Slack Notification) — receives URLs as args, no `BITBUCKET_*` refs ✓
- [x] **Unit tests** (spec §Testability) — `provider_detect_context`, `provider_compare_url`, `provider_check_open_pr`, `provider_post_pr_comment` tested in both provider test files ✓
- [x] **Test fixtures** — `bitbucket-pr.json` and `gitlab-mr.json` created ✓
- [x] **README updated** (spec §GitLab Usage) — `.gitlab-ci.yml` snippet and variable table ✓
