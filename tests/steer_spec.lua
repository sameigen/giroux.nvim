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

  ["steer: attach lets C-z through to suspend claude (now a shell job)"] = function()
    local km = {}
    for _, m in ipairs(steer.attach_keymaps()) do
      km[m.lhs] = m.rhs
    end
    -- claude now runs as a job in an interactive shell, so ^Z suspends it to that
    -- shell (work, then `fg`). The attach must NOT intercept C-z or it'd block
    -- that — let it pass straight through to the pane.
    assert(km["<C-z>"] == nil, "C-z must pass through to claude (suspends it to a shell)")
    assert(km["<C-q>"] == "<C-\\><C-n>", "C-q leaves terminal mode for scroll/copy")
    assert(km["<Esc>"] == "<Esc>", "Esc still belongs to the agent")
  end,

  ["dispatch: resume_cmd rebuilds a --resume launch as a shell job"] = function()
    local cmd = dispatch.resume_cmd("giroux/app-bb22", "bb22ffff", "/Users/dev/Code/app", "06df2f18-dead-beef")
    assert(cmd:find("tmux new%-session %-d %-s 'giroux/app%-bb22'"))
    assert(cmd:find("GIROUX_SESSION_ID=", 1, true) and cmd:find("bb22ffff", 1, true), "fresh steer id injected")
    assert(cmd:find("-c '/Users/dev/Code/app'", 1, true), "in the session's cwd")
    assert(cmd:find("tmux send%-keys %-t 'giroux/app%-bb22'.*Enter"), "agent run as a job in the shell")
    -- the agent argv travels base64; decode it to verify --resume <id> + flags
    local b64 = (cmd:match("printf %%s%s+(.-)%s+|%s+base64") or ""):gsub("[^A-Za-z0-9+/=]", "")
    local decoded = vim.base64.decode(b64)
    assert(decoded:find("--resume", 1, true), "passes --resume: " .. decoded)
    assert(decoded:find("06df2f18-dead-beef", 1, true), "resumes the original session id")
    assert(decoded:find("dangerously-skip-permissions", 1, true), "flags applied")
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

  ["dispatch: repo_label shows parent/name + recency, fuzzy-friendly"] = function()
    local label = dispatch._repo_label({ path = "/Users/sam/Code/personal/2drs", mtime = os.time() - 7200 })
    assert(label:find("personal/2drs", 1, true), "shows parent/name: " .. label)
    assert(label:find("2h", 1, true), "shows a recency hint: " .. label)
    -- no mtime -> just the short path, no trailing age
    local bare = dispatch._repo_label({ path = "/srv/repos/hydra", mtime = 0 })
    assert(bare:find("repos/hydra", 1, true) and not bare:find("%dm") and not bare:find("%dh"), "bare: " .. bare)
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

  ["dispatch: launch_cmd runs the agent as a shell job (id, cwd, styling)"] = function()
    local cmd = dispatch.launch_cmd("giroux/app-ab12", "ab12cd34", "/Users/dev/Code/app", 'review the "thing"')
    assert(cmd:find("tmux new%-session %-d %-s 'giroux/app%-ab12'"))
    assert(cmd:find("GIROUX_SESSION_ID=ab12cd34", 1, true) or cmd:find("GIROUX_SESSION_ID='ab12cd34'", 1, true))
    assert(cmd:find("-c '/Users/dev/Code/app'", 1, true))
    -- claude is NOT the pane command — it's sent as a foreground job so C-z
    -- suspends it and `fg` resumes. The agent argv travels base64, so neither
    -- "claude" nor the prompt appears literally (multiline-safe).
    assert(cmd:find("tmux send%-keys %-t 'giroux/app%-ab12'.*Enter"), "agent sent as a job: " .. cmd)
    assert(cmd:find("base64 %-d"), "agent argv travels base64")
    assert(not cmd:find("claude", 1, true), "claude must not be a literal pane command (it's the base64 payload)")
    assert(not cmd:find("thing", 1, true), "prompt must not appear literally")
    assert(cmd:find("set%-option .* mouse on"), "styled like the wrapper")
  end,

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

  ["dispatch: launch_cmd quoting survives real shell execution"] = function()
    -- fake tmux: new-session is a no-op (real tmux would start a shell);
    -- send-keys runs the command it would type into that shell (the arg before
    -- "Enter"), exactly like the interactive shell executing it. The prompt must
    -- arrive byte-identical through shq + base64 + eval.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local log = dir .. "/log"
    local f = assert(io.open(dir .. "/tmux", "w"))
    f:write('#!/bin/sh\ncase "$1" in send-keys) shift; sh -c "$3";; esac\nexit 0\n')
    f:close()
    local g = assert(io.open(dir .. "/claude", "w"))
    g:write(('#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a" >> "%s"; done\n'):format(log))
    g:close()
    vim.fn.system({ "chmod", "+x", dir .. "/tmux", dir .. "/claude" })

    local nasty = [[don't "break" $HOME `quoting` \n ok]]
    local cmd = dispatch.launch_cmd("giroux/x-1111", "id12", "/tmp/x", nasty)
    vim.system({ "sh", "-c", ("PATH=%s:$PATH; %s"):format(dir, cmd) }, { text = true }):wait()
    local fh = assert(io.open(log))
    local args = vim.split(fh:read("*a"), "\n", { trimempty = true })
    fh:close()
    vim.fn.delete(dir, "rf")
    assert(args[1] == "--dangerously-skip-permissions", "flags first: " .. vim.inspect(args))
    assert(args[#args] == nasty, ("prompt must round-trip exactly: %q"):format(args[#args]))
  end,
}
