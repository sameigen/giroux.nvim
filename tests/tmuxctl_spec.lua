local tmuxctl = require("giroux.tmuxctl")
local h = require("helpers")
require("giroux").setup({})

---Run the wrapper's decision tree in real zsh with fake claude/tmux binaries
---on PATH. Returns the call log.
---@param args string args to pass to `claude`
---@param env string extra env exports, e.g. "TMUX=fake"
---@return string log
local function run_wrapper(args, env)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local log = dir .. "/log"
  local function fake(name, tag)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(('#!/bin/sh\necho "%s $@" >> "%s"\n'):format(tag, log))
    f:close()
    vim.fn.system({ "chmod", "+x", dir .. "/" .. name })
  end
  fake("claude", "CLAUDE")
  fake("tmux", "TMUX")
  local wrapper = vim.fn.fnamemodify("scripts/claude-wrapper.zsh", ":p")
  -- unset TMUX first so running the suite from inside tmux doesn't trip the
  -- wrapper's in-tmux passthrough; the in-tmux case re-exports it via `env`.
  local script = ([[unset TMUX; %s; export PATH="%s:$PATH"; source "%s"; claude %s]]):format(
    env or "true",
    dir,
    wrapper,
    args
  )
  vim.system({ "zsh", "-c", script }, { text = true }):wait()
  local fh = io.open(log)
  local out = fh and fh:read("*a") or ""
  if fh then
    fh:close()
  end
  vim.fn.delete(dir, "rf")
  return out
end

return {
  ["tmuxctl: slugify matches Claude's project encoding"] = function()
    assert(tmuxctl.slugify("/Users/dev/Code/app") == "-Users-dev-Code-app")
    assert(tmuxctl.slugify("/Users/dev/.cache/nvim/x") == "-Users-dev--cache-nvim-x")
  end,

  ["tmuxctl: parse_list reads panes + ps snapshot; non-giroux panes dropped"] = function()
    -- pane fields: name, pane_pid, cwd, created, attached, pane_title. Title
    -- may carry spaces (and Claude's state glyph) and may be empty.
    local snap = tmuxctl.parse_list(table.concat({
      "giroux/app-a1b2\t100\t/Users/dev/Code/app/sub\t1000\t0\t⠂ Build the thing",
      "giroux/app-c3d4\t200\t/Users/dev/Code/app/sub\t5000\t1\t✳ Build the thing",
      "giroux/web-e5f6\t300\t/Users/dev/Code/web\t1000\t0\t",
      "personal-stuff\t400\t/Users/dev\t1\t1\tshell",
      "===GIROUX-PS===",
      "  100     1",
      "  110   100", -- claude under pane 100's shell
      "  111   110", -- mcp server under claude
      "  200     1", -- claude IS the pane process (dispatch legacy)
      "  300     1", -- bare shell, nothing running
      "  999   998",
    }, "\n"))
    assert(#snap.panes == 3, "giroux panes only: " .. #snap.panes)
    assert(snap.panes[1].pane_pid == 100 and snap.panes[1].attached == false)
    assert(snap.panes[2].attached == true)
    assert(snap.panes[1].title == "⠂ Build the thing", "title with glyph + spaces")
    assert(snap.panes[3].title == nil, "empty title -> nil")
    assert(snap.parent[110] == 100 and snap.parent[999] == 998, "ps table parsed")
  end,

  ["tmuxctl: owner_pane walks pid ancestry to the pane"] = function()
    local snap = tmuxctl.parse_list(table.concat({
      "giroux/app-a1b2\t100\t/x\t1000\t0\t",
      "giroux/app-c3d4\t200\t/x\t1000\t0\t",
      "===GIROUX-PS===",
      "100 1",
      "110 100",
      "111 110",
      "200 1",
      "900 899",
    }, "\n"))
    assert(tmuxctl.owner_pane(snap, 111).name == "giroux/app-a1b2", "grandchild resolves through the shell")
    assert(tmuxctl.owner_pane(snap, 200).name == "giroux/app-c3d4", "claude-as-pane matches itself")
    assert(tmuxctl.owner_pane(snap, 900) == nil, "pid outside any pane tree")
    assert(tmuxctl.owner_pane(snap, nil) == nil)
  end,

  ["tmuxctl: correlate is exact via agents map, honest without it"] = function()
    local snap = tmuxctl.parse_list(table.concat({
      "giroux/app-a1b2\t100\t/Users/dev/Code/app\t1000\t0\t",
      "giroux/app-c3d4\t200\t/Users/dev/Code/app\t1005\t0\t", -- SAME cwd: the wrong-attach trap
      "giroux/web-e5f6\t300\t/Users/dev/Code/web\t1000\t0\t",
      "===GIROUX-PS===",
      "100 1",
      "110 100",
      "200 1",
      "210 200",
      "300 1",
    }, "\n"))
    local agents_map = { ["sid-one"] = { pid = 110 }, ["sid-two"] = { pid = 210 } }
    local slug = "-Users-dev-Code-app"
    -- exact tier: two sessions in one cwd resolve to their OWN panes
    assert(tmuxctl.correlate(snap, "sid-one", agents_map, slug, 1000).name == "giroux/app-a1b2")
    assert(tmuxctl.correlate(snap, "sid-two", agents_map, slug, 1000).name == "giroux/app-c3d4")
    -- an available map with no entry = no live claude = observe-only, never a cwd guess
    assert(tmuxctl.correlate(snap, "sid-gone", agents_map, slug, 1000) == nil)
    -- fallback tier (agents unavailable): only an UNAMBIGUOUS cwd match correlates
    assert(tmuxctl.correlate(snap, "sid-one", nil, slug, 1000) == nil, "two same-cwd candidates = refuse to guess")
    assert(tmuxctl.correlate(snap, "sid-web", nil, "-Users-dev-Code-web", 1001).name == "giroux/web-e5f6")
    assert(
      tmuxctl.correlate(snap, "sid-web", nil, "-Users-dev-Code-web", 100000) == nil,
      "birth far off = different run"
    )
    assert(tmuxctl.correlate(snap, "sid-x", nil, "-Users-dev-Code-nope", 1000) == nil)
  end,

  ["tmuxctl: title_state reads Claude's live state glyph"] = function()
    -- real captured titles: braille spinner = working, ✳ = idle
    assert(tmuxctl.title_state("⠂ Deep dive into giroux.nvim") == "working")
    assert(tmuxctl.title_state("⠐ Review codebase state") == "working")
    assert(tmuxctl.title_state("✳ Set up Cozy Collective") == "idle")
    -- a bare title or an unknown leading glyph is unknown, never a guess
    assert(tmuxctl.title_state("Plain title, no glyph") == nil)
    assert(tmuxctl.title_state("") == nil)
    assert(tmuxctl.title_state(nil) == nil)
  end,

  ["tmuxctl: rename guards"] = function()
    assert(tmuxctl.renameable("giroux/app-a1b2"), "wrapper-minted names rename")
    assert(tmuxctl.renameable("giroux/t/fix-the-sync-race"), "our own titles re-rename")
    assert(not tmuxctl.renameable("giroux/my-hand-picked-name"), "manual renames are never fought")
    assert(tmuxctl.title_to_name("Fix the sync race! (TICKET-123)") == "giroux/t/fix-the-sync-race-ticket-123")
    -- the sid suffix keeps same-titled sessions from colliding on one name
    -- (a colliding rename fails, and bookkeeping used to point the loser at
    -- the winner's session)
    local a = tmuxctl.title_to_name("Fix the sync race", "798c4bca-02d5-4d6f")
    local b = tmuxctl.title_to_name("Fix the sync race", "06df2f18-b486-4968")
    assert(a == "giroux/t/fix-the-sync-race-798c", a)
    assert(a ~= b, "same title, different sessions, different names")
    assert(tmuxctl.exact("giroux/t/fix") == "=giroux/t/fix", "exact pins tmux -t prefix matching")
  end,

  ["wrapper: passthrough and capture decisions (real zsh)"] = function()
    h.skip_unless(h.has("zsh"), "zsh not installed")
    -- inside tmux -> raw claude
    local log = run_wrapper("--dangerously-skip-permissions", "export TMUX=fake")
    assert(log:find("CLAUDE %-%-dangerously"), "in-tmux must pass through: " .. log)
    assert(not log:find("TMUX new"), "no nested tmux")

    -- headless -> raw claude
    log = run_wrapper("-p 'do a thing'", "export GIROUX_WRAPPER_FORCE=1")
    assert(log:find("CLAUDE %-p"), "-p must pass through: " .. log)

    -- utility subcommand -> raw claude
    log = run_wrapper("mcp list", "export GIROUX_WRAPPER_FORCE=1")
    assert(log:find("CLAUDE mcp list"), "subcommands pass through: " .. log)

    -- no tty, no force -> raw claude
    log = run_wrapper("--dangerously-skip-permissions", "")
    assert(log:find("CLAUDE"), "no-tty must pass through: " .. log)

    -- interactive (forced tty) -> tmux capture with env id + cwd + command
    log = run_wrapper("--dangerously-skip-permissions", "export GIROUX_WRAPPER_FORCE=1")
    assert(log:find("TMUX new%-session %-d %-s giroux/"), "must create a giroux session: " .. log)
    assert(log:find("GIROUX_SESSION_ID=%x%x%x%x%x%x%x%x"), "must inject the id: " .. log)
    -- claude is sent as a FOREGROUND JOB into the session's interactive shell
    -- (so C-z suspends it and `fg` resumes), not run as the pane command.
    assert(log:find("TMUX send%-keys %-t giroux/"), "claude must be sent into the shell: " .. log)
    assert(log:find("send%-keys.-claude.-Enter"), "the agent command runs as a job (…Enter): " .. log)
    assert(log:find("dangerously%-skip%-permissions"), "must forward args: " .. log)
    assert(log:find("TMUX set%-option"), "must style the session")
    assert(not log:find("CLAUDE "), "raw claude must NOT run in capture mode: " .. log)
  end,
}
