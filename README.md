# ai-code-review

Shared AI code review tooling for Bitbucket Pipelines and GitLab CI, powered by
[Claude Code](https://claude.ai/code). Drops into any repository with a few lines of
pipeline config. Posts reviews to Slack on every push and as PR/MR comments
on pull requests. Fails the build on Critical findings.

---

## Contents

- [How It Works](#how-it-works)
- [Repository Structure](#repository-structure)
- [Setting Up with Bitbucket Pipelines](#setting-up-with-bitbucket-pipelines)
  - [1. Add the pipeline step](#1-add-the-pipeline-step)
  - [2. Create a Bitbucket API Token](#2-create-a-bitbucket-api-token)
  - [3. Set Repository Variables](#3-set-repository-variables)
- [Setting Up with GitLab CI](#setting-up-with-gitlab-ci)
  - [1. Add the pipeline job](#1-add-the-pipeline-job)
  - [2. Set CI/CD Variables](#2-set-cicd-variables)
- [Create a Slack App](#create-a-slack-app)
- [Platform Detection](#platform-detection)
- [Extending Skills for a Specific Project](#extending-skills-for-a-specific-project)
- [Build Failure Behaviour](#build-failure-behaviour)
- [Review Output Format](#review-output-format)
- [Versioning / Pinning](#versioning--pinning)
- [Tuning](#tuning)
- [Troubleshooting](#troubleshooting)

---

## How It Works

```
Push or PR event
       │
       ▼
bitbucket-pipelines.yml / .gitlab-ci.yml
  git clone AppstersBP/ai-code-review
  bash .ai-code-review/scripts/ci-review.sh
       │
       ├─ Resolves commit range (merge-base with default branch..HEAD)
       ├─ Detects platform (Android / iOS / generic)
       ├─ Selects skill file from skills/
       ├─ Appends .claude/skills/*.ext.md if present in the project repo
       ├─ Runs Claude Code headlessly against the diff
       ├─ Posts result to Slack (always)
       ├─ Posts result as PR/MR comment (PR/MR events only)
       └─ Exits 1 if Critical issues found, 0 otherwise
```

| Event | Commit range reviewed | PR/MR comment | Slack |
|-------|-----------------------|---------------|-------|
| Push to any branch | `merge-base(HEAD, default-branch)..HEAD` | No | Yes |
| Pull/Merge Request opened / updated | `merge-base(HEAD, destination)..HEAD` | Yes | Yes |

---

## Repository Structure

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

---

## Setting Up with Bitbucket Pipelines

### 1. Add the pipeline step

In your `bitbucket-pipelines.yml`:

```yaml
image: ghcr.io/appstersbp/ai-code-review:latest

definitions:
  steps:
    - step: &code-review
        name: "Claude Code Review"
        max-time: 15
        script:
          - git clone --depth=1 https://github.com/AppstersBP/ai-code-review.git .ai-code-review
          - bash .ai-code-review/scripts/ci-review.sh
        artifacts:
          - review-output.txt
          - review-exit-code.txt
          - review-raw.json
          - review-stderr.txt

pipelines:
  pull-requests:
    "**":
      - step:
          <<: *code-review
          name: "Claude Code Review (PR)"
  branches:
    "**":
      - step:
          <<: *code-review
          name: "Claude Code Review (Push)"
```

That's all the code you need in the project repo. Everything else comes from this
shared repository.

The pre-built image includes Claude and all dependencies so the pipeline step stays
minimal. To pin to a specific Claude version instead of `latest`, see
[Versioning / Pinning](#versioning--pinning).

> **Installing Claude at runtime instead:** If you prefer not to use the pre-built image,
> replace the `image` with `node:22-slim` and add
> `apt-get update -qq && apt-get install -y -qq git` as the first `script` line.
> `ci-review.sh` will install the remaining dependencies (curl, jq, Claude) on every run.

### 2. Create a Bitbucket API Token

App passwords were deprecated on September 9, 2025 and will stop working on June 9, 2026.
Use an API token instead.

1. Bitbucket → Your avatar → **Account settings** → (Atlassian account page) **Security** tab
2. Click **Create and manage API tokens** → **Create API token with scopes**
3. Label it `Claude CI Reviewer`, set an expiration date, select **Bitbucket**
4. Add scope: `write:pullrequest:bitbucket` (this includes read access)
5. Click **Create token** and copy it immediately — it is shown only once
   The token starts with the prefix `ATAT`

> **Rotation reminder:** API tokens expire. Set a calendar reminder before the expiry
> date to rotate the token and update the `BITBUCKET_TOKEN` repository variable.

### 3. Set Repository Variables

In Bitbucket: **Repository settings** → **Repository variables**

| Variable | Value | Secured | Required |
|----------|-------|---------|---------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key | ✅ Yes | Yes |
| `SLACK_BOT_TOKEN` | `xoxb-...` from the Slack App setup below | ✅ Yes | Yes |
| `SLACK_CHANNEL_ID` | Channel ID from the Slack App setup below | No | Yes |
| `BITBUCKET_TOKEN` | API token from step 2 (starts with `ATAT`) | ✅ Yes | Yes |
| `BITBUCKET_USERNAME` | Your Atlassian **account email address** | No | Yes |
| `DEFAULT_BRANCH` | e.g. `develop` — overrides auto-detection of the default branch | No | No |
| `CLAUDE_MAX_TURNS` | Maximum Claude turns per review (default `30`). Increase for large diffs; decrease to cap spend. | No | No |

---

## Setting Up with GitLab CI

### 1. Add the pipeline job

In your `.gitlab-ci.yml`:

```yaml
code-review:
  image: ghcr.io/appstersbp/ai-code-review:latest
  timeout: 15 minutes
  script:
    - git clone --depth=1 https://github.com/AppstersBP/ai-code-review.git .ai-code-review
    - bash .ai-code-review/scripts/ci-review.sh
  artifacts:
    paths:
      - review-output.txt
      - review-exit-code.txt
      - review-raw.json
      - review-stderr.txt
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH
```

The `rules` block means the job runs on both MR pipelines (which post an MR comment) and
plain branch pushes (which post to Slack only). The deduplication logic skips the push
pipeline automatically when an MR pipeline is already running for the same branch.

The pre-built image includes Claude and all dependencies so no install step is needed.
To pin to a specific Claude version instead of `latest`, see
[Versioning / Pinning](#versioning--pinning).

> **Installing Claude at runtime instead:** If you prefer not to use the pre-built image,
> replace the `image` with `node:22-slim` and add
> `apt-get update -qq && apt-get install -y -qq git` as the first `script` line.
> `ci-review.sh` will install the remaining dependencies (curl, jq, Claude) on every run.

### 2. Set CI/CD Variables

GitLab project → **Settings** → **CI/CD** → **Variables**:

| Variable | Value | Masked | Required |
|----------|-------|--------|---------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key | ✅ Yes | Yes |
| `SLACK_BOT_TOKEN` | `xoxb-...` from the Slack App setup below | ✅ Yes | Yes |
| `SLACK_CHANNEL_ID` | Channel ID from the Slack App setup below | No | Yes |
| `GITLAB_TOKEN` | Personal/project access token | ✅ Yes | No — `CI_JOB_TOKEN` is used by default and is sufficient for all required operations |
| `GITLAB_API_URL` | e.g. `https://gitlab.example.com/api/v4` | No | No — only for self-hosted GitLab |
| `DEFAULT_BRANCH` | e.g. `develop` | No | No |
| `CLAUDE_MAX_TURNS` | e.g. `30` | No | No |

> **`CI_JOB_TOKEN` is injected automatically** by GitLab CI into every job. It has
> sufficient permissions to list open MRs and post MR comments on the same project.
> You only need `GITLAB_TOKEN` if your self-hosted instance has restricted job token
> API access policies.

---

## Create a Slack App

This step is the same regardless of your CI platform.

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → From scratch
2. Name it `Claude Code Reviewer`, pick your workspace
3. Go to **OAuth & Permissions** → **Bot Token Scopes**, add:
   - `chat:write`
   - `chat:write.public` (only needed for public channels)
   - `users:read.email` — allows the bot to look up a Slack user by the commit
     author's email address and mention them directly. Without this scope the
     bot falls back to `@here` instead of a personal mention.
4. Click **Install to Workspace**
5. Copy the **Bot User OAuth Token** (`xoxb-...`)
6. Invite the bot to your channel: `/invite @Claude Code Reviewer`
7. Copy the **Channel ID** from the channel's details (starts with `C`)

---

## Platform Detection

`ci-review.sh` inspects the project root to select the right skill automatically:

| Files present | Platform | Skill used |
|---------------|----------|------------|
| `build.gradle`, `build.gradle.kts`, `settings.gradle`, or `settings.gradle.kts` | `android` | `ci-code-review-mobile.md` |
| `Podfile` or `*.xcodeproj` | `ios` | `ci-code-review-mobile.md` |
| Neither | `generic` | `ci-code-review.md` |

The detected platform is also passed to Claude so it applies the correct platform-specific
checks within the mobile skill.

---

## Extending Skills for a Specific Project

The shared skills cover general best practices. For project-specific rules — architecture
conventions, known footguns, naming standards — add an extension file in the project repo.

### How it works

`ci-review.sh` looks for a file named `<skill-name>.ext.md` in `.claude/skills/` of the
project repo. If found, its contents are appended to the shared skill under a
**Project-Specific Extensions** heading before Claude runs.

### Example

For a project using the mobile skill, create:

```
your-repo/
└── .claude/
    └── skills/
        └── ci-code-review-mobile.ext.md
```

The file is plain Markdown — no frontmatter required:

```markdown
### Acme Android — Project-Specific Patterns

**No direct Retrofit calls in Fragments**
- All network calls must go through a ViewModel. A Retrofit call made directly in a
  Fragment will survive configuration changes and leak the Fragment.

**ResultWrapper is the error type**
- This codebase uses `ResultWrapper<T>` for all repository return types.
  Never throw exceptions across the repository boundary.
```

Extension files work for any skill. To extend the generic skill, create
`.claude/skills/ci-code-review.ext.md`.

---

## Build Failure Behaviour

The pipeline exits with code **1** (failing the build) when the review output contains a
`🔴 Critical` section with at least one finding.

Slack and PR/MR comment notifications are always sent **before** the exit, so developers
are never left wondering why the build is red.

To make reviews informational-only (never fail the build), comment out the last block
in `scripts/ci-review.sh`:

```bash
# if [ "$REVIEW_EXIT" -eq 1 ]; then
#   fail "Review found Critical issues — failing the build."
# fi
```

---

## Review Output Format

Claude outputs a structured Markdown review that is posted verbatim to Slack and as a
PR/MR comment. The `**Platform:**` field is included by the mobile skill only.

```
## 🔍 Code Review — {short SHA}

**Commits reviewed:** {base}..{head}
**Files changed:** {N}
**Platform:** android | ios   ← mobile skill only

### Summary
...

### 🔴 Critical — Must Fix Before Merge
...

### 🟡 Important — Should Fix
...

### 🟢 Suggestions — Nice to Have
...

### ✅ Strengths
...

### Verdict
APPROVED | APPROVED WITH SUGGESTIONS | CHANGES REQUESTED
```

---

## Versioning / Pinning

The pre-built image is tagged with the version of Claude it contains (e.g.
`claude-1.2.3`), published to GitHub Container Registry. The review scripts are always
cloned from `main` — there are no repository version tags.

A new image is built automatically whenever the `Dockerfile` changes, and can also be
triggered manually via the GitHub Actions workflow dispatch to pick up a new Claude
release.

To pin a project to a specific Claude version, replace `latest` with the version tag:

**Bitbucket** — in `bitbucket-pipelines.yml`:
```yaml
image: ghcr.io/appstersbp/ai-code-review:claude-1.2.3
```

**GitLab** — in `.gitlab-ci.yml`:
```yaml
code-review:
  image: ghcr.io/appstersbp/ai-code-review:claude-1.2.3
```

The `git clone` line in the `script` block stays as-is (always clones `main`).
Pinning the image gives you a stable Claude version while still picking up any script
or skill updates merged to `main`.

---

## Tuning

| Goal | What to change |
|------|----------------|
| More thorough review on large diffs | Set the `CLAUDE_MAX_TURNS` repository variable (default `30`) |
| Cap per-review spend | Add `--max-budget-usd 2.00` to the `claude` invocation in `ci-review.sh` |
| Force a specific skill regardless of platform | Set `SKILL_FILE` manually before the skill-selection block in `ci-review.sh` |
| Add project-specific rules | Create `.claude/skills/<skill-name>.ext.md` in the project repo |
| Change the output format | Edit the skill file's Step 4 section — **note constraints below** |

> **Output format constraints:** `ci-review.sh` runs Claude with `--output-format json`
> and extracts the review text from the `.result` field. `parse-review.sh` detects
> critical and important findings by searching for the exact headings
> `### 🔴 Critical` and `### 🟡 Important`. If you rename or remove these headings
> the build-failure logic and Slack severity detection will stop working.
> Cosmetic changes (wording, extra fields, reordering sections below Strengths) are safe.

---

## Troubleshooting

**"Claude Code installation failed"**
The `curl -fsSL https://claude.ai/install.sh | bash` step failed. Check network access
from the CI runner. To avoid installing Claude on every run, use the pre-baked image
(`ghcr.io/appstersbp/ai-code-review:latest`) — see **Versioning / Pinning** above.

**"Skill file not found"**
The clone succeeded but the skill path is wrong — usually caused by cloning into a
different directory than `.ai-code-review`. Check the `git clone` target and the
`bash ... /ci-review.sh` path in your pipeline step.

**PR/MR comment not appearing (Bitbucket)**
Verify `BITBUCKET_USERNAME` and `BITBUCKET_TOKEN` are correct and the API token has
`write:pullrequest:bitbucket` scope.

**MR comment not appearing (GitLab)**
By default `CI_JOB_TOKEN` is used. If your instance has restricted job token API access
policies, set `GITLAB_TOKEN` to a personal or project access token with `api` scope.

**Slack message fails with `channel_not_found`**
The bot has not been invited to the channel. Run `/invite @Claude Code Reviewer` in Slack.

**Slack notification uses `@here` instead of mentioning the author**
The bot needs the `users:read.email` scope to look up a user by commit email. Add the
scope under **OAuth & Permissions → Bot Token Scopes**, reinstall the app, and update
`SLACK_BOT_TOKEN` with the new token. The fallback to `@here` is intentional and safe —
the script never fails if the lookup is unavailable.

**Review seems shallow**
Set the `CLAUDE_MAX_TURNS` repository variable to a higher value (default `30`). Complex
codebases with many cross-module dependencies may need 40–50 turns for thorough context
exploration.

**Extension file not being applied**
Confirm the file is named exactly `<skill-name>.ext.md` (e.g. `ci-code-review-mobile.ext.md`)
and lives at `.claude/skills/` in the project repo root.
