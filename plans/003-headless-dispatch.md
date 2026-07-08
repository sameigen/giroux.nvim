# Plan 003: Make `:GirouxDispatch!` actually launch a headless agent (or remove the claim)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/dispatch.lua plugin/giroux.lua lua/giroux/init.lua tests/steer_spec.lua`
> If any changed since this plan was written, compare the "Current state"
> excerpts to the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but if plan 006 will also run, do 003 first — see 006)
- **Category**: bug
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty; `dispatch.lua` had a large uncommitted rework — drift check will surface it)

## Why this matters

`:GirouxDispatch!` is documented as "headless" (the bang) and there is a config
knob `dispatch.headless_flags = { "-p", "--output-format", "text" }` for it. But
the bang is dropped on the floor: `plugin/giroux.lua` passes
`{ headless = cmd.bang }`, and nothing downstream ever reads `opts.headless` or
appends `headless_flags`. So a user who runs `:GirouxDispatch!` for a
fire-and-forget headless run gets an ordinary interactive tmux dispatch instead
— a silent capability gap where the surface (bang + config field + help text)
promises something the code doesn't do. Either wire it through, or remove the
claim so the surface is honest. This plan implements the wiring (small, and the
knob already exists), with an explicit fallback to remove-the-claim if the
headless launch shape turns out to conflict with the tmux job model.

## Current state

The bang is captured and passed (`plugin/giroux.lua:33-35`):

```lua
vim.api.nvim_create_user_command("GirouxDispatch", function(cmd)
  require("giroux.dispatch").open({ headless = cmd.bang })
end, { bang = true, desc = "Dispatch an agent: node -> repo -> worktree -> tmux + claude (! = headless)" })
```

`dispatch.open` reads only `opts.node`, never `opts.headless`
(`lua/giroux/dispatch.lua:405-438`):

```lua
function M.open(opts)
  opts = opts or {}
  ...
  local function with_node(node_name)
    find_repos(node_name, function(repos)
      ...
      require("giroux.pick").open({
        items = repos,
        title = "repo on " .. node_name,
        format = repo_label,
        on_choice = function(it)
          if it then
            maybe_worktree(node_name, it.path)   -- <-- opts.headless not threaded
          end
        end,
      })
    end)
  end
  ...
end
```

The call chain that builds the launch is:
`open → with_node → maybe_worktree(node, repo) → launch_in(node, dir) →
M.launch_cmd(name, id, dir, prompt) → job_launch(...)`.

`M.launch_cmd` assembles the agent argv and never adds `headless_flags`
(`dispatch.lua:104-111`):

```lua
function M.launch_cmd(name, id, dir, prompt)
  local d = require("giroux").config.dispatch
  local argv = {}
  vim.list_extend(argv, d.cmd)
  vim.list_extend(argv, d.flags or {})
  argv[#argv + 1] = prompt
  return job_launch(name, id, dir, argv)
end
```

The config field is declared and defaulted but referenced nowhere in `lua/`
(`lua/giroux/init.lua:10` and `:57`):

```lua
---@field headless_flags string[] extra flags for :GirouxDispatch!
...
    headless_flags = { "-p", "--output-format", "text" },
```

`maybe_worktree` (`dispatch.lua:247`) and `launch_in` (`dispatch.lua:227`) are
file-local functions in the chain; `M.launch_cmd` is already public and tested
(`tests/steer_spec.lua:129`).

Key design context you must honor (from ARCHITECTURE.md / PLAN.md §3): a normal
dispatch launches `claude` as a **foreground job inside an interactive tmux
shell** (so `C-z` suspends it, and it inherits `CLAUDE_CODE_OAUTH_TOKEN` + PATH
from the login profile). A headless `-p` run is fire-and-forget and does NOT
need to be steerable — DESIGN.md §7 calls the `!` variant "headless `claude -p`
for fire-and-forget." The simplest correct implementation keeps the same tmux
job-launch machinery and just appends `headless_flags` to the argv; the session
still lands in tmux (harmless) but runs `-p` and exits. If you discover headless
`-p` must NOT run in tmux at all, that's the STOP/remove-the-claim branch.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `dispatch: thread the headless bang through to launch flags`.

## Commands you will need

| Purpose      | Command                            | Expected on success    |
|--------------|------------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`            | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua dispatch`   | dispatch specs pass    |
| Smoke        | `nvim -l scripts/smoke.lua`        | exit 0                 |
| Format check | `stylua --check lua/ tests/`       | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/dispatch.lua` (thread `headless` through the chain; append flags in `launch_cmd`)
- `tests/steer_spec.lua` (extend the `launch_cmd` coverage — this is where
  dispatch's pure command-builder tests live today)

**Out of scope** (do NOT touch):
- `plugin/giroux.lua` — it already passes `{ headless = cmd.bang }` correctly.
- `lua/giroux/init.lua` — the config field already exists; don't change defaults.
- `pick.lua`, `steer.lua` — unrelated to this fix.
- The `accept_trust` / `follow_new_session` flow — a headless run may not create
  a long-lived tmux session, but wiring those differently is out of scope; if
  the headless path needs them skipped, do the minimal skip (Step 2) and note it.

## Git workflow

- Branch: `advisor/003-headless-dispatch`
- One commit; message like `dispatch: honor the ! bang — append headless_flags to the launch`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a `headless` parameter to `M.launch_cmd` and append the flags

Change `M.launch_cmd` to take an optional `headless` boolean and, when set,
append `d.headless_flags` **after** `d.flags` and **before** the prompt (a
`-p`/`--print` run reads the prompt as its argument):

```lua
---@param headless boolean|nil append dispatch.headless_flags (:GirouxDispatch!)
function M.launch_cmd(name, id, dir, prompt, headless)
  local d = require("giroux").config.dispatch
  local argv = {}
  vim.list_extend(argv, d.cmd)
  vim.list_extend(argv, d.flags or {})
  if headless then
    vim.list_extend(argv, d.headless_flags or {})
  end
  argv[#argv + 1] = prompt
  return job_launch(name, id, dir, argv)
end
```

Preserve the existing parameter order and the `@param` block; add the new one.

**Verify**: `nvim -l tests/run.lua dispatch` → the existing `launch_cmd` tests
still pass (they call `launch_cmd` with 4 args; the 5th defaults to nil → no
behavior change for them).

### Step 2: Thread `headless` down the launch chain

Pass `opts.headless` from `open` through to `launch_cmd`. Concretely:

- In `M.open`, capture `local headless = opts.headless` and pass it into
  `with_node`/`maybe_worktree`. The cleanest minimal change: give `with_node`,
  `maybe_worktree`, and `launch_in` a `headless` parameter and forward it.
- `launch_in(node_name, dir, headless)` calls
  `M.launch_cmd(name, id, dir, prompt, headless)`.

If threading a parameter through three local functions is too invasive to do
cleanly, an acceptable alternative is to stash it on a module-local at the start
of `open` (`M._headless = opts.headless`) and read it in `launch_cmd` — BUT only
if you also reset it, and prefer the explicit parameter. Choose the explicit
parameter unless the call sites make it genuinely awkward.

Also: a `-p` headless run exits quickly and may never produce a steerable tmux
session or hit the folder-trust dialog. If `accept_trust`/`follow_new_session`
are invoked unconditionally in `launch_in`, guard them so a headless run doesn't
spin on a poll that never resolves:

```lua
    if not headless then
      accept_trust(node_name, name)
      follow_new_session(node_name, dir, os.time())
    end
```

(For headless, a simple `vim.notify` that the fire-and-forget run was dispatched
is enough.)

**Verify**: `nvim -l scripts/smoke.lua` → exit 0. `nvim -l tests/run.lua dispatch`
→ existing dispatch specs pass.

### Step 3: Add a test proving the bang appends `headless_flags`

In `tests/steer_spec.lua`, add a test alongside the existing `launch_cmd` ones:

```lua
["dispatch: launch_cmd with headless appends headless_flags"] = function()
  local cmd = dispatch.launch_cmd("giroux/x-2222", "id22", "/tmp/x", "do the thing", true)
  -- the agent argv travels base64; decode and assert -p / output-format present
  local b64 = (cmd:match("printf %%s%s+(.-)%s+|%s+base64") or ""):gsub("[^A-Za-z0-9+/=]", "")
  local decoded = vim.base64.decode(b64)
  assert(decoded:find("%-p", 1, false) or decoded:find(" -p", 1, true), "headless passes -p: " .. decoded)
  assert(decoded:find("output-format", 1, true), "headless passes --output-format: " .. decoded)
  assert(decoded:find("dangerously-skip-permissions", 1, true), "base flags still applied")
  -- non-headless must NOT add -p
  local plain = dispatch.launch_cmd("giroux/x-3333", "id33", "/tmp/x", "do the thing")
  local pb64 = (plain:match("printf %%s%s+(.-)%s+|%s+base64") or ""):gsub("[^A-Za-z0-9+/=]", "")
  assert(not vim.base64.decode(pb64):find("output-format", 1, true), "plain dispatch stays interactive")
end,
```

Mirror the base64-decode idiom already used by
`dispatch: launch_cmd runs the agent as a shell job` (steer_spec.lua:129) and
`dispatch: resume_cmd ...` (steer_spec.lua:31) — copy their exact `b64` extraction
if the regex above doesn't match your `job_launch` output.

**Verify**: `nvim -l tests/run.lua dispatch` → the new test passes.

### Step 4: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`, count +1.
- `stylua --check lua/ tests/` → exit 0.
- `git grep -n "headless_flags" lua/giroux/dispatch.lua` → now returns a match
  (the field is finally used).

## Test plan

- New test in `tests/steer_spec.lua`: `launch_cmd(..., true)` includes the
  headless flags in the decoded argv; `launch_cmd(...)` (no headless) does not.
- Pattern: the existing base64-decode assertions in `steer_spec.lua`.
- Verification: `nvim -l tests/run.lua dispatch` → all pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; count +1.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `git grep -n "headless_flags" lua/giroux` shows a use in `dispatch.lua`,
      not only the declaration/default in `init.lua`.
- [ ] `:GirouxDispatch!` path threads `headless` from `open` to `launch_cmd`
      (readable in the diff).
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 003 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `open`/`launch_cmd`/`launch_in` excerpts don't match the live code (drift).
- You determine a headless `-p` run must NOT run inside a tmux session at all
  (i.e. the whole tmux job-launch machinery is wrong for headless). In that
  case, DO NOT invent a second launch path — instead take the **remove-the-claim
  branch**: delete the `bang = true` + "! = headless" from `plugin/giroux.lua`,
  drop `headless_flags` from `init.lua` defaults and its `@field`, and report
  that headless dispatch was descoped. Note which branch you took in the status row.
- The base64 decode in the new test can't recover the argv (the `job_launch`
  encoding differs from the excerpt) — copy the working extraction from the
  existing passing tests instead of guessing.

## Maintenance notes

- If headless output routing is later built (capturing the `-p` result into a
  buffer), it hooks in where `follow_new_session` is skipped for headless.
- Reviewer should confirm the interactive path is byte-for-byte unchanged when
  the bang is absent (the `headless` default is nil/false).
- The remove-the-claim branch is a legitimate outcome — an honest surface beats
  a half-wired feature. Prefer wiring, but don't fake it.
