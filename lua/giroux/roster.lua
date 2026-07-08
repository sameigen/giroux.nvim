---@module 'giroux.roster'
--- The board (:Giroux). Sessions grouped (by machine | repo | state) with what
--- needs you floated to the top of every group. Renders live off giroux.monitor
--- — every active session is tailed, so a state change (●→?→○) shows within ~1s
--- without polling. State glyphs are proofs, not guesses. `Ctrl+S` cycles the
--- grouping (the choice persists across runs); `Enter` on a group header folds it.

local monitor = require("giroux.monitor")
local vocab = require("giroux.state")

local M = {}

local GROUPINGS = { "machine", "repo", "state" }

local state = { buf = nil, items = {}, rows = {}, unsub = nil, group_by = nil, collapsed = {} }

-- Attention order/labels are single-sourced in giroux.state.
local ORDER = vocab.ORDER
local STATE_NAMES = vocab.LABEL

-- The grouping choice persists across runs (matches Anthropic's Agent View).
local function persist_path()
  local dir = vim.fn.stdpath("state") .. "/giroux"
  vim.fn.mkdir(dir, "p")
  return dir .. "/roster.json"
end

local function load_group_by()
  if not state.group_by then
    local f = io.open(persist_path(), "r")
    if f then
      local ok, data = pcall(vim.json.decode, f:read("*a"))
      f:close()
      if ok and type(data) == "table" and vim.tbl_contains(GROUPINGS, data.group_by) then
        state.group_by = data.group_by
      end
    end
    state.group_by = state.group_by or "machine"
  end
  return state.group_by
end

local function save_group_by()
  local f = io.open(persist_path(), "w")
  if f then
    f:write(vim.json.encode({ group_by = state.group_by }))
    f:close()
  end
end

local function age_str(mtime)
  local d = os.time() - (mtime or os.time())
  if d < 60 then
    return ("%ds"):format(d)
  elseif d < 3600 then
    return ("%dm"):format(math.floor(d / 60))
  end
  return ("%dh"):format(math.floor(d / 3600))
end

local function trunc(s, n)
  s = s or ""
  if vim.fn.strdisplaywidth(s) <= n then
    return s .. string.rep(" ", n - vim.fn.strdisplaywidth(s))
  end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

-- Cap subagents shown under one parent so a wide fan-out (a workflow spawning
-- many agents) can't flood the board; the overflow is summarized in one row.
-- Children are attention-sorted first, so ✗/? never hide behind the cap.
local SUBAGENT_CAP = 12

---Session id from a transcript path (<slug>/<sessionId>.jsonl).
local function sid_of(path)
  return (vim.fs.basename(path):gsub("%.jsonl$", ""))
end

---The name shown in a session's title column. Falls back off a missing
---ai-title to the opening prompt, then to a short session id — never the raw
---UUID basename (a titleless session used to read as opaque hex noise).
---@param it giroux.Session
local function display_title(it)
  if it.title and it.title ~= "" then
    return it.title
  end
  if it.last_prompt and it.last_prompt ~= "" then
    return it.last_prompt
  end
  return sid_of(it.path):sub(1, 8)
end

---@param it giroux.Session
local function repo_of(it)
  return vim.fs.basename(it.project or it.path or "") or "?"
end

---@param it giroux.Session
---@param group_by string
local function group_key(it, group_by)
  if group_by == "machine" then
    return it.node or "?"
  elseif group_by == "repo" then
    return repo_of(it)
  end
  return STATE_NAMES[it.state] or "?"
end

-- context usage past this threshold is worth flagging on the roster — Claude
-- Code auto-compacts well above it, so this is an early warning, not a
-- crisis. Tune here if it's too chatty/quiet in practice.
local CTX_HIGH_PCT = 70

---One session line, indented under its group; the grouping dimension's own
---column is dropped (redundant under the header).
---@param it giroux.Session
---@param hide string|nil "node" | "project" | nil
function M._line(it, hide)
  local info
  if it.state == "?" and it.waiting_for and it.waiting_for ~= "" then
    info = "waiting: " .. it.waiting_for
  elseif #(it.pending or {}) > 0 then
    info = "busy: " .. table.concat(it.pending, ", ")
  elseif it.todos then
    -- the todo panel is a higher-signal "what's actually happening" than raw
    -- tool-call tallies, so it takes the activity/last_prompt tier's slot.
    info = ("todos %d/%d"):format(it.todos.done or 0, it.todos.total or 0)
    if it.todos.current and it.todos.current ~= "" then
      info = info .. " · " .. it.todos.current
    end
  elseif it.activity and it.activity ~= "" then
    info = it.activity
    if it.touched then
      info = info .. "  " .. vim.fn.fnamemodify(it.touched, ":t")
    end
  else
    info = it.last_prompt and ("> " .. it.last_prompt) or ""
  end
  -- ▸ = steerable (a live tmux session giroux can attach/answer); blank =
  -- observe-only (no correlated tmux — a hand-started raw claude or a dead one).
  local ctl = it.tmux and "▸" or " "
  local cols = { it.state .. ctl }
  if hide ~= "node" then
    cols[#cols + 1] = trunc(it.node, 8)
  end
  if hide ~= "project" then
    cols[#cols + 1] = trunc(it.project, 22)
  end
  cols[#cols + 1] = trunc(display_title(it), 34)
  cols[#cols + 1] = ("%4s"):format(age_str(it.mtime))
  cols[#cols + 1] = trunc(info, 44)
  -- compact badges, appended un-truncated (never swallowed by the info
  -- column's 44-char cap): queued input count, permission mode (plan
  -- especially — a session sitting in plan mode is effectively waiting on
  -- the human even though nothing in the transcript proves it, so it's
  -- flagged even though its state glyph stays whatever's actually proven),
  -- context usage. "default"/"bypassPermissions" (the common case — DESIGN
  -- §2's default launch flag) get no badge: badges are for the modes that
  -- are a deviation worth a second look.
  local badges = {}
  if it.queued and it.queued > 0 then
    badges[#badges + 1] = "⧗" .. it.queued
  end
  if it.mode == "plan" then
    badges[#badges + 1] = "PLAN"
  elseif it.mode == "acceptEdits" then
    badges[#badges + 1] = "edits"
  elseif it.mode == "auto" then
    badges[#badges + 1] = "auto"
  end
  if it.ctx_pct and it.ctx_pct >= CTX_HIGH_PCT then
    badges[#badges + 1] = ("ctx%d%%"):format(it.ctx_pct)
  end
  if #badges > 0 then
    cols[#cols + 1] = table.concat(badges, " ")
  end
  return "  " .. table.concat(cols, " ")
end

---A subagent row, nested under its parent session: ⤷ marker, state glyph,
---agent type, and the task it was dispatched with.
---@param it giroux.Session
function M._subline(it)
  local typ = it.agent_type or "agent"
  local desc = it.title or it.description or it.last_prompt
  if not desc or desc == "" then
    desc = it.agent_id and ("agent-" .. it.agent_id:sub(1, 8)) or "subagent"
  end
  local cols = {
    it.state .. " ",
    trunc(typ, 15),
    trunc(desc, 38),
    ("%4s"):format(age_str(it.mtime)),
  }
  return "     ⤷ " .. table.concat(cols, " ")
end

local function by_attention(a, b)
  local oa, ob = ORDER[a.state] or 9, ORDER[b.state] or 9
  if oa ~= ob then
    return oa < ob
  end
  return (a.mtime or 0) > (b.mtime or 0)
end

---Build the grouped display: lines + a per-line row map (kind=title|header|item).
---Pure (no buffer), so it is unit-tested directly.
---@param items giroux.Session[]
---@param group_by string
---@param collapsed table<string, boolean>
---@return {lines: string[], rows: table[]}
function M.build(items, group_by, collapsed)
  collapsed = collapsed or {}
  local lines, rows = {}, {}
  local function emit(line, row)
    lines[#lines + 1] = line
    rows[#lines] = row
  end

  -- Partition into top-level sessions (parents) and subagents. A subagent nests
  -- under its parent by (node, parent session id); an orphan whose parent isn't
  -- in the active window is promoted to a top-level row so it's never lost.
  local parents, index, children = {}, {}, {}
  for _, it in ipairs(items) do
    if not it.is_subagent then
      parents[#parents + 1] = it
      index[it.node .. "\0" .. sid_of(it.path)] = it
    end
  end
  for _, it in ipairs(items) do
    if it.is_subagent then
      local pk = it.node .. "\0" .. (it.parent_id or "")
      if index[pk] then
        children[pk] = children[pk] or {}
        table.insert(children[pk], it)
      else
        parents[#parents + 1] = it
        index[it.node .. "\0" .. sid_of(it.path)] = it
      end
    end
  end
  local function kids(it)
    return children[it.node .. "\0" .. sid_of(it.path)]
  end

  local needs, done = 0, 0
  for _, it in ipairs(items) do
    if it.state == "?" then
      needs = needs + 1
    elseif it.state == "✓" then
      done = done + 1
    end
  end
  emit(
    ("giroux · %d session%s · needs you: %d%s · by %s · %s"):format(
      #parents,
      #parents == 1 and "" or "s",
      needs,
      done > 0 and (" · done: " .. done) or "",
      group_by,
      os.date("%H:%M:%S")
    ),
    { kind = "title" }
  )
  emit("", { kind = "blank" })

  -- bucket parents, then sort within each bucket attention-first
  local groups, order = {}, {}
  for _, it in ipairs(parents) do
    local k = group_key(it, group_by)
    if not groups[k] then
      groups[k] = {}
      order[#order + 1] = k
    end
    groups[k][#groups[k] + 1] = it
  end
  for _, k in ipairs(order) do
    table.sort(groups[k], by_attention)
  end

  -- a group's lead glyph + rank consider its parents AND their subagents, so an
  -- asking/dead subagent floats its group up and shows on the folded header.
  local function group_lead(k)
    local rank, glyph = 9, groups[k][1] and groups[k][1].state or "·"
    local function consider(s)
      local r = ORDER[s.state] or 9
      if r < rank then
        rank, glyph = r, s.state
      end
    end
    for _, it in ipairs(groups[k]) do
      consider(it)
      for _, c in ipairs(kids(it) or {}) do
        consider(c)
      end
    end
    return glyph, rank
  end
  table.sort(order, function(a, b)
    local _, ra = group_lead(a)
    local _, rb = group_lead(b)
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)

  local hide = (group_by == "machine" and "node") or (group_by == "repo" and "project") or nil
  for _, k in ipairs(order) do
    local g = groups[k]
    -- header counts fold in subagents so the badge reflects everything the group
    -- holds (a needs-you/dead subagent counts even when the group is collapsed).
    local q, dead, done_n = 0, 0, 0
    local function tally(it)
      if it.state == "?" then
        q = q + 1
      elseif it.state == "✗" then
        dead = dead + 1
      elseif it.state == "✓" then
        done_n = done_n + 1
      end
    end
    for _, it in ipairs(g) do
      tally(it)
      for _, c in ipairs(kids(it) or {}) do
        tally(c)
      end
    end
    local badge = (q > 0 and ("  ?%d"):format(q) or "")
      .. (dead > 0 and (" ✗%d"):format(dead) or "")
      .. (done_n > 0 and (" ✓%d"):format(done_n) or "")
    -- namespace the fold key by grouping mode so folding repo "loper" doesn't
    -- also fold a machine named "loper" after a Ctrl+S regroup.
    local ckey = group_by .. "\0" .. k
    local folded = collapsed[ckey] == true
    local lead = group_lead(k)
    emit(
      ("%s %s %s (%d)%s"):format(folded and "▸" or "▾", lead, k, #g, badge),
      { kind = "header", group = k, ckey = ckey }
    )
    if not folded then
      for _, it in ipairs(g) do
        emit(M._line(it, hide), { kind = "item", item = it })
        local cs = kids(it)
        if cs then
          table.sort(cs, by_attention)
          for i, c in ipairs(cs) do
            if i > SUBAGENT_CAP then
              emit(("       ⤷ …+%d more"):format(#cs - SUBAGENT_CAP), { kind = "more" })
              break
            end
            emit(M._subline(c), { kind = "item", item = c })
          end
        end
      end
    end
  end
  return { lines = lines, rows = rows }
end

local function clean_window()
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].list = false
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
end

local function render(items, errs)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  state.items = items
  local r = M.build(items, state.group_by or "machine", state.collapsed)
  for node, err in pairs(errs or {}) do
    r.lines[#r.lines + 1] = ("ERR %s: %s"):format(node, err)
    r.rows[#r.lines] = { kind = "err" }
  end
  state.rows = r.rows
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, r.lines)
  vim.bo[state.buf].modifiable = false
end

local function row_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.rows[row]
end

local function item_at_cursor()
  local r = row_at_cursor()
  return r and r.kind == "item" and r.item or nil
end

-- Steering acts on a live tmux session; a subagent has none (it runs inside its
-- parent). Gate the steering verbs so they explain rather than fail silently.
-- Feed/stats/digest still work on a subagent — those just read its transcript.
local function steerable_at_cursor(verb)
  local it = item_at_cursor()
  if it and it.is_subagent then
    vim.notify("giroux: subagents are observe-only — can't " .. verb, vim.log.levels.INFO)
    return nil
  end
  return it
end

function M.refresh()
  monitor.discover() -- force a discovery pass; live tails handle the rest
end

local function stop_heartbeat()
  if state.tick then
    state.tick:stop()
    state.tick:close()
    state.tick = nil
  end
end

-- Re-render on a timer so the clock + age columns stay live even when no
-- session data is changing. Without this the board only repaints on a monitor
-- data event (the discovery tick), so a quiet roster *looks* frozen — the
-- feel-stale bug. Pure-cheap: it just rebuilds the cached items locally.
local function start_heartbeat()
  stop_heartbeat()
  local secs = require("giroux").config.refresh_interval or 0
  if secs <= 0 then
    return
  end
  state.tick = vim.uv.new_timer()
  state.tick:start(
    secs * 1000,
    secs * 1000,
    vim.schedule_wrap(function()
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        render(state.items, {})
      else
        stop_heartbeat()
      end
    end)
  )
end

local function teardown()
  if state.unsub then
    state.unsub()
    state.unsub = nil
  end
  stop_heartbeat()
end

---@param arg string|nil node filter
function M.open(arg)
  local cfg = require("giroux").config
  local opts = arg and arg ~= "" and { node = arg } or {}
  load_group_by()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_set_current_buf(state.buf)
    M.refresh()
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.api.nvim_buf_set_name(buf, "giroux://roster")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "giroux-roster"

  local km = cfg.keymaps.roster
  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "giroux: " .. desc })
    end
  end
  -- <CR>: open the feed on a session, or fold/unfold a group header
  map(km.open_feed, function()
    local r = row_at_cursor()
    if not r then
      return
    end
    if r.kind == "header" then
      state.collapsed[r.ckey] = not state.collapsed[r.ckey]
      render(state.items, {})
    elseif r.kind == "item" then
      require("giroux.feed").open_path({ node = r.item.node, path = r.item.path })
    end
  end, "open feed / fold group")
  map(km.regroup or "<C-s>", function()
    local idx = 1
    for n, g in ipairs(GROUPINGS) do
      if g == state.group_by then
        idx = n
      end
    end
    state.group_by = GROUPINGS[idx % #GROUPINGS + 1]
    save_group_by()
    render(state.items, {})
    vim.notify("giroux: grouped by " .. state.group_by)
  end, "cycle grouping")
  map(km.refresh, function()
    vim.notify("giroux: refreshing…") -- instant feedback; discover() is async
    M.refresh()
  end, "refresh")
  map(km.stats or "S", function()
    local it = item_at_cursor()
    if it then
      require("giroux.statsheet").open({ node = it.node, path = it.path, title = it.title })
    end
  end, "stat sheet")
  map(km.qa or "Q", function()
    local it = item_at_cursor()
    if it then
      require("giroux.qa").open({ node = it.node, path = it.path, title = it.title })
    end
  end, "Q&A digest")
  map(km.close, function()
    teardown()
    vim.api.nvim_buf_delete(buf, { force = true })
    state.buf = nil
  end, "close")
  map(km.dispatch, function()
    require("giroux.dispatch").open({})
  end, "dispatch a new agent")
  map(km.attach, function()
    local it = steerable_at_cursor("attach")
    if it then
      require("giroux.steer").attach(it)
    end
  end, "attach (tmux)")
  map(km.steer, function()
    local it = steerable_at_cursor("steer")
    if it then
      require("giroux.steer").buffer(it)
    end
  end, "steer (compose + send)")
  map(km.resume, function()
    local it = steerable_at_cursor("resume")
    if it then
      require("giroux.dispatch").resume(it.node, it)
    end
  end, "resume from transcript")
  for key, what in pairs({ kill = "kill", diff = "diff" }) do
    map(km[key], function()
      vim.notify(("giroux: %s lands later"):format(what), vim.log.levels.INFO)
    end, what .. " (soon)")
  end
  map(km.help, function()
    vim.notify(
      "⏎ feed / fold · ^S regroup · n dispatch · a attach · s steer · R resume · S stats · Q digest · r refresh · q close"
        .. "  ·  ▸ = steerable, blank = observe-only  ·  ⤷ = subagent  ·  ✓ = done (finished, unreviewed)"
        .. "  ·  ⧗N = N queued inputs  ·  PLAN/edits/auto = permission mode  ·  ctxNN% = context usage (high)",
      vim.log.levels.INFO
    )
  end, "help")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      teardown()
      state.buf = nil
    end,
  })

  vim.api.nvim_set_current_buf(buf)
  clean_window()
  vim.api.nvim_create_autocmd("BufWinEnter", { buffer = buf, callback = clean_window })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "giroux · scanning nodes…" })
  vim.bo[buf].modifiable = false

  -- Render live off the monitor: every active session is tailed, so the board
  -- reflects state changes within ~1s without a poll loop.
  state.unsub = monitor.subscribe(function(items)
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      render(items, {})
    end
  end)
  monitor.start(opts)
  start_heartbeat()
end

M._state = state
return M
