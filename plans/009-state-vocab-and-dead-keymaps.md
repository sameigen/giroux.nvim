# Plan 009: Single-source the state vocabulary; retire silently-dead keymaps

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/monitor.lua lua/giroux/roster.lua lua/giroux/feed.lua lua/giroux/init.lua`
> If any changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW-MED
- **Depends on**: none (but coordinate with 001/007 if they also touch
  `monitor.lua` — different regions, but rebase carefully)
- **Category**: tech-debt
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

Two small debts that make future state changes error-prone:

1. **The attention-ordering priority map is duplicated byte-for-byte** in
   `monitor.lua` and `roster.lua`, and the glyph→label tables live in three
   places (`roster.lua`, `feed.lua`, plus the order map). Adding or reordering a
   state — exactly the kind of change the working tree has been making around
   `✓` done/unseen — means editing the same constant in multiple files, and a
   missed copy silently mis-sorts the roster against the monitor.
2. **Three feed keymaps are defined in config but wired to nothing.**
   `filter_bash`, `filter_edits`, and `thinking` appear in `init.lua`'s feed
   keymap defaults, but `feed.lua` never references them — a user can rebind keys
   that do nothing, and the defaults imply features that don't exist.

Fixing #1 is a clean single-source-of-truth extraction. Fixing #2 is honest
surface hygiene. Both are low-risk.

## Current state

### The duplicated ORDER map

`lua/giroux/monitor.lua:41`:
```lua
local ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["✓"] = 4, ["○"] = 5, ["~"] = 6, ["·"] = 7 }
```
`lua/giroux/roster.lua:18` — **identical**:
```lua
local ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["✓"] = 4, ["○"] = 5, ["~"] = 6, ["·"] = 7 }
```
Both are used to sort by attention (`monitor.lua:73`, `roster.lua:128,185-186`).

Glyph→label tables also duplicated:
- `roster.lua:19` `STATE_NAMES = { ["?"] = "needs you", ["●"] = "working", ["✓"] = "done", ... }`
- `feed.lua:56` `STATE = { ["●"] = { label = "working", hl = "GirouxStateWorking" }, ... }`

### The unwired feed keymaps

`lua/giroux/init.lua:86-101` (feed keymaps) declares:
```lua
    feed = {
      toggle_fold = "<Tab>",
      attach = "a",
      steer = "s",
      diff = "v",
      open_subagent = "<CR>",
      qa = "Q",
      peek = "K",
      next_turn = "]]",
      prev_turn = "[[",
      filter_bash = "b",
      filter_edits = "e",
      thinking = "T",
      close = "q",
      help = "?",
    },
```

`feed.lua` wires only: `toggle_fold`, `open_subagent`, `close`, `attach`,
`steer`, `qa`, `peek`, `next_turn`, `prev_turn` (grep:
`git grep -no "km\.[a-z_]*" lua/giroux/feed.lua`). Never referenced:
`filter_bash`, `filter_edits`, `thinking`. (`diff` is also unwired in the feed,
but see the IMPORTANT note below — leave `diff` alone.)

**IMPORTANT — do NOT remove `diff` or the roster `kill`/`diff` keys.** `diff`
(`v`) is the reserved key for the tier-2 git-diff feature (DESIGN.md §9/§14, a
planned direction item), and the roster `kill`/`diff` keys are *honestly*
stubbed — they fire a `"lands later"` notice (`roster.lua:402-405`), so the user
is told they're coming. Those are honest placeholders. Only `filter_bash`,
`filter_edits`, `thinking` are *silently* dead (no wiring, no notice).

Design context for the three you're removing (inline so the reviewer knows
they're deferred, not cancelled): DESIGN.md §8 lists bash/edits filters ("❓
filters (bash-only, edits-only) — keep? → yes, cheap, `b`/`e`") and folded
thinking as *intended but unbuilt*. Removing the dead config knobs does not
cancel the feature — when filters/thinking-fold are implemented, the keymap
entries return alongside the wiring.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `state: single-source the glyph order/labels; drop unwired feed keys`.

## Commands you will need

| Purpose      | Command                          | Expected on success    |
|--------------|----------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`          | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua roster`   | roster specs pass      |
| Tests (one)  | `nvim -l tests/run.lua monitor`  | monitor specs pass     |
| Smoke        | `nvim -l scripts/smoke.lua`      | exit 0                 |
| Format check | `stylua --check lua/ tests/`     | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/state.lua` (create — the single source for glyph order + labels)
- `lua/giroux/monitor.lua` (import ORDER from `state`)
- `lua/giroux/roster.lua` (import ORDER + labels from `state`)
- `lua/giroux/feed.lua` (import labels from `state`; keep the `hl` mapping local
  if it's feed-specific)
- `lua/giroux/init.lua` (remove the three unwired feed keymap defaults)
- `tests/state_spec.lua` (create — a tiny test for the shared table)

**Out of scope** (do NOT touch):
- The `diff` (`v`) feed keymap and the roster `kill`/`diff` keys and their
  `"lands later"` stub — reserved/honest placeholders.
- The sort *logic* in `monitor.sessions` / `roster.by_attention` — only the
  ORDER *table* moves; the comparisons stay put.
- Highlight-group names (`GirouxState*`) — leave feed's `hl` associations where
  they are unless trivially co-locatable.

## Git workflow

- Branch: `advisor/009-state-vocab-and-dead-keymaps`
- One commit; message like `state: single-source glyph order/labels; drop 3 unwired feed keys`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `lua/giroux/state.lua`

A small module holding the canonical vocabulary. Include ORDER, a glyph→label
map, and (optionally) a helper for the sort key:

```lua
---@module 'giroux.state'
--- The single source of truth for roster/monitor/feed state vocabulary: the
--- attention priority order and the glyph→label map. Duplicating these across
--- modules silently mis-sorts the roster against the monitor.

local M = {}

-- Attention priority: lower sorts first. ✓ (done/unseen) ranks under working
-- and above idle so "ready to review" floats up. See monitor.derive.
M.ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["✓"] = 4, ["○"] = 5, ["~"] = 6, ["·"] = 7 }

M.LABEL = {
  ["?"] = "needs you",
  ["✗"] = "dead",
  ["●"] = "working",
  ["✓"] = "done",
  ["○"] = "idle",
  ["~"] = "stale",
  ["·"] = "idle",
}

---Sort rank for a state glyph (unknown glyphs sort last).
---@param glyph string
---@return integer
function M.rank(glyph)
  return M.ORDER[glyph] or 9
end

return M
```

Copy the exact label strings from `roster.lua:19` `STATE_NAMES` (don't invent
new wording). If `STATE_NAMES` and feed's `STATE` labels disagree on any glyph,
prefer `roster.lua`'s (it's the user-facing board vocabulary) and note the
discrepancy in your status row.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0 (smoke loads every module).

### Step 2: Point `monitor.lua` and `roster.lua` at `state.ORDER`

Replace the local `ORDER` in both files with `require("giroux.state").ORDER`
(assign to a local at the top: `local state = require("giroux.state")` then use
`state.ORDER` or keep `local ORDER = state.ORDER`). Keep the `or 9` fallback in
the comparisons exactly as-is (or route through `state.rank`). Replace
`roster.lua`'s `STATE_NAMES` uses with `state.LABEL`.

**Verify**: `nvim -l tests/run.lua roster monitor` → wait, the runner takes ONE
filter arg; run `nvim -l tests/run.lua roster` then `nvim -l tests/run.lua monitor`
→ both pass. The roster sort behavior must be unchanged.

### Step 3: Point `feed.lua`'s labels at `state.LABEL`

`feed.lua`'s `STATE` table couples a label with a highlight group. Keep the `hl`
mapping where it is, but source the `label` from `state.LABEL` so the wording is
single-sourced:

```lua
local state = require("giroux.state")
local STATE = {
  ["●"] = { label = state.LABEL["●"], hl = "GirouxStateWorking" },
  ["?"] = { label = state.LABEL["?"], hl = "GirouxStateQuestion" },
  ...
}
```

(If feed intentionally shows an uppercase `"QUESTION"` where the roster shows
`"needs you"`, that's a deliberate visual difference — keep feed's literal in
that one case and note it. Don't flatten a deliberate difference.)

**Verify**: `nvim -l tests/run.lua feed` → passes; `nvim -l scripts/smoke.lua`
→ exit 0.

### Step 4: Remove the three silently-dead feed keymaps

In `lua/giroux/init.lua`, delete the `filter_bash = "b"`, `filter_edits = "e"`,
and `thinking = "T"` lines from the `feed` keymaps table. Leave `diff = "v"` and
everything else. Also update the `giroux.KeymapsConfig` doc comment only if it
enumerates these (it likely doesn't).

**Verify**: `git grep -n "filter_bash\|filter_edits\|thinking = " lua/giroux/init.lua`
returns nothing. `nvim -l scripts/smoke.lua` → exit 0 (config still merges).

### Step 5: Add a tiny test + full suite + format

Create `tests/state_spec.lua`:

```lua
local state = require("giroux.state")
return {
  ["state: ORDER ranks needs-you first and idle-ish last"] = function()
    assert(state.rank("?") < state.rank("●"), "questions outrank working")
    assert(state.rank("●") < state.rank("✓"), "working outranks done")
    assert(state.rank("✓") < state.rank("○"), "done outranks idle")
    assert(state.rank("nonsense") == 9, "unknown sorts last")
  end,
  ["state: LABEL covers every ordered glyph"] = function()
    for glyph in pairs(state.ORDER) do
      assert(state.LABEL[glyph], "no label for " .. glyph)
    end
  end,
}
```

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`, count +2.
- `stylua --check lua/ tests/` → exit 0.
- `git grep -n 'ORDER = { \["?"\]' lua/giroux/monitor.lua lua/giroux/roster.lua`
  returns nothing (the duplicated literal is gone from both).

## Test plan

- New `tests/state_spec.lua`: ordering relations + label completeness.
- The existing roster/monitor/feed specs must stay green (behavior unchanged) —
  they're the regression guard that the extraction didn't alter sorting/labels.
- Pattern: any existing flat spec (e.g. `tests/nodes_spec.lua`).
- Verification: `nvim -l tests/run.lua` → all pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; count +2.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `lua/giroux/state.lua` exists; `monitor.lua` and `roster.lua` import
      `state.ORDER` (the duplicated literal is gone from both).
- [ ] `git grep -n "filter_bash\|filter_edits" lua/giroux/init.lua` returns
      nothing; `thinking` keymap default removed.
- [ ] `diff` feed keymap and roster `kill`/`diff` stubs are untouched.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 009 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `ORDER` literals differ between `monitor.lua` and `roster.lua` at execution
  time (they shouldn't) — that's a pre-existing bug; report it rather than
  papering over it.
- Removing the three keymaps breaks a test that referenced them (there shouldn't
  be one, since they're unwired) — report what referenced them.
- Feed's labels and roster's labels disagree in a way that isn't clearly
  intentional — report the discrepancy instead of picking one silently.

## Maintenance notes

- New states or reordering: edit `state.lua` only. `monitor`, `roster`, `feed`
  all read from it.
- When bash/edits filters or thinking-fold are actually implemented, re-add the
  keymap defaults *with* their wiring (DESIGN.md §8) — the removal here is a
  deferral, not a rejection.
- Reviewer should confirm the roster's on-screen sort order is pixel-identical
  before/after (the whole point is behavior-preserving dedup).
