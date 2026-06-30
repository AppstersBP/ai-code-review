#!/usr/bin/env bash
# =============================================================================
# bench.sh — Run multiple model/effort combinations on the same commit range
# and produce a summary with AI-generated commentary.
#
# Usage:
#   bash scripts/bench.sh \
#     --project /path/to/repo                          \
#     --base    <base-sha>                              \
#     --head    <head-sha>                              \
#     --matrix  "haiku:low,haiku:high,sonnet:high,opus:max" \
#     [--out    ./bench-results]                        \
#     [--commentary-model sonnet]                       \
#     [--commentary-effort high]
#
# Required env:
#   ANTHROPIC_API_KEY
#
# Output layout:
#   <out>/<repo>/<base>..<head>/
#     <model>-<effort>/
#       review-output.txt
#       review-raw.json
#       review-exit-code.txt
#       review-stderr.txt
#     summary.md          (metrics table + AI commentary)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REVIEW="${SCRIPT_DIR}/local-review.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --project PATH --base SHA --head SHA --matrix COMBOS [OPTIONS]

Required:
  --project PATH     Path to the project repository
  --base    SHA      Base commit SHA (exclusive)
  --head    SHA      Head commit SHA (inclusive)
  --matrix  COMBOS   Comma-separated model:effort pairs
                     e.g. "haiku:low,haiku:high,sonnet:high,opus:max"

Options:
  --out               DIR   Output root directory (default: ./bench-results)
  --commentary-model  M     Model for AI commentary (default: sonnet)
  --commentary-effort E     Effort for AI commentary (default: high)
EOF
  exit 1
}

PROJECT=""
BASE_SHA=""
HEAD_SHA=""
MATRIX=""
OUT_DIR="./bench-results"
COMMENTARY_MODEL="${COMMENTARY_MODEL:-sonnet}"
COMMENTARY_EFFORT="${COMMENTARY_EFFORT:-high}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)           PROJECT="$2";            shift 2 ;;
    --base)              BASE_SHA="$2";            shift 2 ;;
    --head)              HEAD_SHA="$2";            shift 2 ;;
    --matrix)            MATRIX="$2";             shift 2 ;;
    --out)               OUT_DIR="$2";            shift 2 ;;
    --commentary-model)  COMMENTARY_MODEL="$2";   shift 2 ;;
    --commentary-effort) COMMENTARY_EFFORT="$2";  shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$PROJECT" ]]  || { echo "Error: --project is required" >&2; usage; }
[[ -n "$BASE_SHA" ]] || { echo "Error: --base is required" >&2;    usage; }
[[ -n "$HEAD_SHA" ]] || { echo "Error: --head is required" >&2;    usage; }
[[ -n "$MATRIX" ]]   || { echo "Error: --matrix is required" >&2;  usage; }
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

PROJECT="$(cd "$PROJECT" && pwd)"
REPO_NAME=$(basename "$PROJECT")
RANGE="${BASE_SHA:0:8}..${HEAD_SHA:0:8}"
RUN_DIR="${OUT_DIR}/${REPO_NAME}/${RANGE}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

echo "=== bench: ${REPO_NAME} ${RANGE} ==="
echo "Output: ${RUN_DIR}"
echo ""

# ─── Parse matrix ─────────────────────────────────────────────────────────────
IFS=',' read -ra COMBOS <<< "$MATRIX"

# ─── Per-combo accumulators ───────────────────────────────────────────────────
declare -a LABELS=()
declare -A DURATIONS VERDICTS CRITICALS IMPORTANTS SUGGESTIONS COSTS ACTUAL_MODELS FAILED

# ─── Run each combo ───────────────────────────────────────────────────────────
for combo in "${COMBOS[@]}"; do
  IFS=':' read -r c_model c_effort <<< "$combo"
  label="${c_model}-${c_effort}"
  LABELS+=("$label")
  combo_dir="${RUN_DIR}/${label}"
  mkdir -p "$combo_dir"

  echo "--- ${label} ---"

  start_ts=$(date +%s)
  bash "$LOCAL_REVIEW" \
    --project "$PROJECT" \
    --base    "$BASE_SHA" \
    --head    "$HEAD_SHA" \
    --model   "$c_model" \
    --effort  "$c_effort" \
    --out     "$combo_dir" || true
  end_ts=$(date +%s)

  DURATIONS[$label]=$((end_ts - start_ts))

  review_file="${combo_dir}/review-output.txt"
  raw_file="${combo_dir}/review-raw.json"

  if [[ -s "$review_file" ]]; then
    FAILED[$label]=0

    # Verdict: first non-blank line after the ### Verdict heading
    VERDICTS[$label]=$(awk '/^### Verdict/{f=1; next} f && /[^[:space:]]/{print; exit}' \
      "$review_file" 2>/dev/null || echo "—")

    # Finding counts: bullet lines (^- **) within each severity section
    CRITICALS[$label]=$(awk \
      '/^### 🔴 Critical/{f=1} /^### 🟡 Important/{f=0} f && /^- \*\*/{c++} END{print c+0}' \
      "$review_file")
    IMPORTANTS[$label]=$(awk \
      '/^### 🟡 Important/{f=1} /^### 🟢 Suggestions/{f=0} f && /^- \*\*/{c++} END{print c+0}' \
      "$review_file")
    SUGGESTIONS[$label]=$(awk \
      '/^### 🟢 Suggestions/{f=1} /^### ✅ Strengths/{f=0} f && /^- \*\*/{c++} END{print c+0}' \
      "$review_file")
  else
    FAILED[$label]=1
    VERDICTS[$label]="FAILED"
    CRITICALS[$label]="—"
    IMPORTANTS[$label]="—"
    SUGGESTIONS[$label]="—"
  fi

  if [[ -s "$raw_file" ]]; then
    COSTS[$label]=$(jq -r '.total_cost_usd // empty' "$raw_file" 2>/dev/null \
      | LC_NUMERIC=C awk '{printf "$%.4f", $1}' || echo "—")
    ACTUAL_MODELS[$label]=$(jq -r '.modelUsage | keys[0] // "—"' "$raw_file" 2>/dev/null || echo "—")
  else
    COSTS[$label]="—"
    ACTUAL_MODELS[$label]="—"
  fi

  echo "  Verdict:     ${VERDICTS[$label]}"
  echo "  Findings:    🔴 ${CRITICALS[$label]}  🟡 ${IMPORTANTS[$label]}  🟢 ${SUGGESTIONS[$label]}"
  echo "  Cost/time:   ${COSTS[$label]} / ${DURATIONS[$label]}s"
  echo "  Model:       ${ACTUAL_MODELS[$label]}"
  echo ""
done

# ─── Build summary table ──────────────────────────────────────────────────────
SUMMARY_FILE="${RUN_DIR}/summary.md"

{
  echo "# Bench: ${REPO_NAME}"
  echo ""
  echo "**Range:** \`${RANGE}\`  "
  echo "**Date:** $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo ""
  echo "## Results"
  echo ""
  echo "| Combo | Resolved model | Verdict | 🔴 | 🟡 | 🟢 | Cost | Time |"
  echo "|-------|---------------|---------|:--:|:--:|:--:|------|-----:|"
  for label in "${LABELS[@]}"; do
    printf "| %-22s | %-38s | %-30s | %s | %s | %s | %-8s | %ss |\n" \
      "$label" \
      "${ACTUAL_MODELS[$label]:-—}" \
      "${VERDICTS[$label]:-—}" \
      "${CRITICALS[$label]:-—}" \
      "${IMPORTANTS[$label]:-—}" \
      "${SUGGESTIONS[$label]:-—}" \
      "${COSTS[$label]:-—}" \
      "${DURATIONS[$label]:-—}"
  done
} > "$SUMMARY_FILE"

# ─── AI commentary ────────────────────────────────────────────────────────────
echo "--- Generating AI commentary (${COMMENTARY_MODEL}:${COMMENTARY_EFFORT}) ---"

# Collect review texts — skip combos that produced no output
REVIEWS_BLOCK=""
for label in "${LABELS[@]}"; do
  review_file="${RUN_DIR}/${label}/review-output.txt"
  if [[ "${FAILED[$label]:-1}" -eq 0 ]]; then
    REVIEWS_BLOCK+="
---

## ${label} (resolved: ${ACTUAL_MODELS[$label]:-unknown})

$(cat "$review_file")
"
  else
    REVIEWS_BLOCK+="
---

## ${label}

(Review failed — no output produced)
"
  fi
done

COMMENTARY_PROMPT="You are comparing automated AI code review outputs produced by different model and effort combinations run against the same commit range.

Repository: ${REPO_NAME}
Commit range: ${RANGE}

Each section below is the complete review from one model/effort combination.

${REVIEWS_BLOCK}

---

Write a concise comparative commentary covering these five points:

1. **High-confidence findings** — issues flagged by multiple or all combinations (these are most likely real)
2. **Divergent findings** — significant issues caught by some but not others; name which combination spotted them and which missed them
3. **False positive candidates** — findings raised by only one combination at a severity that looks high relative to what others saw
4. **Quality vs cost** — whether cheaper/faster combinations produced equivalent or sufficient output for this type of change
5. **Recommendation** — which model/effort combination to set as the default for automated CI reviews of this codebase, and why

Be specific. Reference actual findings and model names. This output drives a configuration decision."

COMMENTARY_JSON=$(claude -p "$COMMENTARY_PROMPT" \
  --model   "$COMMENTARY_MODEL" \
  --effort  "$COMMENTARY_EFFORT" \
  --max-turns 1 \
  --output-format json \
  2>/dev/null || echo '{}')

COMMENTARY=$(printf '%s' "$COMMENTARY_JSON" | jq -r '.result // "(Commentary generation failed — check ANTHROPIC_API_KEY)"' 2>/dev/null \
  || echo "(Commentary generation failed)")

{
  echo ""
  echo "## AI Commentary"
  echo ""
  echo "$COMMENTARY"
} >> "$SUMMARY_FILE"

# ─── Final report ─────────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo ""
echo "Summary: ${SUMMARY_FILE}"
echo ""
echo "Full reviews:"
for label in "${LABELS[@]}"; do
  echo "  ${RUN_DIR}/${label}/review-output.txt"
done
