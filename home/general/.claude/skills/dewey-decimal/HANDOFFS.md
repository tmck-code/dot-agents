# Session handoffs

A **session handoff** is a document that one session writes so a later session can continue the task. Subagent handoffs are separate and never use this ledger.

`shelf.sh` owns the ledger (`<shelf>/HANDOFF.md`). Change it only through the script.

The `/handoff-write` command writes handoffs. This file covers resuming.

## Resuming (from `pending:` lines)

- If the user explicitly asked to resume (`/handoff-resume`, or "pick up the handoff"), read the newest pending document without asking.
- Otherwise, list every pending line (path, `written_at`, `written_by`) and ask which one to resume, if any. Older ones are usually replaced by the newest. Do not read a handoff until the user says yes. If they decline, do not ask again this session.
- Report any `MISSING` line to the user. Keep its ledger row.

## After reading

Run `shelf.sh read <handoff>`, where `<handoff>` is the path from the `pending:` line. This records the reader once. Rows that are already read are left unchanged.

## Worktree handoffs

A `pending:` line ending in `worktree=<path>` means the handoff has a `Worktree:` field (absolute path and branch). Enter that worktree before any other work:

1. Load the deferred tool with ToolSearch `select:EnterWorktree`, then call `EnterWorktree` with the path. Paths outside `.claude/worktrees/` need user approval unless in bypassPermissions mode. Such a path is accepted only on first entry; a session already inside a worktree session may enter only worktrees under `.claude/worktrees/`.
2. Run `shelf.sh start` from the worktree. Its shelf is the worktree's, not the one the handoff was read from.
3. If `EnterWorktree` fails or is unavailable, tell the user plainly: the session stays anchored in the main checkout (directory and statusline branch are the main checkout's) and work happens by path (`cd <worktree> && ...`).

`cd` in a Bash call does not move the session: Claude Code resets the shell directory after each call, and the statusline keeps the main checkout's branch. Only `EnterWorktree`, or starting the session inside the worktree, moves it. Do not work in the worktree by `cd` alone while `EnterWorktree` is possible. Subagent `isolation: "worktree"` always creates a new temporary worktree and cannot target an existing one. Give subagents the worktree path in their brief.
