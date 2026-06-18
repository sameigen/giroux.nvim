---@module 'giroux.roster'
--- The board (:Giroux). Sessions grouped (by machine | repo | state) with what
--- needs you floated to the top of every group. Renders live off giroux.monitor
--- — every active session is tailed, so a state change (●→?→○) shows within ~1s
--- without polling. State glyphs are proofs, not guesses. `Ctrl+S` cycles the
--- grouping (the choice persists across runs); `Enter` on a group header folds it.

local monitor = require("giroux.monitor")

local M = {}

local GROUPINGS = { "machine", "repo", "state" }

local state = { buf = nil, items = {}, rows = {}, unsub = nil, group_by = nil, collapsed = {} }

local ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["○"] = 4, ["~"] = 5, ["·"] = 6 }
local STATE_NAMES =
  { ["?"] = "needs you", ["●"] = "working", ["○"] = "idle", ["✗"] = "dead", ["~"] = "stale", ["·"] = "starting" }

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
  cols[#cols + 1] = trunc(it.title or vim.fs.basename(it.path), 34)
  cols[#cols + 1] = ("%4s"):format(age_str(it.mtime))
  cols[#cols + 1] = trunc(info, 44)
  return "  " .. table.concat(cols, " ")
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

  local needs = 0
  for _, it in ipairs(items) do
    if it.state == "?" then
      needs = needs + 1
    end
  end
  emit(
    ("giroux · %d session%s · needs you: %d · by %s · %s"):format(
      #items,
      #items == 1 and "" or "s",
      needs,
      group_by,
      os.date("%H:%M:%S")
    ),
    { kind = "title" }
  )
  emit("", { kind = "blank" })

  -- bucket, then sort within each bucket attention-first
  local groups, order = {}, {}
  for _, it in ipairs(items) do
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
  -- order groups by their most-urgent member (groups[k][1] after the sort), then name
  table.sort(order, function(a, b)
    local ua = ORDER[groups[a][1].state] or 9
    local ub = ORDER[groups[b][1].state] or 9
    if ua ~= ub then
      return ua < ub
    end
    return a < b
  end)

  local hide = (group_by == "machine" and "node") or (group_by == "repo" and "project") or nil
  for _, k in ipairs(order) do
    local g = groups[k]
    local q, dead = 0, 0
    for _, it in ipairs(g) do
      if it.state == "?" then
        q = q + 1
      elseif it.state == "✗" then
        dead = dead + 1
      end
    end
    local badge = (q > 0 and ("  ?%d"):format(q) or "") .. (dead > 0 and (" ✗%d"):format(dead) or "")
    -- namespace the fold key by grouping mode so folding repo "loper" doesn't
    -- also fold a machine named "loper" after a Ctrl+S regroup.
    local ckey = group_by .. "\0" .. k
    local folded = collapsed[ckey] == true
    emit(("%s %s (%d)%s"):format(folded and "▸" or "▾", k, #g, badge), { kind = "header", group = k, ckey = ckey })
    if not folded then
      for _, it in ipairs(g) do
        emit(M._line(it, hide), { kind = "item", item = it })
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

function M.refresh()
  monitor.discover() -- force a discovery pass; live tails handle the rest
end

local function teardown()
  if state.unsub then
    state.unsub()
    state.unsub = nil
  end
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
    local it = item_at_cursor()
    if it then
      require("giroux.steer").attach(it)
    end
  end, "attach (tmux)")
  map(km.steer, function()
    local it = item_at_cursor()
    if it then
      require("giroux.steer").buffer(it)
    end
  end, "steer (compose + send)")
  map(km.resume, function()
    local it = item_at_cursor()
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
        .. "  ·  ▸ = steerable, blank = observe-only",
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
end

M._state = state
return M
