# Plan 012: Route the remaining `vim.ui.select` sites through the built-in picker

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/dispatch.lua lua/giroux/steer.lua lua/giroux/pick.lua`
> If any changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 003 and 006 (soft — all three touch `dispatch.lua`; land the
  bug-fix/tests first to avoid churn. Not a hard blocker.)
- **Category**: direction (UX consistency)
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty; `pick.lua` is new/untracked and `dispatch.lua`/`steer.lua` are mid-rework)

## Why this matters

The working tree introduces a new built-in picker (`lua/giroux/pick.lua`) — a
type-to-filter float that doesn't depend on the user's `vim.ui.select` backend
("no more 'type 1 of 41'"). But it's wired into exactly **one** of five
selection sites: dispatch's repo list. The other four still call
`vim.ui.select`, so the node picker (which can list many auto-discovered tailnet
peers) and the answer-pick still fall back to whatever backend the user has (or
the raw numbered prompt the picker was built to replace). That's a visibly
half-finished migration in the same diff — the repo step gets a fuzzy window
while the adjacent node step doesn't. Finishing it makes the selection UX uniform
and removes the hidden dependency on the user's config. Small and mechanical.

## Current state

The picker API (`lua/giroux/pick.lua:36-48`): `pick.open{ items, title, format,
on_choice }` where `format(item) -> string` is both the display and match text,
and `on_choice(item|nil)` is called once after the window closes (`nil` =
cancelled). Already used correctly at `dispatch.lua:415-424`.

The four remaining `vim.ui.select` sites:

1. **Node select** — `dispatch.lua:433-437`:
   ```lua
   vim.ui.select(names, { prompt = "dispatch on node:" }, function(node_name)
     if node_name then
       with_node(node_name)
     end
   end)
   ```
   `names` is a sorted list of node-name strings.

2. **Worktree choice** — `dispatch.lua:248`:
   ```lua
   vim.ui.select({ "run in the repo", "fresh worktree" }, { prompt = "where should the agent work?" }, function(choice)
     if not choice then return end
     if choice == "run in the repo" then ...
   ```
   A fixed two-item string list.

3. **Clean reap** — `dispatch.lua:381-383`:
   ```lua
   vim.ui.select({ "kill all " .. #reapable .. " idle", unpack(labels) }, {
     prompt = "reap on " .. node_name .. ":",
   }, function(choice, idx) ... end)
   ```
   Note this one uses the **second** callback arg (`idx`) — the picker's
   `on_choice` gives you the item, not the index, so you must map back to an
   index (see Step 3).

4. **Answer-pick** — `steer.lua:183-196`:
   ```lua
   function M.pick(it)
     M.read_question(it, function(q)
       if not q then
         return vim.notify("giroux: no live question on this session's screen", vim.log.levels.WARN)
       end
       local labels = vim.tbl_map(function(o)
         return ("%d. %s"):format(o.n, o.label)
       end, q.options)
       vim.ui.select(labels, { prompt = q.question }, function(_, idx)
         if idx then
           M.answer(it, q.options[idx].n)
         end
       end)
     end)
   end
   ```
   `q.options` is `{ { n = <digit>, label = <string> }, ... }` including meta
   options like "Type something." / "Chat about this". Selecting any option sends
   its digit via `M.answer`; "Type something." makes the TUI open free text — so
   **no special free-text handling is needed here**, just send the chosen digit.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `pick: route node-select, worktree, clean, and answer through the picker`.

## Commands you will need

| Purpose      | Command                          | Expected on success    |
|--------------|----------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`          | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua pick`     | pick specs pass        |
| Tests (one)  | `nvim -l tests/run.lua steer`    | steer specs pass       |
| Smoke        | `nvim -l scripts/smoke.lua`      | exit 0                 |
| Format check | `stylua --check lua/ tests/`     | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/dispatch.lua` (node-select, worktree choice, clean reap)
- `lua/giroux/steer.lua` (answer-pick)

**Out of scope** (do NOT touch):
- `lua/giroux/pick.lua` — the picker itself is done; don't modify its API.
- `vim.ui.input` calls (e.g. the branch-name prompt in `maybe_worktree`) — those
  are free-text input, not selection; the picker doesn't replace `ui.input`.
  Leave every `vim.ui.input` as-is.
- The already-migrated repo picker at `dispatch.lua:415`.
- `M.attach` / attach-keymaps in `steer.lua` (a different plan touches attach).

## Git workflow

- Branch: `advisor/012-finish-pick-migration`
- One commit; message like `pick: migrate the remaining vim.ui.select sites to the built-in picker`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Migrate node-select (`dispatch.lua:433`)

```lua
  require("giroux.pick").open({
    items = names,
    title = "dispatch on node",
    format = tostring,
    on_choice = function(node_name)
      if node_name then
        with_node(node_name)
      end
    end,
  })
```

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 2: Migrate the worktree choice (`dispatch.lua:248`)

```lua
  require("giroux.pick").open({
    items = { "run in the repo", "fresh worktree" },
    title = "where should the agent work?",
    format = tostring,
    on_choice = function(choice)
      if not choice then
        return
      end
      if choice == "run in the repo" then
        return launch_in(node_name, repo)
      end
      -- ... the existing vim.ui.input branch-name flow stays exactly as-is ...
    end,
  })
```

Keep the entire branch-name `vim.ui.input` block and worktree-creation logic
inside the new `on_choice` unchanged — only the outer selection call changes.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 3: Migrate the clean reap (`dispatch.lua:381`) — mind the index

The old code uses the `idx` callback arg to decide "kill all" (idx 1) vs a single
target (`reapable[idx - 1]`). The picker returns the chosen *item*, not an index,
so build items that carry their own identity. The cleanest approach: make items a
list of tables, the first being a sentinel "kill all":

```lua
  local pick_items = { { all = true, label = "kill all " .. #reapable .. " idle" } }
  for _, r in ipairs(reapable) do
    pick_items[#pick_items + 1] = { r = r, label = ("%s (idle %dm)"):format(r.name, math.floor(r.idle / 60)) }
  end
  require("giroux.pick").open({
    items = pick_items,
    title = "reap on " .. node_name,
    format = function(it) return it.label end,
    on_choice = function(choice)
      if not choice then
        return
      end
      local targets = choice.all and reapable or { choice.r }
      for _, r in ipairs(targets) do
        ssh.exec(node.host, ssh.login_wrap(("tmux kill-session -t %s 2>/dev/null"):format(shq(r.name))), function() end)
      end
      tmuxctl.invalidate(node_name)
      vim.notify(("giroux: reaped %d session(s) on %s"):format(#targets, node_name))
      require("giroux.monitor").discover()
    end,
  })
```

Preserve the exact reap side effects (the `ssh.exec` kill, `tmuxctl.invalidate`,
the notify, the `monitor.discover()`); only the selection mechanism and the
item→target mapping change. `labels`, `shq`, `tmuxctl`, `ssh`, `node` are all
already in scope at that call site — confirm before editing.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0. Manually re-read the diff to
confirm "kill all" still kills all and a single choice kills exactly one.

### Step 4: Migrate answer-pick (`steer.lua:183`)

```lua
function M.pick(it)
  M.read_question(it, function(q)
    if not q then
      return vim.notify("giroux: no live question on this session's screen", vim.log.levels.WARN)
    end
    require("giroux.pick").open({
      items = q.options,
      title = q.question,
      format = function(o) return ("%d. %s"):format(o.n, o.label) end,
      on_choice = function(o)
        if o then
          M.answer(it, o.n)
        end
      end,
    })
  end)
end
```

The free-text path is unchanged: choosing the "Type something." option sends its
digit, and the TUI opens its own free-text input — giroux already relies on that.
Do NOT add special handling; just send the digit as before.

**Verify**: `nvim -l tests/run.lua steer` → the existing steer specs (including
`parse_question`) still pass — this change is downstream of `parse_question`,
which is untouched.

### Step 5: Confirm no `vim.ui.select` remains + full suite

**Verify**:
- `git grep -n "vim.ui.select" lua/giroux/` returns **nothing**.
- `git grep -n "vim.ui.input" lua/giroux/` still returns the branch-name prompt
  (untouched — `ui.input` is not in scope).
- `nvim -l tests/run.lua` → `0 failed`.
- `nvim -l scripts/smoke.lua` → exit 0.
- `stylua --check lua/ tests/` → exit 0.

## Test plan

- The picker's decision core (`pick.rank` / the `open` handle) is already
  unit-tested (`tests/pick_spec.lua`); these migrations are call-site changes.
- Optionally add a test that drives answer-pick through the picker handle: build
  a fake `q` with options, call the migrated `M.pick` with `read_question`
  stubbed to return `q`, drive `pick._active` (the handle exposed at
  `pick.lua:182`) to `choose()`, and assert `M.answer` was invoked with the
  right digit (stub `M.answer` to capture). Only add this if it's clean; the
  picker handle API (`set_query`/`move`/`choose`/`cancel`) is designed for it.
- Verification: `nvim -l tests/run.lua` → all pass.

## Done criteria

ALL must hold:

- [ ] `git grep -n "vim.ui.select" lua/giroux/` returns nothing.
- [ ] `git grep -n "vim.ui.input" lua/giroux/` still shows the branch-name prompt
      (unchanged).
- [ ] `nvim -l tests/run.lua` exits `0 failed`.
- [ ] `nvim -l scripts/smoke.lua` exits 0; `stylua --check lua/ tests/` exit 0.
- [ ] Clean reap still supports "kill all" and single-target; answer-pick still
      sends the chosen digit (readable in the diff).
- [ ] No files outside `dispatch.lua`/`steer.lua` modified (`git status`).
- [ ] `plans/README.md` status row for 012 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `vim.ui.select` excerpts don't match the live code (drift).
- The clean-reap index remapping can't be done without changing the reap side
  effects — report rather than altering what gets killed.
- The picker's `on_choice` semantics differ from "called once with item-or-nil"
  as documented (`pick.lua:42-48`) — re-read `pick.open` and report.

## Maintenance notes

- With this done, `pick.open` is the single selection primitive; any new
  selection UI should use it, not `vim.ui.select`.
- Reviewer should scrutinize the clean-reap item→target mapping (the one place
  the picker's item-return vs the old index-return semantics diverge) — a wrong
  mapping there kills the wrong tmux session.
- `vim.ui.input` (free text) is intentionally still used; the picker is for
  selection only. If a fuzzy free-text input is ever wanted, that's a separate
  pick.lua enhancement, not this plan.
