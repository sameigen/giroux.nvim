# CLAUDE.md — giroux.nvim

giroux.nvim is a Neovim plugin for observing and steering Claude Code agent sessions
across a Tailscale network — it tails session transcripts for a lossless live feed
(tool calls, diffs, bash output) without getting between the agent and its work.
Shared roadmap with parole.nvim: `~/Code/personal/giroux-parole-roadmap.md`.

## Commands

- Tests: `nvim -l tests/run.lua` (filter: `nvim -l tests/run.lua <name>`)
- Smoke (modules load, config merges): `nvim -l scripts/smoke.lua`
- Gauntlet (stream real transcripts, prove 0 crashes): `nvim -l scripts/gauntlet.lua <dir>`
- Format: `stylua --check lua/ tests/` (fix with `stylua lua/ tests/`)
- Lint: `selene lua/ tests/`
- Typecheck: runs in CI (nvim-typecheck-action on `lua/`, Error level)

## Conventions

- **Commit messages: no AI trailers** (PLAN.md working agreement). Terse,
  lowercase, module-prefixed — e.g. `monitor: freshness-gate the title spinner`.
- Pure logic is unit-tested without a buffer; buffer wiring is integration-tested
  headlessly. Add specs for new pure logic (CONTRIBUTING.md).
- Every top-level transcript field is optional — never crash on unknown records;
  emit an `unknown`/`other` event. The gauntlet is the bar.
- State is *proven*, not guessed (DESIGN.md §4).
- LuaCATS annotations on public functions.
- Deeper rationale: DESIGN.md (why), ARCHITECTURE.md (what/how), CONTRIBUTING.md.

## Hub

This project is registered in Sam's ops hub: `~/Code/personal/hub`. Read
`projects/giroux.nvim.md` there for cross-project context, `STATUS.md` for the big picture.
- End substantive sessions with `~/Code/personal/hub/bin/hub post giroux.nvim "<one-paragraph digest of what changed>"`.
- When giroux.nvim's state meaningfully changes, update `~/Code/personal/hub/projects/giroux.nvim.md`
  (append to its Log, absolute dates only).
- Push your commits before ending the session — unpushed work is invisible to other machines (the nightly digest nags about it).
