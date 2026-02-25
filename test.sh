#!/bin/bash
# cc-resilience test suite — run with: ./test.sh
set -uo pipefail

CCR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr"
PASS=0 FAIL=0 TOTAL=0

assert() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    TOTAL=$((TOTAL + 1))
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        echo "     expected to contain: $needle"
        echo "     actual: ${haystack:0:200}"
        FAIL=$((FAIL + 1))
    fi
}

# Setup temp dir
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"
git init -q
mkdir -p .claude src

# ─── 1. Error Classification ──────────────────────────────────────
echo "═══ classify ═══"
assert "TRANSIENT: 529 overloaded" "TRANSIENT" "$(echo '529 overloaded' | "$CCR" classify)"
assert "TRANSIENT: ECONNRESET" "TRANSIENT" "$(echo 'ECONNRESET' | "$CCR" classify)"
assert "TRANSIENT: socket hang up" "TRANSIENT" "$(echo 'socket hang up' | "$CCR" classify)"
assert "TRANSIENT: SIGKILL" "TRANSIENT" "$(echo 'SIGKILL' | "$CCR" classify)"
assert "POISON: image too large" "POISON" "$(echo 'image exceeds 5 MB maximum' | "$CCR" classify)"
assert "POISON: conversation too long" "POISON" "$(echo 'Conversation too long, try again' | "$CCR" classify)"
assert "CONTEXT: context limit" "CONTEXT" "$(echo 'Context limit reached' | "$CCR" classify)"
assert "CONTEXT: input too long" "CONTEXT" "$(echo 'input length and max_tokens exceed context limit' | "$CCR" classify)"
assert "AUTH: 401" "AUTH" "$(echo 'HTTP 401 Unauthorized' | "$CCR" classify)"
assert "AUTH: authentication_error" "AUTH" "$(echo 'authentication_error' | "$CCR" classify)"
assert "UNKNOWN: random text" "UNKNOWN" "$(echo 'something weird happened' | "$CCR" classify)"

# ─── 2. Setup ─────────────────────────────────────────────────────
echo "═══ setup ═══"
OUT=$("$CCR" setup "Build a test project" --max-iterations 8 2>&1)
assert_contains "setup creates state file" "Target Loop activated" "$OUT"
assert "state: iteration=1" "1" "$("$CCR" state iteration)"
assert "state: max_iterations=8" "8" "$("$CCR" state max_iterations)"
assert "state: phase=outline" "outline" "$("$CCR" state phase)"
assert "state: body preserved" "Build a test project" "$("$CCR" state --body)"

# Guard: can't overwrite active loop
ERR=$("$CCR" setup "Another project" 2>&1 || true)
assert_contains "setup rejects if active" "already active" "$ERR"

rm -f .claude/target-loop.local.md

# ─── 3. Verify — all pass ────────────────────────────────────────
echo "═══ verify (all pass) ═══"
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Echo test"
    verify: "echo hello"
    depends: []
  - id: T2
    name: "True test"
    verify: "true"
    depends: ["T1"]
YAML
VRESULT=$("$CCR" verify 2>/dev/null)
assert "all_pass=true" "True" "$(echo "$VRESULT" | "$CCR" parse-field all_pass)"
assert "passed=2" "2" "$(echo "$VRESULT" | "$CCR" parse-field passed)"
assert "total=2" "2" "$(echo "$VRESULT" | "$CCR" parse-field total)"

# ─── 4. Verify — with failures ───────────────────────────────────
echo "═══ verify (failures) ═══"
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Pass"
    verify: "true"
    depends: []
  - id: T2
    name: "Fail"
    verify: "echo 'broken' && exit 1"
    depends: []
  - id: T3
    name: "Blocked"
    verify: "true"
    depends: ["T2"]
YAML
VRESULT=$("$CCR" verify 2>/dev/null)
assert "all_pass=false" "False" "$(echo "$VRESULT" | "$CCR" parse-field all_pass)"
assert "passed=1" "1" "$(echo "$VRESULT" | "$CCR" parse-field passed)"
assert "total=3" "3" "$(echo "$VRESULT" | "$CCR" parse-field total)"
assert "first_fail=T2" "T2" "$(echo "$VRESULT" | "$CCR" parse-field first_fail)"

# Check BLOCKED status
T3_STATUS=$(echo "$VRESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print([r['status'] for r in d['results'] if r['id']=='T3'][0])")
assert "T3 blocked by T2" "BLOCKED" "$T3_STATUS"

# ─── 5. Verify — timeout ─────────────────────────────────────────
echo "═══ verify (timeout) ═══"
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Slow"
    verify: "sleep 60"
    depends: []
YAML
VRESULT=$("$CCR" verify 2>/dev/null)
T1_OUT=$(echo "$VRESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['output'])")
assert_contains "timeout detected" "TIMEOUT" "$T1_OUT"

# ─── 6. Prompt generation ────────────────────────────────────────
echo "═══ prompt ═══"
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Pass"
    verify: "true"
    depends: []
  - id: T2
    name: "Fail"
    verify: "false"
    depends: []
YAML
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 3
max_iterations: 10
phase: build
targets_approved: true
consecutive_same_failures: 0
last_failure_hash: ""
---

Test prompt
STATE
PROMPT=$("$CCR" verify 2>/dev/null | "$CCR" prompt 2>/dev/null)
assert_contains "prompt has iteration" "ITERATION 3/10" "$PROMPT"
assert_contains "prompt has pass count" "1/2 targets passing" "$PROMPT"
assert_contains "prompt has focus" "Focus: T2" "$PROMPT"
assert_contains "prompt has rules" "Rules (enforced)" "$PROMPT"
assert_contains "prompt has remaining" "7 iterations remaining" "$PROMPT"

# ─── 7. Stop hook — phases ───────────────────────────────────────
echo "═══ stop-hook (phases) ═══"

# Outline phase, no targets file
rm -f .claude/targets.local.yaml
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 1
max_iterations: 10
phase: outline
targets_approved: false
consecutive_same_failures: 0
last_failure_hash: ""
---

Test
STATE
HOOK=$("$CCR" stop-hook 2>/dev/null)
assert_contains "outline: block" '"decision": "block"' "$HOOK"
assert_contains "outline: create targets" "create" "$HOOK"

# Outline → approval transition
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Test"
    verify: "true"
    depends: []
YAML
HOOK=$("$CCR" stop-hook 2>/dev/null)
assert_contains "approval: block" '"decision": "block"' "$HOOK"
PHASE=$("$CCR" state phase)
assert "phase transitions to approval" "approval" "$PHASE"

# Approval phase
HOOK=$("$CCR" stop-hook 2>/dev/null)
assert_contains "approval: needs user" "approval" "$HOOK"

# Build phase — all pass → clean exit
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 1
max_iterations: 10
phase: build
targets_approved: true
consecutive_same_failures: 0
last_failure_hash: ""
---

Test
STATE
HOOK=$("$CCR" stop-hook 2>/dev/null)
assert_contains "all pass: clean exit" "ALL" "$HOOK"
# State file should be removed
[[ ! -f .claude/target-loop.local.md ]]
assert "all pass: state file removed" "0" "$?"

# Build phase — failure → block
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 1
max_iterations: 10
phase: build
targets_approved: true
consecutive_same_failures: 0
last_failure_hash: ""
---

Test
STATE
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Fail"
    verify: "false"
    depends: []
YAML
HOOK=$("$CCR" stop-hook 2>/dev/null)
assert_contains "fail: block" '"decision": "block"' "$HOOK"
assert_contains "fail: has iteration info" "Iter 2/10" "$HOOK"

# Max iterations → clean exit
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 10
max_iterations: 10
phase: build
targets_approved: true
consecutive_same_failures: 0
last_failure_hash: ""
---

Test
STATE
HOOK=$("$CCR" stop-hook 2>/dev/null || true)
assert "max iter: state file removed" "1" "$([[ ! -f .claude/target-loop.local.md ]] && echo 1 || echo 0)"

# ─── 8. update-state ─────────────────────────────────────────────
echo "═══ update-state ═══"
cat > .claude/target-loop.local.md << 'STATE'
---
active: true
iteration: 1
max_iterations: 10
phase: build
targets_approved: true
consecutive_same_failures: 0
last_failure_hash: ""
session_id: ""
---

Body text
STATE
"$CCR" update-state iteration=5 session_id=abc-123
assert "update iteration" "5" "$("$CCR" state iteration)"
assert "update session_id" "abc-123" "$("$CCR" state session_id)"
assert "body preserved after update" "Body text" "$("$CCR" state --body)"

# ─── 9. parse-field ──────────────────────────────────────────────
echo "═══ parse-field ═══"
assert "parse string" "hello" "$(echo '{"key":"hello"}' | "$CCR" parse-field key)"
assert "parse number" "42" "$(echo '{"n":42}' | "$CCR" parse-field n)"
assert "parse bool" "True" "$(echo '{"b":true}' | "$CCR" parse-field b)"
assert "parse missing" "" "$(echo '{"a":1}' | "$CCR" parse-field missing)"

# ─── 10. progress ────────────────────────────────────────────────
echo "═══ progress ═══"
cat > "$TMPDIR/test.jsonl" << 'JSONL'
{"type":"human","message":{"content":[{"type":"text","text":"do stuff"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"I fixed the bug in auth.ts"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Tests now pass"}]}}
JSONL
PROG=$("$CCR" progress "$TMPDIR/test.jsonl")
assert_contains "extracts assistant text" "fixed the bug" "$PROG"
assert_contains "extracts last message" "Tests now pass" "$PROG"
PROG1=$("$CCR" progress "$TMPDIR/test.jsonl" -n 1)
# Should only get the last message
assert_contains "n=1 gets last only" "Tests now pass" "$PROG1"

# ─── 11. status-only ─────────────────────────────────────────────
echo "═══ verify --status-only ═══"
cat > .claude/targets.local.yaml << 'YAML'
targets:
  - id: T1
    name: "Works"
    verify: "true"
    depends: []
YAML
STATUS=$("$CCR" verify --status-only 2>/dev/null)
assert_contains "status has count" "1/1 passing" "$STATUS"
assert_contains "status has icon" "✅" "$STATUS"

# ─── Results ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════"
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "═══════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
