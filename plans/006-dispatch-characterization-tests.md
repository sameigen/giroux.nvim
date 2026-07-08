# Plan 006: Characterize the dispatch orchestration flow

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/dispatch.lua`
> If it changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 003 (soft — if plan 003 wires the headless flag through
  `launch_cmd`, land it first so the tests you add here also cover headless;
  otherwise these plans don't conflict)
- **Category**: tests
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty; `dispatch.lua` had a large uncommitted rework — the reason this coverage matters now)

## Why this matters

`dispatch.lua` just underwent the biggest change in the working tree (the launch
model moved from a pane-command to a base64 `send-keys` shell job, and repo
selection moved from `vim.ui.select` to the new `pick` module). Yet its only
test coverage is the pure command-**builders** in `tests/steer_spec.lua`
(`launch_cmd`, `resume_cmd`, `parse_reapable`, `repo_label`). The
**orchestration** that turns discovery output into those calls is untested:

- `find_repos` builds a `find | while read | stat` pipeline and parses
  `"<mtime>\t<repo>"` lines back into a repo list.
- `accept_trust` polls `capture-pane` and blind-sends `Enter` whenever the pane
  contains "trust this folder" or "Quick safety check" — an auto-keypress with
  **zero** test pinning the trigger condition.
- `follow_new_session` correlates a freshly created transcript to the dispatch
  by cwd slug + birth time.

A regression in repo parsing, the trust-gate substring, or session correlation
would ship green today. The trust auto-accept is the scariest: it presses Enter
on the agent's behalf, and nothing verifies *when*. This plan extracts the pure
decision cores and pins them with tests, following the exact pattern the repo
already uses for `launch_cmd`/`parse_reapable` (expose a pure function, test its
input→output).

## Current state

`find_repos` (`lua/giroux/dispatch.lua:145-169`) — builds the command by string
concatenation and parses the output:

```lua
local function find_repos(node_name, cb)
  local _, node = nodes.get(node_name)
  local cfg = require("giroux").config
  local roots = table.concat(vim.tbl_map(shq_path, node.roots or cfg.roots), " ")
  local cmd = "find "
    .. roots
    .. " -maxdepth 3 -name .git \\( -type d -o -type f \\) 2>/dev/null"
    .. " | while IFS= read -r g; do d=${g%/.git};"
    .. ' m=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null);'
    .. ' printf \'%s\\t%s\\n\' "${m:-0}" "$d"; done | sort -rn'
  ssh.exec(node.host, cmd, function(ok, stdout)
    local repos = {}
    if ok then
      for line in vim.gsplit(vim.trim(stdout), "\n", { trimempty = true }) do
        local mtime, path = line:match("^(%d+)\t(.+)$")
        if path then
          repos[#repos + 1] = { path = path, mtime = tonumber(mtime) or 0 }
        end
      end
    end
    cb(repos)
  end)
end
```

`accept_trust` (`dispatch.lua:176-194`) — the auto-Enter gate:

```lua
      if stdout:find("trust this folder", 1, true) or stdout:find("Quick safety check", 1, true) then
        ssh.exec(node.host, ssh.login_wrap(("tmux send-keys -t %s Enter"):format(shq(name))), function() end)
      elseif tries < 5 then
        vim.defer_fn(poll, 2000)
      end
```

`follow_new_session` (`dispatch.lua:201-223`) — the correlation predicate:

```lua
      for _, s in ipairs(list) do
        if vim.fs.basename(vim.fs.dirname(s.path)) == slug and (s.birth or 0) >= since - 5 then
          require("giroux.monitor").discover()
          require("giroux.feed").open_path({ node = node_name, path = s.path })
          return
        end
      end
```

The repo already exposes internals for tests by assigning `M._name = localfn`
(e.g. `M._repo_label` is tested at `tests/steer_spec.lua:64`; `M.launch_cmd`,
`M.resume_cmd`, `M.parse_reapable` are public). Follow that exact convention:
extract the pure decision core of each function and expose it as `M._<name>`.

Conventions:
- Pure logic unit-tested without a buffer (CONTRIBUTING.md). The command
  builders and parsers here are pure or trivially made pure.
- Tests are flat tables of `["name"] = function() ... assert ... end`, no
  framework (see `tests/steer_spec.lua`).
- Commit terse/lowercase/module-prefixed, no AI trailers. Example:
  `dispatch: characterize repo parsing, trust gate, and session correlation`.

## Commands you will need

| Purpose      | Command                            | Expected on success    |
|--------------|------------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`            | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua dispatch`   | dispatch specs pass    |
| Smoke        | `nvim -l scripts/smoke.lua`        | exit 0                 |
| Format check | `stylua --check lua/ tests/`       | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/dispatch.lua` (extract + expose 3 pure cores as `M._*`; NO
  behavior change to the orchestration)
- `tests/dispatch_spec.lua` (create — a new spec file for dispatch)

**Out of scope** (do NOT touch):
- The launch/steer command builders already tested in `tests/steer_spec.lua` —
  leave them and their tests where they are (don't move them into the new file).
- Any behavior change to dispatch — this plan is **tests + a pure-extraction
  refactor only**. If you find a bug while writing tests, STOP and report it;
  don't fix it here (it may already be covered by another plan).
- `pick.lua`, `steer.lua`, `plugin/giroux.lua`.

## Git workflow

- Branch: `advisor/006-dispatch-characterization-tests`
- One commit; message like `dispatch: characterize repo parsing, trust gate, correlation`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extract and expose the `find_repos` output parser

Split `find_repos` into (a) the command build + ssh call (unchanged) and (b) a
pure parser `parse_repos(stdout)` that turns the `"<mtime>\t<repo>"` text into
the repo list. Expose the parser:

```lua
---Parse the `find_repos` stdout ("<mtime>\t<repo>\n"...) into a repo list. Pure.
---@param stdout string
---@return {path: string, mtime: integer}[]
function M._parse_repos(stdout)
  local repos = {}
  for line in vim.gsplit(vim.trim(stdout or ""), "\n", { trimempty = true }) do
    local mtime, path = line:match("^(%d+)\t(.+)$")
    if path then
      repos[#repos + 1] = { path = path, mtime = tonumber(mtime) or 0 }
    end
  end
  return repos
end
```

Then have `find_repos`'s ssh callback call `cb(ok and M._parse_repos(stdout) or {})`.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0; `nvim -l tests/run.lua dispatch`
→ existing dispatch specs still pass.

### Step 2: Extract and expose the trust-gate predicate

Pull the auto-Enter condition out of `accept_trust` into a pure predicate so the
*exact* trigger is pinned:

```lua
---True when a captured pane is showing Claude's folder-trust dialog (the only
---prompt dispatch auto-accepts — dispatching IS the trust decision). Pure.
---@param pane string tmux capture-pane output
---@return boolean
function M._is_trust_prompt(pane)
  return pane:find("trust this folder", 1, true) ~= nil
    or pane:find("Quick safety check", 1, true) ~= nil
end
```

Have `accept_trust` call `M._is_trust_prompt(stdout)` in place of the inline
`find`s. No behavior change.

**Verify**: `nvim -l tests/run.lua dispatch` → passes.

### Step 3: Extract and expose the session-correlation predicate

Pull the correlation match out of `follow_new_session` into a pure predicate:

```lua
---True when a discovered session `s` is the transcript a dispatch just created:
---its parent dir matches the cwd slug AND it was born at/after the dispatch
---(minus a 5s clock-skew grace). Pure.
---@param s {path: string, birth: integer|nil}
---@param slug string
---@param since integer dispatch epoch seconds
---@return boolean
function M._is_dispatched_session(s, slug, since)
  return vim.fs.basename(vim.fs.dirname(s.path)) == slug and (s.birth or 0) >= since - 5
end
```

Have `follow_new_session` use it in the loop. No behavior change.

**Verify**: `nvim -l tests/run.lua dispatch` → passes.

### Step 4: Write `tests/dispatch_spec.lua`

Create the new spec. Model structure on `tests/steer_spec.lua` (flat table,
`require("giroux").setup({})` at top, plain asserts). Cover:

```lua
local dispatch = require("giroux.dispatch")
require("giroux").setup({})

return {
  ["dispatch: _parse_repos sorts-agnostic, keeps paths with spaces, drops junk"] = function()
    local out = table.concat({
      "1720000000\t/Users/sam/Code/personal/giroux.nvim",
      "1719990000\t/srv/repos/my project",   -- space in path preserved
      "garbage line with no tab",
      "0\t/x/no-mtime-ok",
    }, "\n")
    local repos = dispatch._parse_repos(out)
    assert(#repos == 3, "3 valid rows, junk dropped: " .. #repos)
    assert(repos[1].path == "/Users/sam/Code/personal/giroux.nvim" and repos[1].mtime == 1720000000)
    assert(repos[2].path == "/srv/repos/my project", "space preserved: " .. repos[2].path)
    assert(repos[3].mtime == 0, "missing mtime -> 0")
    assert(#dispatch._parse_repos("") == 0, "empty stdout -> empty list")
  end,

  ["dispatch: _is_trust_prompt fires only on the folder-trust dialog"] = function()
    assert(dispatch._is_trust_prompt("Do you trust this folder?\n> Yes"))
    assert(dispatch._is_trust_prompt("Quick safety check before we start"))
    -- must NOT auto-Enter on ordinary agent output or a real question
    assert(not dispatch._is_trust_prompt("⏺ Running tests…\n❯ 1. Red\n  2. Blue"))
    assert(not dispatch._is_trust_prompt(""))
  end,

  ["dispatch: _is_dispatched_session matches by slug and birth window"] = function()
    local since = 1000000
    local slug = "-Users-sam-Code-app"    -- whatever tmuxctl.slugify produces; use the shape, see note
    local match = { path = "/home/u/.claude/projects/" .. slug .. "/abc.jsonl", birth = since + 2 }
    assert(dispatch._is_dispatched_session(match, slug, since), "born after dispatch, slug matches")
    local old = { path = match.path, birth = since - 30 }
    assert(not dispatch._is_dispatched_session(old, slug, since), "born well before dispatch -> no")
    local other = { path = "/home/u/.claude/projects/-other-repo/abc.jsonl", birth = since + 2 }
    assert(not dispatch._is_dispatched_session(other, slug, since), "different slug -> no")
    local grace = { path = match.path, birth = since - 3 }
    assert(dispatch._is_dispatched_session(grace, slug, since), "within 5s skew grace -> yes")
  end,
}
```

NOTE on the slug: `_is_dispatched_session` compares `basename(dirname(s.path))`
to `slug`, so the test's `slug` just has to equal that basename — you control
both sides, so any string works (the real `tmuxctl.slugify` value is irrelevant
to this predicate's logic). Do not couple the test to `slugify`'s exact format.

**Verify**: `nvim -l tests/run.lua dispatch` → the three new tests pass and
`tests/run.lua` discovers `dispatch_spec.lua` (the runner globs `tests/*_spec.lua`).

### Step 5: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`, count +3 (or +4 if 003's headless test
  also landed).
- `stylua --check lua/ tests/` → exit 0.
- `nvim -l scripts/smoke.lua` → exit 0.

## Test plan

- New file `tests/dispatch_spec.lua` with three tests: repo-output parsing
  (incl. spaces + junk + empty), the trust-gate predicate (fires on the dialog,
  not on agent output or a question picker), and session correlation (slug +
  birth window + 5s grace).
- Pattern: `tests/steer_spec.lua` (flat table, plain asserts, `setup({})`).
- Verification: `nvim -l tests/run.lua dispatch` → all pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; count increased by ≥3.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `tests/dispatch_spec.lua` exists and is discovered by the runner.
- [ ] `M._parse_repos`, `M._is_trust_prompt`, `M._is_dispatched_session` exist
      and are used by the (unchanged-behavior) orchestration functions.
- [ ] `git diff` shows NO behavior change to dispatch — only extraction +
      exposure + tests.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 006 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `find_repos`/`accept_trust`/`follow_new_session` excerpts don't match the
  live code (drift).
- While extracting, you discover a genuine bug (e.g. `accept_trust` sends Enter
  on a pane it shouldn't, or the correlation matches the wrong session) — report
  it; do not fix it in this tests-only plan.
- Exposing a `M._*` core would require changing the orchestration's control flow
  in a non-trivial way — report rather than restructuring the flow.

## Maintenance notes

- These are characterization tests: they lock in *current* behavior so future
  refactors of the dispatch flow are safe. If the trust dialog wording changes
  in a future Claude Code release, `_is_trust_prompt` and its test are the single
  place to update.
- Reviewer should confirm the three extractions are pure (no ssh, no side
  effects) and that the orchestration calls them with identical arguments to the
  old inline code.
- Follow-up (not here): a headless integration smoke that actually launches a
  local `claude -p` is deliberately deferred — too environment-dependent for CI.
