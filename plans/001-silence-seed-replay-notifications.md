# Plan 001: Seed-window replay never fires interrupt notifications

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/monitor.lua tests/monitor_spec.lua`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `482e989`, 2026-07-07 (working tree was dirty; `monitor.lua` had uncommitted changes — the drift check above will surface them)

## Why this matters

giroux's entire attention thesis (DESIGN.md §6) is that a macOS banner / Glass
sound fires **only on a state transition giroux actually witnessed** — a fresh
question, a fresh death. Right now, every time a session tracker starts (roster
open, discovery adds a session), the monitor re-reads the last 32 KB of the
transcript to recover the pending-set. During that replay, an already-answered
`AskUserQuestion` transiently re-enters state `?` (its `tool_use` line sets the
pending-set, a later `tool_result` line clears it), and a crashed-with-work
session re-enters `✗`. Because the "seed silently" guard only covers the very
first replayed line, all the later replayed lines fire **real** notifications
for history that is minutes or hours old. The result is spurious "needs your
input" / "went dark" pages whenever you open the board over existing sessions —
exactly the noise the design says must never happen.

## Current state

- `lua/giroux/monitor.lua` — the realtime backbone. `derive(tr, live)` computes
  a session's state and fires/clears notifications; `feed_line(tr, line)` calls
  it once per transcript line delivered by the merged tail.

The seed/notify logic in `derive` (monitor.lua:158-173):

```lua
  local notify = require("giroux.notify")
  local seed = not tr.primed
  tr.primed = true
  local function signal(event, on, msg)
    if not on then
      return notify.clear(event, tr.session)
    end
    if seed then
      notify.seed(event, tr.session)
    else
      notify.fire(event, tr.session, msg)
    end
  end
  signal("question", st == "?", "needs your input — " .. (tr.session.title or tr.session.project or ""))
  signal("dead", st == "✗", "went dark with work pending — " .. (tr.session.title or tr.session.project or ""))
  signal("end_of_turn", st == "✓", "finished — " .. (tr.session.title or tr.session.project or ""))
end
```

`tr.primed` is `nil` on a new tracker, so `seed` is `true` for the **first**
`derive` call and `false` for every call after. But `derive` runs once per
line (see `feed_line` below), so only the first replayed line seeds silently.

`feed_line` already computes a per-line `live` flag and passes it to `derive`
(monitor.lua:187-218):

```lua
  -- liveness: this line is a live append (vs pre-watch history being replayed)
  -- iff it begins at/after the file size we saw when the tracker was created.
  -- resume_offset() here is the byte where this line starts (pre-feed).
  local live = tr.parser:resume_offset() >= (tr.live_after or 0)
  ...
  derive(tr, live)
  notify()
```

`tr.live_after` is set to the file size at tracker creation (monitor.lua:286,
`live_after = s.size`), so a replayed history line has `live == false` and a
genuine new append has `live == true`. **The fix is to also seed when the line
is not live.** The done/`✓` latch a few lines below already consults `live`
correctly (`if prev == "●" and live then tr.done_unseen = true`), so this
change aligns the notification gate with the latch that already gets it right.

`notify.fire` (lua/giroux/notify.lua:62) dedupes per state-entry via a `fired`
latch, but `notify.clear` releases that latch — which is why the answered
question's `?`→(clear) replay pair fires anew rather than being deduped.

Repo conventions that apply:
- Pure logic is unit-tested without a buffer (CONTRIBUTING.md). `derive` is not
  currently exposed for direct testing; you will add a minimal seam (Step 2).
- Terse comments; rationale lives in DESIGN.md / ARCHITECTURE.md. Match the
  existing comment density in `monitor.lua`.
- Commit messages: terse, lowercase, module-prefixed, **no AI trailers**
  (PLAN.md:187). Example from `git log`: `monitor: freshness-gate the title spinner so a stale title can't mislead`.

## Commands you will need

| Purpose      | Command                              | Expected on success        |
|--------------|--------------------------------------|----------------------------|
| Tests (all)  | `nvim -l tests/run.lua`              | `... passed, 0 failed`     |
| Tests (one)  | `nvim -l tests/run.lua monitor`      | the monitor specs pass     |
| Smoke        | `nvim -l scripts/smoke.lua`          | exit 0, modules load       |
| Format check | `stylua --check lua/ tests/`         | exit 0 (no diff)           |
| Format fix   | `stylua lua/ tests/`                 | rewrites files in place    |

(Typecheck runs in CI via `nvim-typecheck-action` on `lua/` at Error level; run
it locally only if you have `lua-language-server` installed.)

## Scope

**In scope** (the only files you should modify):
- `lua/giroux/monitor.lua`
- `tests/monitor_spec.lua` (add a test)

**Out of scope** (do NOT touch):
- `lua/giroux/notify.lua` — the badge/latch behavior is correct as-is; do not
  change `fire`/`seed`/`clear`. This plan changes *when* the monitor calls them,
  not the notify module.
- The `done_unseen` / `✓` latch logic — it already uses `live` correctly; leave
  it exactly as it is.
- `tests/notify_spec.lua` — a separate plan (007) touches it.

## Git workflow

- Branch: `advisor/001-seed-replay-notifications`
- One commit; message style like `monitor: seed the whole replay window silently (no spurious pages on open)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Gate `seed` on `live`

In `lua/giroux/monitor.lua`, change the `seed` computation inside `derive` so
the entire pre-catch-up replay seeds silently. `derive`'s signature is
`derive(tr, live)`; use that `live` parameter:

```lua
  -- seed silently for the whole pre-watch replay (live == false), not just the
  -- first line: an answered AskUserQuestion re-enters ? during replay and would
  -- otherwise page for a question already resolved. Only witnessed (live)
  -- transitions call notify.fire.
  local seed = not tr.primed or not live
  tr.primed = true
```

Leave everything else in `derive` unchanged.

**Verify**: `git diff lua/giroux/monitor.lua` shows only the `seed` line (and its
comment) changed. Then `nvim -l scripts/smoke.lua` → exit 0.

### Step 2: Expose `derive` for a direct unit test

The current specs cannot call `derive` (it is a file-local function). Add a
minimal test seam next to the other `M._`-prefixed test exports in
`monitor.lua`. Find where the module already exposes internals for tests (grep
`monitor.lua` for `^M%._` or `M%._` assignments — e.g. `M._title_lift`,
`M._should_discover` if present) and follow that exact pattern. If `derive` is
local, add near the bottom of the file, before `return M`:

```lua
M._derive = derive
```

If a differently-named seam already exists that runs `derive` on a hand-built
tracker, reuse it instead of adding a second one.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 3: Add a regression test

In `tests/monitor_spec.lua`, add a test that builds a tracker table with an
answered-question shape and asserts that a **replayed** (`live == false`) derive
does NOT fire, while a **live** (`live == true`) derive does. Model the tracker
shape on how `feed_line`/discovery construct `tr` (it needs at least
`tr.parser`, `tr.session`, `tr.acc`; inspect the existing monitor specs and the
`start`/`track` code in `monitor.lua` for the real field names — do not guess).
The assertion should observe the notification via a captured sink rather than a
real banner: check whether plan 007 has landed a `notify` sink seam and reuse
it; if not, assert on `require("giroux.notify").statusline()` / badge state,
which changes on both `seed` and `fire` — so instead assert the **channel**
effect by temporarily setting `notify.levels` to a capturable channel.

Simplest robust assertion that needs no notify refactor: drive two `derive`
calls on the same tracker whose state is `?`, once with `live=false` (seed) and
once with `live=true` (fire), and assert that `notify.statusline()` is non-empty
after the seed (badge counts either way) **and** that a spy on `vim.notify`
captured nothing during the `live=false` call. Set the channel to `"notify"`
for the test so a fire would route through `vim.notify`:

```lua
["monitor: replayed (non-live) question seeds silently, live one pages"] = function()
  require("giroux").setup({ notify = { levels = { question = "notify" } } })
  require("giroux.notify").reset()
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg) captured[#captured + 1] = msg end
  -- build a tracker `tr` in state ? (see feed_line/track for the real shape),
  -- then:
  --   monitor._derive(tr, false)  -- replay: must NOT call vim.notify
  --   assert(#captured == 0, "replay must not page")
  --   monitor._derive(tr, true)   -- live: MUST page
  --   assert(#captured >= 1, "live transition pages")
  vim.notify = orig
  require("giroux.notify").reset()
end,
```

Fill in the tracker construction from the real code. If you cannot build a
tracker in state `?` without a live transcript, STOP and report (see STOP
conditions) rather than faking `_derive`'s inputs in a way that doesn't match
production.

**Verify**: `nvim -l tests/run.lua monitor` → the new test passes and no other
monitor test regresses.

### Step 4: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `... passed, 0 failed` (count is one higher than before).
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` first if it complains).
- During the run, the string `giroux: went dark` must NOT appear in the output
  from *this* plan's test (plan 007 addresses a separate pre-existing leak in
  `notify_spec`; that one may still show until 007 lands).

## Test plan

- New test in `tests/monitor_spec.lua`: a replayed (`live=false`) `?` derive
  fires nothing; a live (`live=true`) `?` derive pages. This is the exact
  regression: spurious pages on roster open.
- Structural pattern: the existing tests in `tests/monitor_spec.lua`.
- Verification: `nvim -l tests/run.lua monitor` → all monitor specs pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits with `0 failed`; total passing count is +1.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `git grep -n "local seed = not tr.primed$" lua/giroux/monitor.lua` returns
      nothing (the old one-condition guard is gone).
- [ ] The new monitor test proves a non-live `?` derive does not call `vim.notify`.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 001 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `derive`/`feed_line` excerpts above don't match the live code (drift).
- `tr.live_after` is no longer set to the file size at tracker creation, or the
  `live` flag no longer distinguishes replay from live appends — the fix's
  premise is then invalid.
- You cannot construct a state-`?` tracker for the test without inventing inputs
  that don't correspond to real transcript parsing.
- The full suite fails after the change in a way you can't tie to the new test.

## Maintenance notes

- If the monitor ever stops re-reading a seed window on tracker start (e.g. it
  starts tailing from EOF only), the `not live` half of the guard becomes a
  no-op but stays harmless.
- Reviewer should confirm the `✓`/`done_unseen` latch still uses `live` and was
  not disturbed — it is the sibling of this gate.
- Deferred: a fuller `derive` characterization suite (transitions across all
  five states) is out of scope here; plan 007 improves related test hygiene.
