# Plan 004: `:GirouxAttach` closes its own terminal tab, not an unrelated one

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/steer.lua tests/steer_spec.lua`
> If either changed since this plan was written, compare the "Current state"
> excerpt against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty; `steer.lua` had uncommitted changes — drift check will surface them)

## Why this matters

When you attach to a session's TUI (`:GirouxAttach` / roster `a`) and later
detach (`C-b d`) or the agent exits, giroux tries to close the terminal's tab
and return you to the board. It computes the tab with
`vim.api.nvim_win_get_tabpage(win)`, which returns an opaque **tabpage handle**,
then passes it to `{count}tabclose`, which expects a **tab position number**.
Handles and positions coincide only until any tab is closed or reordered
(handles are monotonic and never reused; positions renumber). So after you've
opened/closed a few tabs, detaching either closes an unrelated, unmodified tab
or targets a non-existent position and silently no-ops (leaving the dead
terminal tab open). The `pcall` swallows the error, so it reads as "attach
sometimes doesn't clean up." This is a small, high-certainty fix.

## Current state

`lua/giroux/steer.lua:266-279` (inside `M.attach`, the `jobstart` `on_exit`):

```lua
    vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        vim.schedule(function()
          -- detach/exit: close this terminal's tab and return to the board
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            local tab = vim.api.nvim_win_get_tabpage(win)
            if #vim.api.nvim_list_tabpages() > 1 then
              pcall(vim.cmd, tab .. "tabclose")
            end
          end
        end)
      end,
    })
```

`buf` is the terminal buffer created by `vim.cmd.tabnew()` just above
(`steer.lua:261-262`). `nvim_win_get_tabpage(win)` returns a tabpage **handle**;
`tab .. "tabclose"` builds e.g. `"3tabclose"` treating that handle as a position.

The correct conversion is `vim.api.nvim_tabpage_get_number(tab)` (handle →
1-based position), or — simpler and position-independent — close the window
directly with `vim.api.nvim_win_close(win, true)`, which removes the last window
in a tab (and thus the tab) without any number arithmetic.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `steer: close the attach tab by handle, not by stale position`.

## Commands you will need

| Purpose      | Command                         | Expected on success    |
|--------------|---------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`         | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua steer`   | steer specs pass       |
| Smoke        | `nvim -l scripts/smoke.lua`     | exit 0                 |
| Format check | `stylua --check lua/ tests/`    | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/steer.lua` (the `on_exit` cleanup in `M.attach`)
- `tests/steer_spec.lua` (add a pure test for a small extracted helper — see Step 2)

**Out of scope** (do NOT touch):
- The rest of `M.attach` (the ssh/tmux command build, keymaps, notify) — correct.
- `M.attach_keymaps` and its existing test — unrelated.
- Any other module.

## Git workflow

- Branch: `advisor/004-attach-tabclose`
- One commit; message like `steer: close the attach terminal window by handle`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Close the terminal window by handle instead of a stale position

Replace the buggy cleanup loop. Prefer closing the window directly — it needs no
position math and no "more than one tab" guard beyond not closing the last
window:

```lua
      on_exit = function()
        vim.schedule(function()
          -- detach/exit: close this terminal's window(s) and return to the board.
          -- Close by window handle — do NOT convert a tabpage handle to a tab
          -- number (they diverge as tabs are opened/closed); nvim_win_close on
          -- the terminal's last window drops its tab too.
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_tabpages() > 1 then
              pcall(vim.api.nvim_win_close, win, true)
            end
          end
        end)
      end,
```

Note: keep the `#vim.api.nvim_list_tabpages() > 1` guard so that if the attach
tab is somehow the only tab, you don't try to close the last window (which
errors). The `pcall` stays as a belt-and-suspenders guard.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 2: Add a focused regression test

This code path involves a real terminal job, which is awkward to unit-test
headlessly. Add a small test that proves the tab-close logic operates on the
right target using nvim's real tab/window API (no terminal needed):

```lua
["steer: attach cleanup closes its own tab even after tab reordering"] = function()
  -- reproduce the handle-vs-position hazard: open extra tabs so a tabpage
  -- HANDLE no longer equals its 1-based POSITION, then close a target window
  -- by handle and confirm only that tab went away.
  vim.cmd("tabnew"); vim.cmd("tabnew"); vim.cmd("tabnew")
  vim.cmd("tabnew") -- this is the "attach" tab
  local buf = vim.api.nvim_get_current_buf()
  local before = #vim.api.nvim_list_tabpages()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  assert(#vim.api.nvim_list_tabpages() == before - 1, "exactly one tab closed")
  assert(not vim.api.nvim_buf_is_loaded(buf) or #vim.fn.win_findbuf(buf) == 0,
    "the attach buffer's window is gone")
  -- clean up remaining scratch tabs so we don't leak into other specs
  while #vim.api.nvim_list_tabpages() > 1 do vim.cmd("tabclose") end
end,
```

This test intentionally inlines the same close logic you put in Step 1 (the real
`on_exit` can't run without a live terminal). If you prefer, extract the close
loop into a small exposed helper `M._close_own_tab(buf)` and have both the
`on_exit` and the test call it — that removes the duplication and is the cleaner
option. Do whichever keeps the production code readable; if you extract, the
test calls `steer._close_own_tab(buf)`.

**Verify**: `nvim -l tests/run.lua steer` → the new test passes; the existing
`steer:` tests still pass.

### Step 3: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`, count +1.
- `stylua --check lua/ tests/` → exit 0.
- `git grep -n 'tab .. "tabclose"' lua/giroux/steer.lua` → no matches.

## Test plan

- New test in `tests/steer_spec.lua`: after opening several tabs (so
  handle ≠ position), closing the target window by handle removes exactly one
  tab — the right one.
- Pattern: the flat, assertion-based specs already in `tests/steer_spec.lua`.
- Verification: `nvim -l tests/run.lua steer` → all pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; count +1.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `git grep -n "nvim_win_get_tabpage" lua/giroux/steer.lua` returns nothing
      (the handle-as-number usage is gone), OR if you kept it, it is only fed to
      `nvim_tabpage_get_number` before any `tabclose`.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 004 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `on_exit` excerpt doesn't match the live code (drift).
- Closing the window by handle turns out to leave the terminal job running or
  produces a "cannot close last window" error you can't guard around — report
  the behavior rather than adding `:q!`-style force hacks.

## Maintenance notes

- If attach ever opens the TUI in a split instead of a full tab, this cleanup
  must revisit whether closing the window is still the right teardown.
- Reviewer should confirm the guard still prevents closing the final tab (which
  would error), and that detach returns focus to the roster as before.
