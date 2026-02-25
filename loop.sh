#!/bin/bash
# Headless iteration loop — calls claude -p, verifies, loops until done
# Crash-safe: persists iteration + session_id to state file after every step
set -euo pipefail

CCR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr"
[[ ! -f ".claude/target-loop.local.md" ]] && { echo "ERROR: No state file" >&2; exit 1; }
[[ ! -f ".claude/targets.local.yaml" ]] && { echo "ERROR: No targets file" >&2; exit 1; }

MAX_ITER=$("$CCR" state max_iterations)
ITERATION=$("$CCR" state iteration)
SESSION_ID=$("$CCR" state session_id 2>/dev/null || echo "")
PROMPT=$("$CCR" state --body)

# If resuming from crash with a session_id, use it
[[ -n "$SESSION_ID" ]] && echo "Resuming session: $SESSION_ID from iteration $ITERATION"

echo "═══ TARGET LOOP: max=$MAX_ITER iter=$ITERATION ═══"

while true; do
    ITERATION=$((ITERATION + 1))
    [[ $ITERATION -gt $MAX_ITER ]] && { echo "═══ MAX ITERATIONS ($MAX_ITER) ═══"; exit 1; }
    echo -e "\n═══ ITERATION $ITERATION/$MAX_ITER ═══"

    # Persist iteration BEFORE calling Claude (so crash mid-claude keeps position)
    "$CCR" update-state iteration=$ITERATION

    CLAUDE_ARGS=(-p "$PROMPT" --output-format json)
    [[ -n "$SESSION_ID" ]] && CLAUDE_ARGS+=(--resume "$SESSION_ID")
    RESULT=$(claude "${CLAUDE_ARGS[@]}" 2>/tmp/loop-stderr.log) || true
    [[ -z "$RESULT" ]] && { echo "WARNING: Empty output, retrying..."; continue; }

    # Extract + persist session_id for crash recovery
    SESSION_ID=$(echo "$RESULT" | "$CCR" parse-field session_id 2>/dev/null || true)
    [[ -n "$SESSION_ID" ]] && "$CCR" update-state "session_id=$SESSION_ID"
    echo "Claude done (session=$SESSION_ID). Verifying..."

    VERIFY=$("$CCR" verify 2>/dev/null || echo '{"all_pass":false,"passed":0,"total":0}')
    ALL_PASS=$(echo "$VERIFY" | "$CCR" parse-field all_pass 2>/dev/null || echo "False")
    PASSED=$(echo "$VERIFY" | "$CCR" parse-field passed 2>/dev/null || echo 0)
    TOTAL=$(echo "$VERIFY" | "$CCR" parse-field total 2>/dev/null || echo 0)
    echo "Targets: $PASSED/$TOTAL all_pass=$ALL_PASS"

    if [[ "$ALL_PASS" == "True" || "$ALL_PASS" == "true" ]]; then
        echo -e "\n═══ ALL PASSED after $ITERATION iters ═══"
        "$CCR" update-state phase=done
        exit 0
    fi

    git diff --name-only -- .claude/targets.local.yaml 2>/dev/null | grep -q . && git checkout -- .claude/targets.local.yaml 2>/dev/null
    PROMPT=$(echo "$VERIFY" | "$CCR" prompt 2>/dev/null)
done
