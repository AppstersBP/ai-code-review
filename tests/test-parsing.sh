#!/usr/bin/env bash
# =============================================================================
# tests/test-parsing.sh — Unit tests for parse-review.sh
#
# Usage: bash tests/test-parsing.sh
# Run from the repo root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/parse-review.sh"

# ─── Test runner ──────────────────────────────────────────────────────────────
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

# ─── Sample reviews ───────────────────────────────────────────────────────────

REVIEW_APPROVED=$(cat <<'EOF'
## 🔍 Code Review — abc1234

**Commits reviewed:** def5678..abc1234
**Files changed:** 1
**Platform:** android

---

### Summary
Documentation-only change correcting variable descriptions. No functional impact.

---

### 🔴 Critical — Must Fix Before Merge
None.

---

### 🟡 Important — Should Fix
None.

---

### 🟢 Suggestions — Nice to Have
None.

---

### ✅ Strengths
Accurate and well-scoped fix.

---

### Verdict
APPROVED
EOF
)

REVIEW_WITH_CRITICAL=$(cat <<'EOF'
## 🔍 Code Review — abc1234

**Commits reviewed:** def5678..abc1234
**Files changed:** 2
**Platform:** android

---

### Summary
Adds a new fragment with several lifecycle issues.

---

### 🔴 Critical — Must Fix Before Merge
- **MyFragment.kt:42** — `_binding` is never nulled in `onDestroyView`, leaking the View hierarchy.
- **MyFragment.kt:67** — Observer uses `this` instead of `viewLifecycleOwner`, causing accumulation.

---

### 🟡 Important — Should Fix
None.

---

### 🟢 Suggestions — Nice to Have
None.

---

### ✅ Strengths
Good use of ViewBinding overall.

---

### Verdict
CHANGES REQUESTED
EOF
)

REVIEW_WITH_IMPORTANT=$(cat <<'EOF'
## 🔍 Code Review — abc1234

**Commits reviewed:** def5678..abc1234
**Files changed:** 1
**Platform:** android

---

### Summary
Adds logging to a ViewModel. Generally fine, one improvement suggested.

---

### 🔴 Critical — Must Fix Before Merge
None.

---

### 🟡 Important — Should Fix
- **MyViewModel.kt:88** — `Log.e` is called with a hardcoded string TAG instead of a constant.

---

### 🟢 Suggestions — Nice to Have
None.

---

### ✅ Strengths
Replaces printStackTrace correctly.

---

### Verdict
APPROVED WITH SUGGESTIONS
EOF
)

REVIEW_WITH_BOTH=$(cat <<'EOF'
## 🔍 Code Review — abc1234

**Commits reviewed:** def5678..abc1234
**Files changed:** 3
**Platform:** android

---

### Summary
Significant changes across multiple files with several issues.

---

### 🔴 Critical — Must Fix Before Merge
- **Foo.kt:10** — Force unwrap `!!` on API response will crash on empty results.

---

### 🟡 Important — Should Fix
- **Bar.kt:55** — `setValue` called from a background thread; use `postValue`.

---

### 🟢 Suggestions — Nice to Have
- **Baz.kt:3** — Unused import.

---

### ✅ Strengths
Broad coverage of the feature.

---

### Verdict
CHANGES REQUESTED
EOF
)

REVIEW_CLAUDE_FAILED="❌ Code review failed to produce output. Check CI logs."

# ─── has_critical_findings ────────────────────────────────────────────────────
echo "has_critical_findings"
check "all-none review: no critical"            false  has_critical_findings "$REVIEW_APPROVED"
check "critical findings present: detected"     true   has_critical_findings "$REVIEW_WITH_CRITICAL"
check "important-only review: no critical"      false  has_critical_findings "$REVIEW_WITH_IMPORTANT"
check "both critical and important: detected"   true   has_critical_findings "$REVIEW_WITH_BOTH"
check "claude failure message: no critical"     false  has_critical_findings "$REVIEW_CLAUDE_FAILED"

# ─── has_important_findings ───────────────────────────────────────────────────
echo ""
echo "has_important_findings"
check "all-none review: no important"           false  has_important_findings "$REVIEW_APPROVED"
check "critical-only review: no important"      false  has_important_findings "$REVIEW_WITH_CRITICAL"
check "important findings present: detected"    true   has_important_findings "$REVIEW_WITH_IMPORTANT"
check "both critical and important: detected"   true   has_important_findings "$REVIEW_WITH_BOTH"
check "claude failure message: no important"    false  has_important_findings "$REVIEW_CLAUDE_FAILED"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
