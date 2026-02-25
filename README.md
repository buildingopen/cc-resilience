# cc-resilience

Crash-resilient Claude Code wrapper. Solves Problem 1: auto-recovery from crashes.

## What It Handles

| Error Type | Detection | Recovery |
|-----------|-----------|----------|
| Image too large | stderr pattern | Fresh session + JSONL context recovery |
| Context overflow | stderr pattern | Try compact, then fresh session |
| Compaction deadlock | stderr pattern | Fresh session + context recovery |
| Server 500 | stderr pattern | Try compact |
| Transient (529, timeout) | stderr pattern | Retry with backoff |
| Process crash | exit code != 0 | Continue session (claude -c) |
| Unknown error | catch-all | Try continue, then fresh |

## Recovery Strategy

1. First attempt: `claude -c` (continue) or `claude -r <session-id>` (resume)
2. If poisoned (image too large): Parse JSONL -> extract progress -> fresh session with context
3. If context overflow: Try continue (may auto-compact) -> fresh if still failing
4. If transient: Retry with exponential backoff
5. After MAX_RETRIES: Give up and log

## Pre/Post Compaction Hooks

Saves session state before compaction, restores after. Prevents context loss during auto-compaction.

## Usage

```bash
./install.sh                           # Install
cc-resilient -d ~/myproject            # Run with crash recovery
cc-resilient -d ~/myproject --verbose  # With logging
cc-resilient -s "session-id" -d ~/myproject  # Resume specific session
```
