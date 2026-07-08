# Modern Claude Code support — implementation plans

Generated 2026-07-08 (against HEAD `47b9665`, on top of the subagent-monitoring
work). giroux's parser and feed were written against an **older Claude Code tool
vocabulary**; the product has since grown task/todo tracking, workflows, MCP
tools, scheduling, queued input, richer permission modes, and multi-question
`AskUserQuestion`. giroux never *crashes* on the new records (the gauntlet
enforces that) — but it renders them as `vim.inspect` noise and misses the new
attention signals. These six plans teach giroux the modern vocabulary.

Grounding: every plan was written against the live code **and** a fresh census
of real `~/.claude/projects` transcripts. Trust the on-disk shapes the plans
cite over any prose (one brief claim — `TaskUpdate`'s `toolUseResult` shape —
was found wrong on disk and corrected in plan 02).

## Verification commands (every plan)

```
nvim -l tests/run.lua                                                   # specs
nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua         # modules load
nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts
stylua --check lua/ tests/                                              # format (scope to your files while others are in flight)
```

Commit convention: terse, lowercase, module-prefixed, **no AI trailers**.

## File-ownership matrix (no two plans share a file)

| Plan | Owns | New? |
|------|------|------|
| 01 parser | `lua/giroux/transcript.lua`, `tests/events_spec.lua`, `tests/fixtures/transcripts/edge-cases.jsonl` | edits |
| 02 todos | `lua/giroux/todos.lua`, `tests/todos_spec.lua` | **new module** |
| 03 context | `lua/giroux/stats.lua`, `tests/stats_spec.lua` | edits |
| 04 feed | `lua/giroux/feed.lua`, `tests/feed_spec.lua` | edits (+new spec) |
| 05 steer | `lua/giroux/steer.lua`, `tests/steer_spec.lua` | edits |
| 06 integration | `lua/giroux/monitor.lua`, `lua/giroux/sessions.lua`, `lua/giroux/roster.lua`, `tests/{monitor,sessions,roster}_spec.lua` | edits |

Disjoint by construction — that's what makes Wave 1 fully parallel-safe.

## Execution order (waves)

**Wave 1 — five plans in parallel (disjoint files):** `01`, `02`, `03`, `04`, `05`.
None depend on another *landing* first: 04/05 defend against the old shapes where
they touch parser output, so they don't block on 01.

**Wave 2 — the integration:** `06`. Owns the shared monitor/sessions/roster
surface and **consumes** Wave 1's outputs, so it runs after them:
- hard-needs `lua/giroux/todos.lua` (02) and the stats context helper (03),
- soft-needs the `queue` parser event (01 — already present in the live parser;
  01 mostly regression-proofs it).

## Integration contract (what 06 adds; what 01–03 must produce)

Workstream 06 threads these onto `tr.session` and renders them; the producing
plans must expose exactly these:

```
session.todos   = { total, done, in_progress, current } | nil   -- from giroux.todos (02): Acc:summary()
session.queued  = <int> | nil    -- count of pending queued inputs: enqueue − (remove|dequeue), popAll clears
session.ctx_pct = <int> | nil    -- from stats (03): acc:summary()
session.model   = <string> | nil -- from stats (03)
session.mode    = <string> | nil -- from the permission-mode session_meta (already parsed)
```

Producer APIs the contract pins:
- **02** `giroux.todos`: `M.new()` → `Acc:add(event)` / `Acc:summary()` (mirrors
  `stats.lua`); `summary()` = `{total, done, in_progress, pending, current}` (06
  uses the subset above). Also exports `M.TASK_TOOL_NAMES`.
- **01** parser: `queue` event is `kind="queue"` with `{op, text}` (do **not**
  rename — `feed.lua` already consumes those names); `question` event carries the
  full un-flattened `questions` array.
- **03** stats: `acc:summary()` gains `ctx_pct` + `model` (additive).

Render contract (06, in `roster._line`): when `session.todos` present, the info
column shows `todos D/T · <current>`; compact badges append `⧗N` (queued), a
mode tag (`plan`/`acceptEdits`/`auto` — plan mode is a needs-you-class signal),
and `ctxNN%` when high. Existing attention glyphs/semantics unchanged.

04 (feed, answered-question render) and 05 (steer, live-pane answering) both
touch `AskUserQuestion` but on different files and different data sources
(transcript event vs. tmux pane) — complementary, no overlap.

## Status

| Plan | Title | Wave | Status |
|------|-------|------|--------|
| 01 | Parser: queue event, new subtypes, block fallback, question array | 1 | TODO |
| 02 | `todos.lua`: fold Task* events into a live todo model | 1 | TODO |
| 03 | `stats.lua`: context-window pressure + active model | 1 | TODO |
| 04 | `feed.lua`: render the modern tool vocabulary + multi-question | 1 | TODO |
| 05 | `steer.lua`: answer multi-question + multiSelect prompts | 1 | TODO |
| 06 | Surface todos/queued/context/mode on the roster | 2 | TODO |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (reason).
