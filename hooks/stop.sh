#!/bin/bash
# Stop hook — thin wrapper around ccr stop-hook
# Safety: if anything crashes, allow exit (never leave Claude stuck)
trap 'echo "{\"decision\":\"allow\"}"; exit 0' ERR

# Consume stdin (hook protocol requires reading it)
cat > /dev/null

# Delegate all logic to Python
CCR="$(dirname "$0")/../ccr"

OUTPUT=$("$CCR" stop-hook 2>/dev/null)

# If ccr produced output, use it; otherwise allow exit
if [[ -n "$OUTPUT" ]]; then
    echo "$OUTPUT"
else
    # No output = no active loop or clean exit
    echo '{"decision":"allow"}'
fi
