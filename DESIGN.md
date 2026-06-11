# giroux.nvim — design tree

Working notes, 2026-06-11. ✅ settled, ❓ open (→ = recommendation).
Named for the captain. Opinionated for Claude Code — no agent abstraction layer.

## 1. The core bet: transcripts are the product ✅

Every Claude Code session — interactive or headless, local or remote — writes
a lossless JSONL transcript to `~/.claude/projects/<cwd-slug>/<uuid>.jsonl`:
assistant text, thinking blocks, every `tool_use` with its **full input**
(the exact bash command, the Edit old/new strings, the WebFetch URL), every
`tool_result` with full output, token usage, model. Subagents land in
`<uuid>/subagents/agent-*.jsonl`.

Tailing that file over SSH is a *complete* observation plane that cannot
interrupt the session (it's a file read). This solves the
wrappers-hide-the-tool-calls problem definitionally: giroux renders the same
substrate the TUI renders, plus what the TUI elides (full outputs, thinking,
subagent internals, spend).

Corollary: **observe and steer are separate planes.** Observation needs zero
cooperation from the session. Steering is the only part that needs a way in.

## 2. Steering plane ✅ tmux-first

Giroux-dispatched agents run as interactive `claude` inside a per-agent tmux
session on the node (`giroux/<name>`). Steering = `send-keys` (identical
semantics to typing: queues while the agent works). Attach = the real TUI in
a terminal split, zero fidelity loss. Disconnect-proof by construction —
bed-wifi drops lose nothing server-side.

Pre-existing bare-terminal sessions: observe-only (roster still sees them via
the passive scan). Handoff model, not co-piloting: **one console at a time**.

Auth on macOS over SSH: the login keychain is locked in non-GUI SSH, so
dispatched/headless claude must use `CLAUDE_CODE_OAUTH_TOKEN` (from
`claude setup-token`, exported in the node's shell rc) — NOT the keychain.
See memory: claude-headless-auth. Default launch flags: `--dangerously-skip-permissions`. This is an
opinionated plugin for a single-operator tailnet; permission prompts are not part of
the loop. Config can override per node/repo, but the product is built around
agents that never stall on permissions — which makes the remaining
"needs-you" states (questions, end of turn) the *entire* attention surface.

## 3. Session inventory ✅ passive scan

`ssh node 'find ~/.claude/projects -name "*.jsonl" -mmin -N'` + tail parse is
the truth — sees every session, giroux-launched or not. The dispatch registry
only annotates tmux coords + steerability.

Corpus facts (2026-06-11 census): subagents nest (`<sess>/subagents/...` can
contain `workflows/wf_*/` trees with their own agent transcripts); exclude
`journal.jsonl` (Workflow-tool journal, different format — parser degrades it
to `unknown` gracefully, but it's not a session). mtime is a proven activity
signal (every append updates it). Max observed line ~400KB (big Read results,
base64 images) — line buffers are unbounded.

## 4. State model ✅ provability is imperative

Each state must be *provable* and *visually distinct*. Two evidence sources,
combined: **semantic truth** from the transcript tail, **process truth** from
tmux (`has-session` / pane alive).

| State | Proof |
|---|---|
| `●` skating (working) | file growing; or last assistant entry has pending `tool_use` with no result, process alive |
| `?` question | pending `AskUserQuestion` tool_use with no result (fully structured — question, options, multiSelect all in the transcript); or turn ended on an interrogative |
| `○` end of turn | last assistant entry `stop_reason: end_turn`, nothing pending |
| `✗` dead | pending work in transcript but tmux pane/process gone (crash, OOM, kill) |
| `~` stale | idle past `active_window`, demoted out of the default roster view |

`?` is the gem: AskUserQuestion's input is in the JSONL *before* it's
answered, so giroux can render the question + options **natively in nvim** —
cursor a line, `<CR>` picks it, giroux translates to the keystrokes the TUI
expects (send-keys). The user never sees the TUI's question chrome unless
they attach. Free-text "Other" = the steer buffer.

## 5. Input funnel ✅ buffer-shaped

Steering is never a floating input() — it's a buffer, fugitive-commit-style:
`s` on a roster/feed line opens a small `gitcommit`-like scratch split
(`giroux://steer/<session>`); write it (`:w` or `ZZ`) to send, `q` to abort.
Same buffer doubles as the answer surface for free-text question replies.
Multi-line prompts, registers, normal-mode editing — all for free.

## 6. Attention routing ✅ tiers

Notify on: **turn complete, questions, dead agents** (permission stalls
removed from the equation by §2). Channels:
- in-nvim: roster badge + statusline segment (`giroux: 2● 1? 1○`) + `vim.notify`
- macOS notification via `osascript` when nvim doesn't have focus (or always — config)
- phase 2: ntfy → toshiro (iOS) for away-from-keyboard

Pushback accepted ✅: with a posse running, turn-complete on every agent gets
noisy — default config: questions + dead = macOS notification; turn-complete
= badge/statusline only. One knob: `notify.levels = { question = "macos",
dead = "macos", end_of_turn = "statusline" }`.

## 7. Delegation (`:GirouxDispatch`) ✅ worktrees always

Pick node → repo on node → prompt (steer buffer) → giroux creates a worktree
(parole's discipline; **always** worktrees — collision rule: two agents never
share a checkout), launches `claude --dangerously-skip-permissions` in tmux,
registers the session. `:GirouxClean` reaps worktrees + dead tmux sessions.
`!` variant = headless `claude -p` for fire-and-forget.

## 8. Feed rendering ❓ details open

One buffer per session (`giroux://feed/<node>/<session>`), append-only.
- Prose: markdown (render-markdown.nvim).
- Tool calls: one-line folds, distinct glyphs:
  `▸ $ cargo test --workspace                    3.2s ✓`
  `▸ ✎ src/api/routes.rs                         +18 −4`  (fold = unified diff, free from Edit inputs)
  `▸ ⌁ GET docs.rs/axum/latest                   200 41KB`
- Thinking folded, toggleable. Subagents: `<CR>` on the Task line drills into
  a nested feed.
- Backfill: open at live tail, scroll-up streams history (1.7MB files exist).
- ❓ filters (bash-only, edits-only) — keep? → yes, cheap, `b`/`e`.

## 9. Diffs ✅ three tiers

1. Transcript-derived (free, instant): Edit/Write inputs → inline unified diffs.
2. Repo truth: `ssh node git -C worktree diff` → diff buffer (diffview later).
3. File access: rsync-on-demand cache under `~/.cache/giroux/<node>/...`.

## 10. Transport ✅ pure SSH, no daemon

Fugitive ethos: shell out. One `ControlMaster auto, ControlPersist 4h` mux
per node (giroux-owned ssh config include); every tail/exec rides it.
Reconnect = resume `tail` from byte offset. tmux on the node holds state.

## 11. Naming ✅ giroux.nvim

Claude Giroux, Flyers legend. The captain runs the lines. Optional flavor
kept light (statusline `●` count is "on the ice"); commands stay sober:
`:Giroux`, `:GirouxFeed`, `:GirouxDispatch`, `:GirouxAttach`, `:GirouxSteer`,
`:GirouxClean`.

## 12. Relationship to parole ✅ separate, kindred

Separate repos, shared conventions (worktree discipline, single-key verbs,
buffer-shaped inputs). Pipeline: giroux supervises the work → PR opens →
parole reviews it for release. Future: `:ParoleAgent` routes through giroux
when the target repo lives on another node.

## 13. Out of scope (phase 1)

- toshiro/iOS as a control surface (notifications only, phase 2).
- Co-piloting a session attached elsewhere.
- Non-Claude agents.
- Cost dashboards beyond per-session spend in the feed statusline.

## 14. Stat sheet & context provenance ✅

The transcript carries everything needed for a per-session box score —
no extra instrumentation, it's pure aggregation over the same events the
feed already parses:

- **Written**: Edit/Write/NotebookEdit inputs → file set with ± line counts,
  dirs derived. Repo truth cross-check = `git status --porcelain` in the
  worktree over SSH (tier 2 of §9).
- **Read (context provenance)**: Read/Glob/Grep inputs → the agent's read-set
  in chronological order — *where its context is coming from*. Bash reads
  (`cat`/`head`/rg) best-effort parsed; WebFetch/WebSearch URLs listed.
- **Spend**: per-message `usage` → cumulative tokens/cost, cache hit ratio,
  model mix, subagent attribution.

UI: `S` on a roster line / in a feed opens `giroux://stats/<session>` —
sections Written / Read / Web / Spend, fugitive-status-shaped: cursor a file,
`<CR>` opens it (rsync cache), `v` diffs it, files ordered by recency.
Roster gets a compact column: `✎3 ⊙27` (written/read counts).

**Tripwires** — the steering trigger that matters most ("stop the agent when
it reads a codebase I know is stale"): config glob patterns matched against
read/write paths as events stream; a hit escalates to question-level
notification with a one-key path into the steer buffer:

```lua
tripwires = {
  read  = { "**/legacy/**", "~/Code/myproject/legacy/**" },
  write = { "**/migrations/**" },
}
```

Observation feeding intervention — the whole product in one feature.

## Build order

1. `transcript.lua` — JSONL → events, against the real parole session as fixture
2. `feed.lua` — render events, folds, live tail (local first, then over SSH)
3. `sessions.lua` + `roster.lua` — scan, state proofs, the board
4. `stats.lua` + `statsheet.lua` — DONE: stat sheet (written/read/web/spend),
   context provenance, tripwires; S opens giroux://stats; roster activity column
5. `dispatch.lua` + `steer.lua` — tmux lifecycle, send-keys, steer buffer, question UX
6. notifications, diffs tier 2/3, `:GirouxClean`, checkhealth
