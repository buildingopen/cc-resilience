---
description: "Check current target loop status"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ccr:*)"]
---

# Target Status

Run verification on all targets:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ccr" verify --status-only
```
