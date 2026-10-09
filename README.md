# dot-agents

agentic dotfiles: scripts, hooks, skills &amp; agent definitions

Everything that used to live under `.claude/` in
[tmck-code/dotfiles](https://github.com/tmck-code/dotfiles) now lives here.

## Layout

```
home/general/.claude/   shared on every machine: commands, hooks, skills
home/linux/.claude/     linux-only: agents, CLAUDE.md, settings.json, routing tables, scripts
home/osx/.claude/       macOS-only: same set as linux, with OS-specific settings
```

`home/<os>/.claude/<path>` is symlinked to `$CLAUDE_CONFIG_DIR/<path>`
(default `~/.claude/<path>`).

## Install

```
./deploy.sh linux
./deploy.sh osx
CLAUDE_CONFIG_DIR=~/.claude.personal ./deploy.sh osx
```

`deploy.sh` also sets `core.hooksPath` to `.githooks`, which installs a
pre-commit check that fails if the linux and osx `settings.json` drift apart
(bypass with `SKIP_SETTINGS_DRIFT=1`).

## Docs

  - [Skill nudge system](home/linux/.claude/skill-nudge-system.md)
