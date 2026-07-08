local notify = require("giroux.notify")

return {
  ["notify: macos channel with no osascript routes the message to vim.notify"] = function()
    -- regression: default channel for question/dead is "macos"; on a Linux node
    -- vim.system{"osascript"} raises ENOENT and used to crash monitor.derive().
    require("giroux").setup({ notify = { levels = { dead = "macos" } } })
    notify.reset()
    local seen = {}
    local orig = notify._sink
    notify._sink = {
      notify = function(msg)
        seen[#seen + 1] = msg
      end,
      osascript = function()
        error("osascript must not fire when absent")
      end,
    }
    -- if the host HAS osascript, this test still proves fire() doesn't raise and
    -- routes *somewhere* via the sink; the capture makes the assertion real.
    local ok = pcall(notify.fire, "dead", { path = "/x", title = "X" }, "went dark")
    notify._sink = orig
    notify.reset()
    assert(ok, "fire must not raise")
    -- on a host without osascript, the degraded path captured the message:
    if vim.fn.executable("osascript") ~= 1 then
      assert(vim.tbl_contains(seen, "giroux: went dark"), "message routed to the sink, no real banner")
    end
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
}
