# giroux.nvim — architecture

The state of the build as of 2026-06-11. For the *why* behind each decision
see [DESIGN.md](DESIGN.md); this doc is the *what* and *how* — the map a new
contributor needs.

## The one idea

A Claude Code session writes a **lossless JSONL transcript** to
`~/.claude/projects/<cwd-slug>/<uuid>.jsonl`: every assistant message,
thinking block, `tool_use` (with full input — the exact bash command, the
Edit old/new strings, the URL), `tool_result` (full output), token usage.
Tailing that file **cannot interrupt the session** (it's a file read), so it
is a complete, non-invasive observation plane. Everything giroux shows is a
render of that substrate, local or remote, over plain SSH. The only thing
that needs a *way in* is steering — and that rides tmux (not yet built).

## Data flow

```
                  ssh (ControlMaster mux, no daemon on nodes)
  remote/local file ──tail -F / cat──▶ ssh.lua ──chunks──▶ transcript.lua
                                                              │ parser:feed()
                                                              ▼
                                                   normalized events
                                  ┌───────────────┬──────────┴───────┬─────────────┐
                                  ▼               ▼                  ▼             ▼
                              feed.lua        monitor.lua         stats.lua      qa.lua
                            (live buffer)   (roster trackers)  (aggregation)  (digest)
                                  │               │                  │             │
                                  ▼               ▼                  ▼             ▼
                          :GirouxFeed        :Giroux            :Giroux S      :GirouxQA
                                          (live roster)        statsheet.lua
```

## Modules (`lua/giroux/`)

| module | role |
|---|---|
| `init.lua` | config schema + defaults + `setup()`. The opinionated knobs live here (skip-permissions default, tripwires, notify levels, keymaps, scrollback). |
| `ssh.lua` | transport. `exec` (one-shot), `stream` (long-lived stdout), `tail` (follow a file from a byte offset). `host = nil` runs locally. No daemon; everything shells out over the ControlMaster mux. |
| `nodes.lua` | tailnet node resolution. `config.nodes` + an implicit `local` node. |
| `transcript.lua` | **the core.** Two layers: (1) a byte-chunk → line assembler with offsets (resume-after-disconnect, partial-tail buffering); (2) a record → normalized-event parser (19 event kinds). Grounded in a census of 264 real transcripts (CC 2.1.85–2.1.172). The pending-set (unresolved `tool_use` ids) *is* the working/question state proof. |
| `sessions.lua` | discovery + per-tail state derivation. `list()` = cheap stat-only active-file discovery; `scan()` = one-shot list+state via 32KB tails; `derive_state()` = the 5-state proof (●/?/○/✗/~). |
| `monitor.lua` | **realtime backbone.** Holds a persistent `tail -F` per active session, parses locally, derives state, and notifies subscribers on an 80ms debounce. Cheap discovery decides which sessions to track. The roster renders off this. |
| `roster.lua` | `:Giroux` — the board. One line per session, attention-sorted, live off a monitor subscription. |
| `feed.lua` | `:GirouxFeed` — the live per-session buffer. Foldable tool one-liners, inline diffs (from `structuredPatch`), wrap-proof user-message decoration, native question rendering, reconnect-with-backoff, follow-the-tail. Opens from a tail window (`initial_tail`, 1MB) for instant open on huge files. |
| `stats.lua` | pure aggregation over events: written set (with diffstat), read set (context provenance), web, spend, tool counts, subagents. Plus the glob matcher + `tripwire()` (fires when an agent reads/writes a flagged path). |
| `statsheet.lua` | `S` — full-parse a session over SSH into a `giroux://stats` buffer. Files are actionable (`<CR>`). |
| `qa.lua` | `:GirouxQA` / `Q` — the digest. Groups events into exchanges (turn + prose answer + tool tally); `<CR>` drills into the feed at that turn. |
| `tmuxctl.lua` | tmux correlation + control. Maps a transcript to the tmux session the claude-wrapper minted (cwd-slug match, creation-time tiebreak), renames it to the transcript's ai-title (`giroux/t/<slug>`, never fighting manual names), caches per-node listings. `scripts/claude-wrapper.zsh` is the capture side: interactive `claude` lands in `tmux` with `GIROUX_SESSION_ID`, minimal status, mouse, set-titles. |
| `dispatch.lua` | `:GirouxDispatch` — node→repo→worktree→context→detached `tmux new-session` + claude (GIROUX_SESSION_ID injected), auto-accepts the folder-trust dialog, follows the new transcript onto the roster/feed. |
| `steer.lua` | the steering plane on tmuxctl correlation: `send` (base64 paste-buffer + Enter), `buffer` (compose split, :w sends), `attach` (TUI in a terminal tab; ssh -t for remote), `answer`/`pick`/`read_question`/`parse_question` (answer-pick reads the live picker off the tmux pane — see the AskUserQuestion finding below). Uncorrelated sessions degrade to observe-only. |
| `notify.lua` | interrupt-worthy moments → channels (`config.notify.levels`: statusline badge / `vim.notify` / macOS osascript). Fires on state ENTRY; conditions already true on first sight seed silently (badge only). `statusline()` is a user statusline component. |
| `health.lua` | `:checkhealth giroux` (stub). |

## Conventions worth keeping

- **Pure renderers are unit-tested without a buffer** (`M._call_head`,
  `M._result_suffix`, `qa._build`, `qa._render`, `statsheet.render`,
  `sessions.parse_scan`). Buffer wiring is integration-tested headlessly.
- **Every top-level transcript field is optional**; unknown record/block
  types degrade to `unknown`/`other` events, never crash. Proven by the
  gauntlet (`scripts/gauntlet.lua`): 264 files / 121MB / 0 crashes.
- **Display hygiene**: giroux windows force `list/number/signcolumn` so the
  user's `listchars` etc. don't bleed in. User-message emphasis is done with
  **extmark line-highlight + sign**, never text rules (they fight wrap).
- **State is proven, never guessed**: ● = unresolved tool_use; ? = unresolved
  AskUserQuestion; ○ = clean turn end; ✗ = pending work but process gone;
  ~ = stale by file mtime. mtime (from discovery) drives staleness, not read
  time.
- LuaCATS annotations on public functions; parole-style `scripts/smoke.lua`
  asserts every module loads + config merges.

## Test & verify

```
nvim -l tests/run.lua            # unit + integration specs (39 currently)
nvim -l scripts/smoke.lua        # every module loads, config merges
nvim -l scripts/gauntlet.lua DIR # stream every real transcript, prove 0 crashes
```

## Transport (post merged-tail refactor, 2026-06-11)

One ssh channel per node, not per session: `ssh.multi_tail` runs every
active file's `tail -c +<off> -F` remotely, line-prefixed (`<path>\t<line>`
via awk with per-line fflush) and demuxed locally (`ssh.demux`). The monitor
holds one stream per node; trackers are demux targets; discovery changes
rebuild the node's stream with per-file resume offsets. Feeds ride the same
stream via `monitor.subscribe_lines(node, path, on_line, on_drop)` —
on_line carries the line's byte offset so the feed drops what its own
window snapshot already covered; on_drop (monitor stopped tracking) falls
back to an owned `tail -F`. A `trap 'kill $(jobs -p)'` reaps the remote
tails on disconnect (never `kill 0` — locally that's nvim's process group).

## The AskUserQuestion transcript finding (2026-06-11)

Claude Code writes an `AskUserQuestion` `tool_use` record **only when the
question is answered**, paired with its result — never while it is pending
(verified: 24/24 records across the real corpus are resolved; a live
pending question is absent from the JSONL until answered). So the
transcript-derived `?` state (DESIGN §4) **cannot fire from a pure tail**.
A *live* question exists only on the tmux pane; `steer.parse_question`
reads it from `tmux capture-pane`, and that — not the parser pending-set —
is the real source for `?` on a tmux-correlated session. The pending-set
still correctly proves `●` for every *other* tool. (Phase-5 TODO: feed the
pane-derived `?` into the roster for tmux sessions.)

## Known issues / tech debt

- `?` roster state is dead for non-tmux (observe-only) sessions — see the
  finding above; needs pane-based detection for tmux sessions (phase 5).
- `sessions.lua`/`monitor.lua` use BSD `stat` (macOS). Linux nodes need
  `stat -c '%Y %s %W'`. Gate on node OS when a Linux node comes online.
- `nodes.lua`: `host = false` means "local" (used by tests for fake roots).
- `:GirouxClean` is still a stub.
