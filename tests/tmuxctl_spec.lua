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

  ["tmuxctl: parse_list and correlate by slug + creation time"] = function()
    -- fields: name, cwd, created, pane_title, gid. Title may carry spaces (and
    -- Claude's state glyph) and may be empty; gid may be empty.
    local list = tmuxctl.parse_list(table.concat({
      "giroux/app-a1b2\t/Users/dev/Code/app/sub\t1000\t⠂ Build the thing\tdeadbeef",
      "giroux/app-c3d4\t/Users/dev/Code/app/sub\t5000\t✳ Build the thing\t",
      "giroux/web-e5f6\t/Users/dev/Code/web\t1000\t\tcafe1234",
    }, "\n"))
    assert(#list == 3, "parsed " .. #list)
    assert(list[1].gid == "deadbeef" and list[2].gid == nil)
    assert(list[1].title == "⠂ Build the thing", "title with glyph + spaces: " .. tostring(list[1].title))
    assert(list[3].title == nil, "empty title -> nil")

    local slug = "-Users-dev-Code-app-sub"
    local hit = tmuxctl.correlate(list, slug, 4990)
    assert(hit and hit.name == "giroux/app-c3d4", "closest creation time wins same-cwd ties")
    assert(tmuxctl.correlate(list, slug, 100000) == nil, "creation far from birth = different run")
    assert(tmuxctl.correlate(list, "-Users-dev-Code-web", 1001).name == "giroux/web-e5f6")
    assert(tmuxctl.correlate(list, "-Users-dev-Code-nope", 1000) == nil)
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
