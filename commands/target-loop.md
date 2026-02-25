---
description: "Start Target Loop - verified iteration until all targets pass"
argument-hint: "PROMPT [--max-iterations N] [--targets-file PATH]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ccr:*)"]
hide-from-slash-command-tool: "true"
---

# Target Loop Command

Execute the setup script to initialize the target loop:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ccr" setup $ARGUMENTS
```

You are now in a **target-verified iteration loop**. This is NOT ralph-loop.

## How This Works
1. You will create a project outline with specific TARGETS
2. Each target has a VERIFICATION COMMAND (shell command, exit 0 = pass)
3. You write code to make targets pass
4. When you try to exit, the loop runs ALL verification commands automatically
5. You'll see REAL results — what passed, what failed, actual error output
6. The loop continues until ALL targets pass or max iterations reached

## Phase 1: Create Your Outline
Write a targets file to `.claude/targets.local.yaml` with this EXACT format:

```yaml
project: "Project Name"
targets:
  - id: T1
    name: "Short name"
    description: "What this target means"
    verify: "shell command that exits 0 on success"
    depends: []
  - id: T2
    name: "Short name"
    description: "What this target means"
    verify: "shell command that exits 0 on success"
    depends: ["T1"]
```

Guidelines:
- 3-7 targets, incremental (foundations first)
- Every target MUST have a verify command that returns exit 0 on success
- Common patterns: `npm run build`, `npm test`, `test -f path`, `curl -sf URL`, `grep -q "pattern" file`
- Do NOT use subjective checks — only objective shell commands

After writing the targets file, tell the user to review it. Do NOT start coding until approved.

## Phase 2: Build
Once approved, work through targets in order (T1 → T2 → T3...).

## CRITICAL RULES
- Do NOT modify `.claude/targets.local.yaml` after approval
- Do NOT modify test files to make tests pass
- Do NOT self-assess quality — the verification script does that
- Do NOT suggest stopping early — the loop decides when you're done
- Focus on making code ACTUALLY pass the verify commands
