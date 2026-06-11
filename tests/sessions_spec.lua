local sessions = require("giroux.sessions")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end

return {
  ["sessions: state proofs"] = function()
    assert(sessions.derive_state({}, 10) == "○")
    assert(sessions.derive_state({}, 7200) == "~")
    assert(sessions.derive_state({ x = { name = "Bash" } }, 10) == "●")
    assert(sessions.derive_state({ x = { name = "Bash" } }, 3000) == "✗", "silent pending work is dead")
    assert(sessions.derive_state({ x = { name = "Bash" }, y = { name = "AskUserQuestion" } }, 10) == "?")
  end,

  ["sessions: an open turn proves working even with no pending tools"] = function()
    assert(sessions.derive_state({}, 10, true) == "●", "text/thinking generation is not idleness")
    assert(sessions.derive_state({}, 3000, true) == "✗", "turn open but silent = dead")
    assert(sessions.derive_state({}, 10, false) == "○")
    assert(sessions.derive_state({ y = { name = "AskUserQuestion" } }, 10, true) == "?", "question outranks turn")
  end,

  ["sessions: turn lifecycle drives in_turn through the parser"] = function()
    local transcript = require("giroux.transcript")
    local p = transcript.parser()
    local function feed(rec)
      p:feed(J(rec) .. "\n")
    end
    assert(not p:in_turn(), "fresh parser: no turn")
    feed({ type = "user", uuid = "u1", message = { role = "user", content = "do the thing" } })
    assert(p:in_turn(), "user prompt opens the turn")
    feed({
      type = "assistant",
      uuid = "a1",
      message = {
        id = "m1",
        role = "assistant",
        content = { { type = "tool_use", id = "t1", name = "Bash", input = {} } },
      },
    })
    feed({
      type = "user",
      uuid = "u2",
      message = { role = "user", content = { { type = "tool_result", tool_use_id = "t1", content = "ok" } } },
    })
    assert(p:in_turn(), "tool resolved but turn still open — the roster-idle bug")
    assert(next(p:pending()) == nil, "no pending tools")
    feed({ type = "system", subtype = "turn_duration", uuid = "td", durationMs = 1, messageCount = 1 })
    assert(not p:in_turn(), "turn_duration closes the turn")

    feed({ type = "user", uuid = "u3", message = { role = "user", content = "again" } })
    feed({
      type = "assistant",
      uuid = "a2",
      message = {
        id = "m2",
        role = "assistant",
        content = { { type = "text", text = "done" } },
        stop_reason = "end_turn",
      },
    })
    assert(not p:in_turn(), "end_turn closes the turn")

    feed({ type = "user", uuid = "u4", message = { role = "user", content = "once more" } })
    feed({
      type = "user",
      uuid = "u5",
      message = { role = "user", content = { { type = "text", text = "[Request interrupted by user]" } } },
    })
    assert(not p:in_turn(), "interrupt closes the turn")

    -- mid-turn seed join: only assistant activity visible
    local p2 = transcript.parser()
    p2:feed(J({
      type = "assistant",
      uuid = "a3",
      message = { id = "m3", role = "assistant", content = { { type = "thinking", thinking = "hmm" } } },
    }) .. "\n")
    assert(p2:in_turn(), "assistant activity alone proves an open turn (seed-window join)")
  end,

  ["sessions: project display from slug"] = function()
    assert(sessions.project_display("/Users/dev/.claude/projects/-Users-dev-Code-app/x.jsonl") == "~/Code/app")
    assert(sessions.project_display("/Users/dev/.claude/projects/-Users-dev/x.jsonl") == "~")
    assert(sessions.project_display("/p/-Users-dev--cache-nvim-parole/x.jsonl") == "~/.cache/nvim/parole")
  end,

  ["sessions: parse_scan derives state from tails"] = function()
    local now = os.time()
    local working = {
      J({ type = "ai-title", aiTitle = "Busy one", sessionId = "s1" }),
      J({
        type = "assistant",
        uuid = "a1",
        sessionId = "s1",
        timestamp = "2026-06-11T05:00:00.000Z",
        message = {
          id = "m1",
          model = "x",
          role = "assistant",
          content = { { type = "tool_use", id = "t1", name = "Bash", input = { command = "make" } } },
          stop_reason = vim.NIL,
          usage = { input_tokens = 1, output_tokens = 1 },
        },
      }),
    }
    local idle = {
      J({ type = "ai-title", aiTitle = "Done one", sessionId = "s2" }),
      J({ type = "last-prompt", lastPrompt = "ship it", sessionId = "s2" }),
      J({ type = "system", subtype = "turn_duration", uuid = "td", sessionId = "s2", durationMs = 5, messageCount = 1 }),
    }
    local stdout = table.concat({
      ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s1.jsonl"):format(now - 5, now - 60),
      table.concat(working, "\n"),
      "",
      ("===GIROUX=== %d 400 %d /p/-Users-dev-Code-app/s2.jsonl"):format(now - 120, now - 600),
      table.concat(idle, "\n"),
      "",
    }, "\n")
    local items = sessions.parse_scan("workhorse", stdout, now)
    assert(#items == 2, "expected 2 sessions, got " .. #items)
    assert(items[1].state == "●" and items[1].title == "Busy one", vim.inspect(items[1]))
    assert(items[1].pending[1] == "Bash")
    assert(items[2].state == "○" and items[2].last_prompt == "ship it", vim.inspect(items[2]))
    assert(items[1].project == "~/Code/app")
  end,

  ["sessions: big-file tail drops the partial first line"] = function()
    local now = os.time()
    local stdout = table.concat({
      ("===GIROUX=== %d %d %d /p/-Users-dev/big.jsonl"):format(now - 5, sessions.TAIL_BYTES + 999, now - 60),
      '..."truncated-mid-record":true}', -- garbage fragment from tail -c
      J({ type = "system", subtype = "turn_duration", uuid = "td", sessionId = "s", durationMs = 1, messageCount = 1 }),
      "",
    }, "\n")
    local items = sessions.parse_scan("local", stdout, now)
    assert(#items == 1)
    assert(items[1].state == "○", "fragment must be dropped, not poison the parse: " .. items[1].state)
  end,
}
