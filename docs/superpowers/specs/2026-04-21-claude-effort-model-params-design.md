# Claude Effort and Model Parameters — Design Spec

**Date:** 2026-04-21
**Status:** Approved

---

## Goal

Expose two optional Claude Code CLI flags — `--effort` and `--model` — as repository variables so pipeline maintainers can tune review thoroughness and pick a model without editing scripts. Defaults are unchanged: if neither variable is set, the `claude` invocation is byte-identical to today.

---

## New Repository Variables

Both are optional. When unset, the corresponding flag is omitted from the `claude` command and the CLI uses its own default.

| Variable | Allowed values | Effect |
|---|---|---|
| `CLAUDE_EFFORT` | `low`, `medium`, `high`, `xhigh`, `max` | Passed as `--effort <value>` — controls Claude Code's extended-thinking budget for the review |
| `CLAUDE_MODEL` | Alias (`haiku`, `sonnet`, `opus`) or full model ID (e.g. `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) | Passed as `--model <value>` — selects the Claude model used for the review |

No validation in the script. Claude CLI rejects invalid values with a clear error, matching the existing `CLAUDE_MAX_TURNS` philosophy.

---

## `ci-review.sh` Changes

### 1. Header comment block

Add both variables to the *Optional repository variables* section at the top of the file, alongside `CLAUDE_MAX_TURNS`:

```
#   CLAUDE_EFFORT           Claude effort level: low|medium|high|xhigh|max
#                           (default: Claude CLI default)
#   CLAUDE_MODEL            Claude model alias (haiku|sonnet|opus) or full
#                           model ID (e.g. claude-opus-4-7)
#                           (default: Claude CLI default)
```

### 2. Read the variables near the existing `MAX_TURNS` block

```sh
EFFORT="${CLAUDE_EFFORT:-}"
MODEL="${CLAUDE_MODEL:-}"
[ -n "$EFFORT" ] && log "Effort: ${EFFORT}"
[ -n "$MODEL" ]  && log "Model: ${MODEL}"
```

### 3. Extend the runner heredoc

Accept two additional positional args (`$5` effort, `$6` model) and conditionally append the flags using bash arrays so an empty value never produces an empty flag:

```sh
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

### 4. Pass the new args in the `su` invocation

```sh
su -s /bin/bash reviewer -c \
  "$RUNNER $APIKEY_FILE $BUILD_DIR $PROMPT_FILE $MAX_TURNS \"$EFFORT\" \"$MODEL\"" \
  > review-raw.json 2>review-stderr.txt || true
```

The trailing positional args are quoted so empty values are preserved as empty strings (and therefore skipped by the `[ -n ... ]` guard inside the runner).

---

## `README.md` Changes

Extend the *Tuning* table with two new rows:

| Goal | What to change |
|------|----------------|
| Adjust Claude's thinking budget | Set `CLAUDE_EFFORT` to `low`, `medium`, `high`, `xhigh`, or `max` |
| Pin a specific Claude model | Set `CLAUDE_MODEL` to an alias (`haiku`, `sonnet`, `opus`) or a full model ID (e.g. `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) |

---

## Backwards Compatibility

- No existing variables renamed or removed.
- Default behaviour (both variables unset) produces the exact same `claude` command as before, so existing pipelines are unaffected.

---

## Out of Scope

- No tests added. `ci-review.sh` has no existing test coverage (the suite covers `parse-review.sh` and the provider scripts only), and this change is a trivial pass-through of two flags.
- No changes to `Dockerfile`, skill files, Slack formatting, provider scripts, or parsing logic.
