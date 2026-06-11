local transcript = require("giroux.transcript")

local function J(t)
  return vim.json.encode(t) .. "\n"
end

local function kinds(events)
  return vim.tbl_map(function(e)
    return e.kind
  end, events)
end

-- Shapes below mirror the 2026-06-11 census of real transcripts (CC 2.1.85-2.1.172).

local function assistant_rec(blocks, extra)
  local rec = {
    type = "assistant",
    uuid = "u-" .. math.abs(#vim.json.encode(blocks)),
    parentUuid = vim.NIL,
    timestamp = "2026-06-11T05:00:00.000Z",
    sessionId = "s1",
    isSidechain = false,
    requestId = "req_1",
    message = {
      id = (extra and extra.message_id) or "msg_1",
      model = "claude-fable-5",
      role = "assistant",
      type = "message",
      content = blocks,
      stop_reason = (extra and extra.stop_reason) or vim.NIL,
      stop_sequence = vim.NIL,
      usage = {
        input_tokens = 100,
        output_tokens = 50,
        cache_read_input_tokens = 1000,
        cache_creation_input_tokens = 200,
        service_tier = "standard",
      },
    },
  }
  for k, v in pairs(extra or {}) do
    if k ~= "message_id" and k ~= "stop_reason" then
      rec[k] = v
    end
  end
  return rec
end

local function result_rec(id, content, detail)
  return {
    type = "user",
    uuid = "u-res-" .. id,
    timestamp = "2026-06-11T05:00:01.000Z",
    sessionId = "s1",
    message = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = id, content = content, is_error = false } },
    },
    toolUseResult = detail,
    sourceToolAssistantUUID = "u-src",
  }
end

return {
  ["events: split message dedupes usage by message.id"] = function()
    local p = transcript.parser()
    -- one API message streamed as 3 records (thinking, text, tool_use), shared message.id
    local evs = {}
    vim.list_extend(evs, p:feed(J(assistant_rec({ { type = "thinking", thinking = "hmm", signature = "sig" } }))))
    vim.list_extend(evs, p:feed(J(assistant_rec({ { type = "text", text = "on it" } }))))
    vim.list_extend(
      evs,
      p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_1", name = "Bash", input = { command = "ls" } } })))
    )
    local usage = vim.tbl_filter(function(e)
      return e.kind == "usage"
    end, evs)
    assert(#usage == 1, "usage must dedupe by message.id, got " .. #usage)
    assert(usage[1].input == 100 and usage[1].cache_read == 1000)
  end,

  ["events: pending tool_use is the WORKING proof, cleared by result"] = function()
    local p = transcript.parser()
    p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_9", name = "Bash", input = { command = "sleep 6" } } })))
    assert(p:pending()["toolu_9"], "tool_use at EOF must be pending")
    assert(p:pending()["toolu_9"].name == "Bash")
    local evs = p:feed(J(result_rec("toolu_9", "done", { stdout = "done", stderr = "", interrupted = false })))
    assert(next(p:pending()) == nil, "result must clear pending")
    assert(evs[1].kind == "tool_result" and evs[1].text == "done")
    assert(type(evs[1].detail) == "table" and evs[1].detail.stdout == "done")
  end,

  ["events: AskUserQuestion becomes question + pending_question"] = function()
    local p = transcript.parser()
    local q = {
      questions = {
        {
          question = "Which approach?",
          header = "Approach",
          multiSelect = false,
          options = { { label = "tmux", description = "..." }, { label = "daemon", description = "..." } },
        },
      },
    }
    local evs = p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_q", name = "AskUserQuestion", input = q } })))
    assert(evs[1].kind == "question", "got " .. evs[1].kind)
    assert(evs[1].questions[1].options[2].label == "daemon")
    local id = p:pending_question()
    assert(id == "toolu_q", "question must be provable from pending set")
    -- census: answer's tool_result content is a plain string; envelope has answers map
    p:feed(J(result_rec("toolu_q", 'Your questions have been answered: "Which approach?"="tmux"', {
      questions = q.questions,
      answers = { ["Which approach?"] = "tmux" },
    })))
    assert(p:pending_question() == nil)
  end,

  ["events: interrupt clears pending and emits marker"] = function()
    local p = transcript.parser()
    p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_x", name = "Bash", input = { command = "x" } } })))
    local evs = p:feed(J({
      type = "user",
      uuid = "u-int",
      sessionId = "s1",
      interruptedMessageId = "msg_55",
      message = { role = "user", content = { { type = "text", text = "[Request interrupted by user]" } } },
    }))
    assert(evs[1].kind == "interrupt" and evs[1].interrupted_message_id == "msg_55")
    assert(next(p:pending()) == nil, "interrupt aborts in-flight tools")
  end,

  ["events: turn_end from turn_duration, stop from end_turn"] = function()
    local p = transcript.parser()
    local evs = p:feed(J(assistant_rec({ { type = "text", text = "done." } }, { stop_reason = "end_turn" })))
    assert(vim.tbl_contains(kinds(evs), "stop"))
    evs = p:feed(J({
      type = "system",
      subtype = "turn_duration",
      uuid = "u-td",
      sessionId = "s1",
      durationMs = 79131,
      messageCount = 40,
    }))
    assert(evs[1].kind == "turn_end" and evs[1].duration_ms == 79131)
  end,

  ["events: metadata family has no envelope and still parses"] = function()
    local p = transcript.parser()
    local evs = {}
    vim.list_extend(evs, p:feed(J({ type = "mode", mode = "normal", sessionId = "s1" })))
    vim.list_extend(
      evs,
      p:feed(J({ type = "permission-mode", permissionMode = "bypassPermissions", sessionId = "s1" }))
    )
    vim.list_extend(evs, p:feed(J({ type = "ai-title", aiTitle = "Building giroux", sessionId = "s1" })))
    vim.list_extend(evs, p:feed(J({ type = "last-prompt", sessionId = "s1" }))) -- census: lastPrompt/leafUuid both optional
    vim.list_extend(
      evs,
      p:feed(J({ type = "pr-link", prNumber = 7, prUrl = "https://github.com/x/y/pull/7", sessionId = "s1" }))
    )
    for _, e in ipairs(evs) do
      assert(e.kind == "session_meta", e.kind)
    end
    assert(evs[2].value == "bypassPermissions")
    assert(evs[4].value == nil, "missing lastPrompt tolerated")
  end,

  ["events: compact boundary and summary"] = function()
    local p = transcript.parser()
    local evs = p:feed(J({
      type = "system",
      subtype = "compact_boundary",
      uuid = "u-cb",
      parentUuid = vim.NIL,
      sessionId = "s1",
      logicalParentUuid = "u-prev",
      compactMetadata = { trigger = "manual", preTokens = 150000, postTokens = 20000 },
    }))
    assert(evs[1].kind == "compact" and evs[1].pre_tokens == 150000)
    evs = p:feed(J({
      type = "user",
      uuid = "u-cs",
      sessionId = "s1",
      isCompactSummary = true,
      isVisibleInTranscriptOnly = true,
      message = { role = "user", content = "This session is being continued from a previous conversation..." },
    }))
    assert(evs[1].kind == "summary", "compact summary must not surface as user_text")
  end,

  ["events: synthetic api-error assistant record"] = function()
    local p = transcript.parser()
    local rec = assistant_rec({ { type = "text", text = "API Error: ECONNRESET" } }, { isApiErrorMessage = true })
    rec.requestId = nil -- census: error records lack requestId
    rec.message.model = "<synthetic>"
    local evs = p:feed(J(rec))
    assert(evs[1].kind == "api_error" and evs[1].text:find("ECONNRESET"))
  end,

  ["events: meta/markup user content classified local_command"] = function()
    local p = transcript.parser()
    local evs = p:feed(J({
      type = "user",
      uuid = "u-m",
      sessionId = "s1",
      isMeta = true,
      message = {
        role = "user",
        content = "<local-command-stdout>Set model to \27[1mFable\27[22m</local-command-stdout>",
      },
    }))
    assert(evs[1].kind == "local_command", evs[1].kind)
    evs = p:feed(J({
      type = "user",
      uuid = "u-h",
      sessionId = "s1",
      message = { role = "user", content = "hello there" },
    }))
    assert(evs[1].kind == "user_text" and evs[1].source == "typed")
  end,

  ["events: background subagent announcement"] = function()
    local p = transcript.parser()
    p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_a", name = "Agent", input = { prompt = "go" } } })))
    local evs = p:feed(J(result_rec("toolu_a", "Async agent launched", {
      isAsync = true,
      status = "async_launched",
      agentId = "a9b5632983faa3a63",
      description = "Observe",
      outputFile = "/tmp/tasks/a9b5632983faa3a63.output",
      canReadOutputFile = false,
    })))
    local sub
    for _, e in ipairs(evs) do
      if e.kind == "subagent" then
        sub = e
      end
    end
    assert(sub and sub.agent_id == "a9b5632983faa3a63" and sub.status == "async_launched")
    assert(
      transcript.subagent_path("/x/projects/-p/s1.jsonl", sub.agent_id)
        == "/x/projects/-p/s1/subagents/agent-a9b5632983faa3a63.jsonl"
    )
  end,

  ["events: unknown types and garbage never crash, never drop"] = function()
    local p = transcript.parser()
    local evs = {}
    vim.list_extend(evs, p:feed("not json at all\n"))
    vim.list_extend(evs, p:feed(J({ type = "hologram-sync", payload = { x = 1 } })))
    vim.list_extend(evs, p:feed(J({ type = "assistant", message = { content = { { type = "warp-block", q = 1 } } } })))
    assert(evs[1].kind == "unknown" and evs[1].rtype == "undecodable")
    assert(evs[2].kind == "unknown" and evs[2].rtype == "hologram-sync")
    assert(evs[3].kind == "other", "unknown block types degrade to other, got " .. evs[3].kind)
  end,

  ["events: tool_result content as block list, detail as string"] = function()
    local p = transcript.parser()
    p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_b", name = "Read", input = { file_path = "/x" } } })))
    local evs = p:feed(J({
      type = "user",
      uuid = "u-r",
      sessionId = "s1",
      message = {
        role = "user",
        content = {
          {
            type = "tool_result",
            tool_use_id = "toolu_b",
            content = { { type = "text", text = "line1" }, { type = "text", text = "line2" } },
          },
        },
      },
      toolUseResult = "InputValidationError: nope", -- census: string envelope on errors
    }))
    assert(evs[1].kind == "tool_result")
    assert(evs[1].text == "line1\nline2")
    assert(evs[1].detail == "InputValidationError: nope")
  end,

  ["events: queue operations and queued_command attachments"] = function()
    local p = transcript.parser()
    local evs = {}
    vim.list_extend(
      evs,
      p:feed(J({
        type = "queue-operation",
        operation = "enqueue",
        sessionId = "s1",
        timestamp = "t",
        content = "do this next",
      }))
    )
    vim.list_extend(
      evs,
      p:feed(J({
        type = "attachment",
        uuid = "u-at",
        sessionId = "s1",
        attachment = { type = "queued_command", prompt = "and this" },
      }))
    )
    vim.list_extend(
      evs,
      p:feed(J({ type = "attachment", uuid = "u-at2", sessionId = "s1", attachment = { type = "task_reminder" } }))
    )
    assert(evs[1].kind == "queue" and evs[1].text == "do this next")
    assert(evs[2].kind == "queue" and evs[2].text == "and this")
    assert(evs[3].kind == "other" and evs[3].subtype == "task_reminder")
  end,

  ["events: streaming chunk boundaries produce identical events"] = function()
    local doc = J(assistant_rec({ { type = "tool_use", id = "toolu_s", name = "Bash", input = { command = "x" } } }))
      .. J(result_rec("toolu_s", "ok", { stdout = "ok" }))
      .. J({
        type = "system",
        subtype = "turn_duration",
        uuid = "u",
        sessionId = "s1",
        durationMs = 5,
        messageCount = 2,
      })
    local whole = transcript.parser():feed(doc)
    local p = transcript.parser()
    local chunked = {}
    for i = 1, #doc, 7 do
      vim.list_extend(chunked, p:feed(doc:sub(i, i + 6)))
    end
    assert(vim.deep_equal(kinds(whole), kinds(chunked)), "chunking must not change events")
    assert(vim.deep_equal(whole, chunked))
  end,
}
