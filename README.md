# cc-resilience

Crash-resilient automation for Claude Code. Verified iteration loops + automatic crash recovery.

**658 lines. Zero inline Python. Crash recovery proven.**

## What This Does

Two problems, one system:

1. **Crash Recovery** — Claude Code crashes (overloaded, context overflow, network errors). `recover.sh` catches the crash, classifies it, and auto-recovers: retry, resume, or fresh session with context extracted from JSONL.

2. **Verified Iteration** — Claude says "done" but the code doesn't work. The target loop blocks exit until objective verification commands (shell commands, exit 0 = pass) actually pass. No self-assessment. No trust. Just exit codes.

## Architecture

```
ccr                 Python CLI — ALL data processing
hooks/stop.sh       Stop hook — thin wrapper → ccr stop-hook  
hooks/precompact.sh Save state before context compaction
hooks/postcompact.sh Restore state after compaction
loop.sh             Headless iteration loop (claude -p mode)
recover.sh          Crash recovery wrapper
install.sh          Unified installer
commands/           Slash commands (/target-loop, /target-status, /cancel-targets)
```

The key insight: `ccr` is one Python file that owns YAML parsing, JSON handling, state management, verification, prompt generation, error classification, and progress extraction. Bash scripts are thin orchestration — no inline `python3 -c`, no `jq` pipelines, no data processing.

## Quick Start

```bash
# Install (registers hooks, installs plugin + recovery wrapper)
./install.sh

# Crash-resilient Claude session
cc-resilient -d ~/myproject
cc-resilient -d ~/myproject -g "Fix the auth bug" --verbose

# Target loop (interactive — stop hook blocks exit until targets pass)
# Inside Claude:
/target-loop "Build a REST API with auth and tests"

# Target loop (headless — external iteration via claude -p)
cd ~/myproject
ccr setup "Build a REST API" --max-iterations 15
./loop.sh
```

## Target Loop

### How It Works

1. You describe what to build
2. Claude creates `.claude/targets.local.yaml` with verification commands
3. You approve the targets
4. Claude works. When it tries to exit, the stop hook runs every verification command
5. If anything fails → Claude gets the actual error output and keeps working
6. Loop exits only when ALL targets pass or max iterations reached

### Targets File Format

```yaml
targets:
  - id: T1
    name: "API builds"
    verify: "npm run build"
    depends: []
  - id: T2
    name: "Auth tests pass"
    verify: "npm test -- --testNamePattern=auth"
    depends: ["T1"]
  - id: T3
    name: "Health endpoint responds"
    verify: "curl -sf http://localhost:3000/health"
    depends: ["T1"]
```

### Anti-Gaming

- **Tamper detection**: Claude can't modify the targets file or state file after approval — changes are git-reverted
- **Test file protection**: Modifications to test files are detected and reverted
- **Stuck loop detection**: Same error 5+ times → forces fundamentally different approach
- **Objective verification**: Shell commands with exit codes, not self-assessment

### Two Modes

| Mode | How | When |
|------|-----|------|
| **Interactive** | Stop hook fires on exit attempt | Working with Claude manually |
| **Headless** | `loop.sh` runs `claude -p` in a loop | Automation, CI, agent orchestration |

Both share the same verification engine (`ccr verify` + `ccr prompt`).

### Crash-Safe Iteration

`loop.sh` persists `iteration` and `session_id` to the state file after every step. If the process dies:

```bash
# Just restart — picks up where it left off
./loop.sh
# Output: "Resuming session: abc123 from iteration 4"
```

## Crash Recovery

### Error Classification

```bash
echo "529 overloaded" | ccr classify    # → TRANSIENT
echo "image exceeds 5 MB" | ccr classify # → POISON
echo "authentication_error" | ccr classify # → AUTH
```

| Class | Examples | Recovery |
|-------|----------|----------|
| POISON | Image too large, conversation too long | Fresh session + JSONL context recovery |
| CONTEXT | Context limit, input too long | Try continue → fresh session |
| TRANSIENT | 529, ECONNRESET, ETIMEDOUT, 500 | Retry with exponential backoff |
| AUTH | 401, 403, authentication_error | Retry with backoff |
| UNKNOWN | Anything else | Try continue → fresh |

### Usage

```bash
cc-resilient -d ~/myproject                    # Auto-recover crashes
cc-resilient -d ~/myproject -g "Fix auth bug"  # With goal for fresh restarts
cc-resilient -s "session-id" -d ~/myproject    # Resume specific session
cc-resilient --max-retries 10 --verbose        # More retries, verbose logging
```

## ccr CLI Reference

```bash
ccr verify [--status-only]     # Run target verification, output JSON
ccr prompt                     # Generate iteration prompt (stdin: verify JSON)
ccr stop-hook                  # Full stop hook logic (phases + verify + prompt)
ccr setup PROMPT [OPTIONS]     # Create state file for new loop
ccr classify                   # Classify error from stdin
ccr progress PATH [-n N]       # Extract progress from session JSONL
ccr parse-field FIELD          # Extract field from JSON stdin
ccr state FIELD                # Read state file field
ccr update-state key=value     # Update state file fields
```

## Compaction Hooks

Claude Code compacts context when it gets too long. These hooks preserve state across compaction:

- **PreCompact**: Snapshots git diff, uncommitted changes, loop state, test results
- **PostCompact / SessionStart**: Restores the snapshot into context

## Install

```bash
git clone <repo> && cd cc-resilience
./install.sh
```

Requires: `python3`, `jq`, `claude` (Claude Code CLI). PyYAML recommended.

Installs to:
- Plugin: `~/.claude/plugins/local/target-loop/`
- Recovery: `/usr/local/bin/cc-resilient`
- Hooks: `~/.claude/hooks/` + `~/.claude/settings.json`

## Line Count

```
  283  ccr
   52  loop.sh
  159  recover.sh
  106  install.sh
   20  hooks/stop.sh
   28  hooks/precompact.sh
   10  hooks/postcompact.sh
  ───
  658  total
```

## License

MIT
