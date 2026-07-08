# Plan 02 (modern-cc): `todos.lua` — pure fold of Task* events into a live todo model

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/modern-cc/README.md` **if that file exists by the time you run**
> (it may be created by the initiative's coordinating plan; do not create it
> yourself — see Done criteria).
>
> **Drift check (run first)**: `git diff --stat 47b96658977ef64ae415a57a9b33f87930fdaf48..HEAD -- lua/giroux/transcript.lua lua/giroux/stats.lua lua/giroux/monitor.lua`
> This plan cites real line numbers from those three files to ground its
> design (it edits none of them). If any changed since this plan was written,
> re-read the cited excerpts against the live code before proceeding; on a
> shape mismatch for the `tool_call`/`tool_result` events specifically, treat
> it as a STOP condition (see below).

## Status

- **Priority**: P1 (foundational — workstream 06 depends on this module's shape)
- **Effort**: S
- **Risk**: LOW (new pure module + new spec file only; zero existing files touched, zero IO, zero `vim.*` runtime calls)
- **Depends on**: none
- **Category**: feature
- **Planned at**: commit `47b96658977ef64ae415a57a9b33f87930fdaf48`, 2026-07-08 (working tree clean)

## Why this matters

giroux's parser (`transcript.lua`) already turns every `TaskCreate`/`TaskUpdate`/
`TaskStop` tool call into a normal `tool_call`/`tool_result` event — it never
crashes on them. But nothing folds that event stream into a todo model, so
every one of these calls falls through to the feed's generic renderer:

```
lua/giroux/feed.lua:135
  return fmt("tool", ("%s (%s)"):format(e.name, table.concat(keys, ", "))), lines_of(vim.inspect(input))
```

That means a session working a 7-item todo list (the modern Claude Code
default for anything non-trivial) currently shows as seven-plus lines of
`vim.inspect`-dumped `{subject=..., description=..., activeForm=...}` noise
in the feed, and the roster has no "3/7 done, doing: Vet the nvim config"
signal at all — exactly the gap the initiative brief calls out: giroux
degrades the new vocabulary gracefully but renders it as noise instead of
surfacing it as the attention signal it is.

This plan builds the one piece that makes that signal renderable: a pure
accumulator, `giroux.todos`, that folds the Task* event stream into
`{total, done, in_progress, pending, current}`. It mirrors `giroux.stats`'s
accumulator shape on purpose — `monitor.lua` already threads `stats` through
every tracker this exact way (see Current state below), so workstream 06 can
thread `todos` through it identically with no new plumbing pattern to invent.
This module has zero dependents yet; it is pure infrastructure for 06 (and
optionally 04/feed) to consume.

## Current state

**The module does not exist yet** — confirmed:

```
$ ls lua/giroux/todos.lua tests/todos_spec.lua
ls: cannot access 'lua/giroux/todos.lua': No such file or directory
ls: cannot access 'tests/todos_spec.lua': No such file or directory
```

### The event shapes this module folds (`lua/giroux/transcript.lua`)

The parser already normalizes any `tool_use` block (Task* included) into a
`tool_call` event, and any `tool_result` block into a `tool_result` event.
From the `EventKind` doc alias (`transcript.lua:94-114`):

```
---| "tool_call"      # {id, name, input, message_id}
---| "question"       # {id, questions, message_id} AskUserQuestion tool_use (also enters pending)
---| "tool_result"    # {id, text, is_error, detail} detail = toolUseResult envelope (dict|string|list)
```

The `tool_call` construction (`transcript.lua:258-274`, inside `on_assistant`):

```lua
      elseif btype == "tool_use" then
        local id, name = nz(block.id), nz(block.name) or "?"
        if id then
          self.pending_calls[id] = { name = name, ts = nz(rec.timestamp), input = nz(block.input) }
        end
        if name == "AskUserQuestion" then
          local input = nz(block.input) or {}
          out[#out + 1] = envelope(
            { kind = "question", offset = offset, id = id, questions = nz(input.questions) or {}, message_id = mid },
            rec
          )
        else
          out[#out + 1] = envelope(
            { kind = "tool_call", offset = offset, id = id, name = name, input = nz(block.input), message_id = mid },
            rec
          )
        end
```

`TaskCreate`/`TaskUpdate`/`TaskStop` are ordinary tool names here — no
special-casing exists (or should exist) in the parser; they land as
`tool_call` events with `e.name` one of those three strings and `e.input`
whatever the model passed.

The `tool_result` construction (`transcript.lua:336-364`, inside `on_user`):

```lua
  local detail = nz(rec.toolUseResult) -- dict | string | list, per tool
  for _, block in ipairs(content) do
    local btype = nz(block.type)
    if btype == "tool_result" then
      local id = nz(block.tool_use_id)
      ...
      out[#out + 1] = envelope({
        kind = "tool_result",
        offset = offset,
        id = id,
        text = rtext or "",
        is_error = nz(block.is_error) or false,
        detail = detail,
      }, rec)
```

`e.id` on a `tool_result` event equals `e.id` on the `tool_call` event it
resolves (both come from `tool_use_id`/`block.id`) — this is the correlation
key `stats.lua` already relies on (see below) and this module relies on too.

### The accumulator idiom to mirror (`lua/giroux/stats.lua`)

`stats.lua`'s `Acc` (`stats.lua:90-117`) is the shape this module's API must
match:

```lua
---@class giroux.stats.Acc
---@field written table<string, {add: integer, del: integer, n: integer}>
...
local Acc = {}
Acc.__index = Acc

function M.new()
  return setmetatable({
    written = {},
    ...
  }, Acc)
end
```

`Acc:add(e)` (`stats.lua:129-187`) switches on `e.kind`, correlates a
`tool_call` and its later `tool_result` by `e.id` via a private open-calls
table (`stats.lua:100,133,151,169`: `self.calls[e.id] = e` on the call,
consulted and cleared on the matching result) — the exact pattern this
module needs for `TaskCreate` (see "Real corpus grounding" below for *why*
it's needed here too). `Acc:summary()` (`stats.lua:212-225`) returns a plain
table snapshot, and `M.aggregate(events)` (`stats.lua:227-236`) is a
convenience one-shot fold:

```lua
function M.aggregate(events)
  local acc = M.new()
  for _, e in ipairs(events) do
    acc:add(e)
  end
  return acc
end
```

### How `monitor.lua` already threads an accumulator (the pattern 06 will replicate for `todos`)

Not this plan's file, but this is *why* `todos.lua`'s API must match `stats`'s
shape exactly — 06 will thread it in identically. `monitor.lua` requires
`stats` (`monitor.lua:9`), creates one accumulator per tracker at tracker
start (`monitor.lua:309-318`):

```lua
  state.trackers[k] = {
    session = vim.tbl_extend("force", s, { state = "·", pending = {}, activity = "" }),
    acc = stats.new(),
    parser = transcript.parser({ start_offset = from }),
    skip_partial = from > 0,
    live_after = s.size,
  }
```

feeds every parsed event to it (`monitor.lua:217-218`, inside `feed_line`):

```lua
  for _, e in ipairs(tr.parser:feed(line .. "\n")) do
    tr.acc:add(e)
```

and derives session fields off the accumulator's live state
(`monitor.lua:160-161`):

```lua
  tr.session.activity = tr.acc:recent_line()
  tr.session.touched = tr.acc.recent_files[#tr.acc.recent_files]
```

06 will add `tr.todos = todos.new()` next to `acc = stats.new()`,
`tr.todos:add(e)` next to `tr.acc:add(e)`, and
`tr.session.todos = tr.todos:summary()` next to the `tr.session.activity`
line — no new wiring pattern, just this module's API dropped into the
existing slot.

### Real corpus grounding (2026-07-08 census, live `~/.claude/projects` transcripts on this machine)

The initiative brief's stated shapes are close but **one detail is wrong**,
verified directly against 19 real `TaskCreate`/`TaskUpdate` invocations in
`~/.claude/projects/-home-ko-Code-personal/81a2cdf3-b1f3-45a6-b317-20c9b5be0527.jsonl`:

**`TaskCreate` — confirmed exactly as briefed.** The `tool_use` input carries
NO id:

```json
tool_use  TaskCreate {"subject": "Verify giroux.nvim dev loop", "description": "Run smoke (with rtp)...", "activeForm": "Verifying giroux dev loop"}
tool_result           {"task": {"id": "1", "subject": "Verify giroux.nvim dev loop"}}
```

The real task id (a short string like `"1"`, `"2"`, ...) is assigned **only**
in the `tool_result`'s `toolUseResult.task.id`. A design that only reads
`tool_call` inputs (ignoring `tool_result`) can never learn the id that later
`TaskUpdate` calls will reference — it would have to key tasks by the
`tool_use` block id instead (a long `toolu_...` string), which never matches
`TaskUpdate`'s short `taskId`. **This module therefore must consume both the
`tool_call` and the matching `tool_result` for `TaskCreate`**, exactly the
"also fold the tool_result task object" option the workstream brief flagged
as a choice — here it's not optional, it's required for correctness.

**`TaskUpdate` — briefed shape for `tool_result` is WRONG; the `tool_use`
input shape is confirmed.** `tool_use` input:

```json
TaskUpdate {"taskId": "1", "status": "in_progress"}
TaskUpdate {"taskId": "10", "description": "Tailnet auto-discovery SHIPPED (PR #3)..."}   -- no "status" key at all
TaskUpdate {"taskId": "1", "status": "completed"}
```

Confirms the brief: `{taskId, status}`, and additionally proves `status` is
**optional** — a real `TaskUpdate` call in this corpus updates only
`description`, with no status transition. But its `tool_result` is **not**
`{task: <the updated task object>}` as briefed — on disk it is:

```json
tool_result for the {"taskId":"1","status":"in_progress"} call:
  {"success": true, "taskId": "1", "updatedFields": ["status"], "statusChange": {"from": "pending", "to": "in_progress"}}
tool_result for the description-only call:
  {"success": true, "taskId": "10", "updatedFields": ["description"]}
```

**Design consequence**: this module does not read `TaskUpdate`'s
`tool_result` at all — `taskId`/`status` ride the `tool_use` input, which is
always present the moment the update takes effect, so there is nothing the
result would add. (If a future Claude Code version's `TaskUpdate` result
shape carries something this module should react to, that's a follow-up —
see Maintenance notes.)

**`TaskStop` — no real invocation exists in the census.** `TaskStop` appears
in this machine's transcripts, but only inside tool-vocabulary *listings*
(the deferred-tools array Claude Code logs), never as an actual `tool_use`
call:

```
$ grep -o '.\{80\}TaskStop.\{150\}' <subagent transcript with a TaskStop match>
...,"TaskCreate","TaskGet","TaskList","TaskStop","TaskUpdate","WebFetch",...
```

That is a tool-name enumeration, not an invocation. This module implements a
conservative best-effort fold for `TaskStop` (see Step 1) and flags it as
unverified in both the code comment and here — do not treat its behavior as
grounded the way `TaskCreate`/`TaskUpdate` are.

**`TaskGet`/`TaskList`** are read-only introspection tools (also present in
the vocabulary listing above) — deliberately excluded from this module; they
never mutate the todo model.

### Repo conventions that apply

- Pure logic is unit-tested without a buffer, flat spec tables, plain asserts
  (CONTRIBUTING.md; `tests/stats_spec.lua` is the idiom to match).
- Every top-level transcript field is optional — never crash on a missing
  one (CONTRIBUTING.md; this module receives already-parsed events, but
  `e.input`, `e.detail`, and nested fields inside them are all still
  optional from *this* module's point of view and must degrade, not error).
- LuaCATS annotations on public functions. Terse comments; rationale lives in
  the module's own header, mirroring `stats.lua:1-7`.
- Commit messages terse/lowercase/module-prefixed, **no AI trailers**.
- `.stylua.toml`: 2-space indent, `AutoPreferDouble` quotes, 120 column width.

## Commands you will need

| Purpose         | Command                                                                          | Expected on success        |
|------------------|-----------------------------------------------------------------------------------|-----------------------------|
| Tests (all)      | `nvim -l tests/run.lua`                                                          | `... passed, 0 failed`     |
| Tests (this spec)| `nvim -l tests/run.lua todos`                                                    | 9 `todos:` tests pass      |
| Module load check| `nvim --headless --clean --cmd "set rtp+=." -c "lua assert(require('giroux.todos'))" -c "qa"` | silent exit 0 |
| Smoke            | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`                | exit 0, `smoke ok`         |
| Format check     | `stylua --check lua/ tests/`                                                     | exit 0 (no diff)           |
| Format fix       | `stylua lua/ tests/`                                                             | rewrites files in place    |
| Gauntlet         | `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` | 0 crashes |

(Bare `nvim -l scripts/smoke.lua` / `scripts/gauntlet.lua` can't find the
module — always use the `--cmd "set rtp+=."` form, per CLAUDE.md.)

## Scope

**In scope** (the only files you should create/modify):
- `lua/giroux/todos.lua` (**NEW**)
- `tests/todos_spec.lua` (**NEW**)

**Out of scope** (do NOT touch):
- `lua/giroux/monitor.lua` / `lua/giroux/sessions.lua` — threading `todos`
  into the tracker/session-field contract (`session.todos = {...}`) is
  workstream 06. This plan only builds the accumulator 06 will consume.
- `lua/giroux/feed.lua` — folding Task* tool lines into a nicer feed render
  (instead of the `vim.inspect` fallback cited above) is workstream 04's
  concern; it may optionally use `todos.lua`, but this plan doesn't wire it.
- `scripts/smoke.lua` — its module list (`scripts/smoke.lua:2-18`) is a
  static array, not auto-globbed; adding `"giroux.todos"` to it is a
  one-line change that legitimately belongs to whichever plan first wires
  this module into a live code path (recommended: 06, since it's already
  touching `monitor.lua`). Leaving it out of *this* plan is deliberate — see
  Maintenance notes for why the unit tests are sufficient coverage without it.
- `plans/modern-cc/README.md` — do not create it. If it exists by the time
  you execute this plan (another workstream may have added it), update this
  plan's status row there; otherwise skip that step entirely.
- Anything else in the repo.

## Git workflow

- Branch: `advisor/modern-cc-02-todos-module`
- One commit; message like `todos: fold TaskCreate/TaskUpdate/TaskStop into a live todo model`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `lua/giroux/todos.lua`

Write the full file:

```lua
---@module 'giroux.todos'
--- Pure fold of Task* tool events into a live todo model. No IO, no buffer —
--- mirrors giroux.stats's accumulator shape (see stats.lua) so monitor.lua
--- can thread it exactly the way it already threads stats: one `todos.new()`
--- per tracker, `tr.todos:add(e)` per event, `tr.session.todos = tr.todos:summary()`.
---
--- Real corpus shapes (2026-07-08 census, live ~/.claude/projects transcripts):
---   TaskCreate tool_use input:     {subject, description, activeForm?}  -- NO id
---   TaskCreate tool_result detail: {task = {id, subject}}               -- id assigned HERE
---   TaskUpdate tool_use input:     {taskId, status?, description?, ...} -- status is
---     OPTIONAL: a real TaskUpdate call was observed carrying only
---     {taskId, description} with no status change at all.
---   TaskUpdate tool_result detail: {success, taskId, updatedFields, statusChange={from,to}}
---     -- NOT {task = ...}. This module never reads a TaskUpdate's tool_result;
---     -- taskId/status ride the tool_use input, which is always present the
---     -- moment the update takes effect.
---   TaskStop: present in the tool vocabulary but ZERO real invocations found
---     in the census (the string only ever appears inside tool-listing
---     metadata). Treated conservatively — see Acc:add.

local M = {}

---@class giroux.todos.Task
---@field id string
---@field subject string|nil
---@field description string|nil
---@field activeForm string|nil
---@field status string "pending"|"in_progress"|"completed"|"deleted"|string
---@field seq integer monotonic touch order, breaks "most recent" ties

---Tool names this module folds. Exported so other modules (feed's fold UX,
---monitor's dispatch) can detect a Task* event without re-listing the names.
---TaskGet/TaskList are deliberately excluded: read-only, never mutate a task.
M.TASK_TOOL_NAMES = { TaskCreate = true, TaskUpdate = true, TaskStop = true }

---@class giroux.todos.Acc
---@field tasks table<string, giroux.todos.Task>
---@field private pending_creates table<string, {subject: string|nil, description: string|nil, activeForm: string|nil}>
---@field private seq integer
local Acc = {}
Acc.__index = Acc

function M.new()
  return setmetatable({
    tasks = {},
    pending_creates = {},
    seq = 0,
  }, Acc)
end

---Fetch-or-create a task by id and bump its touch order. Robust to updates
---for unknown ids (create-on-update): the TaskCreate landed before this
---tracker attached, or a TaskUpdate references an id this stream never saw
---created.
---@param self giroux.todos.Acc
---@param id string
---@return giroux.todos.Task
local function touch(self, id)
  local t = self.tasks[id]
  if not t then
    t = { id = id, status = "pending", seq = 0 }
    self.tasks[id] = t
  end
  self.seq = self.seq + 1
  t.seq = self.seq
  return t
end

---@param e giroux.transcript.Event
function Acc:add(e)
  if e.kind == "tool_call" then
    if e.name == "TaskCreate" then
      -- buffer: the real task id isn't known until the tool_result lands
      -- (TaskCreate's own input never carries one — see module header).
      if e.id then
        local input = e.input or {}
        self.pending_creates[e.id] =
          { subject = input.subject, description = input.description, activeForm = input.activeForm }
      end
    elseif e.name == "TaskUpdate" then
      local input = e.input or {}
      local id = input.taskId and tostring(input.taskId)
      if id then
        local t = touch(self, id)
        if input.subject then
          t.subject = input.subject
        end
        if input.description then
          t.description = input.description
        end
        if input.status then -- optional: a description-only update omits it
          t.status = input.status
        end
      end
    elseif e.name == "TaskStop" then
      -- Unverified shape (no real invocation on disk as of 2026-07-08 — the
      -- string appears only inside tool-vocabulary listings). Best-effort:
      -- honor an explicit status if the input carries one, otherwise assume
      -- "stop" means "drop it from the active total". Revisit once a real
      -- TaskStop call is on disk.
      local input = e.input or {}
      local id = input.taskId and tostring(input.taskId)
      if id then
        touch(self, id).status = input.status or "deleted"
      end
    end
  elseif e.kind == "tool_result" then
    local created = e.id and self.pending_creates[e.id]
    if created then
      self.pending_creates[e.id] = nil
      local detail = e.detail
      local task_detail = type(detail) == "table" and detail.task or nil
      local id = (type(task_detail) == "table" and task_detail.id and tostring(task_detail.id)) or e.id
      local t = touch(self, id)
      t.subject = (type(task_detail) == "table" and task_detail.subject) or created.subject
      t.description = created.description
      t.activeForm = created.activeForm
    end
  end
end

---@return {total: integer, done: integer, in_progress: integer, pending: integer, current: string|nil}
function Acc:summary()
  local total, done, in_progress, pending = 0, 0, 0, 0
  local current, current_seq = nil, -1
  local latest, latest_seq = nil, -1
  for _, t in pairs(self.tasks) do
    if t.status ~= "deleted" then
      total = total + 1
      local label = t.subject or ("task " .. t.id)
      if t.status == "completed" then
        done = done + 1
      elseif t.status == "in_progress" then
        in_progress = in_progress + 1
        if t.seq > current_seq then
          current, current_seq = label, t.seq
        end
      else -- "pending" or an unrecognized status folds into pending
        pending = pending + 1
      end
      if t.seq > latest_seq then
        latest, latest_seq = label, t.seq
      end
    end
  end
  return { total = total, done = done, in_progress = in_progress, pending = pending, current = current or latest }
end

---Aggregate a list of events in one call (mirrors stats.aggregate).
---@param events giroux.transcript.Event[]
---@return giroux.todos.Acc
function M.aggregate(events)
  local acc = M.new()
  for _, e in ipairs(events) do
    acc:add(e)
  end
  return acc
end

return M
```

**Verify**:
```
nvim --headless --clean --cmd "set rtp+=." -c "lua assert(require('giroux.todos'))" -c "qa"
```
should exit 0 with no output (a syntax/runtime error would print a traceback
and leave nvim sitting at an error prompt instead of exiting — if that
happens, fix before continuing). Also run `stylua --check lua/giroux/todos.lua`
to confirm formatting; if it complains, run `stylua lua/giroux/todos.lua` and
re-check.

### Step 2: Create `tests/todos_spec.lua`

Write the full file (records built from the real corpus shapes grounded
above, following the flat-table/plain-assert idiom of `tests/stats_spec.lua`):

```lua
local todos = require("giroux.todos")
local transcript = require("giroux.transcript")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end

local function events(records)
  local p = transcript.parser()
  local out = {}
  for _, r in ipairs(records) do
    vim.list_extend(out, p:feed(J(r) .. "\n"))
  end
  return out
end

-- tool_use assistant record (mirrors tests/stats_spec.lua's helper).
local function tool_use(id, name, input)
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-07-08T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
    },
  }
end

-- tool_result user record; `detail` becomes toolUseResult.
local function result(id, detail)
  return {
    type = "user",
    uuid = "u" .. id,
    sessionId = "s",
    message = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = "ok" } } },
    toolUseResult = detail,
  }
end

-- A create+its-result pair exactly as the real corpus writes them (2026-07
-- census, ~/.claude/projects/.../81a2cdf3-*.jsonl): tool_use TaskCreate
-- carries no id; the id is assigned in the tool_result's {task={id,subject}}.
local function create(tool_use_id, real_id, subject, extra)
  extra = extra or {}
  local input = {
    subject = subject,
    description = extra.description or (subject .. " — details"),
    activeForm = extra.activeForm or ("Working: " .. subject),
  }
  return {
    tool_use(tool_use_id, "TaskCreate", input),
    result(tool_use_id, { task = { id = real_id, subject = subject } }),
  }
end

-- A TaskUpdate call + its (real-shape) result: {success, taskId, updatedFields, statusChange}.
-- This module never reads the result — included here only for realism.
local function update(tool_use_id, real_id, fields)
  local input = vim.tbl_extend("force", { taskId = real_id }, fields)
  return {
    tool_use(tool_use_id, "TaskUpdate", input),
    result(tool_use_id, { success = true, taskId = real_id, updatedFields = vim.tbl_keys(fields) }),
  }
end

local function flat(...)
  local out = {}
  for _, group in ipairs({ ... }) do
    vim.list_extend(out, group)
  end
  return out
end

return {
  ["todos: TaskCreate is invisible until its tool_result assigns the real id"] = function()
    local acc = todos.new()
    local recs = create("toolu_1", "1", "Ship the thing")
    local p = transcript.parser()
    for _, e in ipairs(p:feed(J(recs[1]) .. "\n")) do
      acc:add(e)
    end
    assert(acc:summary().total == 0, "uncommitted create must not count yet: " .. vim.inspect(acc:summary()))
    for _, e in ipairs(p:feed(J(recs[2]) .. "\n")) do
      acc:add(e)
    end
    local sum = acc:summary()
    assert(sum.total == 1 and sum.pending == 1, vim.inspect(sum))
  end,

  ["todos: create -> in_progress -> completed drives the counters"] = function()
    local evs = events(flat(
      create("toolu_1", "1", "Verify dev loop"),
      create("toolu_2", "2", "Install stylua"),
      update("toolu_3", "1", { status = "in_progress" }),
      update("toolu_4", "1", { status = "completed" }),
      update("toolu_5", "2", { status = "in_progress" })
    ))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 2, vim.inspect(sum))
    assert(sum.done == 1, vim.inspect(sum))
    assert(sum.in_progress == 1, vim.inspect(sum))
    assert(sum.pending == 0, vim.inspect(sum))
    assert(sum.current == "Install stylua", vim.inspect(sum))
  end,

  ["todos: status deleted excludes from total"] = function()
    local evs = events(flat(
      create("toolu_1", "1", "Task A"),
      create("toolu_2", "2", "Task B"),
      update("toolu_3", "2", { status = "deleted" })
    ))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 1, vim.inspect(sum))
    assert(sum.pending == 1, vim.inspect(sum))
  end,

  ["todos: TaskUpdate for an unknown id creates a placeholder (robust to a missed create)"] = function()
    local evs = events(update("toolu_9", "99", { status = "in_progress" }))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 1, vim.inspect(sum))
    assert(sum.in_progress == 1, vim.inspect(sum))
    assert(sum.current == "task 99", vim.inspect(sum)) -- no subject known -> id fallback
  end,

  ["todos: current falls back to the most recently touched task when none in_progress"] = function()
    local evs = events(flat(
      create("toolu_1", "1", "First"),
      create("toolu_2", "2", "Second"),
      update("toolu_3", "1", { status = "completed" })
    ))
    local sum = todos.aggregate(evs):summary()
    assert(sum.in_progress == 0, vim.inspect(sum))
    assert(sum.current == "First", vim.inspect(sum)) -- most recently touched (the completion)
  end,

  ["todos: description-only TaskUpdate (no status key) leaves status untouched"] = function()
    -- real corpus: {"taskId": "10", "description": "..."} with NO status field
    local evs = events(flat(
      create("toolu_1", "10", "Grouped roster"),
      update("toolu_2", "10", { status = "in_progress" }),
      update("toolu_3", "10", { description = "narrowed scope" })
    ))
    local sum = todos.aggregate(evs):summary()
    assert(sum.in_progress == 1, "status must survive a description-only update: " .. vim.inspect(sum))
    assert(sum.current == "Grouped roster", vim.inspect(sum))
  end,

  ["todos: TaskStop honors an explicit status; otherwise best-effort treated as deleted"] = function()
    local evs = events(flat(create("toolu_1", "1", "Task A"), { tool_use("toolu_2", "TaskStop", { taskId = "1" }) }))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 0, "TaskStop with no status assumed deleted: " .. vim.inspect(sum))

    local evs2 = events(flat(
      create("toolu_3", "2", "Task B"),
      { tool_use("toolu_4", "TaskStop", { taskId = "2", status = "completed" }) }
    ))
    local sum2 = todos.aggregate(evs2):summary()
    assert(sum2.total == 1 and sum2.done == 1, "TaskStop with explicit status honors it: " .. vim.inspect(sum2))
  end,

  ["todos: missing input fields never crash (defensive)"] = function()
    local acc = todos.new()
    acc:add({ kind = "tool_call", name = "TaskCreate", id = "x" }) -- input is nil
    acc:add({ kind = "tool_result", id = "x", detail = nil })
    acc:add({ kind = "tool_call", name = "TaskUpdate", id = "y", input = {} }) -- no taskId
    acc:add({ kind = "tool_call", name = "TaskStop", id = "z", input = nil })
    local ok, sum = pcall(function()
      return acc:summary()
    end)
    assert(ok, tostring(sum))
    assert(sum.total == 1 and sum.current == "task x", vim.inspect(sum)) -- only the TaskCreate resolved
  end,

  ["todos: non-Task events are ignored, not counted"] = function()
    local evs = events({
      tool_use("e1", "Edit", { file_path = "/a.rs" }),
      result("e1", { structuredPatch = {} }),
    })
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 0, vim.inspect(sum))
    assert(sum.current == nil, vim.inspect(sum))
  end,
}
```

**Verify**: `nvim -l tests/run.lua todos` → 9 tests pass, 0 failed (the
runner filters by substring match against spec name or test name, both of
which contain `"todos"`).

### Step 3: Full suite + format + regression fences

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`; total passing count is +9 versus the
  pre-plan baseline.
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` first if it
  complains).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0,
  prints `smoke ok`. Note: this does **not** exercise `todos.lua` — its
  module list is static and out of this plan's scope (see Maintenance
  notes). This check only proves the new files didn't break anything else
  (e.g. a stray global, a `require` cycle).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts`
  → still reports 0 crashes. `todos.lua` isn't wired into any live parse path
  yet, so this is a pure regression fence, not new coverage.

## Test plan

- `tests/todos_spec.lua`, 9 tests, all pure (no buffer, no IO):
  1. A `TaskCreate` whose `tool_result` hasn't landed yet contributes nothing
     to `total` — proves the required create-on-result design (see "Real
     corpus grounding": `TaskCreate`'s `tool_use` input has no id).
  2. Full lifecycle (`create` × 2, `in_progress`, `completed`, `in_progress`)
     drives `total`/`done`/`in_progress`/`pending`/`current` correctly.
  3. `status = "deleted"` excludes a task from `total`.
  4. A `TaskUpdate` for an id never created (create-on-update) still produces
     a countable task, with `current` falling back to a `"task <id>"` label
     when no subject is known.
  5. `current` falls back to the most-recently-touched non-deleted task when
     nothing is `in_progress`.
  6. A description-only `TaskUpdate` (the real corpus shape with no `status`
     key) does not clobber an existing status.
  7. `TaskStop`'s best-effort fold: explicit `status` in the input is
     honored; absent, the task is dropped from the total.
  8. Malformed/absent input fields on every Task* tool never error
     (`pcall`-wrapped summary call), and a partially-fed stream (only one of
     two buffered events landing) still produces a sane result.
  9. Non-Task tool events (`Edit`) are ignored entirely.
- Pattern: `tests/stats_spec.lua` (flat table, `require("giroux").setup({})`
  at the top even though this module doesn't need config — matches repo
  convention for consistency with sibling specs; plain asserts with
  `vim.inspect` context on failure).
- Verification: `nvim -l tests/run.lua todos` → all pass; `nvim -l tests/run.lua`
  → full suite, count +9.

## Done criteria

ALL must hold:

- [ ] `lua/giroux/todos.lua` exists: pure (no `require(...)` of any other
      giroux module, no `vim.fn`/`vim.loop`/IO calls), exports `M.new`,
      `Acc:add`, `Acc:summary`, `M.aggregate`, `M.TASK_TOOL_NAMES`.
- [ ] `tests/todos_spec.lua` exists, is discovered by `tests/run.lua` (globs
      `tests/*_spec.lua`), and all 9 tests pass.
- [ ] `nvim -l tests/run.lua` exits `0 failed`; total passing count is +9.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` exits
      0 (existing modules unaffected).
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts`
      still reports 0 crashes.
- [ ] No files outside `lua/giroux/todos.lua` / `tests/todos_spec.lua` are
      modified (`git status --short`).
- [ ] If `plans/modern-cc/README.md` exists at execution time, its status row
      for this plan is updated; if it doesn't exist, this criterion is
      satisfied vacuously (do not create the file).

## STOP conditions

Stop and report (do not improvise) if:

- The `tool_call`/`tool_result` event shapes cited from `transcript.lua`
  (`{id, name, input}` / `{id, detail}`, correlated by matching `id`) no
  longer match the live code — the whole correlation design depends on this.
- A live transcript shows `TaskUpdate`'s `tool_use` input **without** a
  `taskId` field in the common case (not just as a defensive edge case) —
  the create-on-update / status-application design assumes `taskId` is
  always present when a real update happens.
- Implementing a test faithfully would require importing or depending on
  another workstream's file (`monitor.lua`, `feed.lua`, `sessions.lua`) —
  this module and its spec must stay dependency-free; report instead of
  reaching outside scope.
- The full suite fails after adding the new spec in a way you can't tie to
  `tests/todos_spec.lua` itself (a pre-existing regression unrelated to this
  plan — report it, don't fix it here).

## Maintenance notes

- **The initiative brief's `TaskUpdate` `toolUseResult` shape is wrong** —
  it says `{task: <the updated task object>}`; the real corpus (verified
  2026-07-08, 19 invocations) shows `{success, taskId, updatedFields,
  statusChange: {from, to}}`. This module doesn't depend on that shape
  either way (it reads `TaskUpdate`'s `tool_use` input only), but if a
  future consumer wants to read `TaskUpdate`'s result directly, ground it
  against real data again — don't trust the brief's phrasing for that tool.
- **`TaskStop`'s shape is unverified** — no real invocation exists in the
  census this plan was grounded against; only its name appears, inside
  tool-vocabulary listings. The "explicit status wins, else treated as
  deleted" fold is a best-effort placeholder. Revisit `Acc:add`'s `TaskStop`
  branch (and its test) the first time a real `TaskStop` call turns up in a
  transcript — it may turn out to carry no `taskId` at all (e.g. "stop
  whatever's in_progress"), which this module does not currently handle.
- **Session-field contract is a subset of this module's `summary()`** — the
  architecture note in the initiative brief specifies
  `session.todos = {total, done, in_progress, current}`, but this module's
  `summary()` also returns `pending`. That's intentional: 06 can pick
  whichever fields it wants to thread onto `session.todos`; nothing here
  needs to change to support either the 4-field or 5-field version.
- **`scripts/smoke.lua` doesn't load this module** — its module list
  (`scripts/smoke.lua:2-18`) is a hardcoded array, not auto-globbed, and
  it's out of this plan's scope to edit. Until a downstream plan (recommend
  06, already touching `monitor.lua`) adds `"giroux.todos"` to that list, the
  unit tests (which `require("giroux.todos")` directly) are the load-bearing
  check that this module parses and loads correctly.
- **`M.TASK_TOOL_NAMES`** is exported so 04 (feed's fold UX) and 06
  (monitor's per-event dispatch) don't each re-hardcode
  `{TaskCreate, TaskUpdate, TaskStop}`; if a fourth Task* mutating tool shows
  up in a future Claude Code release, this is the one place to add it.
- Reviewer should confirm `Acc:add` never indexes into `e.input`/`e.detail`
  without a `type(...) == "table"` guard first — every field on those two is
  optional per CONTRIBUTING.md, and this module receives already-parsed
  events from a parser that itself never crashes on malformed records, so
  `todos.lua` inherits that obligation rather than re-deriving it from raw
  JSON.
