---
description: Write a session handoff onto this branch's scratch shelf for the next session.
argument-hint: What the next session will focus on (default: for the next session to continue)
disable-model-invocation: false
allowed-tools: Bash("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/dewey-decimal/shelf.sh":*)
---

Write a session handoff so a later session can continue this task.

## Handoff path

`shelf.sh handoff` already ran. It added the ledger row. Its output:

!`"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/dewey-decimal/shelf.sh" handoff 2>&1 || echo "exit=$?"`

- A path: write the handoff document to that exact path.
- `exit=3`: the branch is a trunk or HEAD is detached. Ask the user whether to shelve there. If yes, run `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/dewey-decimal/shelf.sh" -y handoff` and use the path it prints.
- `exit=2`: not a git repo. Ask the user where to write the handoff.

## Worktree

If the work lives in a linked worktree that is not this session's checkout:

- Run `shelf.sh handoff` again from inside the worktree (`cd <worktree> && ...`) and write to that path, so the handoff lands on the worktree's shelf. Ignore the path above.
- Then remove the unused row for the path above: `shelf.sh drop <path relative to its shelf, e.g. handoff/handoff.<timestamp>.md>`. Run it from this session's checkout. Without it, that row stays pending.
- Put a field near the top of the document: `Worktree: <absolute path> (branch <branch>)`. The resuming session reads it and calls `EnterWorktree`.
- Tell the next session to give subagents the worktree path in their brief. `isolation: "worktree"` cannot target an existing worktree.

## Content

Follow the `handoff` skill below for the content. The path above replaces its save location.

!`awk 'n >= 2; /^---$/ { n++ }' ~/.agents/skills/handoff/SKILL.md`

Focus for the next session: $ARGUMENTS

When that line carries no text after the colon, the focus is: for the next session to continue. Write the handoff for continuing the current task from where it stands.

Done when the document exists at the path and you have told the user that path.
