---@module 'giroux.transcript'
--- JSONL parsing for Claude Code session transcripts (DESIGN.md §1/§4/§14).
--- Layer 1 (lines): stateful assembler turning arbitrary byte chunks (tail -F
--- over SSH delivers no guaranteed boundaries) into complete lines with byte
--- offsets, so a dropped connection resumes exactly where it left off.
--- Layer 2 (parser): line -> normalized events. Schema knowledge is grounded
--- in a census of 154 real transcripts across CC 2.1.85-2.1.172 (2026-06-11):
---  - records are pure-append, one content block per line; blocks of one API
---    message share message.id (usage must dedupe on it or spend ~2-4x)
---  - tool_use lands when execution starts, tool_result on completion, so an
---    unresolved tool_use is a provable WORKING signal; pair strictly by
---    tool_use_id (parallel calls break parentUuid pairing)
---  - metadata records (mode/ai-title/last-prompt/...) have no uuid/envelope
---    and interleave anywhere, including line 1
---  - every top-level field is optional somewhere; unknown record/block types
---    appear between patch releases -> never crash, emit `unknown`

local M = {}

---@class giroux.transcript.Line
---@field text string complete line, newline stripped
---@field offset integer byte offset of the line start within the file
---@field bytes integer byte length including the trailing newline

---@class giroux.transcript.Lines
---@field private buf string unconsumed partial tail
---@field private offset integer file offset where `buf` begins
local Lines = {}
Lines.__index = Lines

---@param start_offset integer|nil byte offset the stream begins at (resume support)
---@return giroux.transcript.Lines
function M.lines(start_offset)
  return setmetatable({ buf = "", offset = start_offset or 0 }, Lines)
end

---Feed a chunk of bytes; returns every line completed by this chunk.
---A partial trailing line is buffered until its newline arrives.
---@param chunk string
---@return giroux.transcript.Line[]
function Lines:feed(chunk)
  if chunk == "" then
    return {}
  end
  self.buf = self.buf .. chunk
  local out = {}
  local from = 1
  while true do
    local nl = self.buf:find("\n", from, true)
    if not nl then
      break
    end
    local text = self.buf:sub(from, nl - 1)
    if text:sub(-1) == "\r" then -- tolerate CRLF, never expected but cheap
      text = text:sub(1, -2)
    end
    local bytes = nl - from + 1
    if text ~= "" then -- skip blank lines, keep offsets honest
      out[#out + 1] = { text = text, offset = self.offset, bytes = bytes }
    end
    self.offset = self.offset + bytes
    from = nl + 1
  end
  if from > 1 then
    self.buf = self.buf:sub(from)
  end
  return out
end

---Byte offset to resume from after a disconnect: everything before it has
---been emitted as complete lines; the partial tail (if any) re-reads.
---@return integer
function Lines:resume_offset()
  return self.offset
end

---True if bytes are buffered awaiting a newline (file ends mid-record).
---@return boolean
function Lines:partial()
  return self.buf ~= ""
end

-- ---------------------------------------------------------------------------
-- Layer 2: events

---De-NIL: vim.json.decode maps JSON null to vim.NIL, which is truthy in Lua.
local function nz(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@alias giroux.transcript.EventKind
---| "user_text"      # {text, source}             real user prompt (typed/queued/system)
---| "local_command"  # {text}                      /commands, ! shell, caveats, system-reminders
---| "assistant_text" # {text, model, message_id}
---| "thinking"       # {text, message_id}          skipped when empty
---| "tool_call"      # {id, name, input, message_id}
---| "question"       # {id, questions, message_id} AskUserQuestion tool_use (also enters pending)
---| "tool_result"    # {id, text, is_error, detail} detail = toolUseResult envelope (dict|string|list)
---| "subagent"       # {agent_id, agent_type, status, output_file, description, stats}
---| "interrupt"      # {interrupted_message_id}    clears pending
---| "stop"           # {stop_reason, message_id}   end_turn|stop_sequence on an assistant record
---| "turn_end"       # {duration_ms, message_count} system/turn_duration; clears pending
---| "usage"          # {message_id, model, input, output, cache_read, cache_creation} deduped by message_id
---| "api_error"      # {text, retry_in_ms, attempt}
---| "compact"        # {trigger, pre_tokens, post_tokens}
---| "summary"        # {text}                      away_summary / compact summary
---| "retract"        # {uuids}                     model-fallback retractions/supersedes
---| "session_meta"   # {key, value}                mode/permission-mode/ai-title/last-prompt/pr-link/agent-name
---| "queue"          # {op, text}
---| "other"          # {rtype, subtype}            recognized but uninteresting (snapshots, attachments...)
---| "unknown"        # {rtype, raw}                unrecognized or undecodable: never dropped, never fatal

---@class giroux.transcript.Event
---@field kind giroux.transcript.EventKind
---@field ts string|nil ISO timestamp when the record carries one
---@field offset integer byte offset of the source line
---@field uuid string|nil
---@field agent_id string|nil set in subagent transcripts
---@field sidechain boolean|nil

---@class giroux.transcript.Parser
---@field private lines giroux.transcript.Lines
---@field private seen_usage table<string, boolean> message.id dedupe for usage
---@field private pending_calls table<string, {name: string, ts: string|nil, input: any}>
---@field private turn_open boolean a user turn has started and not yet ended
local Parser = {}
Parser.__index = Parser

---@param opts {start_offset?: integer}|nil
---@return giroux.transcript.Parser
function M.parser(opts)
  opts = opts or {}
  return setmetatable({
    lines = M.lines(opts.start_offset),
    seen_usage = {},
    pending_calls = {},
    turn_open = false,
  }, Parser)
end

---Map of unresolved tool_use id -> {name, ts, input}. An entry here is the
---proof of WORKING (DESIGN.md §4); an AskUserQuestion entry proves QUESTION.
function Parser:pending()
  return self.pending_calls
end

---True while a user turn is in flight: a prompt (or assistant activity, for
---mid-turn seed joins) has been seen with no turn_end/end_turn/interrupt yet.
---Proves WORKING even when no tool call is pending — text and thinking
---generation appends with an empty pending-set, which is not idleness.
---@return boolean
function Parser:in_turn()
  return self.turn_open
end

---First unresolved AskUserQuestion call, or nil.
---@return string|nil id, table|nil call
function Parser:pending_question()
  for id, call in pairs(self.pending_calls) do
    if call.name == "AskUserQuestion" then
      return id, call
    end
  end
  return nil, nil
end

function Parser:resume_offset()
  return self.lines:resume_offset()
end

local INTERRUPT_TEXT = "[Request interrupted by user]"
-- Meta/markup user content: harness chrome, not a human prompt.
local META_PREFIXES = {
  "<local%-command%-caveat>",
  "<command%-name>",
  "<local%-command%-stdout>",
  "<bash%-input>",
  "<bash%-stdout>",
  "<bash%-stderr>",
  "<system%-reminder>",
  "<task%-notification>",
}

local function is_meta_text(text)
  for _, pat in ipairs(META_PREFIXES) do
    if text:find("^%s*" .. pat) then
      return true
    end
  end
  return false
end

-- Session-metadata family: {record key -> session_meta key}. No uuid/envelope.
local SESSION_META = {
  ["mode"] = "mode",
  ["permission-mode"] = "permissionMode",
  ["ai-title"] = "aiTitle",
  ["last-prompt"] = "lastPrompt",
  ["agent-name"] = "agentName",
  ["pr-link"] = "prUrl",
}

---@param ev table partially built event
---@param rec table decoded record
local function envelope(ev, rec)
  ev.ts = nz(rec.timestamp)
  ev.uuid = nz(rec.uuid)
  ev.agent_id = ev.agent_id or nz(rec.agentId) -- subagent events set their own
  if nz(rec.isSidechain) then
    ev.sidechain = true
  end
  return ev
end

---@param self giroux.transcript.Parser
---@param rec table assistant record
---@param out giroux.transcript.Event[]
local function on_assistant(self, rec, offset, out)
  local msg = nz(rec.message) or {}
  local mid = nz(msg.id)
  local model = nz(msg.model)

  if nz(rec.isApiErrorMessage) then
    local text
    local content = nz(msg.content)
    if type(content) == "table" then
      for _, b in ipairs(content) do
        if nz(b.type) == "text" then
          text = nz(b.text)
        end
      end
    end
    out[#out + 1] = envelope({ kind = "api_error", offset = offset, text = text }, rec)
    return
  end

  self.turn_open = true -- any assistant record proves a turn in flight
  local content = nz(msg.content)
  if type(content) == "string" then -- never observed; defend
    out[#out + 1] =
      envelope({ kind = "assistant_text", offset = offset, text = content, model = model, message_id = mid }, rec)
  elseif type(content) == "table" then
    for _, block in ipairs(content) do
      local btype = nz(block.type)
      if btype == "text" then
        out[#out + 1] = envelope(
          { kind = "assistant_text", offset = offset, text = nz(block.text) or "", model = model, message_id = mid },
          rec
        )
      elseif btype == "thinking" then
        local thought = nz(block.thinking)
        if thought and thought ~= "" then -- signature-only thinking blocks exist
          out[#out + 1] = envelope({ kind = "thinking", offset = offset, text = thought, message_id = mid }, rec)
        end
      elseif btype == "tool_use" then
        local id, name = nz(block.id), nz(block.name) or "?"
        if id then
          self.pending_calls[id] = { name = name, ts = nz(rec.timestamp), input = nz(block.input) }
        end
        if name == "AskUserQuestion" then
          local input = nz(block.input) or {}
          out[#out + 1] = envelope(
            { kind = "question", offset = offset, id = id, questions = nz(input.questions) or {}, message_id = mid },
            rec
          )
        else
          out[#out + 1] = envelope(
            { kind = "tool_call", offset = offset, id = id, name = name, input = nz(block.input), message_id = mid },
            rec
          )
        end
      else -- e.g. "fallback" blocks; future block types
        out[#out + 1] = envelope({ kind = "other", offset = offset, rtype = "assistant", subtype = btype }, rec)
      end
    end
  end

  if nz(rec.supersedesUuids) then
    out[#out + 1] = envelope({ kind = "retract", offset = offset, uuids = nz(rec.supersedesUuids) }, rec)
  end

  local stop = nz(msg.stop_reason)
  if stop == "end_turn" or stop == "stop_sequence" then
    self.turn_open = false
    out[#out + 1] = envelope({ kind = "stop", offset = offset, stop_reason = stop, message_id = mid }, rec)
  end

  local usage = nz(msg.usage)
  if usage and mid and not self.seen_usage[mid] then
    self.seen_usage[mid] = true
    out[#out + 1] = envelope({
      kind = "usage",
      offset = offset,
      message_id = mid,
      model = model,
      input = nz(usage.input_tokens) or 0,
      output = nz(usage.output_tokens) or 0,
      cache_read = nz(usage.cache_read_input_tokens) or 0,
      cache_creation = nz(usage.cache_creation_input_tokens) or 0,
    }, rec)
  end
end

---@param self giroux.transcript.Parser
---@param rec table user record
---@param out giroux.transcript.Event[]
local function on_user(self, rec, offset, out)
  local msg = nz(rec.message) or {}
  local content = nz(msg.content)

  if nz(rec.isCompactSummary) then
    local text = type(content) == "string" and content or ""
    out[#out + 1] = envelope({ kind = "summary", offset = offset, text = text }, rec)
    return
  end

  local source = nz(rec.promptSource) or "typed"
  local meta = nz(rec.isMeta) and true or false

  if type(content) == "string" then
    if meta or is_meta_text(content) then
      out[#out + 1] = envelope({ kind = "local_command", offset = offset, text = content }, rec)
    else
      self.turn_open = true
      out[#out + 1] = envelope({ kind = "user_text", offset = offset, text = content, source = source }, rec)
    end
    return
  end
  if type(content) ~= "table" then
    return
  end

  local detail = nz(rec.toolUseResult) -- dict | string | list, per tool
  for _, block in ipairs(content) do
    local btype = nz(block.type)
    if btype == "tool_result" then
      local id = nz(block.tool_use_id)
      if id then
        self.pending_calls[id] = nil
      end
      local rtext
      local c = nz(block.content)
      if type(c) == "string" then
        rtext = c
      elseif type(c) == "table" then
        local parts = {}
        for _, rb in ipairs(c) do
          if nz(rb.type) == "text" then
            parts[#parts + 1] = nz(rb.text)
          end
        end
        rtext = table.concat(parts, "\n")
      end
      out[#out + 1] = envelope({
        kind = "tool_result",
        offset = offset,
        id = id,
        text = rtext or "",
        is_error = nz(block.is_error) or false,
        detail = detail,
      }, rec)
      -- Agent (Task) results announce subagents: sync ones carry stats,
      -- background ones carry outputFile; both carry agentId.
      if type(detail) == "table" and nz(detail.agentId) then
        out[#out + 1] = envelope({
          kind = "subagent",
          offset = offset,
          agent_id = nz(detail.agentId),
          agent_type = nz(detail.agentType),
          status = nz(detail.status),
          output_file = nz(detail.outputFile),
          description = nz(detail.description),
          stats = nz(detail.toolStats),
        }, rec)
      end
      detail = nil -- envelope belongs to the first result block only
    elseif btype == "text" then
      local text = nz(block.text) or ""
      if text:find(INTERRUPT_TEXT, 1, true) == 1 then
        self.pending_calls = {} -- interrupt aborts in-flight tools
        self.turn_open = false
        out[#out + 1] =
          envelope({ kind = "interrupt", offset = offset, interrupted_message_id = nz(rec.interruptedMessageId) }, rec)
      elseif meta or is_meta_text(text) then
        out[#out + 1] = envelope({ kind = "local_command", offset = offset, text = text }, rec)
      else
        self.turn_open = true
        out[#out + 1] = envelope({ kind = "user_text", offset = offset, text = text, source = source }, rec)
      end
    else -- image blocks (base64, up to ~400KB), future types
      out[#out + 1] = envelope({ kind = "other", offset = offset, rtype = "user", subtype = btype }, rec)
    end
  end
end

---@param self giroux.transcript.Parser
---@param rec table system record
---@param out giroux.transcript.Event[]
local function on_system(self, rec, offset, out)
  local sub = nz(rec.subtype)
  if sub == "turn_duration" then
    self.pending_calls = {} -- belt: a finished turn leaves nothing in flight
    self.turn_open = false
    out[#out + 1] = envelope({
      kind = "turn_end",
      offset = offset,
      duration_ms = nz(rec.durationMs),
      message_count = nz(rec.messageCount),
    }, rec)
  elseif sub == "api_error" then
    local err = nz(rec.error)
    out[#out + 1] = envelope({
      kind = "api_error",
      offset = offset,
      text = type(err) == "table" and vim.inspect(err) or tostring(err or "api_error"),
      retry_in_ms = nz(rec.retryInMs),
      attempt = nz(rec.retryAttempt),
    }, rec)
  elseif sub == "away_summary" then
    out[#out + 1] = envelope({ kind = "summary", offset = offset, text = nz(rec.content) or "" }, rec)
  elseif sub == "compact_boundary" then
    local cm = nz(rec.compactMetadata) or {}
    out[#out + 1] = envelope({
      kind = "compact",
      offset = offset,
      trigger = nz(cm.trigger),
      pre_tokens = nz(cm.preTokens),
      post_tokens = nz(cm.postTokens),
    }, rec)
  elseif sub == "model_refusal_fallback" then
    out[#out + 1] = envelope({ kind = "retract", offset = offset, uuids = nz(rec.retractedMessageUuids) or {} }, rec)
  else -- stop_hook_summary, local_command, scheduled_task_fire, informational, ...
    out[#out + 1] = envelope({ kind = "other", offset = offset, rtype = "system", subtype = sub }, rec)
  end
end

---@param line giroux.transcript.Line
---@param out giroux.transcript.Event[]
function Parser:on_line(line, out)
  local ok, rec = pcall(vim.json.decode, line.text)
  if not ok or type(rec) ~= "table" then
    out[#out + 1] = { kind = "unknown", offset = line.offset, rtype = "undecodable", raw = line.text }
    return
  end
  local rtype = nz(rec.type)

  if rtype == "assistant" then
    on_assistant(self, rec, line.offset, out)
  elseif rtype == "user" then
    on_user(self, rec, line.offset, out)
  elseif rtype == "system" then
    on_system(self, rec, line.offset, out)
  elseif SESSION_META[rtype] then
    out[#out + 1] = { kind = "session_meta", offset = line.offset, key = rtype, value = nz(rec[SESSION_META[rtype]]) }
  elseif rtype == "queue-operation" then
    out[#out + 1] = {
      kind = "queue",
      offset = line.offset,
      ts = nz(rec.timestamp),
      op = nz(rec.operation),
      text = nz(rec.content),
    }
  elseif rtype == "attachment" then
    local att = nz(rec.attachment) or {}
    local atype = nz(att.type)
    if atype == "queued_command" then
      out[#out + 1] = envelope({ kind = "queue", offset = line.offset, op = "enqueue", text = nz(att.prompt) }, rec)
    else
      out[#out + 1] = envelope({ kind = "other", offset = line.offset, rtype = "attachment", subtype = atype }, rec)
    end
  elseif rtype == "file-history-snapshot" then
    out[#out + 1] = { kind = "other", offset = line.offset, rtype = rtype }
  else
    out[#out + 1] = { kind = "unknown", offset = line.offset, rtype = rtype or "?", raw = line.text }
  end
end

---Feed a chunk of bytes; returns normalized events for every record completed.
---@param chunk string
---@return giroux.transcript.Event[]
function Parser:feed(chunk)
  local out = {}
  for _, line in ipairs(self.lines:feed(chunk)) do
    self:on_line(line, out)
  end
  return out
end

---Subagent transcript path for an agent_id announced by a `subagent` event.
---@param session_path string path to the main session .jsonl
---@param agent_id string
function M.subagent_path(session_path, agent_id)
  return session_path:gsub("%.jsonl$", "") .. "/subagents/agent-" .. agent_id .. ".jsonl"
end

return M
