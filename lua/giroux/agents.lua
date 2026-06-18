---@module 'giroux.agents'
--- Live session state from Claude Code's own `claude agents --json` (CC >= 2.1.140).
--- A best-effort ENRICHMENT layer, not a discovery source: it gives two things a
--- transcript tail cannot — process truth (the session is actually alive) and the
--- needs-you signal (`waitingFor`), since an AskUserQuestion / permission prompt
--- sits on screen and only lands in the JSONL once answered. Discovery and the
--- lossless feed stay transcript-based (DESIGN.md §10): if this command is missing
--- or errors (older CC, unreachable node), callers fall back with no regression.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")

local M = {}

---@class giroux.AgentEntry
---@field status string|nil idle|waiting|working|...
---@field waiting_for string|nil e.g. "permission prompt", "input needed"
---@field pid integer|nil
---@field cwd string|nil
---@field kind string|nil interactive|background

---When a sessionId appears under multiple pids, keep the most actionable entry.
---@param status string|nil
---@param waiting_for string|nil
---@return integer
local function rank(status, waiting_for)
  if (waiting_for and waiting_for ~= "") or status == "waiting" then
    return 3
  end
  if status == "working" or status == "running" or status == "busy" then
    return 2
  end
  return 1
end

---Parse `claude agents --json` output into sessionId -> entry. Tolerant: bad
---JSON or an unexpected shape yields an empty map (the caller falls back).
---@param json string
---@return table<string, giroux.AgentEntry>
function M.parse(json)
  local ok, arr = pcall(vim.json.decode, json or "", { luanil = { object = true, array = true } })
  if not ok or type(arr) ~= "table" then
    return {}
  end
  local by_id, best = {}, {}
  for _, e in ipairs(arr) do
    if type(e) == "table" and type(e.sessionId) == "string" then
      local r = rank(e.status, e.waitingFor)
      if not by_id[e.sessionId] or r > best[e.sessionId] then
        by_id[e.sessionId] = {
          status = e.status,
          waiting_for = e.waitingFor,
          pid = e.pid,
          cwd = e.cwd,
          kind = e.kind,
        }
        best[e.sessionId] = r
      end
    end
  end
  return by_id
end

---Is this agent blocked waiting on the human (question or permission prompt)?
---@param entry giroux.AgentEntry|nil
---@return boolean
function M.needs_input(entry)
  if not entry then
    return false
  end
  if entry.status == "waiting" then
    return true
  end
  local w = (entry.waiting_for or ""):lower()
  return w:find("input", 1, true) ~= nil or w:find("permission", 1, true) ~= nil
end

---Classify a session from its agent entry ALONE, or nil to defer to the
---transcript heuristic. Only two signals are trusted here: human-blocking
---(`?`) and daemon-reported actively-working (`●`). Liveness does NOT imply
---healthy — a hung/zombie pid still appears in the list — so dead/stale (and
---plain idle) stay the transcript's job (age-based), which is what catches a
---process wedged with work pending.
---@param entry giroux.AgentEntry|nil
---@return string|nil "?" | "●" | nil (defer)
function M.classify(entry)
  if M.needs_input(entry) then
    return "?"
  end
  if entry and (entry.status == "working" or entry.status == "running" or entry.status == "busy") then
    return "●"
  end
  return nil
end

---Fetch the live agent map for a node. cb(map) on the main loop; {} on any
---failure. Login-wrapped so `claude` resolves and authenticates over ssh.
---@param node_name string
---@param cb fun(map: table<string, giroux.AgentEntry>)
function M.list(node_name, cb)
  local _, node = nodes.get(node_name)
  if not node then
    return cb({})
  end
  ssh.exec(node.host, "claude agents --json 2>/dev/null", function(ok, stdout)
    cb(ok and M.parse(stdout) or {})
  end, { login = true })
end

return M
