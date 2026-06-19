---@module 'giroux.monitor'
--- Realtime backbone behind the roster: stat-only discovery picks the active
--- sessions, one merged tail per node feeds them, subscribers are notified on
--- an 80ms debounce. See DESIGN.md §3/§4 and ARCHITECTURE.md (Transport).

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")
local sessions = require("giroux.sessions")

local M = {}

local SEED = 32768 -- bytes of tail re-read on first sight to recover pending-set

local state = {
  trackers = {}, ---@type table<string, table>
  node_streams = {}, ---@type table<string, {stream: giroux.ssh.Stream, gen: integer, backoff: integer}>
  subscribers = {}, ---@type table<string, fun(list: table)>
  line_subs = {}, ---@type table<string, table<string, {on_line: fun(line: string, offset: integer), on_drop: fun()}>>
  agents = {}, ---@type table<string, table<string, giroux.AgentEntry>> per node: sessionId -> live entry
  discover_timer = nil,
  debounce = nil,
  running = false,
}

---Session id from a transcript path (<slug>/<sessionId>.jsonl) — the key into
---the `claude agents --json` map.
---@param path string
---@return string
local function sid_of(path)
  return (vim.fs.basename(path):gsub("%.jsonl$", ""))
end

local function key(node, path)
  return node .. "\0" .. path
end

-- ✓ = done/unseen (a finished turn you haven't reviewed) ranks just under
-- working and above plain idle, so "ready to review" floats up the roster.
local ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["✓"] = 4, ["○"] = 5, ["~"] = 6, ["·"] = 7 }

---Lift a quiet state (○/~) to working (●) when a FRESH tmux title shows a live
---spinner. The title is ground truth that the agent is generating — instant,
---unlike the 10s agents poll, and available without `claude agents` at all.
---Positive-only: ✓/?/✗ pass through untouched, so it can add a "working" but
---never invent a needs-you or hide a done/death. Freshness-gated: a title
---older than ~one discovery cycle proves nothing about *now* (it's captured
---only on the probe tick), so a stale spinner can't flip a just-finished or
---just-reviewed session back to working.
---@param st string derived state glyph
---@param title string|nil last-captured pane title
---@param age integer seconds since that title was captured
---@return string
function M.title_lift(st, title, age)
  if st ~= "○" and st ~= "~" then
    return st
  end
  local ttl = (require("giroux").config.discover_interval or 10) + 6
  if age <= ttl and require("giroux.tmuxctl").title_state(title) == "working" then
    return "●"
  end
  return st
end

---@return giroux.Session[] sorted attention-first
function M.sessions()
  local list = {}
  for _, tr in pairs(state.trackers) do
    list[#list + 1] = tr.session
  end
  table.sort(list, function(a, b)
    local oa, ob = ORDER[a.state] or 9, ORDER[b.state] or 9
    if oa ~= ob then
      return oa < ob
    end
    return (a.mtime or 0) > (b.mtime or 0)
  end)
  return list
end

local function notify()
  if state.debounce then
    return
  end
  state.debounce = vim.defer_fn(function()
    state.debounce = nil
    local list = M.sessions()
    for _, fn in pairs(state.subscribers) do
      pcall(fn, list)
    end
  end, 80)
end

---@param tr table
---@param live boolean|nil true (default) when this derive reflects current
---  reality (a live transcript append, an agents poll, an age flip); false
---  during the initial seed/replay of historical transcript bytes, where a
---  ●→○ edge is pre-watch history and must NOT latch a (✓) done/unseen.
local function derive(tr, live)
  live = live ~= false
  -- staleness is the file's age, not when we happened to read it: only a
  -- live append (after we've caught up to the seed window) bumps the clock.
  local age = os.time() - (tr.session.mtime or os.time())
  -- Enrich with `claude agents --json`, when available. It supplies the needs-you
  -- signal (waitingFor) that a transcript tail can't, and a daemon-reported
  -- "working" status. But "listed" does NOT prove "healthy" — a hung/zombie pid
  -- can still appear — so dead/stale (and ●/○) stay owned by the transcript
  -- heuristic, which is age-based and catches a process that's wedged with work
  -- pending. (Earlier this clobbered ✗/~ whenever an entry existed; that hid the
  -- "dead" alert for hung agents and is the bug this restores.)
  local entry = (state.agents[tr.session.node] or {})[sid_of(tr.session.path)]
  -- agents.classify trusts only the needs-you and actively-working signals;
  -- it returns nil for everything else so the age-based transcript heuristic
  -- still owns dead/stale/idle (a listed pid can be hung).
  local st = require("giroux.agents").classify(entry)
    or sessions.derive_state(tr.parser:pending(), age, tr.parser:in_turn())
  -- a pane-confirmed live question (AskUserQuestion never hits the transcript
  -- while pending) still wins, covering nodes/CC without `claude agents` —
  -- but only while the file is recent enough that it can't be stale-answered.
  if tr.question and age <= 1800 then
    st = "?"
  end
  -- done / unseen: a turn that just finished (working → idle) and hasn't been
  -- reviewed is "done" (✓) — ready to look at — and ranks above plain idle.
  -- Opening its feed (M.mark_seen) demotes it back to ○. Only a *witnessed*
  -- finish latches it: a session found already idle on first sight (prev "·")
  -- stays idle, so opening the roster over old work doesn't light everything up.
  local prev = tr.session.state
  if st == "○" then
    if prev == "●" and live then
      tr.done_unseen = true
    end
    if tr.done_unseen then
      st = "✓"
    end
  elseif st == "●" then
    -- working again clears the latch; the next *witnessed* finish re-arms it.
    tr.done_unseen = false
  end
  local lifted = M.title_lift(st, tr.session.tmux_title, os.time() - (tr.session.tmux_title_at or 0))
  if lifted ~= st then
    st = lifted
    tr.done_unseen = false -- it's working, not done
  end
  tr.session.state = st
  tr.session.activity = tr.acc:recent_line()
  tr.session.touched = tr.acc.recent_files[#tr.acc.recent_files]
  tr.session.waiting_for = entry and entry.waiting_for or nil
  tr.session.pending = {}
  for _, c in pairs(tr.parser:pending()) do
    tr.session.pending[#tr.session.pending + 1] = c.name
  end

  -- fire/clear interrupt-worthy notifications on state ENTRY. A condition
  -- already true on first sight is seeded silently (counts on the badge, no
  -- banner) — only a transition that happens while we're watching pages.
  local notify = require("giroux.notify")
  local seed = not tr.primed
  tr.primed = true
  local function signal(event, on, msg)
    if not on then
      return notify.clear(event, tr.session)
    end
    if seed then
      notify.seed(event, tr.session)
    else
      notify.fire(event, tr.session, msg)
    end
  end
  signal("question", st == "?", "needs your input — " .. (tr.session.title or tr.session.project or ""))
  signal("dead", st == "✗", "went dark with work pending — " .. (tr.session.title or tr.session.project or ""))
  signal("end_of_turn", st == "✓", "finished — " .. (tr.session.title or tr.session.project or ""))
end

---Feed one complete transcript line to a tracker.
---@param tr table
---@param line string without trailing newline
local function feed_line(tr, line)
  if tr.skip_partial then
    -- tail -c from mid-file: the first "line" is a fragment; account its
    -- bytes, then start the real parser at the first record boundary.
    tr.skip_partial = false
    tr.parser = transcript.parser({ start_offset = tr.parser:resume_offset() + #line + 1 })
    return
  end
  -- liveness: this line is a live append (vs pre-watch history being replayed)
  -- iff it begins at/after the file size we saw when the tracker was created.
  -- resume_offset() here is the byte where this line starts (pre-feed).
  local live = tr.parser:resume_offset() >= (tr.live_after or 0)
  local cfg = require("giroux").config
  for _, e in ipairs(tr.parser:feed(line .. "\n")) do
    tr.acc:add(e)
    -- any fresh byte clears a stale question latch; a still-open one is
    -- re-confirmed by the next probe tick.
    tr.question = false
    if e.kind == "session_meta" then
      if e.key == "ai-title" then
        tr.session.title = e.value
        if e.value and e.value ~= "" and cfg.tmux_rename then
          require("giroux.tmuxctl").maybe_rename(tr.session.node, tr.session, e.value)
        end
      elseif e.key == "last-prompt" then
        tr.session.last_prompt = e.value
      end
    elseif e.kind == "user_text" then
      tr.session.last_prompt = e.text:match("^[^\n]*")
    end
    local wire = require("giroux.stats").tripwire(e, cfg.tripwires or {})
    if wire then
      require("giroux.notify").fire(
        "tripwire",
        tr.session,
        ("%s %s (%s)"):format(wire.kind, vim.fn.fnamemodify(wire.path, ":t"), wire.glob)
      )
    end
  end
  derive(tr, live)
  notify()
end

---(Re)start the merged tail for one node over every tracked session,
---resuming each file from its parser's offset. One ssh channel per node.
---@param node_name string
local function rebuild_stream(node_name)
  local prev = state.node_streams[node_name]
  if prev and prev.stream then
    prev.stream.stop()
  end
  local files = {}
  for _, tr in pairs(state.trackers) do
    if tr.session.node == node_name then
      files[#files + 1] = { path = tr.session.path, offset = tr.parser:resume_offset() }
    end
  end
  if #files == 0 then
    state.node_streams[node_name] = nil
    return
  end
  local _, node = nodes.get(node_name)
  local entry = { gen = (prev and prev.gen or 0) + 1, backoff = prev and prev.backoff or 1000 }
  state.node_streams[node_name] = entry
  entry.stream = ssh.multi_tail(node.host, files, function(path, line)
    entry.backoff = 1000
    local k = key(node_name, path)
    local tr = state.trackers[k]
    local line_offset = tr and tr.parser:resume_offset() or 0
    if tr then
      feed_line(tr, line)
    end
    local subs = state.line_subs[k]
    if subs then
      for _, sub in pairs(subs) do
        pcall(sub.on_line, line, line_offset)
      end
    end
  end, function()
    -- stream died (connection drop / node restart): reconnect with backoff
    -- if this generation is still the live one and sessions remain.
    if state.node_streams[node_name] ~= entry then
      return
    end
    vim.defer_fn(function()
      if state.node_streams[node_name] == entry then
        entry.backoff = math.min(entry.backoff * 2, 30000)
        rebuild_stream(node_name)
      end
    end, entry.backoff)
  end)
end

---@param s table discovery item
local function start_tracker(s)
  local k = key(s.node, s.path)
  if state.trackers[k] then
    return
  end
  local from = math.max(0, s.size - SEED)
  state.trackers[k] = {
    session = vim.tbl_extend("force", s, { state = "·", pending = {}, activity = "" }),
    acc = stats.new(),
    parser = transcript.parser({ start_offset = from }),
    skip_partial = s.size > SEED,
    -- bytes up to here are pre-watch history (the seed window we replay); only
    -- appends beyond it are "live" and may latch a (✓) done/unseen finish.
    live_after = s.size,
  }
end

local function drop_line_subs(k)
  for _, sub in pairs(state.line_subs[k] or {}) do
    pcall(sub.on_drop)
  end
  state.line_subs[k] = nil
end

local function reconcile(found, errored)
  errored = errored or {}
  local seen, dirty = {}, {}
  for _, s in ipairs(found) do
    local k = key(s.node, s.path)
    seen[k] = true
    if state.trackers[k] then
      state.trackers[k].session.mtime = s.mtime
      derive(state.trackers[k]) -- age-based flips (●→✗, ○→~) without new bytes
    else
      start_tracker(s)
      dirty[s.node] = true
    end
  end
  local n = require("giroux.notify")
  for k, tr in pairs(state.trackers) do
    -- drop a tracker only when its node scanned OK and the session genuinely
    -- isn't there anymore — never on a node whose scan errored (a transient
    -- ssh/find failure returns zero rows, which must not nuke live trackers).
    if not seen[k] and not errored[tr.session.node] then
      -- release this session's notification latches/badge counts; nothing else
      -- clears them once the tracker is gone (else ?/✗/✓ badges leak forever).
      n.clear("question", tr.session)
      n.clear("dead", tr.session)
      n.clear("end_of_turn", tr.session)
      dirty[tr.session.node] = true
      state.trackers[k] = nil
      drop_line_subs(k)
    end
  end
  for node_name in pairs(dirty) do
    rebuild_stream(node_name)
  end
  notify()
end

---Mark a session as reviewed: clears its done/unseen latch so a ✓ ("done")
---demotes back to ○ (idle). Called when its feed is opened. No-op for an
---untracked session or one that isn't currently done/unseen.
---@param node string
---@param path string
function M.mark_seen(node, path)
  local tr = state.trackers[key(node, path)]
  if tr and tr.done_unseen then
    tr.done_unseen = false
    derive(tr) -- recompute now so the ✓ → ○ flip + badge clear are immediate
    notify()
  end
end

---True when the monitor is live-tailing this session (so a feed can ride the
---node stream instead of opening its own channel).
---@param node string
---@param path string
---@return boolean
function M.tracks(node, path)
  return state.running and state.trackers[key(node, path)] ~= nil
end

---Subscribe to raw transcript lines for one tracked session, demuxed off the
---node's merged stream. on_line(line, offset) gives the byte offset of the
---line's start so the caller can drop lines it has already parsed. on_drop
---fires when the monitor stops tracking the session (caller should fall back
---to its own tail). Returns an unsubscribe function.
---@param node string
---@param path string
---@param on_line fun(line: string, offset: integer)
---@param on_drop fun()
---@return fun()
function M.subscribe_lines(node, path, on_line, on_drop)
  local k = key(node, path)
  local id = tostring(on_line) .. tostring(vim.uv.hrtime())
  state.line_subs[k] = state.line_subs[k] or {}
  state.line_subs[k][id] = { on_line = on_line, on_drop = on_drop }
  return function()
    if state.line_subs[k] then
      state.line_subs[k][id] = nil
      if not next(state.line_subs[k]) then
        state.line_subs[k] = nil
      end
    end
  end
end

---Subscribe to live session updates. Returns an unsubscribe function.
---@param fn fun(list: giroux.Session[])
---@return fun()
function M.subscribe(fn)
  local id = tostring(fn) .. tostring(vim.uv.hrtime())
  state.subscribers[id] = fn
  return function()
    state.subscribers[id] = nil
    if not next(state.subscribers) then
      M.stop()
    end
  end
end

---@param opts {node: string|nil}|nil
function M.start(opts)
  state.opts = opts or {}
  if state.running then
    M.discover()
    return
  end
  state.running = true
  -- seed the discovered-node cache so the first pass already includes tailnet peers
  nodes.refresh(function()
    M.discover()
  end)
  local interval = (require("giroux").config.discover_interval or 10) * 1000
  state.discover_timer = vim.uv.new_timer()
  state.discover_timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if next(state.subscribers) then
        M.discover()
      else
        M.stop()
      end
    end)
  )
end

function M.discover()
  nodes.maybe_refresh() -- async; freshens the discovered-node cache for the next tick
  sessions.list(state.opts or {}, reconcile)
  M.refresh_agents()
  M.probe_questions()
end

---Pull `claude agents --json` for every tracked node and re-derive its sessions
---with the fresh process/needs-you truth. Best-effort: a node without the
---command (older CC) just yields an empty map and the transcript heuristic
---stands. One ssh round-trip per node per tick.
function M.refresh_agents()
  local agents = require("giroux.agents")
  local seen = {}
  for _, tr in pairs(state.trackers) do
    seen[tr.session.node] = true
  end
  for node_name in pairs(seen) do
    agents.list(node_name, function(map)
      if not state.running then
        return -- a straggler landing after stop() must not resurrect the cleared map
      end
      state.agents[node_name] = map
      for _, tr in pairs(state.trackers) do
        if tr.session.node == node_name then
          derive(tr)
        end
      end
      notify()
    end)
  end
end

---Correlate every tracked session to a tmux session (steerability) and, for
---steerable ones not currently running a tool, probe the pane for a live
---AskUserQuestion (never in the transcript while pending — ARCHITECTURE).
---Cheap: tmux listing per node is cached (tmuxctl), so correlation is local
---and at most one capture-pane per steerable, idle-ish session per tick.
function M.probe_questions()
  local steer = require("giroux.steer")
  local tmuxctl = require("giroux.tmuxctl")
  local now = os.time()
  for _, tr in pairs(state.trackers) do
    local s = tr.session
    tmuxctl.target(s.node, s, function(target) -- sets s.tmux (cached listing)
      local steerable = target ~= nil
      local probeable = steerable and not next(tr.parser:pending()) and (now - (s.mtime or now)) >= 3
      if probeable or tr.question then
        steer.read_question(s, function(q)
          local was = tr.question
          tr.question = q ~= nil
          if tr.question ~= was then
            derive(tr)
          end
          notify()
        end)
      else
        notify() -- refresh the steerable marker even when not probing
      end
    end)
  end
end

function M.stop()
  state.running = false
  if state.discover_timer then
    state.discover_timer:stop()
    state.discover_timer:close()
    state.discover_timer = nil
  end
  for node_name, entry in pairs(state.node_streams) do
    if entry.stream then
      entry.stream.stop()
    end
    state.node_streams[node_name] = nil
  end
  for k in pairs(state.trackers) do
    state.trackers[k] = nil
    drop_line_subs(k)
  end
  state.agents = {}
  require("giroux.notify").reset()
end

M._state = state
return M
