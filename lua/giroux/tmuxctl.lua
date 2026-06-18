---@module 'giroux.tmuxctl'
--- Correlate transcripts to the tmux sessions the claude-wrapper minted, by
--- cwd-slug (Claude's [/.]->'-' encoding) with a creation-time tiebreak, and
--- rename them to the transcript's ai-title. Foundation for steer.lua.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")

local M = {}

---@class giroux.TmuxSession
---@field name string tmux session name (giroux/...)
---@field cwd string pane current path
---@field created integer epoch seconds
---@field gid string|nil GIROUX_SESSION_ID, when injected

---Claude's cwd -> project-slug transform.
---@param cwd string
---@return string
function M.slugify(cwd)
  return (cwd:gsub("[/%.]", "-"))
end

---One shell round-trip listing giroux tmux sessions with cwd, created, id.
---@return string
function M.list_cmd()
  return [[tmux list-panes -a -F '#{session_name}	#{pane_current_path}	#{session_created}' 2>/dev/null ]]
    .. [[| sort -u | while IFS='	' read -r s p c; do case "$s" in giroux/*) ]]
    .. [[printf '%s\t%s\t%s\t%s\n' "$s" "$p" "$c" ]]
    .. [["$(tmux show-environment -t "$s" GIROUX_SESSION_ID 2>/dev/null | cut -d= -f2)";; esac; done]]
end

---@param stdout string
---@return giroux.TmuxSession[]
function M.parse_list(stdout)
  local out = {}
  for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
    local name, cwd, created, gid = line:match("^([^\t]+)\t([^\t]+)\t(%d+)\t?(.*)$")
    if name then
      out[#out + 1] = { name = name, cwd = cwd, created = tonumber(created), gid = gid ~= "" and gid or nil }
    end
  end
  return out
end

---Best tmux session for a transcript: same cwd-slug, closest creation time.
---@param tmux_sessions giroux.TmuxSession[]
---@param project_slug string transcript dir name, e.g. "-Users-dev-Code-app"
---@param birth integer|nil transcript file birth (epoch), nil = any
---@return giroux.TmuxSession|nil
function M.correlate(tmux_sessions, project_slug, birth)
  local best, best_gap
  for _, t in ipairs(tmux_sessions) do
    if M.slugify(t.cwd) == project_slug then
      local gap = birth and math.abs((t.created or 0) - birth) or 0
      if not best or gap < best_gap then
        best, best_gap = t, gap
      end
    end
  end
  -- a candidate created hours away from the transcript is a different run
  if best and birth and best_gap > 600 then
    return nil
  end
  return best
end

---Only rename names the wrapper minted (giroux/<dir>-<4hex>) or that we
---renamed before (giroux/t/...): never fight a manual rename.
---@param name string
---@return boolean
function M.renameable(name)
  return name:match("^giroux/.+%-%x%x%x%x$") ~= nil or name:match("^giroux/t/") ~= nil
end

---@param title string transcript ai-title
---@return string tmux-safe session name
function M.title_to_name(title)
  local slug = title:lower():gsub("[^%w%s-]", ""):gsub("%s+", "-"):gsub("%-+", "-"):sub(1, 40):gsub("%-$", "")
  return "giroux/t/" .. slug
end

local cache = {} ---@type table<string, {at: integer, list: giroux.TmuxSession[]}> per node

---Drop a node's cached session listing (after a rename/kill changes it).
---@param node_name string
function M.invalidate(node_name)
  cache[node_name] = nil
end

---List giroux tmux sessions on a node (cached briefly; cb on main loop).
---@param node_name string
---@param cb fun(list: giroux.TmuxSession[])
function M.sessions(node_name, cb)
  local c = cache[node_name]
  if c and os.time() - c.at < 5 then
    return cb(c.list)
  end
  local _, node = nodes.get(node_name)
  if not node then
    return cb({})
  end
  ssh.exec(node.host, ssh.login_wrap(M.list_cmd()), function(ok, stdout)
    local list = ok and M.parse_list(stdout) or {}
    cache[node_name] = { at = os.time(), list = list }
    cb(list)
  end)
end

local renamed = {} ---@type table<string, string> transcript path -> applied title

---Rename the correlated tmux session after the transcript's ai-title.
---Rate-limited per title; silently does nothing without a correlation.
---@param node_name string
---@param session giroux.Session monitor/scan session (path, mtime)
---@param title string
function M.maybe_rename(node_name, session, title)
  if renamed[session.path] == title then
    return
  end
  M.sessions(node_name, function(list)
    local slug = vim.fs.basename(vim.fs.dirname(session.path))
    local t = M.correlate(list, slug, session.birth or session.mtime)
    if not t or not M.renameable(t.name) then
      return
    end
    renamed[session.path] = title
    local _, node = nodes.get(node_name)
    local new_name = M.title_to_name(title)
    ssh.exec(
      node.host,
      ssh.login_wrap(("tmux rename-session -t '%s' '%s' 2>/dev/null"):format(t.name, new_name)),
      function()
        cache[node_name] = nil
        session.tmux = new_name
      end
    )
  end)
end

---Attach a transcript session to its tmux target, if one correlates.
---Sets session.tmux (used by the roster as the steerable marker).
---@param node_name string
---@param session giroux.Session
---@param cb fun(target: string|nil)
function M.target(node_name, session, cb)
  M.sessions(node_name, function(list)
    local slug = vim.fs.basename(vim.fs.dirname(session.path))
    local t = M.correlate(list, slug, session.birth or session.mtime)
    session.tmux = t and t.name or nil
    cb(t and t.name or nil)
  end)
end

return M
