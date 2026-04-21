# Claude Effort and Model Parameters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two optional repository variables — `CLAUDE_EFFORT` and `CLAUDE_MODEL` — that pass through to the `claude` CLI invocation in `scripts/ci-review.sh`, with documentation in `README.md`.

**Architecture:** Both variables are read near the existing `CLAUDE_MAX_TURNS` block, stored in local variables, conditionally forwarded to the runner script as positional args `$5`/`$6`, and appended as `--effort`/`--model` flags only when non-empty. No validation — Claude CLI rejects bad values. README receives new rows in all three relevant tables.

**Tech Stack:** bash

---

### Task 1: Update `scripts/ci-review.sh`

**Files:**
- Modify: `scripts/ci-review.sh:19` (header comment)
- Modify: `scripts/ci-review.sh:293-298` (variable reading and runner comment)
- Modify: `scripts/ci-review.sh:301-316` (runner heredoc + su invocation)

No automated tests exist for `ci-review.sh` — the existing test suite only covers `parse-review.sh` and the provider scripts. Run that suite after the change to confirm nothing regressed.

- [ ] **Step 1: Add the two new variables to the header comment block**

In `scripts/ci-review.sh`, the optional-variables section currently ends at line 19:
```
#   CLAUDE_MAX_TURNS        Max Claude turns per review (default: 30)
```

Replace that line with:
```bash
#   CLAUDE_MAX_TURNS        Max Claude turns per review (default: 30)
#   CLAUDE_EFFORT           Effort level passed to Claude Code: low|medium|high|xhigh|max
#                           (default: Claude CLI default)
#   CLAUDE_MODEL            Model alias (haiku|sonnet|opus) or full model ID
#                           (e.g. claude-opus-4-7, claude-sonnet-4-6,
#                           claude-haiku-4-5-20251001)
#                           (default: Claude CLI default)
```

- [ ] **Step 2: Read the new variables near the MAX_TURNS block**

The current block at lines 290–294 reads:
```bash
# Optional: allow the number of Claude turns to be tuned via a repository
# variable. Higher values give more thorough reviews on large diffs but
# consume more pipeline minutes and API spend.
MAX_TURNS="${CLAUDE_MAX_TURNS:-30}"
log "Max turns: ${MAX_TURNS}"
```

Replace it with:
```bash
# Optional: allow the number of Claude turns to be tuned via a repository
# variable. Higher values give more thorough reviews on large diffs but
# consume more pipeline minutes and API spend.
MAX_TURNS="${CLAUDE_MAX_TURNS:-30}"
log "Max turns: ${MAX_TURNS}"

# Optional: effort level and model override for the Claude invocation.
# When unset the flag is omitted entirely and Claude uses its own default.
EFFORT="${CLAUDE_EFFORT:-}"
MODEL="${CLAUDE_MODEL:-}"
[ -n "$EFFORT" ] && log "Effort: ${EFFORT}"
[ -n "$MODEL" ]  && log "Model: ${MODEL}"
```

- [ ] **Step 3: Update the runner heredoc comment and body**

The current comment + runner block at lines 296–311 reads:
```bash
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
```

Replace it with:
```bash
# Runner script executed as the non-root reviewer user.
# git requires safe.directory when the repo is owned by a different user.
# $1 = api key env file, $2 = build dir, $3 = prompt file, $4 = max turns
# $5 = effort (optional, empty string if unset), $6 = model (optional, empty string if unset)
BUILD_DIR="$(pwd)"
RUNNER=$(mktemp /tmp/runner.XXXXXX.sh)
cat > "$RUNNER" << 'RUNNER_EOF'
#!/bin/bash
set -a; source "$1"; set +a
export HOME=/home/reviewer
git config --global --add safe.directory "$2" 2>/dev/null || true
EFFORT_ARGS=(); [ -n "$5" ] && EFFORT_ARGS=(--effort "$5")
MODEL_ARGS=();  [ -n "$6" ] && MODEL_ARGS=(--model  "$6")
claude -p "$(cat "$3")" \
  --allowedTools 'Bash(git *)' 'Read' 'Grep' 'Glob' \
  --dangerously-skip-permissions \
  --max-turns "$4" \
  "${EFFORT_ARGS[@]}" \
  "${MODEL_ARGS[@]}" \
  --output-format json
RUNNER_EOF
```

- [ ] **Step 4: Pass the new args in the `su` invocation**

The current `su` call at line 315 reads:
```bash
su -s /bin/bash reviewer -c "$RUNNER $APIKEY_FILE $BUILD_DIR $PROMPT_FILE $MAX_TURNS" \
  > review-raw.json 2>review-stderr.txt || true
```

Replace it with:
```bash
su -s /bin/bash reviewer -c "$RUNNER $APIKEY_FILE $BUILD_DIR $PROMPT_FILE $MAX_TURNS \"$EFFORT\" \"$MODEL\"" \
  > review-raw.json 2>review-stderr.txt || true
```

The values are double-quoted in the command string so an empty value is passed as `""` — the `[ -n ... ]` guard inside the runner then skips the flag.

- [ ] **Step 5: Run the existing test suite**

```bash
bash tests/test-parsing.sh && bash tests/test-bitbucket-provider.sh && bash tests/test-gitlab-provider.sh
```

Expected: all tests pass with no failures reported.

- [ ] **Step 6: Commit**

```bash
git add scripts/ci-review.sh
git commit -m "feat: add CLAUDE_EFFORT and CLAUDE_MODEL optional repository variables"
```

---

### Task 2: Update `README.md`

**Files:**
- Modify: `README.md:151` (Bitbucket variables table)
- Modify: `README.md:204` (GitLab variables table)
- Modify: `README.md:373` (Tuning table)

- [ ] **Step 1: Add rows to the Bitbucket variables table**

The Bitbucket table currently ends at line 151:
```
| `CLAUDE_MAX_TURNS` | Maximum Claude turns per review (default `30`). Increase for large diffs; decrease to cap spend. | No | No |
```

Append two rows after it:
```markdown
| `CLAUDE_EFFORT` | Effort level for the review: `low`, `medium`, `high`, `xhigh`, or `max` (default: Claude CLI default) | No | No |
| `CLAUDE_MODEL` | Model to use: alias (`haiku`, `sonnet`, `opus`) or full ID (e.g. `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) (default: Claude CLI default) | No | No |
```

- [ ] **Step 2: Add rows to the GitLab variables table**

The GitLab table currently ends at line 204:
```
| `CLAUDE_MAX_TURNS` | e.g. `30` | No | No |
```

Append two rows after it:
```markdown
| `CLAUDE_EFFORT` | e.g. `high` | No | No |
| `CLAUDE_MODEL` | e.g. `claude-opus-4-7` | No | No |
```

- [ ] **Step 3: Add rows to the Tuning table**

The Tuning table currently starts at line 371. The first data row (line 373) reads:
```
| More thorough review on large diffs | Set the `CLAUDE_MAX_TURNS` repository variable (default `30`) |
```

Append two rows after it:
```markdown
| Adjust Claude's thinking budget | Set `CLAUDE_EFFORT` to `low`, `medium`, `high`, `xhigh`, or `max` |
| Pin a specific Claude model | Set `CLAUDE_MODEL` to an alias (`haiku`, `sonnet`, `opus`) or a full model ID (e.g. `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) |
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document CLAUDE_EFFORT and CLAUDE_MODEL in README variable tables and Tuning section"
```
