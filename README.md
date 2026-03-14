# ai-code-review

Shared AI code review tooling for Bitbucket Pipelines, powered by
[Claude Code](https://claude.ai/code). Drops into any repository with two lines in
`bitbucket-pipelines.yml`. Posts reviews to Slack on every push and as PR comments
on pull requests. Fails the build on Critical findings.

---

## How It Works

```
Push or PR event
       │
       ▼
bitbucket-pipelines.yml
  git clone AppstersBP/ai-code-review
  bash .ai-code-review/scripts/ci-review.sh
       │
       ├─ Resolves commit range (PREVIOUS_COMMIT..HEAD or merge-base..HEAD)
       ├─ Detects platform (Android / iOS / generic)
       ├─ Selects skill file from skills/
       ├─ Appends .claude/skills/*.ext.md if present in the project repo
       ├─ Runs Claude Code headlessly against the diff
       ├─ Posts result to Slack (always)
       ├─ Posts result as PR comment (PR events only)
       └─ Exits 1 if Critical issues found, 0 otherwise
```

| Event | Commit range reviewed | PR comment | Slack |
|-------|-----------------------|------------|-------|
| Push to any branch | `PREVIOUS_COMMIT..HEAD` | No | Yes |
| Pull Request opened / updated | `merge-base(HEAD, destination)..HEAD` | Yes | Yes |

---

## Repository Structure

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

---

## Adding to a Repository

### 1. Add the pipeline step

In your `bitbucket-pipelines.yml`:

```yaml
image: node:20-slim   # or whatever base image you use

definitions:
  steps:
    - step: &code-review
        name: "Claude Code Review"
        script:
          # Pin to a release tag once you start tagging (--branch v1.0.0)
          - apt-get update -qq && apt-get install -y -qq git
          - git clone --depth=1 https://github.com/AppstersBP/ai-code-review.git .ai-code-review
          - bash .ai-code-review/scripts/ci-review.sh
        artifacts:
          - review-output.txt
          - review-exit-code.txt

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

### 2. Create a Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → From scratch
2. Name it `Claude Code Reviewer`, pick your workspace
3. Go to **OAuth & Permissions** → **Bot Token Scopes**, add:
   - `chat:write`
   - `chat:write.public` (only needed for public channels)
4. Click **Install to Workspace**
5. Copy the **Bot User OAuth Token** (`xoxb-...`)
6. Invite the bot to your channel: `/invite @Claude Code Reviewer`
7. Copy the **Channel ID** from the channel's details (starts with `C`)

### 3. Create a Bitbucket API Token

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

### 4. Set Repository Variables

In Bitbucket: **Repository settings** → **Repository variables**

| Variable | Value | Secured |
|----------|-------|---------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key | ✅ Yes |
| `SLACK_BOT_TOKEN` | `xoxb-...` from step 2 | ✅ Yes |
| `SLACK_CHANNEL_ID` | Channel ID from step 2 | No |
| `BITBUCKET_TOKEN` | API token from step 3 (starts with `ATAT`) | ✅ Yes |
| `BITBUCKET_USERNAME` | Your Atlassian **account email address** | No |

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

Slack and PR comment notifications are always sent **before** the exit, so developers
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
PR comment:

```
## 🔍 Code Review — {short SHA}

**Commits reviewed:** {base}..{head}
**Files changed:** {N}
**Platform:** android | ios | generic

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

By default the pipeline clones `main`. Once you start tagging releases, pin to a tag for
reproducible, auditable runs across all projects:

```yaml
- git clone --depth=1 --branch v1.2.0 https://github.com/AppstersBP/ai-code-review.git .ai-code-review
```

This means you consciously opt in to updates by bumping the tag, rather than having a
change in this repo silently affect every project's CI.

---

## Tuning

| Goal | What to change |
|------|----------------|
| More thorough review on large diffs | Increase `--max-turns` (default 30) in `ci-review.sh` |
| Cap per-review spend | Add `--max-budget-usd 2.00` to the `claude` invocation in `ci-review.sh` |
| Force a specific skill regardless of platform | Set `SKILL_FILE` manually before the skill-selection block in `ci-review.sh` |
| Add project-specific rules | Create `.claude/skills/<skill-name>.ext.md` in the project repo |
| Change the output format | Edit the skill file's Step 4 section |

---

## Troubleshooting

**"Claude Code installation failed"**
The `curl -fsSL https://claude.ai/install.sh | bash` step failed. Check network access
from the Bitbucket runner. To avoid installing Claude on every run, pre-bake it into a
custom Docker image and set it as the pipeline `image`.

**"Skill file not found"**
The clone succeeded but the skill path is wrong — usually caused by cloning into a
different directory than `.ai-code-review`. Check the `git clone` target and the
`bash ... /ci-review.sh` path in your pipeline step.

**PR comment not appearing**
Verify `BITBUCKET_USERNAME` and `BITBUCKET_TOKEN` are correct and the App Password has
`Pull requests: Write` scope.

**Slack message fails with `channel_not_found`**
The bot has not been invited to the channel. Run `/invite @Claude Code Reviewer` in Slack.

**Review seems shallow**
Increase `--max-turns` in `ci-review.sh`. Complex codebases with many cross-module
dependencies may need 40–50 turns for thorough context exploration.

**Extension file not being applied**
Confirm the file is named exactly `<skill-name>.ext.md` (e.g. `ci-code-review-mobile.ext.md`)
and lives at `.claude/skills/` in the project repo root.
