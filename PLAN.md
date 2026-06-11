# giroux.nvim — steering-plane implementation plan

The phased build plan and the status of each phase. DESIGN.md owns the
*why*, ARCHITECTURE.md the *what*; this is the *order*.

## The governing decision

**Nothing forces sessions through giroux.** the workflow stays exactly:
new ghostty tab → cd to the repo → `claude --dangerously-skip-permissions`.
A shell wrapper transparently lands that in tmux, which is all steering
needs. `:GirouxDispatch` is an *additional* entry point (remote nodes,
worktrees, preloaded context), never the required one.

Design choices:
- tmux inside ghostty: **minimal one-line status** (session name visible),
  mouse on so the wheel scrolls naturally.
- Capture: **automatic** — a `claude()` zsh function wraps every interactive
  hand-started session. `command claude` is the raw escape hatch.
- Naming: **full treatment** — deterministic `giroux/<dir>-<id>` at start,
  ghostty tab title via tmux `set-titles`, then auto-rename to the
  transcript's `ai-title` once it appears

- Order: **transport fix first**, then capture → dispatch → steering.

## Phase 1 — transport: one merged tail per node (the MaxSessions fix)

**STATUS: SHIPPED 2026-06-11.** Verified live: 9 real sessions → 1 node
stream, feed rides it and falls back on monitor stop; 45 specs green.

Problem: one `ssh tail -F` channel per session blows sshd's
`MaxSessions` (default 10) with a handful of sessions + discovery + feeds.

- `ssh.lua`: add `multi_tail(host, files, on_line, on_exit)` — single remote
  command tailing every active file, each line prefixed with its path:
  `for f in <files>; do tail -c +<off> -F "$f" | awk -v p="$f" '{ print p "\t" $0; fflush() }' & done; wait`
  (awk for portable line-buffering; BSD sed's `-l` works on macOS but awk
  gates Linux nodes for free). Demux is stateless: split on first TAB.
- `monitor.lua`: one stream per node, trackers become demux targets keyed by
  path. Discovery reconcile diffs the active set; any change restarts the
  node's stream with per-file resume offsets (cheap, ≤ every
  `discover_interval`). Keep per-file skip-partial on seed.
- `feed.lua`: subscribe to the monitor's per-session line flow
  (`monitor.subscribe_lines(node, path, fn)`) instead of opening its own
  tail — kills the double-tail.
- Tests: demux spec (prefixed chunks, split mid-line), restart-with-offsets
  spec. Bar: gauntlet 0 crashes, roster behavior unchanged but channel count
  = O(nodes).

## Phase 2 — tmux capture layer

**STATUS: SHIPPED 2026-06-11** (wrapper + tmuxctl correlation + ai-title
renames; installed in the operator's ~/.zshrc on workhorse; not yet on other nodes).

- Ship `scripts/claude-wrapper.zsh` + an installer that appends a source
  line to the node's `~/.zshrc`:
  - passthrough when: `$TMUX` set, stdin/stdout not a TTY, or args contain
    `-p`/`--print` (headless — parole's `A` dispatches must stay raw jobs).
  - else: `id=$(uuidgen ...)`, `name=giroux/$(basename $PWD)-${id:0:6}`,
    `tmux new-session -A -s $name -e GIROUX_SESSION_ID=$id -c $PWD
    <absolute claude path> "$@"` (absolute path = recursion-safe).
  - per-session tmux options: minimal status (`status-left "#S"`, quiet
    style), `mouse on`, `set-titles on` with a string that drives the
    ghostty tab title.
- New `tmuxctl.lua`: correlation + control.
  - `panes()`: `tmux list-sessions/list-panes -F` + `show-environment -t`
    → map GIROUX_SESSION_ID / pane_current_path → tmux target.
  - correlate transcript ↔ pane: cwd match (+ recency) confirmed by env id.
  - `rename(target, title)`: on the monitor's `ai-title` session_meta event,
    rename the tmux session to a sanitized short title (rate-limited; never
    fight a manual rename — only rename while the name is still the one the
    wrapper minted).
- Roster: steerable sessions get a marker; correlation failures degrade to
  observe-only (today's behavior), never error.
- Tests: pure correlation specs over canned `tmux -F` output; a local-tmux
  scripted smoke for the wrapper (spawn, env var present, title set).

## Phase 3 — dispatch (`:GirouxDispatch`, roster `n`)

**STATUS: SHIPPED 2026-06-11.** Verified live (real claude in tmux): node→
repo→worktree→context→detached launch, auto-accepts the folder-trust dialog
(dispatching IS the trust decision), follows the new transcript onto the
roster + feed.

- Flow: node → directory (configured roots, `find` over ssh) → optional
  fresh worktree/branch → context compose split (parole-style: `:w` sends)
  → `ssh node 'tmux new-session -d -s giroux/<id> -e GIROUX_SESSION_ID=<id>
  -c <dir> claude <config.dispatch.args> "<prompt>"'`.
- `config.dispatch.args` default `{ "--dangerously-skip-permissions" }`
  (the standing default — mirrors parole's yolo lever being on).
- Shows on the roster within one discovery tick; feed opens on dispatch.
- Later (API stable): parole delegates its agent dispatch here — parole
  builds the PR worktree, giroux owns the session lifecycle.

## Phase 4 — steering (all three together, per DESIGN)

**STATUS: SHIPPED 2026-06-11** (send, steer buffer, attach, answer-pick).
Verified live end-to-end against a real claude session: send queues a
message, answer-pick selects an AskUserQuestion option, attach opens the
TUI. `:GirouxClean` still a stub (notifies).

**KEY FINDING that reshaped answer-pick — Claude Code writes an
AskUserQuestion `tool_use` record only when the question is ANSWERED, never
while it is pending (verified: 24/24 records in the real corpus are
resolved; a live pending question is absent from the transcript until
answered).** Consequences:
- The transcript-derived `?` state in DESIGN §4 / `sessions.derive_state`
  **cannot fire from a pure tail** — by the time the question is in the
  file it is already answered. The roster `?` glyph is effectively dead for
  transcript-only (non-tmux) sessions. **TODO (phase 5):** derive `?` for
  tmux-correlated sessions by reading the pane (steer.parse_question), not
  the pending-set. Keep transcript `?` as a best-effort fallback.
- Answer-pick therefore reads the live question off the **tmux pane**
  (`steer.read_question` → `steer.parse_question` → `vim.ui.select` →
  `steer.answer` sends the bare digit, which the picker selects instantly).
  Feed `<CR>` on a rendered (already-answered) option line triggers a fresh
  pane read so it still works on the current live question.

- `steer.lua` core: `send(session, text)` — multiline via
  `tmux load-buffer -` + `paste-buffer -t <target>` then `send-keys Enter`.
- **Answer-pick**: on a `?` session the feed already renders options; cursor
  one and `<CR>` drives the TUI selection via send-keys (research item:
  arrow-key sequence vs typing the option — verify against the real
  AskUserQuestion UI before committing; fall back to the steer buffer's
  free text for "Other").
- **Steer buffer**: `giroux://steer/<id>` scratch split; `:w` sends (queues
  if the agent is mid-turn — Claude Code queues typed input), `q` aborts.
- **Attach**: roster/feed `a` → terminal tab running
  `ssh -t node tmux attach -t <target>` (plain `tmux attach` locally);
  detach returns. Reuse parole's terminal ergonomics: Esc passes through,
  `<C-q>` to normal mode.
- `:GirouxClean`: reap tmux sessions whose transcript state is ✗/~ (confirm
  first), prune correlation cache.

## Phase 5 — pane-`?`, notifications, clean — STATUS: SHIPPED 2026-06-11

- **Pane-`?` into the roster**: `monitor.probe_questions()` runs each
  discovery tick; for a tmux-correlated tracker whose transcript signature
  is ambiguous (open turn, nothing pending, briefly quiet) it captures the
  pane once and confirms a live AskUserQuestion → state `?`. Verified live:
  a dispatched session asking "Proceed?" flipped to `?` and notified; the
  idle real session stayed `○` (no false positive).
- **Notifications** (`notify.lua`): statusline badge
  (`%{v:lua.require'giroux.notify'.statusline()}`), `vim.notify`, macOS
  osascript per `config.notify.levels`. Fires on state ENTRY only;
  conditions already true on first sight are seeded silently (counted on
  the badge, no banner) so opening `:Giroux` over old dead sessions doesn't
  spam. Tripwires (`stats.tripwire`) ride the question channel.
- **`:GirouxClean`**: reaps detached giroux tmux sessions idle past
  `dispatch.IDLE_REAP_SECS` (30m); a running agent keeps its session alive
  so it's never touched.

### Backlog (post-phase-5, not blocking dogfood)

- parole ↔ giroux handoff: feed detects "PR opened" → offer `:Parole <url>`;
  parole's interactive dispatch optionally delegates to giroux dispatch.
- Worktree pruning in `:GirouxClean` (merged dispatch branches).
- diffs tier 2: `v` → `git diff` in a session's worktree over SSH.
- Linux node support (`stat -c`), once a Linux node comes online.

## Working agreements

- Verify each phase against real sessions headlessly before claiming done;
  gauntlet after any parser-adjacent change.
- `nvim -l tests/run.lua` green; add pure-logic specs alongside features.
- Clean commit messages, no AI trailers. nvim = bob nightly (vim.pack).
