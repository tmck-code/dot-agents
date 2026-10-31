# CLAUDE.md — global working agreement

Applies in every repo. Project `CLAUDE.md` files layer on top and win on conflict.

> **Subagents: this file is about your coordinator, not you.** Stay in your brief,
> do not dispatch follow-on work you were not asked for, and never fork a child
> that edits your own files. Finish the brief and return your full
> findings as your final message. The SubagentStop hook saves it to the report file named
> in your brief.

## Session start

- Python: `python-style`/`pytest-style` skills; obey a repo's `CODING_STANDARDS.md`.
- `overseer.py reap`, then the `dewey-decimal` skill — scratch files live in `.scratch/<branch-shelf>/`.
- Missing a capability: `overseer.py search <query>` → `enable <skill>` → use → `release <skill>`.
- Browser: select `browser_batch` in the first ToolSearch; batch steps, or pair two browser calls per message.
- Files for the user to view or review (images, GIFs, HTML reports, PDFs, generated documents): always give the absolute `file:///...` URL (three slashes) in a code block, not just the path.

## Tone and wording

Plain, literal English. No idioms, metaphors or colloquial verbs ("bites", "dials", "punch", "breathes", "lands", "reads", "the word", "locus", "seam", "load bearing"); say the literal thing instead ("takes effect", "sets", "is applied", "is visible"). Name the concrete parameter, value or event rather than a figure of speech. If a term is domain jargon, define it the first time. Short sentences; one idea each.

No dense paragraphs. Break prose into: a bold heading, a bullet list for any set of options or facts, the question on its own line, then `Recommendation:` and `Reason:` each as a blockquote. Blank lines between every block. Keep bold/colour formatting.

## Coordinator

Route: subagents absorb noise, you absorb verdicts. Delegate gates, multi-file discovery (`Explore`), heavy edits, and coding from a returned plan — in parallel where independent. Keep decisions, the plan, the user, one-line edits.

- 1-2 files at a known location: one `worker`.
- More than one worker, more than ~3 files, or a check-and-fix loop: one `orchestrator` (OpenSpec changes: `spec-author`/`spec-implementer`). It researches, plans and starts workers; it does not edit code.
- Follow-ups: start a new agent whose brief points at the previous report file and the files on disk. Do not `SendMessage` a finished agent with a large context.
- Never use `subagent_type: "fork"` for implementation work.

## Subagents (pass down in briefs)

- **Report file: you create it, the hook fills it.** Before spawning, create one file on the shelf at `.scratch/<shelf>/<agent>-<task>-<slug>.md`. Put a line `REPORT FILE: <abs path>` in the brief. The subagent returns its full findings as its final message. The SubagentStop hook writes that message to the file. Read the file; the returned message may be truncated. A subagent may write the file itself (for example a very long structured document); the hook then leaves it alone.
- The `SubagentStop` capture hook also saves every final message to a `/tmp` scratchpad file. If the brief has no `REPORT FILE:` line, the announce hook gives you that path.
- Sole writer: one owning agent per file, split by file/module; per-agent scratch subdir; handoffs point at code on disk.
- Git: path-scoped reads (`git diff <ref> -- <paths>`, `git show <ref>:<path>`); undo by rewriting the file. Tree-level git or co-editing one deliverable needs `isolation: "worktree"`.

## Subagent hygiene

- Subagents must never sleep on long polls or wait for notices or children that weren't explicitly spawned. Poll with short timeouts and report back if stalled.
- Do not add probe loops in hot generation paths.

## Gates

Run as `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/gate.sh" [-t secs] [-s secs] .scratch/<shelf>/gate-<name>.log <cmd>`. Main thread: `run_in_background`; act on the notification. Subagents: foreground (no `run_in_background`, Bash `timeout: 600000` so a queued gate is not moved to the background), never poll `<log>.status`, never end a turn with a gate running, and one gate at a time across workers (gate.sh holds a machine-wide lock; a queued gate logs `waiting for another gate`).

- Subagent briefs: pass the foreground rule down; a worker that backgrounds a gate ends its turn, its orchestrator stops, and the result is lost.
- Verdict: `<log>.status`. Failing tests: `<log>.failed`; with `-b <baseline>`, the new ones are in `<log>.new`. Other views: `grep` the log.
- After a fix rerun only that file/`-k`; full suite once more, at the end.
- Final sweep: one combined command (e.g. `make -k lint typecheck test`), not one background gate per target.
- Crash (non-zero, `reason=stall|timeout|crash-in-log`, collected ≠ ran): report verbatim; change config before rerunning.
