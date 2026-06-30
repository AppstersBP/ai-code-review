#!/usr/bin/env bash
# =============================================================================
# local-review.sh — Run a single AI code review locally against an explicit
# commit range, bypassing CI infrastructure (Slack, PR comments).
#
# Usage:
#   bash scripts/local-review.sh \
#     --project /path/to/repo \
#     --base    <base-sha>    \
#     --head    <head-sha>    \
#     [--model  haiku|sonnet|opus|<full-id>] \
#     [--effort low|medium|high|xhigh|max]  \
#     [--out    /path/to/output-dir]
#
# Required env:
#   ANTHROPIC_API_KEY
#
# Output files written to --out (or current directory if omitted):
#   review-output.txt    human-readable review
#   review-raw.json      full Claude JSON (usage, cost, model)
#   review-exit-code.txt 0 = pass, 1 = critical issues found
#   review-stderr.txt    Claude stderr for debugging
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --project PATH --base SHA --head SHA [OPTIONS]

Required:
  --project PATH    Path to the project repository to review
  --base    SHA     Base commit SHA (exclusive)
  --head    SHA     Head commit SHA (inclusive)

Options:
  --model   MODEL   Alias (haiku|sonnet|opus) or full model ID
  --effort  LEVEL   low|medium|high|xhigh|max
  --out     DIR     Directory to write output files (default: current directory)
EOF
  exit 1
}

PROJECT=""
BASE_SHA=""
HEAD_SHA=""
MODEL=""
EFFORT=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --base)    BASE_SHA="$2"; shift 2 ;;
    --head)    HEAD_SHA="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --effort)  EFFORT="$2"; shift 2 ;;
    --out)     OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "Error: --project is required" >&2; usage; }
[[ -n "$BASE_SHA" ]] || { echo "Error: --base is required" >&2; usage; }
[[ -n "$HEAD_SHA" ]] || { echo "Error: --head is required" >&2; usage; }
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

PROJECT="$(cd "$PROJECT" && pwd)"
if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  OUT_DIR="$(cd "$OUT_DIR" && pwd)"
fi

REPO_NAME=$(basename "$PROJECT")
BRANCH_NAME=$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "local")

echo "[local-review] Project: ${REPO_NAME}"
echo "[local-review] Range:   ${BASE_SHA:0:8}..${HEAD_SHA:0:8}"
[[ -n "$MODEL" ]]  && echo "[local-review] Model:   ${MODEL}"
[[ -n "$EFFORT" ]] && echo "[local-review] Effort:  ${EFFORT}"
[[ -n "$OUT_DIR" ]] && echo "[local-review] Out:     ${OUT_DIR}"

# Run ci-review.sh from inside the project directory.
#
# SKIP_SLACK=1            — skips Slack posting and relaxes Slack var requirements.
# BASE_SHA_OVERRIDE/
#   HEAD_SHA_OVERRIDE     — bypass fetch-based range detection in ci-review.sh.
# Fake Bitbucket vars     — satisfy provider_validate_env (BITBUCKET_TOKEN/USERNAME)
#                           without making real API calls. IS_PR is always false in
#                           local runs so no PR comment is attempted.
(
  cd "$PROJECT"

  export SKIP_SLACK=1
  export BASE_SHA_OVERRIDE="$BASE_SHA"
  export HEAD_SHA_OVERRIDE="$HEAD_SHA"
  export BITBUCKET_BUILD_NUMBER="local-$$"
  export BITBUCKET_BRANCH="$BRANCH_NAME"
  export BITBUCKET_REPO_FULL_NAME="local/${REPO_NAME}"
  export BITBUCKET_TOKEN="local-dummy"
  export BITBUCKET_USERNAME="local@local"
  [[ -n "$MODEL" ]]  && export CLAUDE_MODEL="$MODEL"
  [[ -n "$EFFORT" ]] && export CLAUDE_EFFORT="$EFFORT"

  bash "${SCRIPT_DIR}/ci-review.sh" || true

  if [[ -n "$OUT_DIR" ]]; then
    for f in review-output.txt review-raw.json review-exit-code.txt review-stderr.txt; do
      [[ -f "$f" ]] && cp "$f" "$OUT_DIR/" || true
    done
    rm -f review-output.txt review-raw.json review-exit-code.txt review-stderr.txt
  fi
)

echo "[local-review] Done."
