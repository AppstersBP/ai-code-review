# GitLab Pipeline Support — Design Spec

**Date:** 2026-03-27
**Status:** Approved

---

## Goal

Make the tool usable from GitLab CI pipelines (and in future GitHub Actions) without breaking any existing Bitbucket Pipelines functionality. The entry point remains a single `bash scripts/ci-review.sh` — the platform is auto-detected from CI environment variables.

---

## Architecture

### Provider pattern

All platform-specific logic is extracted into provider files under `scripts/providers/`. `ci-review.sh` detects the platform, sources the matching provider, and then executes a fully generic orchestration flow using only normalised variables and provider functions.

```
scripts/
├── ci-review.sh                  # Generic orchestrator — unchanged entry point
├── parse-review.sh               # Unchanged
├── post-slack.sh                 # Receives normalised args; compare/PR URLs injected by provider
└── providers/
    ├── bitbucket.sh              # Existing Bitbucket logic, extracted
    └── gitlab.sh                 # New GitLab provider
tests/
├── test-parsing.sh               # Existing, unchanged
├── test-bitbucket-provider.sh    # New unit tests for bitbucket.sh
├── test-gitlab-provider.sh       # New unit tests for gitlab.sh
└── fixtures/
    ├── bitbucket-pr.json         # Fake Bitbucket open-PR API response
    └── gitlab-mr.json            # Fake GitLab open-MR API response
```

`post-pr-comment.sh` is dissolved — its logic moves into each provider's `post_pr_comment` function since the API call is entirely platform-specific.

---

## Platform Detection

At the top of `ci-review.sh`, before validation:

```bash
if [ -n "${BITBUCKET_BUILD_NUMBER:-}" ]; then
  CI_PLATFORM="bitbucket"
elif [ -n "${GITLAB_CI:-}" ]; then
  CI_PLATFORM="gitlab"
else
  fail "Unsupported CI platform — could not detect Bitbucket or GitLab environment"
fi

source "${SCRIPT_DIR}/providers/${CI_PLATFORM}.sh"
provider_validate_env      # provider validates its own required vars
provider_detect_context    # provider sets normalised variables (see below)
```

---

## Provider Contract

Each provider must implement the following functions and set the following variables after `provider_detect_context` is called.

### Normalised variables

| Variable | Description |
|---|---|
| `CI_BRANCH` | Current branch name |
| `CI_REPO_SLUG` | Short repo name (for Slack display) |
| `CI_REPO_FULL_NAME` | Full repo identifier (for API calls) |
| `CI_BUILD_NUMBER` | Pipeline/job ID (for Slack pipeline link) |
| `IS_PR` | `true` or `false` |
| `PR_ID` | MR/PR number (if `IS_PR=true`) |
| `PR_DESTINATION` | Target branch (if `IS_PR=true`) |
| `PR_TITLE` | MR/PR title (if `IS_PR=true`) |
| `PR_URL` | Full URL to the MR/PR (if `IS_PR=true`, for Slack) |
| `PIPELINE_URL` | Full URL to the running pipeline (for Slack) |

### Functions

```bash
provider_validate_env       # Fail fast if provider-specific required vars are missing
provider_detect_context     # Set all normalised variables above
provider_fix_remote_url     # Fix git remote if needed (Bitbucket rewrites it; GitLab no-op)
provider_check_open_pr      # Echo count of open PRs/MRs for current branch via platform API
provider_post_pr_comment    # Post review text as MR/PR comment via platform API
provider_compare_url        # Echo a compare/diff URL; called as: provider_compare_url "$BASE_SHA" "$HEAD_SHA"
```

`ci-review.sh` calls these hooks in order and never references any `BITBUCKET_*` or `GITLAB_*` variables directly after the provider is sourced.

---

## Environment Variables

### Generic (validated in `ci-review.sh`)

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key (mark as secured) |
| `SLACK_BOT_TOKEN` | Yes | Slack bot OAuth token (`xoxb-...`) |
| `SLACK_CHANNEL_ID` | Yes | Slack channel ID |
| `DEFAULT_BRANCH` | No | Override auto-detected default branch |
| `CLAUDE_MAX_TURNS` | No | Max Claude turns per review (default: 30) |
| `REVIEW_WEBHOOK_URL` | No | POST raw review JSON here after each review |

### Bitbucket provider (validated in `providers/bitbucket.sh`)

| Variable | Required | Description |
|---|---|---|
| `BITBUCKET_TOKEN` | Yes | API token (`ATAT...`), scope: `write:pullrequest:bitbucket` |
| `BITBUCKET_USERNAME` | Yes | Atlassian account email address |

All other `BITBUCKET_*` variables are injected automatically by Bitbucket Pipelines — no changes to existing setup.

### GitLab provider (validated in `providers/gitlab.sh`)

| Variable | Required | Description |
|---|---|---|
| `GITLAB_TOKEN` | No | Personal/project access token. Defaults to `CI_JOB_TOKEN`, which is automatically injected by GitLab CI and sufficient for all required API operations (listing open MRs and posting MR comments on the same project). Only needed for self-hosted instances with restricted job token policies. |
| `GITLAB_API_URL` | No | Override GitLab API base URL. Defaults to `https://gitlab.com/api/v4`. Use for self-hosted instances. |

---

## Backward Compatibility

Existing Bitbucket Pipelines configurations require **zero changes**. The `bitbucket.sh` provider reads the same `BITBUCKET_*` env vars as before. The `post-pr-comment.sh` script is removed but nothing external called it directly — it was only invoked by `ci-review.sh`.

---

## GitLab Usage

### `.gitlab-ci.yml`

```yaml
code-review:
  image: node:20-slim
  script:
    - apt-get update -qq && apt-get install -y -qq git curl jq
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

### CI/CD variables to set

GitLab project → Settings → CI/CD → Variables:

| Variable | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Mark as masked |
| `SLACK_BOT_TOKEN` | Yes | Mark as masked |
| `SLACK_CHANNEL_ID` | Yes | |
| `GITLAB_TOKEN` | No | Only needed for self-hosted with restricted job token policy |
| `GITLAB_API_URL` | No | Self-hosted only |
| `DEFAULT_BRANCH` | No | |
| `CLAUDE_MAX_TURNS` | No | Default 30 |

---

## Commit Range Resolution

The merge-base logic in `ci-review.sh` is already largely platform-agnostic (it uses `git` commands). The only platform-specific parts are:

- **Bitbucket**: resets remote URL via `BITBUCKET_GIT_HTTP_ORIGIN` before fetches (`provider_fix_remote_url`)
- **GitLab**: no remote URL rewrite needed; `CI_REPOSITORY_URL` is already the authenticated HTTPS URL injected into the clone

PR destination branch:
- Bitbucket: `BITBUCKET_PR_DESTINATION_BRANCH`
- GitLab: `CI_MERGE_REQUEST_TARGET_BRANCH_NAME`

Both are surfaced via the normalised `PR_DESTINATION` variable.

---

## Deduplication (skip push if open MR exists)

Both providers implement `provider_check_open_pr` to detect when a push pipeline should be skipped because a parallel MR pipeline will run.

- **Bitbucket**: `GET /2.0/repositories/{repo}/pullrequests?state=OPEN`
- **GitLab**: `GET /projects/{id}/merge_requests?state=opened&source_branch={branch}` — authenticated with `CI_JOB_TOKEN` (or `GITLAB_TOKEN` if set)

---

## Testability

### What is unit-tested

- `provider_detect_context` — set fake env vars, assert normalised variables
- `provider_compare_url` — call with two SHAs, assert URL shape
- `provider_check_open_pr` — override `curl` with a shell function returning fixture JSON, assert count
- `provider_post_pr_comment` — override `curl`, assert correct URL and payload
- Platform detection — set/unset `BITBUCKET_BUILD_NUMBER` / `GITLAB_CI`, assert `CI_PLATFORM`

### What is not unit-tested (integration territory)

- Actual git operations and commit range resolution (need a real repo)
- Real API calls to Bitbucket/GitLab/Slack
- Claude invocation and non-root user setup

### curl-override pattern

```bash
curl() {
  echo "$(cat "${SCRIPT_DIR}/fixtures/gitlab-mr.json")"
}
export -f curl
```

Used in provider tests to simulate API responses without live credentials.

---

## Slack Notification

`post-slack.sh` is updated to accept the PR URL and compare URL as arguments (instead of constructing them internally from `BITBUCKET_*` vars). The provider sets `PR_URL` and implements `provider_compare_url`, which `ci-review.sh` calls before invoking `post-slack.sh`. The Slack script itself becomes fully platform-agnostic.

---

## Out of Scope

- GitHub Actions support (deferred — adding it will be a third provider file following the same pattern)
- Changes to review skills or output format
- Changes to Slack notification structure or threading behaviour
