# Plan 06: Surface todos / queued / context / mode on the roster

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update this plan's status row in
> `plans/modern-cc/README.md` if that file exists by the time you run (it may
> be assembled by whichever workstream lands last among 01-05); if it doesn't
> exist yet, skip that step.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/monitor.lua lua/giroux/sessions.lua lua/giroux/roster.lua tests/monitor_spec.lua tests/sessions_spec.lua tests/roster_spec.lua`
> This plan is the LAST wave of a 6-plan initiative (01 queue-event, 02
> todos.lua, 03 stats context, 04/05 elsewhere, 06 = this plan) and is
> designed to run only after 01/02/03 have landed real commits on top of
> `482e989`. If the diff above is empty, **01/02/03 have not landed yet —
> STOP**, this plan's dependencies (`lua/giroux/todos.lua` must exist; the
> `giroux.stats` accumulator must expose the context helper described below)
> are not satisfiable. If the diff is non-empty, read the "Assumed contracts"
> subsection under **Current state** below, then re-read the *actual* landed
> `lua/giroux/todos.lua` and `lua/giroux/stats.lua` before writing any code —
> reconcile any shape mismatch per the guidance there (most mismatches are a
> one-line call-site adjustment, not a STOP).

## Status

- **Priority**: P1 (this is the integration workstream — 01/02/03's new data
  is invisible to the operator until this lands)
- **Effort**: M
- **Risk**: MEDIUM (the only risk is dependency-shape drift from 01/02/03,
  not this plan's own logic — see "Assumed contracts" and STOP conditions)
- **Depends on**: 01 (soft — the `queue` event kind this plan folds is
  already present and committed on `main`, verified below; 01 only needs to
  not have removed/renamed it), 02 (hard — `lua/giroux/todos.lua` must
  exist), 03 (hard — `giroux.stats`'s accumulator must expose a context
  helper). **Must run in its own wave, after 01/02/03**, because it is the
  only workstream touching `monitor.lua`/`sessions.lua`/`roster.lua` (shared
  files every other workstream's data has to flow through).
- **Category**: feature (modern Claude Code vocabulary — see initiative
  rationale)
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty — see
  `plans/README.md`'s intro; this plan's excerpts were read off the live
  working-tree files, which is what the drift check above compares against)

## Why this matters

giroux's parser and feed already understand the modern Claude Code tool
vocabulary (Task*, queue-operation, AskUserQuestion arrays, permission modes,
usage records) at the event layer, but almost none of it reaches the roster —
the one screen an operator actually watches across a fleet of sessions. Four
concrete blind spots this plan closes:

1. **Todos are invisible.** A session tracking a 12-item task list (real
   corpus: 139 `TaskCreate` + 225 `TaskUpdate` calls across 17 sessions on
   this machine alone, 2026-07-08) shows on the roster today as generic
   `edit×3 bash×1` activity noise — no sense of *what it's actually working
   through* or how much is left.
2. **Queued input is invisible.** `queue-operation` records (this machine:
   1342 of them across the corpus) mean the operator typed ahead while an
   agent was busy — that's real intent sitting unresolved. The roster has no
   representation of it at all.
3. **A session in `plan` mode reads as idle, not "waiting on you."** DESIGN's
   whole state model (§4) is built on transcript/process proof, but
   permission-mode has no transcript signal of its own — a session sitting in
   plan mode with an approved-pending plan looks exactly like `○` idle today,
   which is actively misleading: it's the one state that reliably means "a
   human needs to look at this," and it doesn't page.
4. **Context pressure is invisible.** A session approaching its context
   window is heading for an auto-compact (which resets its effective memory)
   — the operator finds out only after the fact, from the feed.

None of this requires new parsing (01/02/03 supply the data); this plan is
purely about threading it onto `session` and rendering it, following the
exact pattern the codebase already uses for every other roster field
(`activity`, `touched`, `waiting_for`).

## Current state

### `lua/giroux/monitor.lua` — the realtime backbone

`start_tracker` builds one tracker per session (monitor.lua:298-319):

```lua
local function start_tracker(s)
  local k = key(s.node, s.path)
  if state.trackers[k] then
    return
  end
  local from
  if s.is_subagent and s.size <= SUBAGENT_FULL_SEED then
    from = 0 -- clean full parse: accurate terminal state for a finished subagent
  else
    from = math.max(0, s.size - SEED)
  end
  state.trackers[k] = {
    session = vim.tbl_extend("force", s, { state = "·", pending = {}, activity = "" }),
    acc = stats.new(),
    parser = transcript.parser({ start_offset = from }),
    -- a mid-file start (from > 0) begins inside a record; drop that fragment.
    skip_partial = from > 0,
    -- bytes up to here are pre-watch history (the seed window we replay); only
    -- appends beyond it are "live" and may latch a (✓) done/unseen finish.
    live_after = s.size,
  }
end
```

`feed_line` folds every parsed event into the tracker (monitor.lua:204-245),
already special-casing `session_meta`/`user_text` inline:

```lua
local function feed_line(tr, line)
  if tr.skip_partial then
    tr.skip_partial = false
    tr.parser = transcript.parser({ start_offset = tr.parser:resume_offset() + #line + 1 })
    return
  end
  local live = tr.parser:resume_offset() >= (tr.live_after or 0)
  local cfg = require("giroux").config
  for _, e in ipairs(tr.parser:feed(line .. "\n")) do
    tr.acc:add(e)
    -- any fresh byte clears a stale question latch; a still-open one is
    -- re-confirmed by the next probe tick.
    tr.question = false
    if e.kind == "session_meta" then
      if e.key == "ai-title" then
        tr.session.title = e.value
        if e.value and e.value ~= "" and cfg.tmux_rename then
          require("giroux.tmuxctl").maybe_rename(tr.session.node, tr.session, e.value)
        end
      elseif e.key == "last-prompt" then
        tr.session.last_prompt = e.value
      end
    elseif e.kind == "user_text" then
      tr.session.last_prompt = e.text:match("^[^\n]*")
    end
    local wire = require("giroux.stats").tripwire(e, cfg.tripwires or {})
    if wire then
      require("giroux.notify").fire(
        "tripwire",
        tr.session,
        ("%s %s (%s)"):format(wire.kind, vim.fn.fnamemodify(wire.path, ":t"), wire.glob)
      )
    end
  end
  derive(tr, live)
  notify()
end
```

`derive` computes state and copies fields onto `tr.session` (monitor.lua:159-174,
inside the larger `derive(tr, live)` at 106-199):

```lua
  tr.session.state = st
  tr.session.activity = tr.acc:recent_line()
  tr.session.touched = tr.acc.recent_files[#tr.acc.recent_files]
  tr.session.waiting_for = entry and entry.waiting_for or nil
  tr.session.pending = {}
  for _, c in pairs(tr.parser:pending()) do
    tr.session.pending[#tr.session.pending + 1] = c.name
  end

  -- subagents surface their state nested under the parent on the roster, but
  -- don't page: a workflow fanning out 16 agents shouldn't fire 16 "finished"
  -- banners. Attention rolls up to the parent session, which owns the signal.
  if tr.session.is_subagent then
    tr.primed = true
    return
  end
```

Note the `is_subagent` early return happens *after* this block — subagents
already get `activity`/`touched`/`pending`/`waiting_for` populated today, so
whatever this plan adds here will reach subagent sessions too "for free" (no
extra branch needed; see Scope for why the render side doesn't use it).

The module already exposes test seams at the bottom (monitor.lua:610-612):

```lua
M._state = state
M._derive = derive
return M
```

### `lua/giroux/sessions.lua` — the discovery-snapshot path

`parse_scan` (sessions.lua:98-151) is the pure, testable twin of the live
monitor path: it full-parses a 32KB tail per session (from a one-shot `find`
+ `tail -c` over ssh) into the same session shape, for the non-live
`M.scan`/`:GirouxDispatch` repo-listing paths:

```lua
function M.parse_scan(node_name, stdout, now)
  local out = {}
  local cur, parser, acc, skipped_partial
  local function finish()
    if not cur then
      return
    end
    cur.pending = {}
    for _, call in pairs(parser:pending()) do
      cur.pending[#cur.pending + 1] = call.name
    end
    cur.state = M.derive_state(parser:pending(), now - cur.mtime, parser:in_turn())
    cur.activity = acc:recent_line()
    cur.touched = acc.recent_files[#acc.recent_files]
    out[#out + 1] = cur
  end
  for line in vim.gsplit(stdout, "\n", { plain = true }) do
    local mtime, size, birth, path = line:match("^" .. MARK .. " (%d+) (%d+) (%d+) (.+)$")
    if mtime then
      finish()
      cur = {
        node = node_name,
        mtime = tonumber(mtime),
        size = tonumber(size),
        birth = tonumber(birth),
        path = path,
        project = M.project_display(path),
      }
      parser = transcript.parser()
      acc = stats.new()
      -- tail -c of a big file starts mid-record; drop the first (partial) line
      skipped_partial = cur.size <= M.TAIL_BYTES
    elseif cur and line ~= "" then
      if not skipped_partial then
        skipped_partial = true
      else
        for _, e in ipairs(parser:feed(line .. "\n")) do
          acc:add(e)
          if e.kind == "session_meta" then
            if e.key == "ai-title" then
              cur.title = e.value
            elseif e.key == "last-prompt" then
              cur.last_prompt = e.value
            end
          elseif e.kind == "user_text" then
            cur.last_prompt = e.text:match("^[^\n]*")
          end
        end
      end
    end
  end
  finish()
  return out
end
```

`M.scan` (sessions.lua:222-262, the ssh-driving caller of `parse_scan`) is
currently **not called from anywhere in `lua/` outside its own definition**
(verified: `grep -rn "\.scan(" lua/ tests/ plugin/ scripts/` returns only the
definition line). It's still fully unit-tested directly via `parse_scan` in
`tests/sessions_spec.lua`, and the initiative brief explicitly calls it out
("mirror what's cheap"), so this plan keeps it in sync anyway — see
Maintenance notes.

`M.derive_state` (sessions.lua:44-59) is unrelated to this plan's fields —
leave it untouched.

### `lua/giroux/roster.lua` — the render

`M._line` (roster.lua:113-141), one row per top-level session:

```lua
function M._line(it, hide)
  local info
  if it.state == "?" and it.waiting_for and it.waiting_for ~= "" then
    info = "waiting: " .. it.waiting_for
  elseif #(it.pending or {}) > 0 then
    info = "busy: " .. table.concat(it.pending, ", ")
  elseif it.activity and it.activity ~= "" then
    info = it.activity
    if it.touched then
      info = info .. "  " .. vim.fn.fnamemodify(it.touched, ":t")
    end
  else
    info = it.last_prompt and ("> " .. it.last_prompt) or ""
  end
  -- ▸ = steerable (a live tmux session giroux can attach/answer); blank =
  -- observe-only (no correlated tmux — a hand-started raw claude or a dead one).
  local ctl = it.tmux and "▸" or " "
  local cols = { it.state .. ctl }
  if hide ~= "node" then
    cols[#cols + 1] = trunc(it.node, 8)
  end
  if hide ~= "project" then
    cols[#cols + 1] = trunc(it.project, 22)
  end
  cols[#cols + 1] = trunc(display_title(it), 34)
  cols[#cols + 1] = ("%4s"):format(age_str(it.mtime))
  cols[#cols + 1] = trunc(info, 44)
  return "  " .. table.concat(cols, " ")
end
```

`M._subline` (roster.lua:146-159) is the subagent nested-row renderer — a
different, deliberately terser column set (state, type, description, age).
Not touched by this plan (see Scope).

`M.build` (roster.lua:175-322) calls `M._line(it, hide)` at line 306 to emit
each item row; it does not otherwise touch per-row content, so no change is
needed there.

The help legend `vim.notify` call (roster.lua:514-520):

```lua
  map(km.help, function()
    vim.notify(
      "⏎ feed / fold · ^S regroup · n dispatch · a attach · s steer · R resume · S stats · Q digest · r refresh · q close"
        .. "  ·  ▸ = steerable, blank = observe-only  ·  ⤷ = subagent  ·  ✓ = done (finished, unreviewed)",
      vim.log.levels.INFO
    )
  end, "help")
```

### The `queue` transcript event — already landed, verified

Unlike todos/ctx, the queue event needs **no new parser work**: `transcript.lua`
(not owned by this plan) already emits it, unmodified on `main` right now
(transcript.lua:458-465):

```lua
  elseif rtype == "queue-operation" then
    out[#out + 1] = {
      kind = "queue",
      offset = line.offset,
      ts = nz(rec.timestamp),
      op = nz(rec.operation),
      text = nz(rec.content),
    }
```

Real `operation` vocabulary, verified 2026-07-08 by grepping this machine's
own `~/.claude/projects/*/*.jsonl` corpus (1342 queue-operation records
total): `enqueue` (673), `remove` (410), `dequeue` (220), `popAll` (35). A
`remove`/`dequeue` record carries no id back to a specific `enqueue` (just
`sessionId` + `timestamp`), so per-item correlation isn't possible from the
record shape alone — only a running count is. `popAll` drains the whole
queue at once (seen paired with a `content` field mirroring the last-popped
item, but semantically it's "the queue is now empty"). This grounds the pure
fold this plan adds in Step 1 (`M.fold_queue`).

The fixture corpus already has one `queue-operation` (`enqueue`) record
(`tests/fixtures/transcripts/edge-cases.jsonl:6`) — the gauntlet already
proves 0 crashes on this exact shape. It has no `remove`/`dequeue`/`popAll`/
`permission-mode`/`Task*` records; fixture coverage is `tests/fixtures/`,
which this plan does not own — not an action item here.

### The `permission-mode` session_meta event — already landed, verified

Also already parsed on `main`, unmodified (transcript.lua:196-204, 456-457):

```lua
local SESSION_META = {
  ["mode"] = "mode",
  ["permission-mode"] = "permissionMode",
  ["ai-title"] = "aiTitle",
  ["last-prompt"] = "lastPrompt",
  ["agent-name"] = "agentName",
  ["pr-link"] = "prUrl",
}
```
```lua
  elseif SESSION_META[rtype] then
    out[#out + 1] = { kind = "session_meta", offset = line.offset, key = rtype, value = nz(rec[SESSION_META[rtype]]) }
```

So a permission-mode record surfaces as `{kind="session_meta", key="permission-mode",
value=<the mode string>}` — the exact same shape `feed_line`/`parse_scan`
already switch on for `key == "ai-title"` / `key == "last-prompt"`. Verified
values on this machine: `auto` (22), `bypassPermissions` (3508 — this is the
value that corresponds to `--dangerously-skip-permissions`, DESIGN.md §2's
default launch flag, i.e. the *common* case). `plan`/`acceptEdits`/`default`
are asserted by the initiative brief's real-data census but not present in
this machine's local corpus — trust the brief for those three.

### Assumed contracts from 01/02/03 — verify before implementing

This plan consumes three things it does not own. The exact session-field
shapes are fixed by the initiative brief (binding across all 6 plans):

```
session.todos   = { total, done, in_progress, current } | nil
session.queued  = <int> | nil
session.ctx_pct = <int> | nil
session.model   = <string> | nil
session.mode    = <string> | nil
```

What this plan *assumes* about how to obtain them, by strict analogy with
the accumulator pattern `stats.new()`/`Acc:add(e)`/`Acc:summary()` already
used for every other per-session running aggregate in this codebase
(monitor.lua's `tr.acc`, sessions.lua's `acc` in `parse_scan`):

- **`giroux.todos`** (workstream 02) exposes `todos.new()` returning an
  accumulator with `:add(event)` (fold in `tool_call`/`tool_result` events
  for `TaskCreate`/`TaskUpdate`/`TaskStop`) and `:summary()` returning the
  `{total, done, in_progress, current}` shape above (or `nil`/an empty shape
  when no tasks exist yet).
- **`giroux.stats`**'s `Acc:summary()` (workstream 03) is extended to also
  return `ctx_pct` (integer 0-100) and `model` (string, the session's
  current/most-recent model — distinct from the existing `summary().models`
  list of every model used all session) directly at the top level, alongside
  the existing `written`/`read`/`tokens`/etc.

**Before writing Step 1 or Step 3**, read the actual landed
`lua/giroux/todos.lua` and the actual `Acc:summary()` in `lua/giroux/stats.lua`.
If either differs from the assumption above in a way that's a **one-line
call-site fix** (different function/field name, e.g. `todos.tracker()`
instead of `todos.new()`, or `ctx()`/`context_pct` instead of `ctx_pct`, or
`ctx_pct`/`model` nested under a `context = {...}` sub-table instead of flat)
— just adapt the call site to match; this is expected drift, not a STOP. If
the shape is structurally incompatible (e.g. `todos.lua` only exposes a
stateless `fold(list_of_all_events)` pure function rather than an
incremental accumulator, which would require retaining full event history
per tracker — a real architectural change, not a call-site tweak) — STOP and
report; do not redesign 02's module to fit this plan's assumption.

## Commands you will need

| Purpose      | Command                                                              | Expected on success        |
|--------------|-----------------------------------------------------------------------|-----------------------------|
| Tests (all)  | `nvim -l tests/run.lua`                                              | `... passed, 0 failed`     |
| Tests (one)  | `nvim -l tests/run.lua monitor` / `sessions` / `roster`              | those specs pass           |
| Smoke        | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`    | `smoke ok`, exit 0         |
| Gauntlet     | `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` | 0 crashes |
| Format check | `stylua --check lua/ tests/`                                         | exit 0 (no diff)           |
| Format fix   | `stylua lua/ tests/`                                                 | rewrites files in place    |

(`nvim -l scripts/smoke.lua` without `--cmd "set rtp+=."` cannot find the
`giroux` module from an arbitrary cwd — always use the `--cmd` form per
CLAUDE.md.)

## Scope

**In scope** (the only files you should modify):
- `lua/giroux/monitor.lua`
- `lua/giroux/sessions.lua`
- `lua/giroux/roster.lua`
- `tests/monitor_spec.lua`
- `tests/sessions_spec.lua`
- `tests/roster_spec.lua`

**Out of scope** (do NOT touch, even if you spot something worth fixing —
report it instead):
- `lua/giroux/todos.lua`, `lua/giroux/transcript.lua`, `lua/giroux/stats.lua`
  — owned by workstreams 02/03/01. If their landed shape is wrong or
  incomplete for this plan's needs in a way that isn't a call-site
  adaptation, STOP and report (see STOP conditions); do not fix it here.
- `lua/giroux/state.lua` — the attention-order/glyph vocabulary. This plan
  adds *informational* badges, not new state glyphs; `M.ORDER`/`M.LABEL`
  stay exactly as they are. A session in `plan` mode still sorts by its
  proven transcript/process state (most commonly `○` idle) — this plan makes
  that state legible ("idle, AND in plan mode") rather than inventing a new
  attention tier for it.
- `M._subline` (roster.lua:146-159) — the subagent nested-row renderer stays
  unchanged. Subagents don't have an independent permission mode or input
  queue (they run inside the parent's process — DESIGN.md §2's "one console
  at a time"), and a per-subagent todos/ctx readout would clutter an already
  capped, terse (12-row) nested list. `tr.session.todos`/`queued`/`ctx_pct`/
  `model` still land on subagent trackers "for free" per the derive() code
  path (see Current state) — simply unused by `_subline`. If a future need
  arises, that's a separate plan.
- `M.build`'s title-line summary counts (needs-you/done badge,
  roster.lua:209-227) and group-header badges (roster.lua:276-303) — not
  touched. Only `M._line` (the per-session row) changes.
- `doc/giroux.txt`, `README.md` — user-facing docs. Not in this plan's file
  list; a doc-sync plan (see `plans/008-doc-sync.md` for the established
  pattern from the prior initiative) is the right place if the maintainer
  wants the roster legend documented there too.
- `sessions.lua`'s `M.list` (the stat-only discovery scan, sessions.lua:159-217)
  — it never reads file content, so there's nothing to thread. Untouched.

## Git workflow

- Branch: `advisor/06-roster-surfacing`
- Commits: as many as make sense per logical unit (e.g. one for the
  sessions.lua+monitor.lua threading, one for the roster render, one for
  tests) or a single commit — your call, but keep messages terse, lowercase,
  module-prefixed, **no AI trailers**. Example shape:
  `roster: surface todos/queued/mode/ctx on the board`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `sessions.lua` — pure queue fold + thread all five fields into `parse_scan`

Add the pure fold helper. Place it after `M.derive_state` (sessions.lua:44-59)
and before `M.subagent_of` (sessions.lua:61-73):

```lua
---Fold one `queue` event's operation into a running count of pending queued
---inputs. Pure. Real op vocabulary (verified against live ~/.claude/projects
---transcripts, 2026-07-08): "enqueue" adds one; "remove" and "dequeue" each
---resolve exactly one — floored at 0, since a resolve for an item enqueued
---before this tracker's seed window must never go negative; "popAll" drains
---the whole queue. Any other/unknown op is left alone: never crash, never
---guess (the parser's "degrade unknowns" contract).
---@param count integer current queued count
---@param op string|nil the queue event's `op` field
---@return integer
function M.fold_queue(count, op)
  if op == "enqueue" then
    return count + 1
  elseif op == "remove" or op == "dequeue" then
    return math.max(0, count - 1)
  elseif op == "popAll" then
    return 0
  end
  return count
end
```

Add the `todos` require near the top, alongside the existing `stats` require
(sessions.lua:6-9):

```lua
local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")
local todos = require("giroux.todos")
```

(If Step "Assumed contracts" verification found a different module path,
use that instead — adjust every reference below to match.)

Now thread the fields through `parse_scan`. Three edits to the existing
function (sessions.lua:98-151):

1. Local declarations (sessions.lua:100) — add `todo_acc` and `queued`:

```lua
  local cur, parser, acc, todo_acc, queued, skipped_partial
```

2. The marker-line branch that resets per-session state (inside the `if mtime then` block, sessions.lua:115-129) — reset the two new accumulators alongside `parser`/`acc`:

```lua
      parser = transcript.parser()
      acc = stats.new()
      todo_acc = todos.new()
      queued = 0
      -- tail -c of a big file starts mid-record; drop the first (partial) line
      skipped_partial = cur.size <= M.TAIL_BYTES
```

3. The event loop (sessions.lua:134-146) — fold every event into `todo_acc`,
   add a `permission-mode` branch alongside the existing `ai-title`/
   `last-prompt` ones, and a `queue` branch:

```lua
        for _, e in ipairs(parser:feed(line .. "\n")) do
          acc:add(e)
          todo_acc:add(e)
          if e.kind == "session_meta" then
            if e.key == "ai-title" then
              cur.title = e.value
            elseif e.key == "last-prompt" then
              cur.last_prompt = e.value
            elseif e.key == "permission-mode" then
              cur.mode = e.value
            end
          elseif e.kind == "user_text" then
            cur.last_prompt = e.text:match("^[^\n]*")
          elseif e.kind == "queue" then
            queued = M.fold_queue(queued, e.op)
          end
        end
```

4. `finish()` (sessions.lua:101-113) — set the new fields on `cur` alongside
   the existing `pending`/`state`/`activity`/`touched`:

```lua
  local function finish()
    if not cur then
      return
    end
    cur.pending = {}
    for _, call in pairs(parser:pending()) do
      cur.pending[#cur.pending + 1] = call.name
    end
    cur.state = M.derive_state(parser:pending(), now - cur.mtime, parser:in_turn())
    cur.activity = acc:recent_line()
    cur.touched = acc.recent_files[#acc.recent_files]
    cur.todos = todo_acc:summary()
    cur.queued = queued > 0 and queued or nil
    local sum = acc:summary()
    cur.ctx_pct = sum.ctx_pct
    cur.model = sum.model
    out[#out + 1] = cur
  end
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ `smoke ok`. `nvim -l tests/run.lua sessions` → existing sessions specs
still pass (they don't yet exercise the new fields — Step 2 adds that).

### Step 2: `tests/sessions_spec.lua` — cover the fold + the threading

Add tests for `M.fold_queue` (pure, no stubbing needed) and for `parse_scan`'s
threading of `mode`/`queued` (also pure, real events — the `queue`/
`session_meta` shapes are already landed and stable) plus `todos`/`ctx_pct`/
`model` (stub the accumulators so this test doesn't depend on 02/03's
internal fold *correctness* — only on *this file's wiring* calling `:add`/
`:summary` correctly; 02/03 own testing their own fold logic in
`todos_spec.lua`/`stats_spec.lua`).

```lua
["sessions: fold_queue tallies enqueue/remove/dequeue/popAll, ignores unknown ops"] = function()
  local n = 0
  n = sessions.fold_queue(n, "enqueue") -- 1
  n = sessions.fold_queue(n, "enqueue") -- 2
  n = sessions.fold_queue(n, "dequeue") -- 1
  assert(n == 1, "enqueue x2, dequeue x1: " .. n)
  n = sessions.fold_queue(n, "remove") -- 0
  assert(n == 0, "remove floors correctly: " .. n)
  n = sessions.fold_queue(n, "remove") -- must not go negative
  assert(n == 0, "remove below 0 stays at 0: " .. n)
  n = sessions.fold_queue(3, "popAll")
  assert(n == 0, "popAll drains to 0: " .. n)
  assert(sessions.fold_queue(5, "reorder") == 5, "unknown op is a no-op, not a guess")
end,

["sessions: parse_scan threads mode + queued from real event shapes"] = function()
  local now = os.time()
  local lines = {
    J({ type = "permission-mode", permissionMode = "plan", sessionId = "s1" }),
    J({ type = "queue-operation", operation = "enqueue", timestamp = "2026-07-08T00:00:00.000Z", content = "next" }),
    J({ type = "queue-operation", operation = "enqueue", timestamp = "2026-07-08T00:00:01.000Z", content = "next2" }),
    J({ type = "queue-operation", operation = "dequeue", timestamp = "2026-07-08T00:00:02.000Z" }),
  }
  local stdout = table.concat({
    ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s1.jsonl"):format(now - 5, now - 60),
    table.concat(lines, "\n"),
    "",
  }, "\n")
  local items = sessions.parse_scan("workhorse", stdout, now)
  assert(#items == 1)
  assert(items[1].mode == "plan", "permission-mode threaded: " .. vim.inspect(items[1].mode))
  assert(items[1].queued == 1, "2 enqueue - 1 dequeue = 1: " .. tostring(items[1].queued))
end,

["sessions: parse_scan threads todos/ctx_pct/model from the accumulator summaries"] = function()
  -- stub the accumulators so this proves parse_scan's WIRING, not 02/03's
  -- fold correctness (that's their own spec files' job).
  local todos_mod = require("giroux.todos")
  local orig_todos_new = todos_mod.new
  todos_mod.new = function()
    return { add = function() end, summary = function()
      return { total = 4, done = 1, in_progress = 1, current = "fix the thing" }
    end }
  end
  local stats = require("giroux.stats")
  local orig_stats_new = stats.new
  stats.new = function()
    local acc = orig_stats_new()
    local orig_summary = acc.summary
    acc.summary = function(self)
      local s = orig_summary(self)
      s.ctx_pct = 62
      s.model = "claude-fake-model"
      return s
    end
    return acc
  end

  local now = os.time()
  local stdout = ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s1.jsonl"):format(now - 5, now - 60) .. "\n"
  local items = sessions.parse_scan("workhorse", stdout, now)

  todos_mod.new = orig_todos_new
  stats.new = orig_stats_new

  assert(#items == 1)
  assert(vim.deep_equal(items[1].todos, { total = 4, done = 1, in_progress = 1, current = "fix the thing" }),
    vim.inspect(items[1].todos))
  assert(items[1].ctx_pct == 62, "ctx_pct threaded: " .. tostring(items[1].ctx_pct))
  assert(items[1].model == "claude-fake-model", "model threaded: " .. tostring(items[1].model))
end,
```

(`J` is the existing local JSON-encode helper already at the top of this
spec file — reuse it, don't redefine it.)

**Verify**: `nvim -l tests/run.lua sessions` → all sessions specs pass,
count +3.

### Step 3: `monitor.lua` — thread the same five fields into the live path

Add the `todos` require alongside the existing module-level requires
(monitor.lua:6-11):

```lua
local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")
local sessions = require("giroux.sessions")
local todos = require("giroux.todos")
local vocab = require("giroux.state")
```

`start_tracker` (monitor.lua:298-319) — add `todos` and `queued` to the
tracker table, alongside `acc`:

```lua
  state.trackers[k] = {
    session = vim.tbl_extend("force", s, { state = "·", pending = {}, activity = "" }),
    acc = stats.new(),
    todos = todos.new(),
    queued = 0,
    parser = transcript.parser({ start_offset = from }),
    skip_partial = from > 0,
    live_after = s.size,
  }
```

`feed_line` (monitor.lua:204-245) — fold every event into `tr.todos`, add a
`permission-mode` branch (mode is a direct passthrough, exactly like
`title`/`last_prompt` — no derive()-time computation needed), and a `queue`
branch using the same `sessions.fold_queue` added in Step 1:

```lua
  for _, e in ipairs(tr.parser:feed(line .. "\n")) do
    tr.acc:add(e)
    tr.todos:add(e)
    -- any fresh byte clears a stale question latch; a still-open one is
    -- re-confirmed by the next probe tick.
    tr.question = false
    if e.kind == "session_meta" then
      if e.key == "ai-title" then
        tr.session.title = e.value
        if e.value and e.value ~= "" and cfg.tmux_rename then
          require("giroux.tmuxctl").maybe_rename(tr.session.node, tr.session, e.value)
        end
      elseif e.key == "last-prompt" then
        tr.session.last_prompt = e.value
      elseif e.key == "permission-mode" then
        tr.session.mode = e.value
      end
    elseif e.kind == "user_text" then
      tr.session.last_prompt = e.text:match("^[^\n]*")
    elseif e.kind == "queue" then
      tr.queued = sessions.fold_queue(tr.queued, e.op)
    end
    local wire = require("giroux.stats").tripwire(e, cfg.tripwires or {})
    if wire then
      require("giroux.notify").fire(
        "tripwire",
        tr.session,
        ("%s %s (%s)"):format(wire.kind, vim.fn.fnamemodify(wire.path, ":t"), wire.glob)
      )
    end
  end
```

`derive` (monitor.lua:159-166) — add the derived fields right after the
existing `tr.session.*` assignments, still *before* the `is_subagent` early
return a few lines below (so subagents get them too, matching how
`activity`/`touched`/`pending` already work — see Scope for why the render
side doesn't use it for subagents):

```lua
  tr.session.state = st
  tr.session.activity = tr.acc:recent_line()
  tr.session.touched = tr.acc.recent_files[#tr.acc.recent_files]
  tr.session.waiting_for = entry and entry.waiting_for or nil
  tr.session.pending = {}
  for _, c in pairs(tr.parser:pending()) do
    tr.session.pending[#tr.session.pending + 1] = c.name
  end
  tr.session.todos = tr.todos:summary()
  tr.session.queued = tr.queued > 0 and tr.queued or nil
  local acc_summary = tr.acc:summary()
  tr.session.ctx_pct = acc_summary.ctx_pct
  tr.session.model = acc_summary.model
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ `smoke ok`. `nvim -l tests/run.lua monitor` → existing monitor specs still
pass (Step 4 adds new ones).

### Step 4: `tests/monitor_spec.lua` — prove the live-path wiring

Build a tracker by hand (the existing specs already do this — see
`"monitor: a pane-confirmed question..."` and
`"monitor: a subagent is never shown dead..."` for the pattern) with a
`todos`/`queued` field and a stubbed `acc.summary`, then drive it through
`monitor._derive` and assert the fields land on `tr.session`:

```lua
["monitor: derive threads todos/queued/ctx/model/mode onto tr.session"] = function()
  require("giroux.notify").reset()
  local todos_mod = require("giroux.todos")
  local tr = {
    session = { node = "x", path = "/a/sess.jsonl", state = "·", mtime = os.time(), mode = "plan" },
    acc = stats.new(),
    todos = todos_mod.new(),
    queued = 2,
    parser = transcript.parser(),
    question = false,
  }
  -- stub this tracker's own accumulators (proves monitor's wiring, not
  -- todos.lua/stats.lua's own fold correctness — they own their own specs).
  tr.todos.summary = function()
    return { total = 5, done = 2, in_progress = 1, current = "ship the roster badges" }
  end
  local orig_summary = tr.acc.summary
  tr.acc.summary = function(self)
    local s = orig_summary(self)
    s.ctx_pct = 88
    s.model = "claude-fake-model"
    return s
  end

  monitor._derive(tr, false)

  assert(vim.deep_equal(tr.session.todos, { total = 5, done = 2, in_progress = 1, current = "ship the roster badges" }),
    vim.inspect(tr.session.todos))
  assert(tr.session.queued == 2, "queued threaded: " .. tostring(tr.session.queued))
  assert(tr.session.ctx_pct == 88, "ctx_pct threaded: " .. tostring(tr.session.ctx_pct))
  assert(tr.session.model == "claude-fake-model", "model threaded: " .. tostring(tr.session.model))
  assert(tr.session.mode == "plan", "mode passthrough (set in feed_line, untouched by derive): "
    .. tostring(tr.session.mode))

  require("giroux.notify").reset()
end,

["monitor: feed_line folds a permission-mode record and queue-operations onto the tracker"] = function()
  require("giroux.notify").reset()
  local tr = {
    session = { node = "x", path = "/a/sess.jsonl", state = "·", mtime = os.time() },
    acc = stats.new(),
    todos = require("giroux.todos").new(),
    queued = 0,
    parser = transcript.parser(),
    live_after = 0,
    question = false,
  }
  -- feed_line is file-local (like derive was before plan 001 added
  -- `M._derive`); drive it through the new `M._feed_line` seam added just
  -- below this test block.
  monitor._feed_line(tr, vim.json.encode({ type = "permission-mode", permissionMode = "acceptEdits" }))
  monitor._feed_line(tr, vim.json.encode({ type = "queue-operation", operation = "enqueue", content = "a" }))
  monitor._feed_line(tr, vim.json.encode({ type = "queue-operation", operation = "enqueue", content = "b" }))
  assert(tr.session.mode == "acceptEdits", "mode set directly in feed_line: " .. tostring(tr.session.mode))
  assert(tr.queued == 2, "two enqueues tallied on the tracker: " .. tostring(tr.queued))

  require("giroux.notify").reset()
end,
```

This second test requires a small seam: `feed_line` is currently file-local
(like `derive` was before plan 001 added `M._derive`). Add `M._feed_line =
feed_line` next to the existing `M._derive = derive` at monitor.lua:610-612:

```lua
M._state = state
M._derive = derive
M._feed_line = feed_line
return M
```

**Verify**: `nvim -l tests/run.lua monitor` → all monitor specs pass, count
+2.

### Step 5: `roster.lua` — render todos/badges in `M._line` + update the help legend

Add a module-level threshold constant right above `M._line`
(roster.lua:113):

```lua
-- context usage past this threshold is worth flagging on the roster — Claude
-- Code auto-compacts well above it, so this is an early warning, not a
-- crisis. Tune here if it's too chatty/quiet in practice.
local CTX_HIGH_PCT = 70
```

Rewrite `M._line` (roster.lua:113-141):

```lua
function M._line(it, hide)
  local info
  if it.state == "?" and it.waiting_for and it.waiting_for ~= "" then
    info = "waiting: " .. it.waiting_for
  elseif #(it.pending or {}) > 0 then
    info = "busy: " .. table.concat(it.pending, ", ")
  elseif it.todos then
    -- the todo panel is a higher-signal "what's actually happening" than raw
    -- tool-call tallies, so it takes the activity/last_prompt tier's slot.
    info = ("todos %d/%d"):format(it.todos.done or 0, it.todos.total or 0)
    if it.todos.current and it.todos.current ~= "" then
      info = info .. " · " .. it.todos.current
    end
  elseif it.activity and it.activity ~= "" then
    info = it.activity
    if it.touched then
      info = info .. "  " .. vim.fn.fnamemodify(it.touched, ":t")
    end
  else
    info = it.last_prompt and ("> " .. it.last_prompt) or ""
  end
  -- ▸ = steerable (a live tmux session giroux can attach/answer); blank =
  -- observe-only (no correlated tmux — a hand-started raw claude or a dead one).
  local ctl = it.tmux and "▸" or " "
  local cols = { it.state .. ctl }
  if hide ~= "node" then
    cols[#cols + 1] = trunc(it.node, 8)
  end
  if hide ~= "project" then
    cols[#cols + 1] = trunc(it.project, 22)
  end
  cols[#cols + 1] = trunc(display_title(it), 34)
  cols[#cols + 1] = ("%4s"):format(age_str(it.mtime))
  cols[#cols + 1] = trunc(info, 44)
  -- compact badges, appended un-truncated (never swallowed by the info
  -- column's 44-char cap): queued input count, permission mode (plan
  -- especially — a session sitting in plan mode is effectively waiting on
  -- the human even though nothing in the transcript proves it, so it's
  -- flagged even though its state glyph stays whatever's actually proven),
  -- context usage. "default"/"bypassPermissions" (the common case — DESIGN
  -- §2's default launch flag) get no badge: badges are for the modes that
  -- are a deviation worth a second look.
  local badges = {}
  if it.queued and it.queued > 0 then
    badges[#badges + 1] = "⧗" .. it.queued
  end
  if it.mode == "plan" then
    badges[#badges + 1] = "PLAN"
  elseif it.mode == "acceptEdits" then
    badges[#badges + 1] = "edits"
  elseif it.mode == "auto" then
    badges[#badges + 1] = "auto"
  end
  if it.ctx_pct and it.ctx_pct >= CTX_HIGH_PCT then
    badges[#badges + 1] = ("ctx%d%%"):format(it.ctx_pct)
  end
  if #badges > 0 then
    cols[#cols + 1] = table.concat(badges, " ")
  end
  return "  " .. table.concat(cols, " ")
end
```

Update the help legend (roster.lua:514-520) to explain the three new
markers:

```lua
  map(km.help, function()
    vim.notify(
      "⏎ feed / fold · ^S regroup · n dispatch · a attach · s steer · R resume · S stats · Q digest · r refresh · q close"
        .. "  ·  ▸ = steerable, blank = observe-only  ·  ⤷ = subagent  ·  ✓ = done (finished, unreviewed)"
        .. "  ·  ⧗N = N queued inputs  ·  PLAN/edits/auto = permission mode  ·  ctxNN% = context usage (high)",
      vim.log.levels.INFO
    )
  end, "help")
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ `smoke ok`. `nvim -l tests/run.lua roster` → existing roster specs still
pass (Step 6 adds new ones). Manually sanity-check line width: eyeball that
a row with all three badges present (`⧗12 PLAN ctx88%`, ~15 chars) doesn't
look absurd in a normal-width terminal — it's appended after the existing
~120-char row, which is already roster.lua's established width budget.

### Step 6: `tests/roster_spec.lua` — cover the render

```lua
["roster: _line shows todos in the info column, ahead of activity/last_prompt"] = function()
  local it = sess({ todos = { total = 5, done = 2, in_progress = 1, current = "fix the flaky test" } })
  local line = roster._line(it, nil)
  assert(line:find("todos 2/5", 1, true), "todo count shown: " .. line)
  assert(line:find("fix the flaky test", 1, true), "current task shown: " .. line)
end,

["roster: _line still prioritizes waiting/busy over todos"] = function()
  local waiting = sess({ state = "?", waiting_for = "pick an option", todos = { total = 3, done = 1 } })
  assert(roster._line(waiting, nil):find("waiting: pick an option", 1, true), "waiting wins over todos")
  local busy = sess({ pending = { "Bash" }, todos = { total = 3, done = 1 } })
  assert(roster._line(busy, nil):find("busy: Bash", 1, true), "busy wins over todos")
end,

["roster: _line appends compact badges for queued/mode/high-context"] = function()
  local it = sess({ queued = 3, mode = "plan", ctx_pct = 85 })
  local line = roster._line(it, nil)
  assert(line:find("⧗3", 1, true), "queued badge: " .. line)
  assert(line:find("PLAN", 1, true), "plan-mode badge: " .. line)
  assert(line:find("ctx85%%", 1, true), "high-context badge: " .. line)
end,

["roster: _line omits mode/ctx badges for the common/boring cases"] = function()
  local common = sess({ mode = "bypassPermissions", ctx_pct = 30 })
  local line = roster._line(common, nil)
  assert(not line:find("bypassPermissions", 1, true), "no badge for the default launch mode: " .. line)
  assert(not line:find("ctx30", 1, true), "no badge below the high-context threshold: " .. line)
  local zero_queued = sess({ queued = 0 })
  assert(not roster._line(zero_queued, nil):find("⧗", 1, true), "no badge for a queue of 0")
end,

["roster: _line shows acceptEdits/auto mode tags too"] = function()
  assert(roster._line(sess({ mode = "acceptEdits" }), nil):find("edits", 1, true))
  assert(roster._line(sess({ mode = "auto" }), nil):find("auto", 1, true))
end,
```

(`sess(o)` is the existing local test-fixture builder already at the top of
this spec file — reuse it.)

**Verify**: `nvim -l tests/run.lua roster` → all roster specs pass, count +5.

### Step 7: Full suite + format + gauntlet

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`; total count is +10 over the pre-plan
  baseline (3 sessions + 2 monitor + 5 roster).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → `smoke ok`.
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts`
  → 0 crashes (this plan adds no new parser code, so this should be a pure
  sanity check, not a real risk surface).
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` first if
  it complains).
- `git status` → only the six in-scope files (plus nothing under
  `lua/giroux/todos.lua`, `lua/giroux/stats.lua`, `lua/giroux/transcript.lua`)
  are modified.

## Test plan

- `tests/sessions_spec.lua`: `fold_queue`'s op-vocabulary handling (pure,
  real ops); `parse_scan` threading `mode`/`queued` from real event shapes;
  `parse_scan` threading `todos`/`ctx_pct`/`model` from stubbed accumulators
  (proves this file's wiring, not 02/03's fold correctness).
- `tests/monitor_spec.lua`: `M._derive` threads todos/queued/ctx/model onto
  `tr.session` (stubbed accumulators, same rationale); `M._feed_line` (new
  seam) folds a `permission-mode` record and `queue-operation` records onto
  the tracker via real event parsing.
- `tests/roster_spec.lua`: `M._line` info-column precedence (waiting > busy >
  todos > activity > last_prompt); badge rendering for queued/mode/ctx-high;
  badge omission for the boring/common cases (0 queued,
  `bypassPermissions`/`default` mode, ctx below threshold).
- Pattern: existing specs in each file (flat table, plain asserts, hand-built
  fixtures — `tr_with`/`tr_open_turn` helpers in monitor_spec.lua, `sess()`
  in roster_spec.lua, `J()` in sessions_spec.lua).
- Verification: `nvim -l tests/run.lua` → all pass, `0 failed`.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; total passing count is +10.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → `smoke ok`.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` → 0 crashes.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `sessions.fold_queue` exists and is used by both `parse_scan` and (via
      `sessions.fold_queue`) `monitor.lua`'s `feed_line` — one fold, two
      call sites, per `git grep -n "fold_queue" lua/`.
- [ ] `session.todos`, `session.queued`, `session.ctx_pct`, `session.model`,
      `session.mode` are populated by both the live path (`monitor.lua`) and
      the snapshot path (`sessions.lua parse_scan`).
- [ ] `M._line` shows `todos D/T · current` in the info column when
      `it.todos` is present, deferring to `waiting:`/`busy:` when those are
      also true; appends `⧗N`/mode-tag/`ctxNN%` badges without disturbing
      the existing column layout for sessions that have none of the new
      fields (a session with no todos/queue/mode/ctx data renders
      byte-identical to before this plan).
- [ ] The help legend documents the three new markers.
- [ ] No files outside the six in-scope files are modified (`git status`).
- [ ] `plans/modern-cc/README.md`'s status row for 06 is updated, if that
      file exists.

## STOP conditions

Stop and report (do not improvise) if:

- Any "Current state" excerpt above doesn't match the live code (drift) —
  re-read the file and reconcile before proceeding; if the mismatch is
  structural (not just shifted line numbers), STOP.
- `lua/giroux/todos.lua` does not exist by the time you start (workstream 02
  hasn't landed) — this plan cannot produce correct output without it.
- `todos.new()` (or whatever 02 actually calls it) does not expose an
  incremental `:add(event)` + `:summary()` accumulator in a form reconcilable
  by a one-line call-site change (see "Assumed contracts").
- `giroux.stats`'s `Acc:summary()` has no recognizable context/model fields
  reconcilable by a one-line call-site change (workstream 03 hasn't landed
  the context helper, or landed something structurally different).
- The `queue` event kind (transcript.lua's `rtype == "queue-operation"`
  handling) has been removed or its `op`/`text` fields renamed in a way that
  breaks `fold_queue`'s op-string matching, AND workstream 01's actual op
  vocabulary can't be determined by reading the landed `transcript.lua` (a
  simple string rename is NOT a stop condition — just update the branches in
  `fold_queue`).
- The full suite fails after your changes in a way you can't tie to this
  plan's own new tests.

## Maintenance notes

- `CTX_HIGH_PCT = 70` (roster.lua) is a guess at a useful early-warning
  threshold, not a measured one — the maintainer should tune it once they've
  watched it fire a few times in practice (too chatty vs. too late relative
  to Claude Code's actual auto-compact trigger point).
- `sessions.lua`'s `M.scan`/`parse_scan` path is currently exercised only by
  tests (`grep -rn "\.scan(" lua/ tests/ plugin/ scripts/` finds no
  production caller as of this plan). This plan still threads it per the
  initiative brief's explicit instruction ("mirror what's cheap") and to
  keep the two code paths (live monitor vs. snapshot scan) from silently
  diverging — if `M.scan` is ever wired up (or removed as dead code) that's
  a separate call, not blocked by this plan.
- `session.model` is threaded through by this plan (both paths) but
  deliberately **not** rendered on the roster row — no render instruction
  asked for it, and the 34-char title column is already tight. A future
  feed.lua/statsheet.lua integration can consume `session.model` since it's
  already there.
- If workstream 02's todos fold ever needs the actual `TaskCreate`/
  `TaskUpdate` input/result shapes for reference: `TaskCreate` tool_use input
  is `{subject, description, activeForm?}`; `TaskUpdate` tool_use input is
  `{taskId, status}` with `status` one of `pending|in_progress|completed|deleted`,
  and its paired `tool_result`'s `detail` (the `toolUseResult` envelope) is
  `{task: <the updated task object>}`. Verified against this machine's real
  corpus (139 `TaskCreate` + 225 `TaskUpdate` + 4 `TaskStop` across 17
  sessions, 2026-07-08) — this plan doesn't implement that fold (02 does),
  but it's recorded here since this plan's tests reference the contract.
- Reviewer should confirm the badge-omission behavior (Step 6's fourth test)
  — a session with none of the new fields set must render byte-identical to
  the pre-plan `M._line` output; this is what makes the change additive/safe
  for the huge existing fleet of sessions that predate todos/queue/mode
  tracking in their transcripts.
