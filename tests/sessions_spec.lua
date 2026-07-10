local sessions = require("giroux.sessions")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end

return {
  ["sessions: subagent_of splits a subagent path into parent + agent id"] = function()
    local p = "/r/-home-ko-Code-app/PARENTSID/subagents/agent-a7a728f1.jsonl"
    local s = sessions.subagent_of(p)
    assert(s and s.parent_id == "PARENTSID", "parent id: " .. vim.inspect(s))
    assert(s.agent_id == "a7a728f1", "agent id: " .. vim.inspect(s))
    assert(sessions.subagent_of("/r/-home-ko-Code-app/PARENTSID.jsonl") == nil, "top-level is not a subagent")
    assert(
      sessions.subagent_of("/r/-home-ko-Code-app/S/workflows/wf_x/agent-1.jsonl") == nil,
      "a workflow file is not a subagents/ file"
    )
  end,

  ["sessions: project_display resolves a subagent to its parent's repo"] = function()
    local parent = "/r/-home-ko-Code-personal-fortunemill/SID.jsonl"
    local sub = "/r/-home-ko-Code-personal-fortunemill/SID/subagents/agent-x.jsonl"
    assert(sessions.project_display(sub) == sessions.project_display(parent), "subagent shares the parent's project")
    assert(sessions.project_display(sub) == "~/Code/personal/fortunemill", sessions.project_display(sub))
  end,

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
    -- Linux home prefix (-home-<user>-) strips just like macOS
    assert(sessions.project_display("/home/ko/.claude/projects/-home-ko-Code-personal/x.jsonl") == "~/Code/personal")
    assert(sessions.project_display("/p/-home-ko/x.jsonl") == "~")
  end,

  ["sessions: parse_scan derives state from tails"] = function()
    local now = os.time()
    local working = {
      J({ type = "ai-title", aiTitle = "Busy one", sessionId = "s1" }),
      J({
        type = "assistant",
        uuid = "a1",
        sessionId = "s1",
        -- a LIVE timestamp: state age runs off record timestamps now, so a
        -- working fixture must look recently-written in record terms too
        timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z", now - 5),
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

  ["sessions: a touched file with old records is stale, not fresh"] = function()
    -- the real-world lie this guards: an idle claude process touches its
    -- transcript (mtime = minutes ago) without appending records (last record
    -- = days ago). The activity clock must follow the RECORDS.
    local now = os.time()
    local old_ts = os.date("!%Y-%m-%dT%H:%M:%S.000Z", now - 9 * 86400)
    local stdout = table.concat({
      ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s9.jsonl"):format(now - 120, now - 10 * 86400),
      J({
        type = "system",
        subtype = "turn_duration",
        uuid = "td9",
        sessionId = "s9",
        timestamp = old_ts,
        durationMs = 5,
        messageCount = 1,
      }),
      "",
    }, "\n")
    local items = sessions.parse_scan("workhorse", stdout, now)
    assert(#items == 1)
    assert(math.abs(sessions.age_of(items[1], now) - 9 * 86400) < 2, "age follows records, not the touched mtime")
    assert(items[1].state == "~", "nine-day-old records = stale, whatever mtime claims: " .. items[1].state)
    -- and without any timestamped record, mtime remains the honest fallback
    assert(sessions.age_of({ mtime = now - 42 }, now) == 42)
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

  ["sessions: fold_queue tallies enqueue/remove/dequeue/popAll, ignores unknown ops"] = function()
    local n = 0
    n = sessions.fold_queue(n, "enqueue") -- 1
    n = sessions.fold_queue(n, "enqueue") -- 2
    n = sessions.fold_queue(n, "dequeue") -- 1
    assert(n == 1, "enqueue x2, dequeue x1: " .. n)
    n = sessions.fold_queue(n, "remove") -- 0
    assert(n == 0, "remove floors correctly: " .. n)
    n = sessions.fold_queue(n, "remove") -- must not go negative
    assert(n == 0, "remove below 0 stays at 0: " .. n)
    n = sessions.fold_queue(3, "popAll")
    assert(n == 0, "popAll drains to 0: " .. n)
    assert(sessions.fold_queue(5, "reorder") == 5, "unknown op is a no-op, not a guess")
  end,

  ["sessions: parse_scan threads mode + queued from real event shapes"] = function()
    local now = os.time()
    local lines = {
      J({ type = "permission-mode", permissionMode = "plan", sessionId = "s1" }),
      J({ type = "queue-operation", operation = "enqueue", timestamp = "2026-07-08T00:00:00.000Z", content = "next" }),
      J({ type = "queue-operation", operation = "enqueue", timestamp = "2026-07-08T00:00:01.000Z", content = "next2" }),
      J({ type = "queue-operation", operation = "dequeue", timestamp = "2026-07-08T00:00:02.000Z" }),
    }
    local stdout = table.concat({
      ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s1.jsonl"):format(now - 5, now - 60),
      table.concat(lines, "\n"),
      "",
    }, "\n")
    local items = sessions.parse_scan("workhorse", stdout, now)
    assert(#items == 1)
    assert(items[1].mode == "plan", "permission-mode threaded: " .. vim.inspect(items[1].mode))
    assert(items[1].queued == 1, "2 enqueue - 1 dequeue = 1: " .. tostring(items[1].queued))
  end,

  ["sessions: parse_scan threads todos/ctx_pct/model from the accumulator summaries"] = function()
    -- stub the accumulators so this proves parse_scan's WIRING, not 02/03's
    -- fold correctness (that's their own spec files' job).
    local todos_mod = require("giroux.todos")
    local orig_todos_new = todos_mod.new
    todos_mod.new = function()
      return {
        add = function() end,
        summary = function()
          return { total = 4, done = 1, in_progress = 1, current = "fix the thing" }
        end,
      }
    end
    local stats = require("giroux.stats")
    local orig_stats_new = stats.new
    stats.new = function()
      local acc = orig_stats_new()
      local orig_summary = acc.summary
      acc.summary = function(self)
        local s = orig_summary(self)
        s.ctx_pct = 62
        s.model = "claude-fake-model"
        return s
      end
      return acc
    end

    local now = os.time()
    local stdout = ("===GIROUX=== %d 500 %d /p/-Users-dev-Code-app/s1.jsonl"):format(now - 5, now - 60) .. "\n"
    local items = sessions.parse_scan("workhorse", stdout, now)

    todos_mod.new = orig_todos_new
    stats.new = orig_stats_new

    assert(#items == 1)
    assert(
      vim.deep_equal(items[1].todos, { total = 4, done = 1, in_progress = 1, current = "fix the thing" }),
      vim.inspect(items[1].todos)
    )
    assert(items[1].ctx_pct == 62, "ctx_pct threaded: " .. tostring(items[1].ctx_pct))
    assert(items[1].model == "claude-fake-model", "model threaded: " .. tostring(items[1].model))
  end,
}
