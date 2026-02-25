#!/bin/bash
# Headless iteration loop — calls claude -p, verifies, loops until done
# Crash-safe: persists iteration + session_id to state file after every step
# Exit codes: 0=all pass, 1=max iterations, 2=config error, 3=prompt failure
set -euo pipefail

CCR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr"
STDERR_LOG="/tmp/loop-stderr.$$.log"
CLAUDE_PID=""
CLAUDE_TIMEOUT=${CLAUDE_TIMEOUT:-600}   # 10 min default
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-120}   # 2 min default
MAX_EMPTY=3
EMPTY_COUNT=0

# --- helpers ---

wait_with_timeout() {
    local pid=$1 secs=$2 elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        [[ $elapsed -ge $secs ]] && return 1
    done
    wait "$pid" 2>/dev/null
    return 0
}

cleanup() {
    [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null && wait "$CLAUDE_PID" 2>/dev/null
    rm -f "$STDERR_LOG" "$STDERR_LOG.out"
}
trap cleanup EXIT INT TERM HUP

# --- preflight ---

[[ ! -f ".claude/target-loop.local.md" ]] && { echo "ERROR: No state file" >&2; exit 2; }
[[ ! -f ".claude/targets.local.yaml" ]] && { echo "ERROR: No targets file" >&2; exit 2; }

MAX_ITER=$("$CCR" state max_iterations)
ITERATION=$("$CCR" state iteration)
SESSION_ID=$("$CCR" state session_id 2>/dev/null || echo "")
PROMPT=$("$CCR" state --body)

[[ "$MAX_ITER" =~ ^[0-9]+$ ]] || { echo "ERROR: max_iterations not numeric: $MAX_ITER" >&2; exit 2; }
[[ "$ITERATION" =~ ^[0-9]+$ ]] || ITERATION=0
[[ -z "$PROMPT" ]] && { echo "ERROR: Empty initial prompt" >&2; exit 2; }

[[ -n "$SESSION_ID" ]] && echo "Resuming session: $SESSION_ID from iteration $ITERATION"
echo "═══ TARGET LOOP: max=$MAX_ITER iter=$ITERATION ═══"

# --- main loop ---

while true; do
    ITERATION=$((ITERATION + 1))
    [[ $ITERATION -gt $MAX_ITER ]] && { echo "═══ MAX ITERATIONS ($MAX_ITER) ═══"; exit 1; }
    echo -e "\n═══ ITERATION $ITERATION/$MAX_ITER ═══"

    "$CCR" update-state "iteration=$ITERATION"

    # Run Claude with timeout (background + wait so trap can kill it)
    CLAUDE_ARGS=(-p "$PROMPT" --output-format json)
    [[ -n "$SESSION_ID" ]] && CLAUDE_ARGS+=(--resume "$SESSION_ID")

    RESULT=""
    claude "${CLAUDE_ARGS[@]}" >"$STDERR_LOG.out" 2>"$STDERR_LOG" &
    CLAUDE_PID=$!
    if wait_with_timeout "$CLAUDE_PID" "$CLAUDE_TIMEOUT"; then
        RESULT=$(cat "$STDERR_LOG.out")
    else
        echo "WARNING: Claude timed out after ${CLAUDE_TIMEOUT}s, killing..."
        kill "$CLAUDE_PID" 2>/dev/null; wait "$CLAUDE_PID" 2>/dev/null
    fi
    CLAUDE_PID=""
    rm -f "$STDERR_LOG.out"

    # Handle empty output with backoff (bail after MAX_EMPTY consecutive)
    if [[ -z "$RESULT" ]]; then
        EMPTY_COUNT=$((EMPTY_COUNT + 1))
        if [[ $EMPTY_COUNT -ge $MAX_EMPTY ]]; then
            echo "FATAL: $MAX_EMPTY consecutive empty outputs. Stderr:"
            cat "$STDERR_LOG" 2>/dev/null || true
            exit 1
        fi
        echo "WARNING: Empty output ($EMPTY_COUNT/$MAX_EMPTY), backing off 10s..."
        sleep 10
        continue
    fi
    EMPTY_COUNT=0

    # Extract + persist session_id
    SESSION_ID=$(echo "$RESULT" | "$CCR" parse-field session_id 2>/dev/null || true)
    [[ -n "$SESSION_ID" ]] && "$CCR" update-state "session_id=$SESSION_ID"
    echo "Claude done (session=$SESSION_ID). Verifying..."

    # Verify with timeout
    VERIFY=$(timeout "$VERIFY_TIMEOUT" "$CCR" verify 2>/dev/null || echo '{"all_pass":false,"passed":0,"total":0}')
    ALL_PASS=$(echo "$VERIFY" | "$CCR" parse-field all_pass 2>/dev/null || echo "False")
    PASSED=$(echo "$VERIFY" | "$CCR" parse-field passed 2>/dev/null || echo 0)
    TOTAL=$(echo "$VERIFY" | "$CCR" parse-field total 2>/dev/null || echo 0)
    echo "Targets: $PASSED/$TOTAL all_pass=$ALL_PASS"

    if [[ "$ALL_PASS" == "True" || "$ALL_PASS" == "true" ]]; then
        echo -e "\n═══ ALL PASSED after $ITERATION iters ═══"
        "$CCR" update-state phase=done
        exit 0
    fi

    # Restore targets if tampered (unstaged + staged)
    if git rev-parse --git-dir &>/dev/null; then
        git diff --name-only -- .claude/targets.local.yaml 2>/dev/null | grep -q . && git checkout -- .claude/targets.local.yaml 2>/dev/null
        git diff --cached --name-only -- .claude/targets.local.yaml 2>/dev/null | grep -q . && git restore --staged .claude/targets.local.yaml 2>/dev/null
    fi

    # Generate next prompt (must not fail silently — exit 3 on failure)
    PROMPT=$(echo "$VERIFY" | "$CCR" prompt 2>/dev/null) || true
    [[ -z "$PROMPT" ]] && { echo "FATAL: ccr prompt failed to generate next iteration prompt" >&2; exit 3; }
done
