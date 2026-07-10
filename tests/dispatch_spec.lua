local dispatch = require("giroux.dispatch")
require("giroux").setup({})

return {
  ["dispatch: _parse_repos sorts-agnostic, keeps paths with spaces, drops junk"] = function()
    local out = table.concat({
      "1720000000\t/Users/sam/Code/personal/giroux.nvim",
      "1719990000\t/srv/repos/my project", -- space in path preserved
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
    local slug = "-Users-sam-Code-app" -- whatever tmuxctl.slugify produces; use the shape, see note
    local match = { path = "/home/u/.claude/projects/" .. slug .. "/abc.jsonl", birth = since + 2 }
    assert(dispatch._is_dispatched_session(match, slug, since), "born after dispatch, slug matches")
    local old = { path = match.path, birth = since - 30 }
    assert(not dispatch._is_dispatched_session(old, slug, since), "born well before dispatch -> no")
    local other = { path = "/home/u/.claude/projects/-other-repo/abc.jsonl", birth = since + 2 }
    assert(not dispatch._is_dispatched_session(other, slug, since), "different slug -> no")
    local grace = { path = match.path, birth = since - 3 }
    assert(dispatch._is_dispatched_session(grace, slug, since), "within 5s skew grace -> yes")
  end,

  ["dispatch: dead_shells reaps only childless, detached, aged panes"] = function()
    local tmuxctl = require("giroux.tmuxctl")
    local now = 100000
    local snap = tmuxctl.parse_list(table.concat({
      ("giroux/dead-a1b2\t100\t/x\t%d\t0\t"):format(now - 7200), -- childless + detached + old -> reap
      ("giroux/live-c3d4\t200\t/x\t%d\t0\t"):format(now - 7200), -- claude child -> keep
      ("giroux/seen-e5f6\t300\t/x\t%d\t1\t"):format(now - 7200), -- attached -> keep (human looking at it)
      ("giroux/new-a9b8\t400\t/x\t%d\t0\t"):format(now - 30), -- fresh dispatch, claude not up yet -> keep
      "===GIROUX-PS===",
      "100 1",
      "200 1",
      "210 200", -- a running (or C-z-suspended) claude is a child
      "300 1",
      "400 1",
    }, "\n"))
    local dead = dispatch.dead_shells(snap, now, dispatch.REAP_GRACE_SECS)
    assert(#dead == 1 and dead[1] == "giroux/dead-a1b2", vim.inspect(dead))
    -- a session is one unit: if ANY of its panes has work, no pane of it dies
    local multi = tmuxctl.parse_list(table.concat({
      ("giroux/split-1111\t500\t/x\t%d\t0\t"):format(now - 7200),
      ("giroux/split-1111\t600\t/x\t%d\t0\t"):format(now - 7200),
      "===GIROUX-PS===",
      "500 1",
      "600 1",
      "610 600",
    }, "\n"))
    assert(#dispatch.dead_shells(multi, now, 600) == 0, "one busy pane protects the whole session")
  end,
}
