# Plan 005: Harden stat-sheet / Q&A remote reads and file-open

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- lua/giroux/statsheet.lua lua/giroux/qa.lua`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 002 (soft — 002 also edits the `cat` line in `statsheet.lua`/`qa.lua`; do 002 first to avoid a merge conflict on the same lines)
- **Category**: bug / security
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

The stat sheet (`S`) and Q&A digest (`Q`) full-parse a session by streaming
`cat <path>` over SSH and rendering from an accumulator when the stream ends.
Three latent defects live in that path:

1. **A failed read renders as an authoritative empty result.** Both `on_exit`
   callbacks ignore the process exit code, so if `cat` fails mid-parse (file
   rotated/removed, ssh drop, unreadable path) the sheet/digest still renders —
   showing "Written (0 files)… out 0" as if the session did nothing, with no
   error surfaced. The operator can't tell "the agent did nothing" from "the
   read failed."
2. **The stream isn't stopped on buffer close**, so closing the window during a
   large remote parse leaves `cat` + `ssh` running to EOF.
3. **`<CR>` on a Written/Read path `fs_stat`s a REMOTE path against the LOCAL
   filesystem.** For a remote node with a mirrored `~/Code/...` layout, this
   silently opens the *local* file as if it were the remote agent's — wrong
   machine, wrong content — and opens it with modelines enabled on a
   transcript-chosen path.

None is catastrophic, but together they make the stat sheet quietly
untrustworthy, and #1 is the kind of bug that makes an operator misjudge an
agent's work. All fixes are small.

## Current state

`lua/giroux/statsheet.lua:138-166` — the stream + on_exit + `<CR>` keymap:

```lua
  local acc = stats.new()
  local parser = transcript.parser()
  local strm = ssh.stream(node.host, ("cat '%s'"):format(opts.path), function(chunk)
    for _, e in ipairs(parser:feed(chunk)) do
      acc:add(e)
    end
  end, function()                              -- <-- on_exit takes NO code arg
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines, targets = M.render(acc:summary(), opts.title or vim.fs.basename(opts.path))
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.b[buf].giroux_targets = targets
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local path = (vim.b[buf].giroux_targets or {})[row]
      if path and vim.uv.fs_stat(path) then    -- <-- local fs_stat for a remote path
        vim.cmd.edit(vim.fn.fnameescape(path))
      elseif path then
        vim.notify("giroux: " .. path .. " (remote open not yet wired)", vim.log.levels.INFO)
      end
    end, { buffer = buf, nowait = true, desc = "giroux: open file" })
    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, nowait = true })
  end)
  return buf, strm
```

The returned `strm` has a `.stop()` method (`ssh.stream` returns
`{ stop, running }`, see `lua/giroux/ssh.lua:90-98`) but the roster caller
discards it (`roster.lua` `S` handler calls `statsheet.open` and ignores the
second return). `node` here is `nodes.get(opts.node)` — `node.host == nil` (or
`false`) means the node is local; any other value is remote.

`lua/giroux/qa.lua:187-196` — the same shape, ignoring the exit code:

```lua
  local parser = transcript.parser()
  local events = {}
  ssh.stream(node.host, ("cat '%s'"):format(opts.path), function(chunk)
    vim.list_extend(events, parser:feed(chunk))
  end, function()                              -- <-- no code arg
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines, decos, turns = M._render(M._build(events))
    apply(buf, lines, decos)
    ...
```

`ssh.stream`'s `on_exit` is invoked as `on_exit(out.code)` (`ssh.lua:81-88`), so
the code is available — both callbacks just don't declare the parameter.

NOTE: plan 002 rewrites the `("cat '%s'")` lines to `("cat %s"):format(ssh.shq(opts.path))`.
If 002 has landed, your edits here sit on the `ssh.shq` form; keep it. If 002
has NOT landed, do not change the quoting in this plan — only add the code-check
and host-gate — and let 002 handle quoting.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `statsheet: surface a failed remote read; gate <CR> to local nodes`.

## Commands you will need

| Purpose      | Command                          | Expected on success    |
|--------------|----------------------------------|------------------------|
| Tests (all)  | `nvim -l tests/run.lua`          | `... passed, 0 failed` |
| Tests (one)  | `nvim -l tests/run.lua stats`    | stats/statsheet specs pass |
| Tests (one)  | `nvim -l tests/run.lua qa`       | qa specs pass          |
| Smoke        | `nvim -l scripts/smoke.lua`      | exit 0                 |
| Format check | `stylua --check lua/ tests/`     | exit 0                 |

## Scope

**In scope**:
- `lua/giroux/statsheet.lua` (on_exit code check, host-gate the `<CR>` open,
  stop stream on buffer close)
- `lua/giroux/qa.lua` (on_exit code check; qa's `<CR>` drills into the feed, not
  a file open — so no host-gate needed there, but check for the same
  stop-on-close gap and fix if the stream handle is available)

**Out of scope** (do NOT touch):
- `lua/giroux/stats.lua` — the pure aggregation is correct.
- `M.render` / `M._render` / `M._build` — the renderers are fine; only the
  failure handling around them changes.
- Actually implementing remote file open (the "not yet wired" branch) — that is
  a separate direction item (tier-2/3 diffs). Keep the notice; just stop
  shadowing it with a wrong local open.
- `roster.lua` — you may optionally have the `S` handler keep the returned
  `strm`, but only if it's a one-line change; if it ripples, leave roster alone
  and register the buffer-close stop inside `statsheet.open` itself (Step 3).

## Git workflow

- Branch: `advisor/005-statsheet-qa-remote-read`
- One commit; message like `statsheet/qa: error on failed reads; don't open a remote path locally`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Surface a failed read in both modules

Give both `on_exit` callbacks the `code` parameter and render an error row when
it's nonzero instead of a misleadingly-empty sheet.

`statsheet.lua` — change `end, function()` to `end, function(code)` and at the
top of the body, after the `nvim_buf_is_valid` guard:

```lua
  end, function(code)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if code and code ~= 0 then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "  giroux: read failed (exit " .. code .. ") — the transcript may have",
        "  rotated, been removed, or the connection dropped. Try again.",
      })
      vim.bo[buf].modifiable = false
      return
    end
    ...
```

`qa.lua` — same treatment: `end, function(code)` and an early error render
before `M._render(M._build(events))`. Use `apply(buf, {...}, {})` if that's how
qa writes lines, or the same `nvim_buf_set_lines` pattern — match qa's existing
render call shape.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 2: Host-gate the stat-sheet `<CR>` file open

Capture whether the node is local before the keymap closure (the `node` from
`nodes.get(opts.node)` is already in scope at the top of `M.open`). Only do the
local `fs_stat` + `edit` when the node is local; otherwise always fall through to
the "remote open not yet wired" notice. Also open with modelines/autocmds off,
since the path is transcript-derived:

```lua
    local is_local = not node.host  -- host nil OR false == local (repo convention)
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local path = (vim.b[buf].giroux_targets or {})[row]
      if not path then
        return
      end
      if is_local and vim.uv.fs_stat(path) then
        -- transcript-derived path: open without running its modelines/autocmds
        vim.cmd("noautocmd edit " .. vim.fn.fnameescape(path))
        vim.bo.modeline = false
      else
        vim.notify("giroux: " .. path .. " (remote open not yet wired)", vim.log.levels.INFO)
      end
    end, { buffer = buf, nowait = true, desc = "giroux: open file" })
```

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 3: Stop the stream when the stat-sheet buffer is wiped

Inside `statsheet.open`, after `strm` is created, register a one-shot autocmd so
closing the buffer stops the remote `cat`:

```lua
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(function()
        if strm and strm.running and strm.running() then
          strm.stop()
        end
      end)
    end,
  })
```

Place it where `buf` and `strm` are both in scope (near the `return buf, strm`).
Do the equivalent in `qa.lua` **only if** qa's stream handle is captured in a
local; qa currently calls `ssh.stream(...)` without assigning it — if so, assign
it to a local `local strm = ssh.stream(...)` and add the same BufWipeout guard.

**Verify**: `nvim -l scripts/smoke.lua` → exit 0.

### Step 4: Full suite + format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed` (no test count change required — these are
  hard to unit-test without a live remote; see Test plan).
- `stylua --check lua/ tests/` → exit 0.

## Test plan

The failure paths here involve a live SSH stream and are integration-shaped, so
new pure unit tests are limited. Do the achievable one:

- If you extract the error-row builder or the `is_local` decision into a small
  pure helper, add a unit test for it (e.g. `statsheet._error_lines(code)`
  returns a non-empty message for `code ~= 0` and the host-gate returns false for
  a remote node). This is optional but preferred — a tiny pure seam is testable.
- Otherwise, rely on smoke + the existing stats/qa specs staying green, and
  verify manually per the Done criteria.
- Do NOT add a flaky test that shells out to a real `cat` on a missing file.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`.
- [ ] `nvim -l scripts/smoke.lua` exits 0.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] Both `on_exit` callbacks in `statsheet.lua` and `qa.lua` declare and check
      a `code` parameter (`git grep -n "function(code)" lua/giroux/statsheet.lua lua/giroux/qa.lua`
      returns both).
- [ ] The stat-sheet `<CR>` open is gated on the node being local
      (`git grep -n "node.host" lua/giroux/statsheet.lua` shows the gate).
- [ ] The stat-sheet stream is stopped on `BufWipeout`.
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/README.md` status row for 005 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `on_exit`/`<CR>` excerpts don't match the live code (drift).
- `ssh.stream`'s `on_exit` no longer receives the exit code (check `ssh.lua`
  ~line 81) — then the code-check premise is invalid.
- Adding the BufWipeout stop causes the existing render to break (e.g. the
  autocmd fires during normal teardown before render) — report rather than
  forcing it.

## Maintenance notes

- When remote file open lands (tier-3 rsync cache, a separate direction plan),
  the `<CR>` "remote open not yet wired" branch is where it hooks in; the
  host-gate added here is the correct place to route local vs remote.
- Reviewer should confirm the error-row path can't be reached on a *successful*
  empty transcript (a genuinely empty session should still render "0 files",
  only a nonzero exit should show the error).
