local monitor = require("giroux.monitor")
local sessions = require("giroux.sessions")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")
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

  ["monitor: should_discover gates the heavy file listing to discover_interval"] = function()
    -- fast liveness ticks (every few s) must NOT re-list files every time; the
    -- expensive discovery only fires once discover_interval has elapsed.
    assert(monitor.should_discover(0, 0, 10) == true, "never-discovered (last=0) must discover first")
    assert(monitor.should_discover(1000, 997, 10) == false, "3s after a discovery: liveness only, no re-list")
    assert(monitor.should_discover(1000, 990, 10) == true, "10s elapsed: time to re-list")
    assert(monitor.should_discover(1000, 985, 10) == true, "past the interval: discover")
  end,

  ["monitor: replayed (non-live) question seeds silently, live one pages"] = function()
    -- regression: an answered AskUserQuestion transiently re-enters ? during
    -- seed-window replay (tool_use sets pending, a later tool_result clears
    -- it). Only the FIRST replayed line was ever seeded silently under the
    -- old guard, so a later non-live re-entry into ? must not be mistaken
    -- for the first line to prove this is really fixed.
    require("giroux").setup({ notify = { levels = { question = "notify" } } })
    require("giroux.notify").reset()
    local captured = {}
    local orig = vim.notify
    vim.notify = function(msg)
      captured[#captured + 1] = msg
    end

    local tr = {
      session = { node = "x", path = "/a/sess.jsonl", state = "·", mtime = os.time() },
      acc = stats.new(),
      parser = transcript.parser(),
      question = false,
    }

    -- line 1 (replay, not a question): primes the tracker without seeding "?"
    monitor._derive(tr, false)
    assert(tr.session.state ~= "?", "sanity: first replayed line is not a question")

    -- line N (replay, NOT the first line): pending-set gets an AskUserQuestion
    -- that was already answered later in history. Must stay silent.
    tr.question = true
    monitor._derive(tr, false)
    assert(tr.session.state == "?", "tracker should have entered ? state")
    assert(#captured == 0, "non-first replayed line must not page: " .. vim.inspect(captured))

    -- line N+1 (replay): the tool_result answers it, clearing the latch.
    tr.question = false
    monitor._derive(tr, false)
    assert(#captured == 0, "clearing during replay must not page")

    -- now watching live: a fresh question genuinely pages.
    tr.question = true
    monitor._derive(tr, true)
    assert(#captured >= 1, "live transition must page")

    vim.notify = orig
    require("giroux.notify").reset()
  end,
}
