---@module 'giroux.tmuxctl'
--- Correlate transcripts to tmux sessions by PROOF, not heuristics: Claude
--- Code's own `claude agents --json` maps sessionId -> pid, tmux maps
--- pane -> pane_pid, and a ps pid/ppid snapshot links the two by ancestry.
--- A transcript's tmux session is the pane whose process tree contains the
--- claude process writing that exact sessionId — never "same cwd, closest
--- creation time" (with N parallel sessions in one repo that was a lottery,
--- and it steered/attached into the wrong agent). Foundation for steer.lua.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")

local M = {}

---@class giroux.TmuxPane
---@field name string tmux session name (giroux/...)
---@field pane_pid integer pid of the pane's root process (shell or claude itself)
---@field cwd string pane current path
---@field created integer epoch seconds
---@field attached boolean a client is attached to the session
---@field title string|nil pane title (Claude sets it to "<state-glyph> <ai-title>")

---@class giroux.TmuxSnapshot
---@field panes giroux.TmuxPane[]
---@field parent table<integer, integer> pid -> ppid, whole node

---Claude's cwd -> project-slug transform.
---@param cwd string
---@return string
function M.slugify(cwd)
  return (cwd:gsub("[/%.]", "-"))
end

local PS_MARK = "===GIROUX-PS==="

---One shell round-trip: giroux panes (with pane_pid) plus a full pid/ppid
---table. The ps snapshot is what lets correlation walk a claude pid up to
---the pane that owns it. pane_title carries Claude's live state glyph.
---@return string
function M.list_cmd()
  return [[tmux list-panes -a -F '#{session_name}	#{pane_pid}	#{pane_current_path}	#{session_created}	#{session_attached}	#{pane_title}' 2>/dev/null; ]]
    .. ("printf '%s\\n'; "):format(PS_MARK)
    .. [[ps -axo pid=,ppid=]]
end

---@param stdout string
---@return giroux.TmuxSnapshot
function M.parse_list(stdout)
  local snap = { panes = {}, parent = {} }
  local in_ps = false
  for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
    if line == PS_MARK then
      in_ps = true
    elseif in_ps then
      local pid, ppid = line:match("^%s*(%d+)%s+(%d+)%s*$")
      if pid then
        snap.parent[tonumber(pid)] = tonumber(ppid)
      end
    else
      local name, pid, cwd, created, attached, title = line:match("^([^\t]+)\t(%d+)\t([^\t]+)\t(%d+)\t(%d)\t?(.*)$")
      if name and name:match("^giroux/") then
        snap.panes[#snap.panes + 1] = {
          name = name,
          pane_pid = tonumber(pid),
          cwd = cwd,
          created = tonumber(created),
          attached = attached == "1",
          title = title ~= "" and title or nil,
        }
      end
    end
  end
  return snap
end

---The pane whose process tree contains `pid`: walk pid -> ppid until a
---pane_pid matches (pid itself counts — dispatch-era panes run claude AS the
---pane process; wrapper panes run it as a job under the pane shell). Bounded
---so a cyclic/garbled ps table can't loop.
---@param snap giroux.TmuxSnapshot
---@param pid integer|nil
---@return giroux.TmuxPane|nil
function M.owner_pane(snap, pid)
  if not pid then
    return nil
  end
  local by_pid = {}
  for _, p in ipairs(snap.panes) do
    by_pid[p.pane_pid] = p
  end
  local cur = pid
  for _ = 1, 64 do
    if by_pid[cur] then
      return by_pid[cur]
    end
    cur = snap.parent[cur]
    if not cur or cur <= 1 then
      return nil
    end
  end
  return nil
end

---Fallback correlation for nodes whose CC predates `claude agents`: cwd-slug
---match, but ONLY when unambiguous — exactly one live candidate in that cwd
---(plus the birth window when known). Two sessions in one repo = nil =
---observe-only; a guess that can attach/steer the wrong agent is worse than
---no correlation (DESIGN.md §4: state is proven, not guessed).
---@param snap giroux.TmuxSnapshot
---@param project_slug string transcript dir name, e.g. "-Users-dev-Code-app"
---@param birth integer|nil transcript file birth (epoch), nil = any
---@return giroux.TmuxPane|nil
function M.correlate_fallback(snap, project_slug, birth)
  local hit, n = nil, 0
  for _, t in ipairs(snap.panes) do
    if M.slugify(t.cwd) == project_slug and (not birth or math.abs((t.created or 0) - birth) <= 600) then
      hit, n = t, n + 1
    end
  end
  return n == 1 and hit or nil
end

---Correlate one transcript to its tmux pane. Exact tier: the agents map
---(sessionId -> pid, from `claude agents --json`) + pid ancestry. When that
---map is UNAVAILABLE (old CC / command failed) — and only then — fall back to
---the unambiguous-cwd heuristic. An available map with no entry/pane means
---the session has no live claude in tmux: nil, honestly observe-only.
---@param snap giroux.TmuxSnapshot
---@param sid string claude session id (transcript basename sans .jsonl)
---@param agents_map table<string, giroux.AgentEntry>|nil nil = agents unavailable
---@param project_slug string
---@param birth integer|nil
---@return giroux.TmuxPane|nil
function M.correlate(snap, sid, agents_map, project_slug, birth)
  if agents_map then
    local entry = agents_map[sid]
    return entry and M.owner_pane(snap, entry.pid) or nil
  end
  return M.correlate_fallback(snap, project_slug, birth)
end

---Classify Claude's pane-title state glyph. The TUI prefixes the title with a
---braille spinner (U+2800–U+28FF) while generating and a ✳ (U+2733) when idle.
---Strict: only the glyphs we've verified map to a state; anything else is nil
---(unknown), never a guess. Verified live against real panes.
---@param title string|nil
---@return "working"|"idle"|nil
function M.title_state(title)
  if not title or title == "" then
    return nil
  end
  local cp = vim.fn.strgetchar(title, 0)
  if cp >= 0x2800 and cp <= 0x28FF then
    return "working"
  elseif cp == 0x2733 then
    return "idle"
  end
  return nil
end

---Only rename names the wrapper minted (giroux/<dir>-<4hex>) or that we
---renamed before (giroux/t/...): never fight a manual rename.
---@param name string
---@return boolean
function M.renameable(name)
  return name:match("^giroux/.+%-%x%x%x%x$") ~= nil or name:match("^giroux/t/") ~= nil
end

---Exact tmux target for a session name: `=` pins tmux's -t resolution to an
---exact match. Without it tmux PREFIX-matches, so `-t giroux/t/fix` can land
---on `giroux/t/fix-something-else` — keys typed into the wrong agent.
---@param name string
---@return string
function M.exact(name)
  return "=" .. name
end

---@param title string transcript ai-title
---@param sid string|nil claude session id; its prefix makes the name unique,
---so two sessions with the same/similar titles can't collide (a colliding
---rename fails silently and used to leave giroux pointing one transcript at
---the OTHER session's pane)
---@return string tmux-safe session name
function M.title_to_name(title, sid)
  local slug = title:lower():gsub("[^%w%s-]", ""):gsub("%s+", "-"):gsub("%-+", "-"):sub(1, 40):gsub("%-$", "")
  local tag = sid and sid:gsub("%-.*", ""):sub(1, 4) or nil
  return "giroux/t/" .. slug .. (tag and ("-" .. tag) or "")
end

---@param path string transcript path
---@return string sid
local function sid_of(path)
  return (vim.fs.basename(path):gsub("%.jsonl$", ""))
end

local cache = {} ---@type table<string, {at: integer, snap: giroux.TmuxSnapshot}> per node
local inflight = {} ---@type table<string, fun(snap: giroux.TmuxSnapshot)[]> callbacks awaiting one exec

---Drop a node's cached snapshot (after a rename/kill changes it).
---@param node_name string
function M.invalidate(node_name)
  cache[node_name] = nil
end

---Tmux + process snapshot for a node (cached briefly; cb on main loop).
---Concurrent misses coalesce onto ONE exec: the probe loop asks per session
---per tick, and a cold cache must not fan out into N parallel ssh channels.
---@param node_name string
---@param cb fun(snap: giroux.TmuxSnapshot)
function M.snapshot(node_name, cb)
  local c = cache[node_name]
  if c and os.time() - c.at < 5 then
    return cb(c.snap)
  end
  local _, node = nodes.get(node_name)
  if not node then
    return cb({ panes = {}, parent = {} })
  end
  if inflight[node_name] then
    inflight[node_name][#inflight[node_name] + 1] = cb
    return
  end
  inflight[node_name] = { cb }
  ssh.exec(node.host, ssh.login_wrap(M.list_cmd()), function(ok, stdout)
    local snap = ok and M.parse_list(stdout) or { panes = {}, parent = {} }
    cache[node_name] = { at = os.time(), snap = snap }
    local waiting = inflight[node_name] or {}
    inflight[node_name] = nil
    for _, fn in ipairs(waiting) do
      fn(snap)
    end
  end)
end

---Resolve a session's pane via snapshot + agents map (both cached).
---@param node_name string
---@param session giroux.Session
---@param cb fun(pane: giroux.TmuxPane|nil)
local function resolve_pane(node_name, session, cb)
  M.snapshot(node_name, function(snap)
    require("giroux.agents").list(node_name, function(agents_map, available)
      local slug = vim.fs.basename(vim.fs.dirname(session.path))
      local birth = session.birth or session.mtime
      cb(M.correlate(snap, sid_of(session.path), available and agents_map or nil, slug, birth))
    end)
  end)
end

local renamed = {} ---@type table<string, string> transcript path -> applied title

---Rename the correlated tmux session after the transcript's ai-title.
---Rate-limited per title; silently does nothing without a correlation.
---Bookkeeping happens ONLY on rename success: a failed rename (name taken,
---session gone) must not mark the title applied, and must never point
---session.tmux at a name we didn't prove we own.
---@param node_name string
---@param session giroux.Session monitor/scan session (path, mtime)
---@param title string
function M.maybe_rename(node_name, session, title)
  if renamed[session.path] == title then
    return
  end
  resolve_pane(node_name, session, function(pane)
    if not pane or not M.renameable(pane.name) then
      return
    end
    local new_name = M.title_to_name(title, sid_of(session.path))
    if pane.name == new_name then
      renamed[session.path] = title
      return
    end
    local _, node = nodes.get(node_name)
    ssh.exec(
      node.host,
      ssh.login_wrap(
        ("tmux rename-session -t %s %s 2>/dev/null"):format(ssh.shq(M.exact(pane.name)), ssh.shq(new_name))
      ),
      function(ok)
        if not ok then
          return -- retried on the next ai-title event; never book a failed rename
        end
        renamed[session.path] = title
        M.invalidate(node_name)
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
  resolve_pane(node_name, session, function(pane)
    session.tmux = pane and pane.name or nil
    session.tmux_title = pane and pane.title or nil -- live state glyph for derive()
    session.tmux_title_at = os.time() -- captured-at, so derive can ignore a stale spinner
    cb(pane and pane.name or nil)
  end)
end

return M
