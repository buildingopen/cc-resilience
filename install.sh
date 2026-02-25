#!/bin/bash
# CC-Resilience unified installer
# Installs: target-loop plugin (hooks + commands), crash recovery, compact hooks
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$HOME/.claude/plugins/local/target-loop"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

log() { echo "[install] $1"; }
fail() { echo "[ERROR] $1" >&2; exit 1; }

# Pre-checks
command -v claude &>/dev/null || [[ -x /usr/local/bin/claude ]] || fail "Claude Code not found"
command -v jq &>/dev/null || fail "jq required (apt install jq)"
command -v python3 &>/dev/null || fail "python3 required"

mkdir -p "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/commands" "$HOOKS_DIR"

# Clean old scripts from previous installs
log "Cleaning old scripts"
rm -f "$PLUGIN_DIR/scripts/verify-targets.sh" "$PLUGIN_DIR/scripts/generate-prompt.sh"       "$PLUGIN_DIR/scripts/setup-target-loop.sh" "$PLUGIN_DIR/scripts/target-loop-headless.sh" 2>/dev/null || true

# 1. Target-loop plugin
log "Installing target-loop plugin"
cp "$SRC/hooks/stop.sh" "$PLUGIN_DIR/hooks/stop-hook.sh"
cp "$SRC/ccr" "$PLUGIN_DIR/scripts/ccr"
# Also keep ccr at plugin root for stop.sh to find via ../ccr
cp "$SRC/ccr" "$PLUGIN_DIR/ccr"
chmod +x "$PLUGIN_DIR/hooks/stop-hook.sh" "$PLUGIN_DIR/scripts/ccr" "$PLUGIN_DIR/ccr"

# Copy commands
if [[ -d "$SRC/commands" ]]; then
    cp "$SRC/commands/"*.md "$PLUGIN_DIR/commands/" 2>/dev/null || true
fi

# Plugin hooks.json
cat > "$PLUGIN_DIR/hooks/hooks.json" <<'HJSON'
{
  "hooks": [
    {
      "type": "Stop",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
    }
  ]
}
HJSON

# 2. Crash recovery wrapper
log "Installing crash recovery"
ln -sf "$SRC/recover.sh" /usr/local/bin/cc-resilient 2>/dev/null || cp "$SRC/recover.sh" /usr/local/bin/cc-resilient
chmod +x /usr/local/bin/cc-resilient

# 3. Compact hooks
log "Installing compact hooks"
cp "$SRC/hooks/precompact.sh" "$HOOKS_DIR/cc-precompact-hook.sh"
cp "$SRC/hooks/postcompact.sh" "$HOOKS_DIR/cc-postcompact-hook.sh"
chmod +x "$HOOKS_DIR/cc-precompact-hook.sh" "$HOOKS_DIR/cc-postcompact-hook.sh"

# 4. Register hooks in settings.json
log "Registering hooks"
STOP_CMD="${PLUGIN_DIR}/hooks/stop-hook.sh"
PRE_CMD="${HOOKS_DIR}/cc-precompact-hook.sh"
POST_CMD="${HOOKS_DIR}/cc-postcompact-hook.sh"

[[ -f "$SETTINGS" ]] && EXISTING=$(cat "$SETTINGS") || EXISTING="{}"

MERGED=$(echo "$EXISTING" | jq \
    --arg stop "$STOP_CMD" \
    --arg pre "$PRE_CMD" \
    --arg post "$POST_CMD" \
    '
    def add_hook($event; $cmd; $timeout):
        .hooks[$event] = (
            (.hooks[$event] // [])
            | [.[] | select(.hooks | all(.command != $cmd))]
            + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd, "timeout": $timeout}]}]
        );
    .hooks = (.hooks // {})
    | add_hook("Stop"; $stop; 120)
    | add_hook("PreCompact"; $pre; 30)
    | add_hook("PostCompact"; $post; 10)
    | add_hook("SessionStart"; $post; 10)
    ')

echo "$MERGED" | jq . > "$SETTINGS"

# 5. Verify
log "Verifying..."
CHECKS=0
[[ -x "$PLUGIN_DIR/hooks/stop-hook.sh" ]] && CHECKS=$((CHECKS+1))
[[ -x "$PLUGIN_DIR/ccr" ]] && CHECKS=$((CHECKS+1))
[[ -x /usr/local/bin/cc-resilient ]] && CHECKS=$((CHECKS+1))
jq -e '.hooks.Stop' "$SETTINGS" >/dev/null 2>&1 && CHECKS=$((CHECKS+1))
jq -e '.hooks.PreCompact' "$SETTINGS" >/dev/null 2>&1 && CHECKS=$((CHECKS+1))

echo ""
echo "════════════════════════════════════"
echo "  CC-Resilience installed ($CHECKS/5)"
echo "════════════════════════════════════"
echo "  Plugin: $PLUGIN_DIR"
echo "  Recovery: /usr/local/bin/cc-resilient"
echo "  Hooks: $SETTINGS"
[[ "$CHECKS" -eq 5 ]] && echo "  All checks passed." || echo "  WARNING: $((5-CHECKS)) check(s) failed."
echo "════════════════════════════════════"
