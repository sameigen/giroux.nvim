# Plan 007: Stop tests from firing real notifications and re-implementing the code they test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/notify.lua lua/giroux/monitor.lua tests/notify_spec.lua tests/monitor_spec.lua`
> If any changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but relates to 001 — if 001 added a `notify` sink seam,
  reuse it here instead of adding a second)
- **Category**: tests
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

Two test-hygiene defects undermine the suite:

1. **A spec fires a real notification.** `tests/notify_spec.lua` calls
   `notify.fire("dead", …, "went dark")` on the `"macos"` channel; off macOS
   that degrades to a real `vim.notify("giroux: went dark")`, which is why the
   string `giroux: went dark` leaks into the test-run output. On macOS it fires
   an actual desktop banner + Glass sound during the run. The test asserts only
   "didn't crash," never the message.
2. **Two specs re-implement the code they claim to cover.** `notify_spec.lua`'s
   pane-question test writes "emulate its rule here" and re-codes the
   `derive` override (`if question and age <= 1800 then st = "?"`) locally
   instead of calling the real `monitor.derive`. If `derive`'s override window
   or precedence changes, the test stays green while the product breaks —
   category-4 "tests the copy, not the code," on the state logic that is the
   whole point of the roster.

Fixing both makes the suite quiet and drift-catching. The fix is a small
injectable sink in `notify.lua` plus tests that call the real derivation.

## Current state

The real notification degradation (`lua/giroux/notify.lua:39-56`):

```lua
local function osascript(msg, title)
  local cfg = require("giroux").config.notify
  if vim.g.giroux_focused and not cfg.macos_when_focused then
    return
  end
  if vim.fn.executable("osascript") ~= 1 then
    return vim.notify("giroux: " .. msg, vim.log.levels.INFO)  -- <-- real notify in tests
  end
  pcall(vim.system, {
    "osascript",
    "-e",
    ('display notification %q with title %q sound name "Glass"'):format(msg, title or "giroux"),
  })
end
```

`M.fire` routes to `osascript` for the `"macos"` channel and to `vim.notify`
for `"notify"` (`notify.lua:73-79`):

```lua
  local ch = channel(event == "tripwire" and "question" or event)
  if ch == "macos" then
    osascript(msg, "giroux · " .. (session.title or session.project or ""))
  elseif ch == "notify" then
    vim.notify("giroux: " .. msg, event == "dead" and vim.log.levels.WARN or vim.log.levels.INFO)
  end
```

The offending test (`tests/notify_spec.lua:5-14`) fires on the macOS channel and
asserts only non-crash:

```lua
  ["notify: macos channel degrades to vim.notify off macOS (no crash)"] = function()
    h.skip_unless(vim.fn.executable("osascript") ~= 1, "needs a host without osascript")
    require("giroux").setup({ notify = { levels = { dead = "macos", question = "macos" } } })
    notify.reset()
    local ok = pcall(notify.fire, "dead", { path = "/x", title = "X" }, "went dark")
    assert(ok, "macos channel must not raise when osascript is absent")
    notify.reset()
  end,
```

The drift-blind test (`tests/notify_spec.lua:40-56`) re-codes `derive`'s rule:

```lua
  ["monitor: pane-confirmed question overrides transcript state"] = function()
    local sessions = require("giroux.sessions")
    assert(sessions.derive_state({}, 10, true) == "●", "baseline: open turn = working")
    -- the override lives in monitor.derive; emulate its rule here
    local function with_question(pending, age, in_turn, question)
      local st = sessions.derive_state(pending, age, in_turn)
      if question and age <= 1800 then
        st = "?"
      end
      return st
    end
    assert(with_question({}, 10, true, true) == "?", "pane question promotes to ?")
    ...
```

The real override lives in `monitor.derive` (`lua/giroux/monitor.lua:118-123`):

```lua
  if tr.question and age <= 1800 then
    st = "?"
  end
```

Conventions: flat spec tables, plain asserts, no framework. Terse comments.
Commit terse/lowercase/module-prefixed, no AI trailers. Example:
`notify: inject the sink so specs capture instead of paging`.

## Commands you will need

| Purpose      | Command                          | Expected on success    |
|--------------|----------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`          | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua notify`   | notify specs pass      |
| Tests (one)  | `nvim -l tests/run.lua monitor`  | monitor specs pass     |
| Smoke        | `nvim -l scripts/smoke.lua`      | exit 0                 |
| Format check | `stylua --check lua/ tests/`     | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/notify.lua` (add an injectable/overridable sink; default behavior unchanged)
- `tests/notify_spec.lua` (capture and assert the message; stop re-emulating derive)
- `tests/monitor_spec.lua` (add a test that calls the real derive override — see Step 3)

**Out of scope** (do NOT touch):
- The badge/latch semantics (`fired`, `badge`, `seed`, `clear`) — correct.
- `monitor.derive`'s logic — only *test* it, don't change it (plan 001 owns any
  behavior change there).
- `sessions.derive_state` — correct.

## Git workflow

- Branch: `advisor/007-test-hygiene`
- One commit; message like `notify: injectable sink; test the real derive override`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an overridable sink to `notify.lua`

Introduce a module-level indirection for the two real emission points
(`vim.notify` and `osascript`), defaulting to today's behavior but overridable
by tests. Add near the top of `notify.lua`:

```lua
-- Emission sink — overridable in tests so specs capture instead of paging.
-- Defaults preserve production behavior exactly.
M._sink = {
  notify = function(msg, level)
    vim.notify(msg, level)
  end,
  osascript = function(argv)
    pcall(vim.system, argv)
  end,
}
```

Then route the existing call sites through it:

- In `osascript(msg, title)`: replace
  `return vim.notify("giroux: " .. msg, vim.log.levels.INFO)` with
  `return M._sink.notify("giroux: " .. msg, vim.log.levels.INFO)`, and replace
  the `pcall(vim.system, { ... })` with `M._sink.osascript({ ... })`.
- In `M.fire`'s `"notify"` branch: replace `vim.notify("giroux: " .. msg, ...)`
  with `M._sink.notify("giroux: " .. msg, ...)`.

Behavior is identical in production (the defaults call the same functions).

**Verify**: `nvim -l scripts/smoke.lua` → exit 0. `nvim -l tests/run.lua notify`
→ still passes (defaults unchanged).

### Step 2: Rewrite the "degrades to vim.notify" test to CAPTURE and ASSERT

Replace the non-crash-only test so it swaps in a capturing sink and asserts the
message actually routed there — and no real banner fires. Remove the
`skip_unless` (with the sink, the test is platform-independent):

```lua
  ["notify: macos channel with no osascript routes the message to vim.notify"] = function()
    require("giroux").setup({ notify = { levels = { dead = "macos" } } })
    notify.reset()
    local seen = {}
    local orig = notify._sink
    notify._sink = {
      notify = function(msg) seen[#seen + 1] = msg end,
      osascript = function() error("osascript must not fire when absent") end,
    }
    -- force the "no osascript" branch regardless of host
    local had = vim.fn.executable
    -- if the host HAS osascript, this test still proves fire() doesn't raise and
    -- routes *somewhere* via the sink; the capture makes the assertion real.
    local ok = pcall(notify.fire, "dead", { path = "/x", title = "X" }, "went dark")
    notify._sink = orig
    notify.reset()
    assert(ok, "fire must not raise")
    -- on a host without osascript, the degraded path captured the message:
    if vim.fn.executable("osascript") ~= 1 then
      assert(vim.tbl_contains(seen, "giroux: went dark"), "message routed to the sink, no real banner")
    end
  end,
```

The key win: on the CI/Linux hosts (no osascript) the message is now asserted
and captured — no `giroux: went dark` leaks to the real message area.

**Verify**: `nvim -l tests/run.lua notify` → passes; run output no longer
contains a stray `giroux: went dark` from this spec.

### Step 3: Replace the derive-emulation test with one that calls the real code

Delete the `with_question` local re-implementation in `tests/notify_spec.lua`'s
"pane-confirmed question overrides transcript state" test. That override lives in
`monitor.derive`, so the test belongs in `tests/monitor_spec.lua` and must call
the real derivation.

If plan 001 already added `monitor._derive`, reuse it. Otherwise add the same
one-line seam in `monitor.lua` (before `return M`): `M._derive = derive`.

In `tests/monitor_spec.lua`, add a test that builds a tracker with
`tr.question = true` and asserts the real `_derive` promotes it to `?` within the
1800s window and not outside it. Use the same tracker-construction approach as
the other monitor specs (inspect them for the real `tr` field names — do not
guess). The assertion targets `tr.session.state` after `_derive`:

```lua
["monitor: a pane-confirmed question promotes to ? only within the freshness window"] = function()
  -- build tr with an open turn, empty pending-set, and tr.question = true
  -- (see the existing monitor specs / feed_line for the real tracker shape)
  -- fresh file (age <= 1800): must become "?"
  -- stale file (age > 1800): must NOT become "?" (stays dead/idle per derive)
  -- tr.question = false: unchanged
  -- assert on tr.session.state after monitor._derive(tr, <live>)
end,
```

Fill in the tracker construction from the real code. Then **remove** the
now-redundant "monitor: pane-confirmed question overrides transcript state" test
from `tests/notify_spec.lua` (it no longer belongs there and no longer
re-implements anything).

**Verify**: `nvim -l tests/run.lua monitor` and `nvim -l tests/run.lua notify` →
both pass; the emulated `with_question` function is gone
(`git grep -n "emulate its rule\|with_question" tests/` returns nothing).

### Step 4: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`. Net test count may be unchanged (one
  moved) or +1.
- `stylua --check lua/ tests/` → exit 0.
- The full run output contains no stray `giroux: went dark` line.

## Test plan

- `tests/notify_spec.lua`: the macOS-channel test now injects a capturing sink
  and asserts the routed message; no real banner/notify.
- `tests/monitor_spec.lua`: a new test drives the REAL `monitor._derive`
  question override across the freshness boundary, replacing the emulated copy.
- Pattern: existing `tests/monitor_spec.lua` / `tests/notify_spec.lua` specs.
- Verification: `nvim -l tests/run.lua` → all pass, output quiet.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `git grep -n "emulate its rule" tests/` returns nothing.
- [ ] `git grep -n "with_question" tests/` returns nothing.
- [ ] `notify.lua` has `M._sink` and all real emission goes through it.
- [ ] Running the full suite prints no `giroux: went dark` line.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 007 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `notify.lua`/`monitor.lua` excerpts don't match the live code (drift).
- You cannot construct a state-`?` tracker for the monitor test without inventing
  inputs that don't match real transcript parsing — report rather than faking it
  (same constraint as plan 001; coordinate if both are being executed).
- Injecting `M._sink` changes any production notification behavior (it must not).

## Maintenance notes

- The `M._sink` seam is the sanctioned way to keep future notification tests
  quiet — new notify tests should override it, never assert by side effect.
- Reviewer should confirm production behavior is byte-identical (the default sink
  calls the same `vim.notify`/`vim.system`).
- If plan 001 also touched `monitor_spec.lua`, reconcile so there's one clear
  `_derive` test surface, not two overlapping ones.
