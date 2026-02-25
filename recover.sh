#!/bin/bash
# cc-resilient: Crash-resilient Claude Code wrapper
# Monitors stderr, auto-recovers from known failure patterns.
set -uo pipefail

CCR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr"

# --- Config ---
MAX_RETRIES=5
RETRY_DELAY=5
BACKOFF_MULT=2
MAX_DELAY=120
LOG="${HOME}/cc-resilience/resilience.log"
SESSION_ID=""
PROJECT_DIR=""
GOAL=""
VERBOSE=false
CLAUDE_ARGS=()

# --- Helpers ---
log() { local lvl="$1"; shift; local msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$lvl] $*"; echo "$msg" >> "$LOG"; [[ "$VERBOSE" == "true" ]] && echo "$msg" >&2; }

usage() {
    cat <<'EOF'
cc-resilient: Crash-resilient Claude Code wrapper

USAGE: cc-resilient [OPTIONS] [-- CLAUDE_ARGS...]

OPTIONS:
  -d, --dir <path>       Project directory (default: cwd)
  -g, --goal <text>      Goal/prompt for fresh restart
  -s, --session <id>     Session ID to resume
  --max-retries <n>      Max attempts (default: 5)
  --verbose              Verbose logging
  -h, --help             Show help
EOF
    exit 0
}

find_session_jsonl() {
    local encoded=$(echo "$1" | sed 's|/|-|g')
    local dir="$HOME/.claude/projects/$encoded"
    [[ -d "$dir" ]] && ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

run_claude() {
    # $1 = mode (continue|resume|fresh), $2 = optional prompt
    local mode="$1" prompt="${2:-}"
    local stderr_file=$(mktemp)

    cd "$PROJECT_DIR"
    case "$mode" in
        continue) claude -c ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} 2>"$stderr_file" ;;
        resume)   claude -r "$SESSION_ID" ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} 2>"$stderr_file" ;;
        fresh)
            if [[ -n "$prompt" ]]; then
                claude -p "$prompt" ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} 2>"$stderr_file"
            else
                claude ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} 2>"$stderr_file"
            fi ;;
    esac
    local ec=$?

    local stderr=$(cat "$stderr_file")
    local class=$(echo "$stderr" | "$CCR" classify 2>/dev/null || echo "UNKNOWN")
    rm -f "$stderr_file"

    # Set globals
    _EXIT=$ec; _CLASS=$class; _STDERR=$stderr
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)        PROJECT_DIR="$2"; shift 2 ;;
        -g|--goal)       GOAL="$2"; shift 2 ;;
        -s|--session)    SESSION_ID="$2"; shift 2 ;;
        --max-retries)   MAX_RETRIES="$2"; shift 2 ;;
        --verbose)       VERBOSE=true; shift ;;
        -h|--help)       usage ;;
        --)              shift; CLAUDE_ARGS=("$@"); break ;;
        *)               CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
mkdir -p "$(dirname "$LOG")"

log "INFO" "=== cc-resilient starting ==="
log "INFO" "Project: $PROJECT_DIR | Retries: $MAX_RETRIES"

trap 'rm -f /tmp/cc-resilient-* 2>/dev/null' EXIT

# --- Recovery loop ---
attempt=0
delay=$RETRY_DELAY
last_class=""

while [[ $attempt -lt $MAX_RETRIES ]]; do
    log "INFO" "--- Attempt $((attempt + 1))/$MAX_RETRIES ---"

    if [[ $attempt -eq 0 ]]; then
        [[ -n "$SESSION_ID" ]] && run_claude resume || run_claude continue
    elif [[ "$last_class" == "POISON" ]]; then
        log "WARN" "Poisoned — fresh session with context recovery"
        JSONL=$(find_session_jsonl "$PROJECT_DIR")
        PROGRESS=""
        [[ -n "$JSONL" ]] && PROGRESS=$("$CCR" progress "$JSONL" 2>/dev/null)
        INJECT=""
        [[ -n "$GOAL" ]] && INJECT="## Goal\n$GOAL\n\n"
        [[ -n "$PROGRESS" ]] && INJECT="${INJECT}## Context from Previous Session\nThe previous session crashed. Here is what was accomplished:\n$PROGRESS\n\nPlease continue.\n"
        run_claude fresh "$(echo -e "$INJECT")"
    elif [[ "$last_class" == "CONTEXT" ]]; then
        log "WARN" "Context overflow — try continue, then fresh"
        run_claude continue
        if [[ "$_CLASS" == "CONTEXT" ]] || [[ "$_CLASS" == "POISON" ]]; then
            JSONL=$(find_session_jsonl "$PROJECT_DIR")
            PROGRESS=""
            [[ -n "$JSONL" ]] && PROGRESS=$("$CCR" progress "$JSONL" 2>/dev/null)
            INJECT=""
            [[ -n "$GOAL" ]] && INJECT="## Goal\n$GOAL\n\n"
            [[ -n "$PROGRESS" ]] && INJECT="${INJECT}## Context\n$PROGRESS\n"
            run_claude fresh "$(echo -e "$INJECT")"
        fi
    elif [[ "$last_class" == "TRANSIENT" ]] || [[ "$last_class" == "AUTH" ]]; then
        log "INFO" "$last_class — retrying after ${delay}s"
        sleep "$delay"
        run_claude continue
    else
        log "WARN" "Unknown — trying continue"
        run_claude continue
    fi

    log "INFO" "Exit: $_EXIT, Class: $_CLASS"

    # Clean exit
    if [[ "$_EXIT" == "0" ]]; then
        log "INFO" "Session completed successfully."
        exit 0
    fi

    last_class="$_CLASS"
    attempt=$((attempt + 1))
    [[ -n "$_STDERR" ]] && log "ERROR" "Stderr: ${_STDERR:0:500}"

    if [[ "$_CLASS" == "POISON" ]]; then
        sleep 2
    else
        log "INFO" "Waiting ${delay}s..."
        sleep "$delay"
        delay=$((delay * BACKOFF_MULT))
        [[ $delay -gt $MAX_DELAY ]] && delay=$MAX_DELAY
    fi
done

log "ERROR" "Max retries ($MAX_RETRIES) exhausted."
echo "cc-resilient: Failed after $MAX_RETRIES attempts. Last: $last_class. See: $LOG" >&2
exit 1
