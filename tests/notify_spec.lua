local notify = require("giroux.notify")

return {
  ["notify: macos channel routes through the sink on every platform"] = function()
    -- regression: default channel for question/dead is "macos"; on a Linux node
    -- vim.system{"osascript"} raises ENOENT and used to crash monitor.derive().
    -- Both branches must land in the sink — banner argv where osascript exists,
    -- vim.notify degradation where it doesn't — and neither may raise.
    require("giroux").setup({ notify = { levels = { dead = "macos" } } })
    notify.reset()
    local seen, osa = {}, {}
    local orig = notify._sink
    notify._sink = {
      notify = function(msg)
        seen[#seen + 1] = msg
      end,
      osascript = function(argv)
        osa[#osa + 1] = argv
      end,
    }
    local ok = pcall(notify.fire, "dead", { path = "/x", title = "X" }, "went dark")
    notify._sink = orig
    notify.reset()
    assert(ok, "fire must not raise")
    if vim.fn.executable("osascript") == 1 then
      assert(#osa == 1 and #seen == 0, "banner argv routed to the osascript sink only")
      assert(osa[1][1] == "osascript", "argv is an osascript invocation")
    else
      assert(vim.tbl_contains(seen, "giroux: went dark"), "message degraded to the notify sink")
      assert(#osa == 0, "no osascript spawn attempted")
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
