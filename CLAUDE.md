# Claude View - Autonomous Remote Control

You have a mobile web UI connected via the `claude-view` MCP server. The user monitors and controls you from their phone, NOT from the terminal.

## On Startup

When you first start, IMMEDIATELY:
1. Use `notify` to announce you're ready (e.g., "Claude is ready in <repo-name>!")
2. Use `status` to show "Ready - waiting for instructions"
3. Use `inbox` to check for any queued instructions
4. If inbox has instructions, process them. Otherwise, end your turn and wait.

## Keepalive

When you see a stop hook message containing "[KEEPALIVE]":
- Do NOT generate a lengthy response or do any work
- Just call `inbox` to check for queued instructions
- If inbox has instructions, process them
- If inbox is empty, end your turn immediately with a brief "Waiting for instructions."

## CRITICAL: How Instructions Arrive

Instructions arrive via the **Stop hook**. When you see:
> "Stop hook feedback: New instruction from user: ..."

That IS the user talking to you from their phone. You MUST:
1. Use the `notify` MCP tool to acknowledge you received it
2. Use the `status` MCP tool to show what you're working on
3. Do the work
4. Use `notify` with level `success` when done

**The user cannot see your terminal.** If you only respond in text, they see nothing. You MUST use the MCP tools to communicate.

## MCP Tools Available

These are your ONLY way to communicate with the user:

- **`notify`** - Send progress updates, results, warnings, errors to the user's phone
- **`ask`** - Ask a question and WAIT for the user's response (blocks until they reply, 5 min timeout)
- **`inbox`** - Check for new instructions the user has queued up
- **`status`** - Update the status bar showing what you're working on

## Rules

1. **ALWAYS respond via MCP tools** - The user is on their phone, not at the terminal. Text output is invisible to them.
2. **Use MCP tools, NOT AskUserQuestion** - AskUserQuestion shows in the terminal which the user cannot see.
3. **Acknowledge every instruction** - When you get a stop hook instruction, immediately `notify` that you received it.
4. **Work independently** - Only use `ask` when genuinely blocked and need a decision.
5. **Check inbox between tasks** - The user may have queued new instructions.
6. **Update status at milestones** - Not every step, just major phase changes.
7. **Keep `ask` options short** - The user is tapping on a phone screen.
8. **Report completion with `notify`** - Use `success` level when a task is done.
9. **Report errors with `notify`** - Use `error` level so it stands out on the phone.
10. **Be concise** - Mobile screen is small, keep messages brief.

## Example Flow

1. You finish a task, the stop hook fires
2. User sends "Add a login page" from their phone
3. You see: `Stop hook feedback: New instruction from user: Add a login page`
4. You call `notify` with "Got it! Working on login page."
5. You call `status` with "Building login page"
6. You do the work
7. You call `notify` with level `success`: "Login page complete!"
8. Stop hook fires again, you wait for next instruction
