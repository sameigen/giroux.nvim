---@module 'giroux.sessions'
--- Session inventory and state derivation: stat-only discovery (list) and a
--- 32KB-tail scan whose parser pending-set + age prove the glyph. No daemon.
--- See DESIGN.md §3/§4.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")

local M = {}

local MARK = "===GIROUX==="
M.TAIL_BYTES = 32768

---@class giroux.Session
---@field node string
---@field path string
---@field mtime integer
---@field size integer
---@field state string ●|?|○|✗|~
---@field title string|nil
---@field last_prompt string|nil
---@field pending string[] unresolved tool names
---@field project string display form of the project slug
---@field activity string recent tool activity (tail-derived, e.g. "edit×3 bash×1")
---@field touched string|nil most recent file path touched
---@field is_subagent boolean|nil this transcript is a spawned subagent (Agent/Task)
---@field parent_id string|nil session id of the parent that spawned it
---@field agent_id string|nil the subagent's own id (from its filename)
---@field agent_type string|nil subagent type, e.g. "general-purpose" (from .meta.json)
---@field description string|nil the task the subagent was dispatched with (.meta.json)
---@field spawn_depth integer|nil nesting depth (1 = spawned by the top-level session)

---State proof from parser pending-set + turn-in-flight + transcript age
---(DESIGN.md §4). WORKING is proven by either an unresolved tool_use OR an
---open turn — text/thinking generation appends with an empty pending-set,
---which is not idleness. Without process truth (tmux, later), "dead" is
---inferred: work in flight but the file silent far longer than sane.
---@param pending table<string, {name: string}>
---@param age_sec number seconds since last append
---@param in_turn boolean|nil a user turn is open (no turn_end/stop/interrupt yet)
---@return string
function M.derive_state(pending, age_sec, in_turn)
  local has, question = false, false
  for _, call in pairs(pending) do
    has = true
    if call.name == "AskUserQuestion" then
      question = true
    end
  end
  if question then
    return "?"
  end
  if has or in_turn then
    return age_sec <= 1800 and "●" or "✗"
  end
  return age_sec <= 3600 and "○" or "~"
end

---Split a subagent transcript path into its parent id + own agent id, or nil
---for a normal (top-level) session. Subagents live at
---`<project>/<parentSid>/subagents/agent-<agentId>.jsonl`. Pure.
---@param path string
---@return {parent_id: string, agent_id: string}|nil
function M.subagent_of(path)
  local agent_id = path:match("/subagents/agent%-([^/]+)%.jsonl$")
  if not agent_id then
    return nil
  end
  local parent_dir = path:gsub("/subagents/agent%-[^/]+%.jsonl$", "")
  return { parent_id = vim.fs.basename(parent_dir), agent_id = agent_id }
end

---"-Users-dev-Code-app" -> "~/Code/app" (lossy on dashed names; display only).
---Strips the home prefix on macOS (-Users-<user>-) and Linux (-home-<user>-).
function M.project_display(path)
  -- a subagent lives one level deeper (<project>/<sid>/subagents/agent-*.jsonl);
  -- collapse to the parent's path so the project slug resolves to the same repo.
  path = path:gsub("/subagents/agent%-[^/]+%.jsonl$", ".jsonl")
  local slug = vim.fs.basename(vim.fs.dirname(path))
  local user = slug:match("^%-Users%-([^%-]+)") or slug:match("^%-home%-([^%-]+)")
  if user then
    slug = slug:gsub("^%-Users%-" .. user .. "%-?", ""):gsub("^%-home%-" .. user .. "%-?", "")
  end
  if slug == "" then
    return "~"
  end
  -- double dash = dot-dir (.cache); collapse after prefixing so a leading dash works too
  return ("~/" .. slug:gsub("%-", "/")):gsub("//", "/.")
end

---Parse one node's scan output into sessions.
---@param node_name string
---@param stdout string
---@param now integer epoch seconds
---@return giroux.Session[]
function M.parse_scan(node_name, stdout, now)
  local out = {}
  local cur, parser, acc, skipped_partial
  local function finish()
    if not cur then
      return
    end
    cur.pending = {}
    for _, call in pairs(parser:pending()) do
      cur.pending[#cur.pending + 1] = call.name
    end
    cur.state = M.derive_state(parser:pending(), now - cur.mtime, parser:in_turn())
    cur.activity = acc:recent_line()
    cur.touched = acc.recent_files[#acc.recent_files]
    out[#out + 1] = cur
  end
  for line in vim.gsplit(stdout, "\n", { plain = true }) do
    local mtime, size, birth, path = line:match("^" .. MARK .. " (%d+) (%d+) (%d+) (.+)$")
    if mtime then
      finish()
      cur = {
        node = node_name,
        mtime = tonumber(mtime),
        size = tonumber(size),
        birth = tonumber(birth),
        path = path,
        project = M.project_display(path),
      }
      parser = transcript.parser()
      acc = stats.new()
      -- tail -c of a big file starts mid-record; drop the first (partial) line
      skipped_partial = cur.size <= M.TAIL_BYTES
    elseif cur and line ~= "" then
      if not skipped_partial then
        skipped_partial = true
      else
        for _, e in ipairs(parser:feed(line .. "\n")) do
          acc:add(e)
          if e.kind == "session_meta" then
            if e.key == "ai-title" then
              cur.title = e.value
            elseif e.key == "last-prompt" then
              cur.last_prompt = e.value
            end
          elseif e.kind == "user_text" then
            cur.last_prompt = e.text:match("^[^\n]*")
          end
        end
      end
    end
  end
  finish()
  return out
end

---Lightweight discovery: active session files with stat only (no content),
---for the live monitor to decide which sessions to tail. cb(list, errored)
---once; `errored` is a set of node names whose scan failed (so the caller can
---keep their trackers instead of treating an empty result as "all gone").
---@param opts {node: string|nil}|nil
---@param cb fun(list: {node: string, path: string, mtime: integer, size: integer, project: string}[], errored: table<string, boolean>)
function M.list(opts, cb)
  opts = opts or {}
  local cfg = require("giroux").config
  local all = nodes.all()
  local out, errored, waiting = {}, {}, 0
  -- subagents (Agent/Task transcripts) are surfaced by default so they nest
  -- under their parent on the roster; the `subagents = false` knob restores the
  -- old parent-only scan. Either way `journal.jsonl` and the workflows/ tree
  -- (JS scripts + JSON journals, not transcripts) are excluded.
  local sub_gate = cfg.subagents == false and "-not -path '*/subagents/*' " or ""
  for name, node in pairs(all) do
    if not opts.node or opts.node == name then
      waiting = waiting + 1
      -- portable stat: GNU (-c, Linux) with a BSD (-f, macOS) fallback. The GNU
      -- form fails on macOS (no -c) and is silently skipped; vice-versa on Linux.
      local cmd = (
        "find %s -name '*.jsonl' -not -name journal.jsonl -not -path '*/workflows/*' %s-mmin -%d 2>/dev/null"
        .. " | while IFS= read -r f; do stat -c '%%Y %%s %%W %%n' \"$f\" 2>/dev/null"
        .. " || stat -f '%%m %%z %%B %%N' \"$f\"; done"
      ):format(node.claude_projects, sub_gate, cfg.active_window)
      ssh.exec(node.host, cmd, function(ok, stdout)
        waiting = waiting - 1
        if ok then
          for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
            local mtime, size, birth, path = line:match("^(%d+) (%d+) (%d+) (.+)$")
            if path then
              local item = {
                node = name,
                path = path,
                mtime = tonumber(mtime),
                size = tonumber(size),
                birth = tonumber(birth),
                project = M.project_display(path),
              }
              local sub = M.subagent_of(path)
              if sub then
                item.is_subagent = true
                item.parent_id = sub.parent_id
                item.agent_id = sub.agent_id
              end
              out[#out + 1] = item
            end
          end
        else
          -- a node whose scan failed (ssh hiccup, node asleep) reports NO
          -- sessions; the caller must not read that as "every session here is
          -- gone" and drop their live trackers. Flag it so they're preserved.
          errored[name] = true
        end
        if waiting == 0 then
          cb(out, errored)
        end
      end)
    end
  end
  if waiting == 0 then
    cb({}, {})
  end
end

---Scan all nodes (or one). cb(sessions) once, sorted: attention first.
---@param opts {node: string|nil}|nil
---@param cb fun(sessions: giroux.Session[], errs: table<string, string>)
function M.scan(opts, cb)
  opts = opts or {}
  local cfg = require("giroux").config
  local all = nodes.all()
  local sessions, errs = {}, {}
  local waiting = 0
  local ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["○"] = 4, ["~"] = 5 }
  for name, node in pairs(all) do
    if not opts.node or opts.node == name then
      waiting = waiting + 1
      -- portable stat: GNU (-c, Linux) with a BSD (-f, macOS) fallback.
      local cmd = (
        "find %s -name '*.jsonl' -not -path '*/subagents/*' -not -name journal.jsonl -mmin -%d 2>/dev/null"
        .. " | while IFS= read -r f; do"
        .. ' s="$(stat -c \'%%Y %%s %%W\' "$f" 2>/dev/null || stat -f \'%%m %%z %%B\' "$f")";'
        .. ' printf \'%s %%s %%s\\n\' "$s" "$f"; tail -c %d "$f"; printf \'\\n\'; done'
      ):format(node.claude_projects, cfg.active_window, MARK, M.TAIL_BYTES)
      ssh.exec(node.host, cmd, function(ok, stdout, stderr)
        waiting = waiting - 1
        if ok then
          vim.list_extend(sessions, M.parse_scan(name, stdout, os.time()))
        else
          errs[name] = vim.trim(stderr or "scan failed")
        end
        if waiting == 0 then
          table.sort(sessions, function(a, b)
            local oa, ob = ORDER[a.state] or 9, ORDER[b.state] or 9
            if oa ~= ob then
              return oa < ob
            end
            return a.mtime > b.mtime
          end)
          cb(sessions, errs)
        end
      end)
    end
  end
  if waiting == 0 then
    cb({}, { [tostring(opts.node)] = "unknown node" })
  end
end

return M
