local agents = require("giroux.agents")

return {
  ["agents: parse maps sessionId -> status / waitingFor"] = function()
    local json = vim.json.encode({
      { pid = 1, cwd = "/a", kind = "interactive", sessionId = "aaa", status = "idle" },
      {
        pid = 2,
        cwd = "/b",
        kind = "interactive",
        sessionId = "bbb",
        status = "waiting",
        waitingFor = "permission prompt",
      },
    })
    local m = agents.parse(json)
    assert(m.aaa and m.aaa.status == "idle", "idle session mapped")
    assert(m.bbb and m.bbb.waiting_for == "permission prompt", "waitingFor mapped")
    assert(agents.needs_input(m.bbb), "waiting => needs input")
    assert(not agents.needs_input(m.aaa), "idle => not needs input")
  end,

  ["agents: duplicate sessionId keeps the most actionable entry"] = function()
    local json = vim.json.encode({
      { sessionId = "x", status = "idle", pid = 1 },
      { sessionId = "x", status = "waiting", waitingFor = "input needed", pid = 2 },
    })
    local m = agents.parse(json)
    assert(agents.needs_input(m.x), "the waiting entry must win over the idle one")
  end,

  ["agents: bad / empty json is an empty map, never a crash"] = function()
    assert(vim.tbl_isempty(agents.parse("not json")))
    assert(vim.tbl_isempty(agents.parse("")))
    assert(vim.tbl_isempty(agents.parse(nil)))
    assert(not agents.needs_input(nil))
  end,

  ["agents: needs_input matches input / permission variants"] = function()
    assert(agents.needs_input({ waiting_for = "input needed" }))
    assert(agents.needs_input({ waiting_for = "Permission prompt" }))
    assert(agents.needs_input({ status = "waiting" }))
    assert(not agents.needs_input({ status = "idle" }))
    assert(not agents.needs_input({ status = "working" }))
  end,

  ["agents: classify trusts only needs-you and working; defers otherwise"] = function()
    assert(agents.classify({ status = "waiting", waiting_for = "input needed" }) == "?")
    assert(agents.classify({ status = "working" }) == "●")
    assert(agents.classify({ status = "running" }) == "●")
    -- idle / unknown / nil must DEFER (nil) so the transcript heuristic can still
    -- decide dead/stale — a listed pid can be hung, "listed" != "healthy".
    assert(agents.classify({ status = "idle" }) == nil)
    assert(agents.classify({ status = "weird" }) == nil)
    assert(agents.classify(nil) == nil)
  end,
}
