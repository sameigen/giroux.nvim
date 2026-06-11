---@module 'giroux.stats'
--- Stat sheet, context provenance, and tripwires (DESIGN.md §14). Pure
--- aggregation over giroux.transcript events — no extra instrumentation.
--- Answers the operator's questions: what did this agent write, what is it reading
--- (where its context comes from), what did it cost — and fires a tripwire
--- the moment it reads/writes a path he's flagged as stale.

local M = {}

-- ---------------------------------------------------------------------------
-- glob matching (tripwires + filters)

---Convert a shell-ish glob to an anchored Lua pattern. Supports ** (any,
---incl. /), * (any but /), ? (one non-/). ~ is expanded by the caller.
---@param glob string
---@return string lua_pattern
function M._glob_to_pattern(glob)
  local out, i, n = { "^" }, 1, #glob
  while i <= n do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        out[#out + 1] = ".*" -- ** spans path separators
        i = i + 2
      else
        out[#out + 1] = "[^/]*" -- * stops at /
        i = i + 1
      end
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    elseif c:match("[%^%$%(%)%%%.%[%]%+%-]") then
      out[#out + 1] = "%" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

local function expand(glob)
  if glob:sub(1, 1) == "~" then
    return vim.fn.expand(glob)
  end
  return glob
end

---@param path string
---@param globs string[]
---@return string|nil matched_glob
function M.match_any(path, globs)
  for _, g in ipairs(globs or {}) do
    if path:match(M._glob_to_pattern(expand(g))) then
      return g
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- paths a tool touches

---Which path(s) a tool_call reads or writes, and the kind. Returns nil for
---tools that touch no path. Bash is best-effort (the command string).
---@param e giroux.transcript.Event tool_call event
---@return {kind: "read"|"write"|"web"|"bash", path: string}|nil
function M.tool_target(e)
  local input = e.input or {}
  local name = e.name
  if name == "Read" or name == "Glob" or name == "Grep" then
    return { kind = "read", path = input.file_path or input.path or input.pattern or "" }
  elseif name == "Edit" or name == "Write" or name == "NotebookEdit" then
    return { kind = "write", path = input.file_path or "" }
  elseif name == "WebFetch" then
    return { kind = "web", path = input.url or "" }
  elseif name == "WebSearch" then
    return { kind = "web", path = "search:" .. (input.query or "") }
  elseif name == "Bash" then
    return { kind = "bash", path = input.command or "" }
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- accumulator

---@class giroux.stats.Acc
---@field written table<string, {add: integer, del: integer, n: integer}>
---@field read table<string, integer> path -> times read
---@field web string[]
---@field bash integer
---@field tools table<string, integer> tool name -> count
---@field tokens {out: integer, cache_read: integer, cache_creation: integer, input: integer}
---@field models table<string, boolean>
---@field subagents table[] {agent_id, agent_type, status, stats}
---@field recent_files string[] last touched paths, newest last
---@field private calls table<string, table> open tool_call inputs by id
local Acc = {}
Acc.__index = Acc

function M.new()
  return setmetatable({
    written = {},
    read = {},
    web = {},
    bash = 0,
    tools = {},
    tokens = { out = 0, cache_read = 0, cache_creation = 0, input = 0 },
    models = {},
    subagents = {},
    recent_files = {},
    calls = {},
  }, Acc)
end

local RECENT_CAP = 12

local function push_recent(acc, path)
  acc.recent_files[#acc.recent_files + 1] = path
  if #acc.recent_files > RECENT_CAP then
    table.remove(acc.recent_files, 1)
  end
end

---@param e giroux.transcript.Event
function Acc:add(e)
  if e.kind == "tool_call" then
    self.tools[e.name] = (self.tools[e.name] or 0) + 1
    if e.id then
      self.calls[e.id] = e
    end
    local t = M.tool_target(e)
    if t then
      if t.kind == "read" then
        self.read[t.path] = (self.read[t.path] or 0) + 1
        push_recent(self, t.path)
      elseif t.kind == "write" then
        self.written[t.path] = self.written[t.path] or { add = 0, del = 0, n = 0 }
        self.written[t.path].n = self.written[t.path].n + 1
        push_recent(self, t.path)
      elseif t.kind == "web" then
        self.web[#self.web + 1] = t.path
      elseif t.kind == "bash" then
        self.bash = self.bash + 1
      end
    end
  elseif e.kind == "tool_result" then
    local call = e.id and self.calls[e.id]
    if call and (call.name == "Edit" or call.name == "Write" or call.name == "NotebookEdit") then
      local path = (call.input or {}).file_path
      local rec = path and self.written[path]
      if rec and type(e.detail) == "table" and type(e.detail.structuredPatch) == "table" then
        for _, hunk in ipairs(e.detail.structuredPatch) do
          for _, l in ipairs(hunk.lines or {}) do
            local c = l:sub(1, 1)
            if c == "+" then
              rec.add = rec.add + 1
            elseif c == "-" then
              rec.del = rec.del + 1
            end
          end
        end
      end
    end
    if e.id then
      self.calls[e.id] = nil
    end
  elseif e.kind == "usage" then
    self.tokens.out = self.tokens.out + (e.output or 0)
    self.tokens.input = self.tokens.input + (e.input or 0)
    self.tokens.cache_read = self.tokens.cache_read + (e.cache_read or 0)
    self.tokens.cache_creation = self.tokens.cache_creation + (e.cache_creation or 0)
    if e.model then
      self.models[e.model] = true
    end
  elseif e.kind == "subagent" then
    self.subagents[#self.subagents + 1] = {
      agent_id = e.agent_id,
      agent_type = e.agent_type,
      status = e.status,
      stats = e.stats,
    }
  end
end

---Compact one-line activity summary for the roster (cheap, tail-derived).
---@return string
function Acc:recent_line()
  local order = { "Edit", "Write", "Bash", "Read", "WebFetch", "Grep", "Glob", "Agent" }
  local short = {
    Edit = "edit",
    Write = "write",
    Bash = "bash",
    Read = "read",
    WebFetch = "web",
    Grep = "grep",
    Glob = "glob",
    Agent = "agent",
  }
  local parts = {}
  for _, name in ipairs(order) do
    if self.tools[name] then
      parts[#parts + 1] = ("%s×%d"):format(short[name] or name, self.tools[name])
    end
  end
  return table.concat(parts, " ")
end

---@return {written: table, read: table, web: string[], tokens: table, tools: table, subagents: table[], recent_files: string[]}
function Acc:summary()
  return {
    written = self.written,
    read = self.read,
    web = self.web,
    bash = self.bash,
    tokens = self.tokens,
    tools = self.tools,
    models = vim.tbl_keys(self.models),
    subagents = self.subagents,
    recent_files = self.recent_files,
  }
end

---Aggregate a list of events in one call.
---@param events giroux.transcript.Event[]
---@return giroux.stats.Acc
function M.aggregate(events)
  local acc = M.new()
  for _, e in ipairs(events) do
    acc:add(e)
  end
  return acc
end

-- ---------------------------------------------------------------------------
-- tripwires

---Check one event against read/write tripwire globs.
---@param e giroux.transcript.Event
---@param wires {read?: string[], write?: string[]}
---@return {kind: string, path: string, glob: string}|nil
function M.tripwire(e, wires)
  if e.kind ~= "tool_call" then
    return nil
  end
  local t = M.tool_target(e)
  if not t then
    return nil
  end
  local globs = (t.kind == "write") and wires.write or (t.kind == "read") and wires.read or nil
  if not globs then
    return nil
  end
  local g = M.match_any(t.path, globs)
  if g then
    return { kind = t.kind, path = t.path, glob = g }
  end
  return nil
end

return M
