local monitor = require("giroux.monitor")
local sessions = require("giroux.sessions")
require("giroux").setup({})

-- monitor's live path is integration-tested headlessly (live_roster_test.lua);
-- here we lock the pure pieces it depends on so refactors can't silently break
-- the realtime contract.
return {
  ["monitor: title_lift lifts only quiet states, only on a fresh spinner"] = function()
    local L = monitor.title_lift
    -- a fresh braille spinner lifts a quiet session to working
    assert(L("○", "⠂ Building", 2) == "●", "idle + fresh spinner -> working")
    assert(L("~", "⠐ Building", 2) == "●", "stale-idle + fresh spinner -> working")
    -- the staleness gate: an OLD spinner proves nothing about now (the BUG fix)
    assert(L("○", "⠂ Building", 9999) == "○", "idle + stale spinner stays idle")
    -- positive-only: a working title never overrides a finish, question, or death
    assert(L("✓", "⠂ Building", 2) == "✓", "done is never masked")
    assert(L("?", "⠂ Building", 2) == "?", "needs-you is never invented over")
    assert(L("✗", "⠂ Building", 2) == "✗", "dead is never masked")
    -- a non-working title (idle ✳, none, unknown) leaves a quiet state alone
    assert(L("○", "✳ Building", 2) == "○", "idle glyph does not lift")
    assert(L("○", nil, 2) == "○", "no title -> no lift")
  end,

  ["monitor: sessions() sorts attention-first"] = function()
    -- inject trackers directly into the module state
    local st = monitor._state
    st.trackers = {
      a = { session = { node = "x", path = "/a", state = "~", mtime = 100 } },
      b = { session = { node = "x", path = "/b", state = "?", mtime = 50 } },
      c = { session = { node = "x", path = "/c", state = "●", mtime = 200 } },
      d = { session = { node = "x", path = "/d", state = "○", mtime = 300 } },
    }
    local list = monitor.sessions()
    local order = vim.tbl_map(function(s)
      return s.state
    end, list)
    assert(vim.deep_equal(order, { "?", "●", "○", "~" }), vim.inspect(order))
    st.trackers = {}
  end,

  ["monitor: derive_state staleness uses file mtime (no read-time bump)"] = function()
    -- a session idle 2h ago must read as stale regardless of when parsed
    assert(sessions.derive_state({}, 7200) == "~")
    -- working but file silent 40min => dead inferred
    assert(sessions.derive_state({ t = { name = "Bash" } }, 2400) == "✗")
  end,
}
