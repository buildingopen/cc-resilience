---
description: "Cancel active Target Loop"
allowed-tools: ["Bash(rm .claude/target-loop.local.md 2>/dev/null && rm .claude/targets.local.yaml 2>/dev/null && echo Target loop cancelled. || echo No active target loop.)"]
---

# Cancel Target Loop

```\!
rm .claude/target-loop.local.md 2>/dev/null && rm .claude/targets.local.yaml 2>/dev/null && echo '✅ Target loop cancelled.' || echo 'No active target loop.'
```
