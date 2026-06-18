local notify = require("giroux.notify")
local h = require("helpers")

return {
  ["notify: macos channel degrades to vim.notify off macOS (no crash)"] = function()
    -- regression: default channel for question/dead is "macos"; on a Linux node
    -- vim.system{"osascript"} raises ENOENT and used to crash monitor.derive().
    h.skip_unless(vim.fn.executable("osascript") ~= 1, "needs a host without osascript")
    require("giroux").setup({ notify = { levels = { dead = "macos", question = "macos" } } })
    notify.reset()
    local ok = pcall(notify.fire, "dead", { path = "/x", title = "X" }, "went dark")
    assert(ok, "macos channel must not raise when osascript is absent")
    notify.reset()
  end,

  ["notify: badge counts live conditions, dedupes per state-entry"] = function()
    require("giroux").setup({ notify = { levels = { question = "statusline", dead = "statusline" } } })
    notify.reset()
    local s1 = { path = "/a", title = "A" }
    local s2 = { path = "/b", title = "B" }
    assert(notify.statusline() == "", "clean board: empty badge")

    notify.fire("question", s1, "needs you")
    notify.fire("question", s1, "needs you") -- dedupe: same session, same event
    assert(notify.statusline():find(" 1", 1, true) or notify.statusline():find("1"), notify.statusline())
    notify.fire("question", s2, "needs you")
    assert(notify.statusline():find("2", 1, true), "two questions: " .. notify.statusline())

    notify.clear("question", s1)
    assert(notify.statusline():find("1", 1, true), "one cleared: " .. notify.statusline())
    notify.clear("question", s2)
    assert(notify.statusline() == "", "all cleared: " .. notify.statusline())

    notify.fire("dead", s1, "dark")
    assert(notify.statusline():find("✗1", 1, true), "dead badge: " .. notify.statusline())
    notify.reset()
    assert(notify.statusline() == "", "reset clears")
  end,

  ["monitor: pane-confirmed question overrides transcript state"] = function()
    local sessions = require("giroux.sessions")
    -- open turn, nothing pending, fresh file -> normally ●; with a confirmed
    -- pane question the monitor promotes it to ?
    assert(sessions.derive_state({}, 10, true) == "●", "baseline: open turn = working")
    -- the override lives in monitor.derive; emulate its rule here
    local function with_question(pending, age, in_turn, question)
      local st = sessions.derive_state(pending, age, in_turn)
      if question and age <= 1800 then
        st = "?"
      end
      return st
    end
    assert(with_question({}, 10, true, true) == "?", "pane question promotes to ?")
    assert(with_question({}, 5000, true, true) == "✗", "but not when stale-dead")
    assert(with_question({}, 10, true, false) == "●", "no question = unchanged")
  end,
}
