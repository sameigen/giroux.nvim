# Plan 03-context: stats.lua — context-window pressure + active model summary

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update/add the status row for this
> plan in `plans/modern-cc/README.md` if one exists by then.
>
> **Drift check (run first)**: `git diff --stat 47b9665..HEAD -- lua/giroux/stats.lua tests/stats_spec.lua`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Consumed by**: workstream 06 (integration) — reads `acc:summary().model`
  and `acc:summary().ctx_pct` off the per-tracker accumulator to fill
  `session.model` / `session.ctx_pct` in the session-field contract.
- **Category**: feature
- **Planned at**: commit `47b9665`, 2026-07-08, branch `feature/subagent-monitoring`.
  `lua/giroux/stats.lua` and `tests/stats_spec.lua` were clean (no uncommitted
  changes) at read time — this plan's excerpts are read straight off that
  commit, not off a dirty tree.

## Why this matters

giroux's modern-vocabulary initiative wants two new attention signals on
every session: **which model is currently active**, and **how full its
context window is right now**. `stats.lua` already ingests every `usage`
event (`lua/giroux/transcript.lua:291-304`) into a running total
(`Acc.tokens`, `lua/giroux/stats.lua:171-178`) and a set of every model seen
(`Acc.models`, same block) — but both are the wrong shape for this job:

- `Acc.tokens` is a **cumulative sum across the whole session**. Useful for
  spend, useless for "how close to the wall is this turn" — a session that
  has burned 2M cumulative input tokens over 40 turns might have a
  perfectly comfortable 20k-token window *right now* if it compacted
  recently. `statsheet.lua:102` computes exactly this cumulative shape
  today (`total_in = t.input + t.cache_read + t.cache_creation`) for the
  Spend section's cache-hit ratio — that formula is correct for spend, and
  it is **not** what context-window pressure needs. This plan must not
  confuse the two.
- `Acc.models` is a **set** (`table<string, boolean>`, turned into a sorted
  list by `vim.tbl_keys` in `summary()`, `lua/giroux/stats.lua:221`) — every
  model the session ever touched, with no notion of *current*. A session
  that started on one model and got switched (manual override, a future
  auto-downgrade, budget policy) has no way to report which one is active
  **now**.

Both gaps are one-line-per-usage-event fixes: the transcript already hands
`stats.lua` a `model` field and the three token counts that sum to a turn's
context size, once per `usage` event (deduped by `message.id`, so exactly
once per API turn — see `transcript.lua:9,106,126,292-293`). This plan adds
a second, non-cumulative "latest" bookkeeping and a small best-effort
model→limit table so `Acc:summary()` can hand back a ready-to-render
`model` + `ctx_pct` without any caller having to reimplement the percentage
math or the "which one is latest" logic.

Every tracker already owns an `Acc` today (`monitor.lua:311`,
`stats.new()` per session tracker; `sessions.lua:127` similarly for the
one-shot scan path) and feeds it every event as the transcript is parsed —
so this is a pure data-shape addition to an accumulator that is already
wired into both the realtime and scan paths. No new plumbing is needed for
this plan to be useful to 06; 06 only has to read two new fields off the
`summary()` table it already gets.

## Current state

`lua/giroux/transcript.lua` — the `usage` event shape (already correct,
no changes needed here), deduped once per `message.id`
(`transcript.lua:291-304`):

```lua
  local usage = nz(msg.usage)
  if usage and mid and not self.seen_usage[mid] then
    self.seen_usage[mid] = true
    out[#out + 1] = envelope({
      kind = "usage",
      offset = offset,
      message_id = mid,
      model = model,
      input = nz(usage.input_tokens) or 0,
      output = nz(usage.output_tokens) or 0,
      cache_read = nz(usage.cache_read_input_tokens) or 0,
      cache_creation = nz(usage.cache_creation_input_tokens) or 0,
    }, rec)
  end
```

`lua/giroux/stats.lua` — the `Acc` class annotation (`stats.lua:90-101`):

```lua
---@class giroux.stats.Acc
---@field written table<string, {add: integer, del: integer, n: integer}>
---@field read table<string, integer> path -> times read
---@field web string[]
---@field bash integer
---@field tools table<string, integer> tool name -> count
---@field tokens {out: integer, cache_read: integer, cache_creation: integer, input: integer}
---@field models table<string, boolean>
---@field subagents table[] {agent_id, agent_type, status, stats}
---@field recent_files string[] last touched paths, newest last
---@field private calls table<string, table> open tool_call inputs by id
local Acc = {}
```

`M.new()` (`stats.lua:104-117`):

```lua
function M.new()
  return setmetatable({
    written = {},
    read = {},
    web = {},
    bash = 0,
    tools = {},
    tokens = { out = 0, cache_read = 0, cache_creation = 0, input = 0 },
    models = {},
    subagents = {},
    recent_files = {},
    calls = {},
  }, Acc)
end
```

`Acc:add`'s `usage` branch (`stats.lua:171-178`) — this is the only place
that sees a `usage` event, and the only place this plan needs to touch to
capture "latest":

```lua
  elseif e.kind == "usage" then
    self.tokens.out = self.tokens.out + (e.output or 0)
    self.tokens.input = self.tokens.input + (e.input or 0)
    self.tokens.cache_read = self.tokens.cache_read + (e.cache_read or 0)
    self.tokens.cache_creation = self.tokens.cache_creation + (e.cache_creation or 0)
    if e.model then
      self.models[e.model] = true
    end
```

`Acc:summary()` (`stats.lua:212-225`) — the public read-out, the only
consumer of which is `statsheet.lua:165` (`M.render(acc:summary(), ...)`,
which reads individual fields by name, not exhaustive-equality — adding
fields here is safe and non-breaking):

```lua
---@return {written: table, read: table, web: string[], tokens: table, tools: table, subagents: table[], recent_files: string[]}
function Acc:summary()
  return {
    written = self.written,
    read = self.read,
    web = self.web,
    bash = self.bash,
    tokens = self.tokens,
    tools = self.tools,
    models = vim.tbl_keys(self.models),
    subagents = self.subagents,
    recent_files = self.recent_files,
  }
end
```

`tests/stats_spec.lua` — the `tool_use` fixture builder every test in this
file uses (`tests/stats_spec.lua:18-38`), currently hardcoded to one model
and one fixed usage block (no way for a test to vary either per call):

```lua
local function tool_use(id, name, input)
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
      usage = {
        input_tokens = 100,
        output_tokens = 50,
        cache_read_input_tokens = 900,
        cache_creation_input_tokens = 100,
      },
    },
  }
end
```

Real model ids observed in this repo's own fixtures/tests are fictional
flavor names for this exercise (`"claude-fable-5"`, and `"claude-basic"` in
`tests/fixtures`) — there is no ground truth here for exact production
context-window sizes per model family, hence "small table + sane default,
never crash on unknown" per the initiative brief. This plan's model→limit
table is explicitly best-effort and named as such.

Repo conventions that apply:
- Pure logic is unit-tested without a buffer (CONTRIBUTING.md); `stats.lua`
  is 100% pure today (no buffer, no ssh) and must stay that way.
- Every top-level transcript field is optional — never crash on missing
  model/usage fields; degrade to `nil` (CONTRIBUTING.md, and explicitly
  required by this workstream's brief).
- Terse comments; commit messages terse/lowercase/module-prefixed, no AI
  trailers. Example from `git log`: `monitor: track subagents — enrich from
  meta.json, roll up instead of paging`.

## Commands you will need

| Purpose      | Command                              | Expected on success        |
|--------------|---------------------------------------|-----------------------------|
| Tests (all)  | `nvim -l tests/run.lua`               | `... passed, 0 failed`     |
| Tests (one)  | `nvim -l tests/run.lua stats`         | the stats specs pass       |
| Smoke        | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` | exit 0, modules load |
| Format check | `stylua --check lua/ tests/`          | exit 0 (no diff)           |
| Format fix   | `stylua lua/ tests/`                  | rewrites files in place    |
| Gauntlet     | `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` | 0 crashes |

(Typecheck runs in CI via `nvim-typecheck-action` on `lua/` at Error level;
run it locally only if you have `lua-language-server` installed.)

## Scope

**In scope** (the only files you should modify):
- `lua/giroux/stats.lua`
- `tests/stats_spec.lua`

**Out of scope** (do NOT touch):
- `lua/giroux/statsheet.lua` — rendering the new `model`/`ctx_pct` fields
  into the `S` stat-sheet buffer is a follow-on (or workstream 06's job);
  this plan only adds the fields to `Acc:summary()`.
- `lua/giroux/monitor.lua` / `lua/giroux/sessions.lua` / `lua/giroux/roster.lua`
  — threading `acc:summary().model` / `.ctx_pct` onto `session.model` /
  `session.ctx_pct` (the session-field contract) is workstream 06's job.
  Do not touch the trackers' `acc = stats.new()` wiring.
- `lua/giroux/transcript.lua` — the `usage` event already carries every
  field this plan needs (`model`, `input`, `cache_read`, `cache_creation`);
  no parser change is required or in scope.
- `lua/giroux/feed.lua` — has its own independent, already-working
  `feed.model` tracking (`feed.lua:298,358,406`) for the feed statusline;
  leave it alone, it is not this plan's concern.

## Git workflow

- Branch: `advisor/03-context-model`
- One commit; message style like `stats: track active model + context-window pressure off the latest usage event`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the model→limit table and the two pure pressure functions

In `lua/giroux/stats.lua`, insert a new section between the end of the
"paths a tool touches" section and the start of the "accumulator" section.
Find this exact block (`stats.lua:84-88`):

```lua
  return nil
end

-- ---------------------------------------------------------------------------
-- accumulator
```

Replace it with:

```lua
  return nil
end

-- ---------------------------------------------------------------------------
-- context-window pressure

-- Best-effort model -> context-window (tokens) table. Order matters: matched
-- top-to-bottom on a lower-cased model id, first hit wins, so a more specific
-- marker (e.g. a long-context "1m" variant) must precede the generic family
-- match it would otherwise also satisfy. Unknown/missing model -> the default.
-- Never authoritative — Anthropic can change limits without notice; this is a
-- pressure *estimate* for the roster/statsheet, not a hard budget.
local DEFAULT_CONTEXT_LIMIT = 200000
local CONTEXT_LIMITS = {
  { pat = "1m", limit = 1000000 }, -- long-context beta variants, e.g. "...-1m"
  { pat = "opus", limit = 200000 },
  { pat = "sonnet", limit = 200000 },
  { pat = "haiku", limit = 200000 },
}

---Context-window size (tokens) to judge pressure against for a model id.
---Falls back to DEFAULT_CONTEXT_LIMIT for nil/unrecognized models — never nil.
---@param model string|nil
---@return integer
function M._context_limit(model)
  local low = (model or ""):lower()
  for _, e in ipairs(CONTEXT_LIMITS) do
    if low:find(e.pat, 1, true) then
      return e.limit
    end
  end
  return DEFAULT_CONTEXT_LIMIT
end

---Context-window pressure: `context_tokens` as a percentage of the model's
---context limit, rounded to the nearest integer. Pure, best-effort, never
---crashes — nil/negative tokens (nothing observed yet) degrade to nil.
---@param model string|nil
---@param context_tokens integer|nil
---@return integer|nil
function M.ctx_pct(model, context_tokens)
  if not context_tokens or context_tokens < 0 then
    return nil
  end
  local limit = M._context_limit(model)
  if not limit or limit <= 0 then
    return nil
  end
  return math.floor((100 * context_tokens / limit) + 0.5)
end

-- ---------------------------------------------------------------------------
-- accumulator
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 2: Extend the `Acc` class annotation

In `stats.lua`, find (`stats.lua:97-98`):

```lua
---@field models table<string, boolean>
---@field subagents table[] {agent_id, agent_type, status, stats}
```

Replace with:

```lua
---@field models table<string, boolean>
---@field latest_model string|nil model id off the most recent usage event (active model)
---@field latest_context integer|nil most recent turn's context size: input+cache_read+cache_creation
---@field subagents table[] {agent_id, agent_type, status, stats}
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 3: Initialize the new fields in `M.new()`

Find (`stats.lua:111-113`):

```lua
    tokens = { out = 0, cache_read = 0, cache_creation = 0, input = 0 },
    models = {},
    subagents = {},
```

Replace with:

```lua
    tokens = { out = 0, cache_read = 0, cache_creation = 0, input = 0 },
    models = {},
    latest_model = nil,
    latest_context = nil,
    subagents = {},
```

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 4: Track "latest" in the `usage` branch of `Acc:add`

Find (`stats.lua:171-178`):

```lua
  elseif e.kind == "usage" then
    self.tokens.out = self.tokens.out + (e.output or 0)
    self.tokens.input = self.tokens.input + (e.input or 0)
    self.tokens.cache_read = self.tokens.cache_read + (e.cache_read or 0)
    self.tokens.cache_creation = self.tokens.cache_creation + (e.cache_creation or 0)
    if e.model then
      self.models[e.model] = true
    end
```

Replace with:

```lua
  elseif e.kind == "usage" then
    self.tokens.out = self.tokens.out + (e.output or 0)
    self.tokens.input = self.tokens.input + (e.input or 0)
    self.tokens.cache_read = self.tokens.cache_read + (e.cache_read or 0)
    self.tokens.cache_creation = self.tokens.cache_creation + (e.cache_creation or 0)
    if e.model then
      self.models[e.model] = true
      self.latest_model = e.model
    end
    -- context-window pressure tracks the LATEST turn only (not cumulative):
    -- input + cache_read + cache_creation on one usage record IS that turn's
    -- total context size, per Anthropic's usage accounting. Events arrive in
    -- transcript order, so the last one processed is the most recent turn.
    self.latest_context = (e.input or 0) + (e.cache_read or 0) + (e.cache_creation or 0)
```

Leave the `tool_call`/`tool_result`/`subagent` branches untouched.

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 5: Surface the new fields via `Acc:summary()`

Find (`stats.lua:212-225`):

```lua
---@return {written: table, read: table, web: string[], tokens: table, tools: table, subagents: table[], recent_files: string[]}
function Acc:summary()
  return {
    written = self.written,
    read = self.read,
    web = self.web,
    bash = self.bash,
    tokens = self.tokens,
    tools = self.tools,
    models = vim.tbl_keys(self.models),
    subagents = self.subagents,
    recent_files = self.recent_files,
  }
end
```

Replace with:

```lua
---@return {written: table, read: table, web: string[], tokens: table, tools: table, subagents: table[], recent_files: string[], model: string|nil, ctx_tokens: integer|nil, ctx_limit: integer|nil, ctx_pct: integer|nil}
function Acc:summary()
  return {
    written = self.written,
    read = self.read,
    web = self.web,
    bash = self.bash,
    tokens = self.tokens,
    tools = self.tools,
    models = vim.tbl_keys(self.models),
    subagents = self.subagents,
    recent_files = self.recent_files,
    model = self.latest_model,
    ctx_tokens = self.latest_context,
    ctx_limit = self.latest_context and M._context_limit(self.latest_model) or nil,
    ctx_pct = M.ctx_pct(self.latest_model, self.latest_context),
  }
end
```

`ctx_limit` is included alongside `ctx_pct` (not strictly required by the
session-field contract, which only names `session.ctx_pct`/`session.model`)
because it is nearly free and lets a future renderer show `"84k/200k"`
without recomputing `_context_limit` itself; it is `nil` exactly when
`ctx_tokens` is `nil` (nothing observed yet), never a spurious default with
no data behind it.

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.
`nvim -l tests/run.lua stats` → existing stats specs still pass unchanged
(no assertions on the exact key set of `summary()`'s return table exist
today, so adding fields cannot break them).

### Step 6: Make the `tool_use` test fixture able to vary model/usage

In `tests/stats_spec.lua`, find (`tests/stats_spec.lua:18-38`):

```lua
local function tool_use(id, name, input)
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
      usage = {
        input_tokens = 100,
        output_tokens = 50,
        cache_read_input_tokens = 900,
        cache_creation_input_tokens = 100,
      },
    },
  }
end
```

Replace with:

```lua
local function tool_use(id, name, input, opts)
  opts = opts or {}
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = opts.model or "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
      usage = opts.usage or {
        input_tokens = 100,
        output_tokens = 50,
        cache_read_input_tokens = 900,
        cache_creation_input_tokens = 100,
      },
    },
  }
end
```

`opts` is optional and defaults to today's exact fixed shape, so every
existing call site (`tool_use("e1", "Edit", {...})` etc., 3-arg calls
throughout the file) is unaffected.

**Verify**: `nvim -l tests/run.lua stats` → still 0 failed, same count as
before this step (no new tests added yet).

### Step 7: Add the three new tests

In `tests/stats_spec.lua`, find the end of the existing "aggregates
written..." test and the start of the next one (`tests/stats_spec.lua:84-87`,
line numbers pre-Step-6-edit — locate by content, not number, since Step 6
shifted lines):

```lua
    assert(sum.tools.Edit == 2 and sum.tools.WebFetch == 1)
  end,

  ["stats: recent_line and recent_files"] = function()
```

Insert three new tests between the `end,` and the next test, so the block
becomes:

```lua
    assert(sum.tools.Edit == 2 and sum.tools.WebFetch == 1)
  end,

  ["stats: ctx_pct is a model-aware, rounded percentage that never crashes"] = function()
    -- known family, exact round numbers so the rounding rule isn't ambiguous
    assert(
      stats.ctx_pct("claude-sonnet-4-5-20250929", 100000) == 50,
      tostring(stats.ctx_pct("claude-sonnet-4-5-20250929", 100000))
    )
    -- unrecognized model id still gets the sane 200k default, never crashes
    assert(stats.ctx_pct("some-future-model-nobody-has-seen", 50000) == 25)
    -- a longer-context ("1m") variant gets the bigger window
    assert(stats.ctx_pct("claude-sonnet-4-5-1m", 500000) == 50)
    -- degrade to nil: no context observed, or a nonsensical negative count
    assert(stats.ctx_pct("claude-fable-5", nil) == nil, "no usage yet -> nil")
    assert(stats.ctx_pct("claude-fable-5", -5) == nil, "negative -> nil")
    -- nil model still resolves to the default limit (never crashes on missing model)
    assert(stats.ctx_pct(nil, 100000) == 50, "nil model -> default 200k limit")
  end,

  ["stats: summary tracks active model + context pressure off the LATEST usage event, not cumulative"] = function()
    local evs = events({
      tool_use("e1", "Edit", { file_path = "/a.rs" }, {
        model = "claude-haiku-4",
        usage = { input_tokens = 1000, output_tokens = 10, cache_read_input_tokens = 0, cache_creation_input_tokens = 0 },
      }),
      tool_use("e2", "Edit", { file_path = "/b.rs" }, {
        model = "claude-opus-4-5",
        usage = { input_tokens = 40000, output_tokens = 20, cache_read_input_tokens = 60000, cache_creation_input_tokens = 0 },
      }),
    })
    local sum = stats.aggregate(evs):summary()
    assert(sum.model == "claude-opus-4-5", "latest usage event's model wins: " .. tostring(sum.model))
    assert(
      sum.ctx_tokens == 100000,
      "latest turn only (40000+60000), not cumulative across both calls: " .. tostring(sum.ctx_tokens)
    )
    assert(sum.ctx_limit == 200000, tostring(sum.ctx_limit))
    assert(sum.ctx_pct == 50, "100000/200000 = 50%: " .. tostring(sum.ctx_pct))
  end,

  ["stats: model/ctx fields degrade to nil when no usage has been observed"] = function()
    local sum = stats.aggregate({}):summary()
    assert(sum.model == nil)
    assert(sum.ctx_tokens == nil)
    assert(sum.ctx_limit == nil)
    assert(sum.ctx_pct == nil)
  end,

  ["stats: recent_line and recent_files"] = function()
```

**Verify**: `nvim -l tests/run.lua stats` → all stats specs pass, count is
+3 versus Step 6.

### Step 8: Full suite + format + gauntlet

**Verify**:
- `nvim -l tests/run.lua` → `... passed, 0 failed`; total count is +3 versus
  before this plan.
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` first if
  it complains about the new blocks' formatting).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts`
  → 0 crashes. Note: the gauntlet (`scripts/gauntlet.lua:8,36`) only drives
  `transcript.parser()` — it never calls into `stats.lua` — so this gate
  cannot regress from this plan's change and is run purely for parity with
  the repo's standard four-command verification suite (CONTRIBUTING.md), not
  because it exercises the new code.

## Test plan

- `stats: ctx_pct is a model-aware, rounded percentage that never crashes` —
  exercises `M.ctx_pct` directly: known family match, unknown-model default,
  the long-context "1m" variant, nil-context degrade, negative-context
  degrade, nil-model degrade-to-default (not degrade-to-nil — a missing
  model must not suppress a pressure estimate, it must use the sane default).
- `stats: summary tracks active model + context pressure off the LATEST usage
  event, not cumulative` — the core regression this plan exists to prevent:
  two usage events with different models/token counts, and `summary()` must
  report the **second** (latest) one's model and **only that turn's** token
  sum, not a running total across both.
- `stats: model/ctx fields degrade to nil when no usage has been observed` —
  zero events in, all four new fields nil out, no crash.
- Pattern: existing tests in `tests/stats_spec.lua` (flat assertions inside
  the module-level test table, `stats.aggregate(events(...)):summary()`
  idiom already used throughout the file).
- Verification: `nvim -l tests/run.lua stats` → all pass; `nvim -l tests/run.lua`
  → full suite still green.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits with `0 failed`; total passing count is +3.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` reports 0 crashes.
- [ ] `M.ctx_pct` and `M._context_limit` exist in `lua/giroux/stats.lua` and
      are pure (no `vim.notify`, no I/O, no buffer/window calls).
- [ ] `Acc:summary()` returns `model`, `ctx_tokens`, `ctx_limit`, `ctx_pct`
      alongside every pre-existing key (`written`, `read`, `web`, `bash`,
      `tokens`, `tools`, `models`, `subagents`, `recent_files` — none removed
      or renamed).
- [ ] `git grep -n "latest_model\|latest_context" lua/giroux/stats.lua` shows
      the class annotation, `M.new()`, the `usage` branch of `Acc:add`, and
      `Acc:summary()` — all four sites updated consistently.
- [ ] No files outside `lua/giroux/stats.lua` and `tests/stats_spec.lua` are
      modified (`git status`).
- [ ] `plans/modern-cc/README.md` status row for this plan updated, if that
      file exists by the time this plan is executed.

## STOP conditions

Stop and report (do not improvise) if:

- The `usage` event shape in `transcript.lua` (`kind, message_id, model,
  input, output, cache_read, cache_creation`) or its once-per-`message.id`
  dedup no longer matches the excerpt in "Current state" — the whole
  "latest turn" premise depends on exactly one `usage` event per API turn,
  in transcript order.
- `Acc:summary()` gains a consumer elsewhere in the repo (besides
  `statsheet.lua`'s field-by-field reads) that does exhaustive key-set
  comparison — adding fields would then be a breaking change, and you should
  report rather than work around it.
- You find that `usage` events are **not** guaranteed to arrive in
  chronological transcript order when fed to `Acc:add` (e.g. a caller
  pre-sorts or replays out of order) — that would invalidate "latest wins"
  as a proxy for "most recent turn." Check `monitor.lua`'s and `sessions.lua`'s
  feed loops before concluding this; if genuinely out of order, report it,
  don't paper over it with a timestamp-based fix here.
- The full suite fails after the change in a way you can't tie to the new
  code (Step 8).

## Maintenance notes

- The `CONTEXT_LIMITS` table is explicitly best-effort/speculative — this
  repo's own fixtures use fictional model ids (`claude-fable-5`,
  `claude-basic`) with no real-world context-window grounding. When real
  production model ids and their actual limits are confirmed, update the
  table in one place (`stats.lua`, just above `M._context_limit`); the
  pure-function test (`stats: ctx_pct is a model-aware...`) is the seam to
  extend alongside it.
- `latest_context` is updated on every `usage` event regardless of whether
  that event carries a `model` (the `if e.model then ... end` guard only
  gates `latest_model`) — a `usage` event without a model (never observed in
  the census, but every field is optional per this repo's parsing
  philosophy) still updates the token count against whatever model was last
  known, rather than dropping the data. This is a deliberate degrade, not an
  oversight.
- Workstream 06 (integration) is the intended next reader: it should pull
  `model`/`ctx_pct` off the tracker's existing `acc:summary()`
  (`monitor.lua:311`, `acc = stats.new()` per tracker, already fed every
  event) — no new accumulator or wiring should be needed on its side beyond
  reading these two fields into `session.model` / `session.ctx_pct`.
- Rendering (`statsheet.lua`'s Spend section, and any roster column) is
  deliberately out of scope here — this plan only makes the data available
  on `summary()`.
