local steer = require("giroux.steer")
local dispatch = require("giroux.dispatch")
require("giroux").setup({})

return {
  ["steer: send_cmd is multiline-safe via base64 paste-buffer"] = function()
    local cmd = steer.send_cmd("giroux/t/fix-it", "line one\nline 'two' with quotes\n$HOME stays literal")
    assert(cmd:find("base64 %-d"), "text must travel base64")
    assert(cmd:find("tmux load%-buffer"), "must use paste-buffer, not send-keys text")
    assert(cmd:find("paste%-buffer %-d %-b giroux%-steer %-t 'giroux/t/fix%-it'"))
    assert(cmd:find("send%-keys %-t 'giroux/t/fix%-it' Enter$"), "submit with Enter")
    assert(not cmd:find("line one"), "raw text must not appear in the shell command")
    -- the payload round-trips
    local b64 = cmd:match("printf '%%s' '([^']+)'")
    assert(vim.base64.decode(b64) == "line one\nline 'two' with quotes\n$HOME stays literal")
  end,

  ["dispatch: resume_cmd rebuilds a --resume launch with a fresh steer id"] = function()
    local cmd = dispatch.resume_cmd("giroux/app-bb22", "bb22ffff", "/Users/dev/Code/app", "06df2f18-dead-beef")
    assert(cmd:find("tmux new%-session %-d %-s 'giroux/app%-bb22'"))
    assert(cmd:find("GIROUX_SESSION_ID=", 1, true) and cmd:find("bb22ffff", 1, true), "fresh steer id injected")
    assert(cmd:find("--resume", 1, true), "passes --resume")
    assert(cmd:find("06df2f18-dead-beef", 1, true), "resumes the original session id")
    assert(cmd:find("dangerously-skip-permissions", 1, true), "flags applied")
    assert(cmd:find("-c '/Users/dev/Code/app'", 1, true), "in the session's cwd")
  end,

  ["dispatch: parse_reapable picks detached, long-idle giroux sessions"] = function()
    local now = 1000000
    local stdout = table.concat({
      ("giroux/app-a1\t0\t%d"):format(now - 3600), -- detached, 1h idle -> reap
      ("giroux/web-b2\t1\t%d"):format(now - 9999), -- attached -> keep
      ("giroux/db-c3\t0\t%d"):format(now - 60), -- detached but fresh -> keep
      ("work\t0\t%d"):format(now - 9999), -- not a giroux session -> ignore
      ("giroux/t/old-thing\t0\t%d"):format(now - 7200), -- renamed + idle -> reap
    }, "\n")
    local r = dispatch.parse_reapable(stdout, now)
    assert(#r == 2, "expected 2 reapable, got " .. #r .. ": " .. vim.inspect(r))
    local names = vim.tbl_map(function(x)
      return x.name
    end, r)
    assert(vim.tbl_contains(names, "giroux/app-a1") and vim.tbl_contains(names, "giroux/t/old-thing"))
    assert(not vim.tbl_contains(names, "giroux/web-b2"), "attached kept")
    assert(not vim.tbl_contains(names, "giroux/db-c3"), "fresh kept")
  end,

  ["steer: parse_question reads the live picker off a captured pane"] = function()
    local pane = table.concat({
      "✻ Worked for 4s",
      "❯ ask which color",
      "────────────────────────────────",
      " ☐ Color",
      "Which color?",
      "❯ 1. Red",
      "     The color red",
      "  2. Blue",
      "     The color blue",
      "  3. Type something.",
      "  4. Chat about this",
      "Enter to select · ↑/↓ to navigate · Esc to cancel",
    }, "\n")
    local q = steer.parse_question(pane)
    assert(q, "must detect the picker")
    assert(q.question == "Which color?", "question: " .. tostring(q.question))
    assert(#q.options == 4, "4 options incl. meta, got " .. #q.options)
    assert(q.options[1].n == 1 and q.options[1].label == "Red")
    assert(q.options[2].label == "Blue")
    assert(q.options[3].label == "Type something.")
    -- a normal feed/idle pane is not a question
    assert(steer.parse_question("⏺ STEEREDOK\n❯ \n-- INSERT --") == nil)
  end,

  ["steer: parse_question ignores the agent's prose numbered list above the picker"] = function()
    -- the real failure: the pane shows a numbered PLAN the agent wrote, then
    -- the actual picker lower down. Only the picker's options count.
    local pane = table.concat({
      "⏺ Here's the plan:",
      "  1. Fill scope.yaml with the bundle ID and backend domains",
      "  2. Confirm the app is installed via TestFlight",
      "  3. Start managed capture and walk every feature",
      "",
      "⏺ How do you want to proceed?",
      " ☐ Approach",
      "Which authorization path?",
      "❯ 1. Owner debug build available",
      "     We have a debug build with pinning disabled",
      "  2. Authorized to repackage IPA",
      "     Written authorization to repackage with Frida",
      "────────────────────────────",
      "  3. Not sure yet",
      "  4. Type something.",
      "  5. Chat about this",
      "Enter to select · ↑/↓ to navigate · Esc to cancel",
    }, "\n")
    local q = steer.parse_question(pane)
    assert(q, "must detect the picker")
    assert(q.question == "Which authorization path?", "got: " .. tostring(q.question))
    assert(#q.options == 5, "picker has 5 options, prose excluded; got " .. #q.options)
    assert(q.options[1].label == "Owner debug build available")
    assert(q.options[5].label == "Chat about this")
  end,

  ["dispatch: launch_cmd injects id, cwd, flags, styling"] = function()
    local cmd = dispatch.launch_cmd("giroux/app-ab12", "ab12cd34", "/Users/dev/Code/app", 'review the "thing"')
    assert(cmd:find("tmux new%-session %-d %-s 'giroux/app%-ab12'"))
    assert(cmd:find("GIROUX_SESSION_ID=ab12cd34", 1, true) or cmd:find("GIROUX_SESSION_ID='ab12cd34'", 1, true))
    assert(cmd:find("-c '/Users/dev/Code/app'", 1, true))
    assert(cmd:find("dangerously%-skip%-permissions"), "config.dispatch.flags applied")
    assert(cmd:find('review the "thing"', 1, true), "prompt forwarded")
    assert(cmd:find("set%-option .* mouse on"), "styled like the wrapper")
  end,

  ["dispatch: launch_cmd quoting survives real shell execution"] = function()
    -- fake tmux executes the inner shell-command exactly like real tmux
    -- (sh -c "$last_arg"); fake claude logs its argv. The prompt must arrive
    -- byte-identical through both quoting layers.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local log = dir .. "/log"
    local f = assert(io.open(dir .. "/tmux", "w"))
    f:write(
      ('#!/bin/sh\ncase "$1" in new-session)\n  for a in "$@"; do last="$a"; done\n  sh -c "$last";;\nesac\nexit 0\n'):format()
    )
    f:close()
    local g = assert(io.open(dir .. "/claude", "w"))
    g:write(('#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a" >> "%s"; done\n'):format(log))
    g:close()
    vim.fn.system({ "chmod", "+x", dir .. "/tmux", dir .. "/claude" })

    local nasty = [[don't "break" $HOME `quoting` \n ok]]
    local cmd = dispatch.launch_cmd("giroux/x-1111", "id12", "/tmp/x", nasty)
    -- launch_cmd login-wraps the agent (${SHELL:-/bin/sh} -lc '…'); pin HOME and
    -- SHELL so that login shell is deterministic and sources no real profile.
    vim
      .system({ "sh", "-c", ("HOME=%s SHELL=/bin/sh PATH=%s:$PATH; %s"):format(dir, dir, cmd) }, { text = true })
      :wait()
    local fh = assert(io.open(log))
    local args = vim.split(fh:read("*a"), "\n", { trimempty = true })
    fh:close()
    vim.fn.delete(dir, "rf")
    assert(args[1] == "--dangerously-skip-permissions", "flags first: " .. vim.inspect(args))
    assert(args[#args] == nasty, ("prompt must round-trip exactly: %q"):format(args[#args]))
  end,
}
