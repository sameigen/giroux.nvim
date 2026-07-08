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

  ["monitor: a pane-confirmed question promotes to ? only within the freshness window"] = function()
    -- the override lives in monitor.derive: a live pane question (AskUserQuestion
    -- never hits the transcript while pending) promotes an otherwise-idle
    -- session to "?" — but only while the file is recent enough that the
    -- question can't be stale-answered. Drive the real derive, not a copy of
    -- its rule (that's what broke: the old test re-coded `age <= 1800` locally).
    require("giroux.notify").reset()
    local function tr_with(path, age, question)
      return {
        session = { node = "x", path = path, state = "·", mtime = os.time() - age },
        acc = stats.new(),
        parser = transcript.parser(),
        question = question,
      }
    end

    -- fresh (age well within 1800s): pane question promotes to "?"
    local fresh = tr_with("/a/fresh.jsonl", 10, true)
    monitor._derive(fresh, false)
    assert(fresh.session.state == "?", "fresh pane question must promote to ?: " .. fresh.session.state)

    -- stale (age well past 1800s): question no longer trusted; derive falls
    -- through to the age-based heuristic instead of "?"
    local stale = tr_with("/a/stale.jsonl", 5000, true)
    monitor._derive(stale, false)
    assert(stale.session.state ~= "?", "stale pane question must not promote to ?: " .. stale.session.state)

    -- no pane question: state is whatever derive would give anyway
    local none = tr_with("/a/none.jsonl", 10, false)
    monitor._derive(none, false)
    assert(none.session.state ~= "?", "no pane question: no promotion: " .. none.session.state)

    require("giroux.notify").reset()
  end,

  ["monitor: a subagent is never shown dead — a silent one returned, not hung"] = function()
    -- an open turn gone silent past the dead threshold derives ✗ for a normal
    -- session; a subagent has no interactive process to hang, so it settles to
    -- idle instead (a finished subagent whose transcript didn't close its turn
    -- cleanly must not read as "went dark with work pending").
    require("giroux.notify").reset()
    local function tr_open_turn(is_sub)
      local tr = {
        session = {
          node = "x",
          path = "/a/-p/P/subagents/agent-z.jsonl",
          state = "·",
          mtime = os.time() - 4000, -- well past the 1800s dead threshold
          is_subagent = is_sub or nil,
        },
        acc = stats.new(),
        parser = transcript.parser(),
      }
      -- a user message opens a turn that never closes → in_turn = true
      tr.parser:feed(
        vim.json.encode({ type = "user", uuid = "u", message = { role = "user", content = "go" } }) .. "\n"
      )
      return tr
    end
    local normal = tr_open_turn(false)
    monitor._derive(normal, false)
    assert(normal.session.state == "✗", "a normal session silent with an open turn is dead: " .. normal.session.state)

    local sub = tr_open_turn(true)
    monitor._derive(sub, false)
    assert(sub.session.state ~= "✗", "a subagent is never dead: " .. sub.session.state)
    assert(sub.session.state == "○", "a silent subagent settles to idle: " .. sub.session.state)

    require("giroux.notify").reset()
  end,
}
