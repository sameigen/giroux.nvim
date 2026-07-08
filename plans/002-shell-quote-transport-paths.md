# Plan 002: Shell-quote every transcript path before it reaches a remote shell

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/ssh.lua lua/giroux/feed.lua lua/giroux/statsheet.lua lua/giroux/qa.lua tests/transport_spec.lua`
> If any of these changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `482e989`, 2026-07-08 (working tree dirty; `ssh.lua`/`feed.lua` had uncommitted changes — drift check will surface them)

## Why this matters

giroux's core promise is that **observation cannot affect the observed** —
tailing a transcript is a file read that can't run code. But the transport
layer interpolates transcript **file paths** into shell command strings that
run on the node over SSH, in the operator's login context (which sources the
`CLAUDE_CODE_OAUTH_TOKEN`). Those paths come from `find ~/.claude/projects`, and
the threat model treats a transcript filename as semi-trusted: an agent running
with `--dangerously-skip-permissions` can create a `*.jsonl` with an arbitrary
name, and any repo whose absolute path contains a shell metacharacter yields
such a name through Claude's cwd→slug directory encoding. The worst site,
`ssh.multi_tail_cmd`, wraps the path in **double quotes**, where `$(...)` and
backticks stay live — no quote-breakout even needed — and it runs automatically
on every node stream. Other sites single-quote but don't escape an embedded
`'`. A correct quoting helper (`shq`) already exists in the codebase (duplicated
in `dispatch.lua` and `steer.lua`) but is never applied on the path observation
data actually travels. This plan routes every such path through one shared
`shq`, turning the trust-inversion back off.

## Current state

A correct single-quote-escaping helper exists, duplicated, at
`lua/giroux/dispatch.lua:12-14` and `lua/giroux/steer.lua:14-16`:

```lua
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
```

`lua/giroux/ssh.lua` has NO such helper and builds these commands with raw
interpolation:

- `ssh.lua:111` (in `M.tail`) — single-quoted, embedded `'` NOT escaped:
  ```lua
  local cmd = ("exec tail -c +%d -F '%s' 2>/dev/null"):format(offset + 1, path)
  ```
- `ssh.lua:128-138` (`M.multi_tail_cmd`) — the worst: **double-quoted** path,
  and the same path double-quoted again inside `awk -v p="..."`:
  ```lua
  function M.multi_tail_cmd(files)
    local parts = { "trap 'kill 0 2>/dev/null' EXIT HUP TERM INT;" }
    for _, f in ipairs(files) do
      parts[#parts + 1] = ('tail -c +%d -F "%s" 2>/dev/null | awk -v p="%s" \'{ print p "\\t" $0; fflush() }\' &'):format(
        f.offset + 1,
        f.path,
        f.path
      )
    end
    parts[#parts + 1] = "wait"
    return table.concat(parts, " ")
  end
  ```

Three more single-quoted, unescaped sites in other modules:

- `lua/giroux/feed.lua:587` — `("tail -c +%d '%s' 2>/dev/null"):format(offset + 1, feed.path)`
- `lua/giroux/feed.lua:831` — `("wc -c < '%s'"):format(feed.path)`
- `lua/giroux/statsheet.lua:140` — `("cat '%s'"):format(opts.path)`
- `lua/giroux/qa.lua:189` — `("cat '%s'"):format(opts.path)`

**Existing test that pins the OLD (double-quoted) form** — you MUST update it
(`tests/transport_spec.lua:19-20`):

```lua
    assert(cmd:find('tail -c +1 -F "/p/a.jsonl"', 1, true), "offset 0 -> byte 1")
    assert(cmd:find('tail -c +101 -F "/p/b.jsonl"', 1, true), "offset 100 -> byte 101")
```

After this plan those paths are single-quote-wrapped, so these asserts change to
match (see Step 4).

Why the double-quote form is the sharp one: inside `"..."` the shell keeps `$`,
`` ` ``, and `\` active, so a filename containing `$(cmd)` or `` `cmd` ``
executes. Single-quotes (`'...'`) are literal for everything **except** a `'`
itself, so the single-quoted sites need only the `'\''` escaping that `shq`
already does.

Repo conventions:
- List-form `vim.system` is used for argv where possible, but these are
  intentionally shell pipelines (`tail | awk`, `cat`) that need a shell — so the
  right fix is escaping, not list-form.
- Terse comments; commit messages terse/lowercase/module-prefixed, no AI
  trailers. Example: `ssh: single-quote-escape every path in the merged tail`.

## Commands you will need

| Purpose        | Command                                | Expected on success     |
|----------------|----------------------------------------|-------------------------|
| Tests (all)    | `nvim -l tests/run.lua`                | `... passed, 0 failed`  |
| Tests (one)    | `nvim -l tests/run.lua transport`      | transport specs pass    |
| Smoke          | `nvim -l scripts/smoke.lua`            | exit 0                  |
| Format check   | `stylua --check lua/ tests/`           | exit 0                  |
| Format fix     | `stylua lua/ tests/`                   | rewrites in place       |

## Scope

**In scope** (the only files you should modify):
- `lua/giroux/ssh.lua` (add `M.shq`; fix `M.tail` and `M.multi_tail_cmd`)
- `lua/giroux/feed.lua` (two sites)
- `lua/giroux/statsheet.lua` (one site)
- `lua/giroux/qa.lua` (one site)
- `tests/transport_spec.lua` (update the two asserts + add a hostile-path test)

**Out of scope** (do NOT touch):
- `lua/giroux/dispatch.lua` / `lua/giroux/steer.lua` — their `shq` is already
  correct and applied. Do NOT try to dedupe them into `ssh.shq` in this plan
  (that's a debt refactor; keep this security fix minimal and low-risk).
- The `tmux rename-session` escaping in `tmuxctl.lua` and the `osascript` call
  in `notify.lua` — lower-reachability, tracked separately; leave them.
- The `--dangerously-skip-permissions` default — a documented product decision.

## Git workflow

- Branch: `advisor/002-shell-quote-transport-paths`
- One commit; message like `ssh: shell-quote every transcript path in the transport layer`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a shared `shq` to `ssh.lua`

Add a public helper near the top of `lua/giroux/ssh.lua` (after the module table
`M` is declared). Make it public (`M.shq`) so the tests can assert on it and so
`feed`/`statsheet`/`qa` can call it:

```lua
---Single-quote a string for POSIX sh: literal for everything except `'`, which
---is closed, escaped, and reopened. The ONLY safe wrap for a semi-trusted path
---(a transcript filename) that ends up in a remote shell command — never use
---double quotes, which keep $(), backticks and \ live.
---@param s string
---@return string
function M.shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
```

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 2: Fix `M.tail` and `M.multi_tail_cmd` in `ssh.lua`

`M.tail` (line ~111) — replace the `'%s'` with `%s` fed by `M.shq(path)`:

```lua
  local cmd = ("exec tail -c +%d -F %s 2>/dev/null"):format(offset + 1, M.shq(path))
```

`M.multi_tail_cmd` — quote the path with `M.shq` for BOTH the `tail` operand and
the `awk -v p=` value. `awk -v p=<shq>` is a shell word, so single-quote it the
same way; awk then receives the literal path as the variable's value:

```lua
    parts[#parts + 1] = ("tail -c +%d -F %s 2>/dev/null | awk -v p=%s '{ print p \"\\t\" $0; fflush() }' &"):format(
      f.offset + 1,
      M.shq(f.path),
      M.shq(f.path)
    )
```

Keep the surrounding `trap 'kill 0 ...'`, the `&`, and the trailing `wait`
exactly as they are — those are load-bearing (see ARCHITECTURE.md Transport;
`kill 0` is deliberate, do not change it).

**Verify**: `nvim -l tests/run.lua transport` → the first transport test will
FAIL on the two double-quote asserts (expected — you fix those in Step 4). No
other assert in that test should fail.

### Step 3: Fix the `feed`/`statsheet`/`qa` sites

Each of these modules already requires `ssh` (grep to confirm the local
variable name — it's `ssh` in all three). Replace the raw `'%s'`:

- `lua/giroux/feed.lua:587`:
  ```lua
  ssh.exec(feed.host, ("tail -c +%d %s 2>/dev/null"):format(offset + 1, ssh.shq(feed.path)), function(ok, stdout)
  ```
- `lua/giroux/feed.lua:831`:
  ```lua
  ssh.exec(feed.host, ("wc -c < %s"):format(ssh.shq(feed.path)), function(ok, stdout)
  ```
- `lua/giroux/statsheet.lua:140`:
  ```lua
  local strm = ssh.stream(node.host, ("cat %s"):format(ssh.shq(opts.path)), function(chunk)
  ```
- `lua/giroux/qa.lua:189`:
  ```lua
  ssh.stream(node.host, ("cat %s"):format(ssh.shq(opts.path)), function(chunk)
  ```

**Verify**: `nvim -l scripts/smoke.lua` → exit 0. `git grep -n "'%s'" lua/giroux/feed.lua lua/giroux/statsheet.lua lua/giroux/qa.lua`
should no longer show the tail/wc/cat lines above (it may show unrelated `'%s'`
uses — only the four path sites must be gone).

### Step 4: Update `transport_spec.lua` and add a hostile-path regression test

Update the two asserts at `tests/transport_spec.lua:19-20` to the single-quoted
form:

```lua
    assert(cmd:find("tail -c +1 -F '/p/a.jsonl'", 1, true), "offset 0 -> byte 1")
    assert(cmd:find("tail -c +101 -F '/p/b.jsonl'", 1, true), "offset 100 -> byte 101")
```

Then add a new test in the same file that proves a hostile path can't break out.
Use a path containing a single quote, `$(...)`, a backtick, and a space, and
assert the command substitution / breakout characters cannot escape the quoting
(i.e. the dangerous substrings appear only *inside* a single-quoted literal, and
there is no bare `$(` or unescaped `"` around the path):

```lua
["transport: multi_tail_cmd neutralizes a hostile filename"] = function()
  local nasty = [[/p/a'; $(touch pwned) `id` .jsonl]]
  local cmd = ssh.multi_tail_cmd({ { path = nasty, offset = 0 } })
  -- the path must be single-quoted with '\'' escaping; no double-quote wrap
  assert(not cmd:find('-F "', 1, true), "path must never be double-quoted")
  -- the literal $(touch pwned) survives only as inert text inside single quotes
  assert(cmd:find("$(touch pwned)", 1, true), "substitution text is present but inert")
  -- round-trip: extracting the single-quoted operand and un-escaping yields the path
  -- (sanity that shq is reversible for this input)
  assert(ssh.shq(nasty):find("'\\''", 1, true), "embedded quote is escaped")
end,
```

If `ssh.multi_tail_cmd` is not `require`-able as written (it is `M.multi_tail_cmd`,
already used by the existing test at line 10), reuse the existing `local ssh =
require("giroux.ssh")` at the top of the spec.

**Verify**: `nvim -l tests/run.lua transport` → all transport specs pass,
including the new one.

### Step 5: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `... passed, 0 failed` (count +1 for the new test).
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` if needed).
- `git grep -n 'tail -c .* -F "' lua/giroux/ssh.lua` → no matches (no
  double-quoted tail operand remains).

## Test plan

- Update the two existing double-quote asserts in `tests/transport_spec.lua` to
  the single-quoted form.
- New test in `tests/transport_spec.lua`: a filename containing `'`, `$(...)`,
  backtick, and space is single-quoted and inert (no breakout).
- Pattern: the existing `transport: multi_tail_cmd builds one channel over many
  files` test.
- Verification: `nvim -l tests/run.lua transport` → all pass.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`; count is +1.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `git grep -n 'tail -c .* -F "' lua/giroux/ssh.lua` returns nothing.
- [ ] `git grep -n "cat '%s'\|wc -c < '%s'" lua/giroux` returns nothing.
- [ ] `M.shq` exists in `ssh.lua` and is used by `M.tail`, `M.multi_tail_cmd`,
      and the four `feed`/`statsheet`/`qa` sites.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 002 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `multi_tail_cmd`/`tail` excerpts don't match the live code (drift).
- Escaping the `awk -v p=` value changes the demux behavior — the demux splits
  on the first TAB (`ssh.lua` `demux`); the awk `print p "\t" $0` must still
  emit exactly one TAB after the path. If a passing `transport` test that checks
  demux/`fflush` starts failing, stop and report.
- `feed`/`statsheet`/`qa` turn out to reference `ssh` under a different local
  name than `ssh` — confirm before editing; do not add a new require.

## Maintenance notes

- Any NEW shell-out that interpolates a path or transcript-derived string must
  use `ssh.shq`. Consider this the single sanctioned quoter for the transport
  layer.
- Follow-up (separate, lower priority): dedupe the `dispatch.lua`/`steer.lua`
  local `shq` into `ssh.shq`, and apply `shq` to `tmuxctl.rename-session` and
  `notify.osascript`. Deliberately out of scope here to keep the security fix
  small and reviewable.
- Reviewer should confirm no path site was missed: `git grep -nE "(tail|cat|wc|stat|find) .*%%s" lua/giroux`
  and check each hit wraps the `%s` argument in `ssh.shq` or an already-safe
  quoter.
