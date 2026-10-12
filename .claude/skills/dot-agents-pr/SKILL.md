---
name: dot-agents-pr
description: Draft or rewrite a pull request for the dot-agents repo in its house style. Use when asked to open, draft, write up or edit a PR here.
---

# dot-agents PR

A PR here is a short, literal change log. One sentence says why; bullets say what; images show diagrams; a closing section names what the reviewer must know. Plain English, short sentences, no idioms. Match the voice of PRs #1 to #3.

## Steps

1. **Collect the diff.** Run `git log --oneline origin/main..HEAD` and `git diff --stat origin/main`. If local `main` carries commits that `origin/main` lacks, they ride along: open the summary with one sentence naming them and their hashes (PR #2 does this).
2. **Title.** One line, sentence case, no trailing period. Lead with the component when the change is scoped to one, as `excalidraw-diagram: house style, dual-mode export`. Join two deliverables with a semicolon, as `Track the four local hooks; add hook canvas diagram`.
3. **Body.** Follow the skeleton below. Every section earns its place; drop an empty one.
4. **Images.** Each diagram the PR adds is rendered, committed under `docs/` and embedded. Pushed file: `![alt](https://raw.githubusercontent.com/<owner>/<repo>/<branch>/docs/<file>.png)`. Hand-uploaded file: keep the `<img width height alt src>` tag GitHub emits. Several diagrams go in a two-column `| title | img |` table.
5. **Create.** `gh pr create --draft --base main` with the body from a heredoc. End the body with the attribution line in force for the session.
6. **Verify.** `gh pr view --json body` and read it back. A table whose pipes render literally failed to parse; see Tables.

## Skeleton

```markdown
## Summary

<One sentence: what this brings in and why.>

- **<Bold lead>**: <what changed>, with paths in backticks.
- **<Bold lead>**: ...

**<Group heading>** (`<path or scope>`)
- <bullet>

## <Diagram name>

<image or image table>

## Things to know

- <A fact the reviewer needs: what is not wired, what lags, what was left for another PR.>

## Test plan

- [x] `<command that was run>`
```

Section names in use: `Summary` (always, first), a named diagram section, `Things to know`, `Test plan`, `Deploying`.

## Voice

- Bullets start with a bold lead of two to four words, then a colon.
- State what a thing does, not what it is: "PreToolUse guard that intercepts Bash calls containing npm".
- Paths, flags, file names and settings keys go in backticks. At most one per sentence.
- Name the gap honestly. If a hook is tracked but not registered, say so and give the entry that would register it.
- Numbers only when they change what the reader does.

## Tables

GitHub tables break in two ways that both show as literal pipes:

- **No blank line before the table.** A table cannot interrupt a paragraph or a bullet. Put an empty line between a bullet and a table nested under it, and keep the table's indent equal to the bullet's content.
- **A newline inside a cell.** Lists in a cell are `<ul><li>…</li></ul>` on one line; line breaks are `<br/>`. Backticks still render as code inside them.

Worked example: the hook table nested under the first Summary bullet of PR #3, with a lead phrase, `<br/>`, then a `<ul>` per cell.
