# Contributing to giroux.nvim

Thanks for taking a look. giroux is small and opinionated; PRs and issues are
welcome.

## Scope

giroux observes and steers Claude Code sessions by tailing their JSONL
transcripts. It supports **macOS and Linux nodes** (discovery is portable:
GNU `stat -c` with a BSD `stat -f` fallback). It is also
**Claude-Code-only** by design — no agent-abstraction layer.

## Development

Dev-link the repo (Neovim 0.12 `vim.pack` or your manager's local/dir source),
then:

```sh
nvim -l tests/run.lua          # unit + integration specs
nvim -l scripts/smoke.lua      # every module loads, config merges
nvim -l scripts/gauntlet.lua ~/.claude/projects   # stream real transcripts, prove 0 crashes
stylua --check lua/ tests/     # formatting (run `stylua lua/ tests/` to fix)
```

CI runs four jobs: `stylua` (format check), `lint` (`selene`), `typecheck`
(`nvim-typecheck-action`), and `test` — smoke + the specs + the gauntlet
(against a committed fixture corpus, `tests/fixtures/transcripts/`) — on
Linux (stable/nightly) and macOS. Integration specs that need `zsh` or BSD
`stat` skip themselves off-platform — see `tests/helpers.lua`
(`skip_unless`).

## Conventions

- Pure logic is unit-tested without a buffer; buffer wiring is integration-
  tested headlessly. Add specs for new pure logic.
- Every top-level transcript field is optional — never crash on unknown
  records; emit an `unknown`/`other` event. The gauntlet is the bar.
- State is *proven*, not guessed (see DESIGN.md §4).
- LuaCATS annotations on public functions. Keep comments terse; rationale
  lives in DESIGN.md / ARCHITECTURE.md.

## Regenerating the demo GIF

`scripts/demo.sh` (needs `asciinema` + `agg`). It's fully scripted and
deterministic — no Claude, API, or real sessions involved.
