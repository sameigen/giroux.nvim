---@module 'giroux.roster'
--- The board (:Giroux). One buffer, one session per line, sorted so what
--- needs you floats to the top. Renders live off giroux.monitor — every
--- active session is tailed, so a state change (●→?→○) shows within ~1s
--- without polling. State glyphs are proofs, not guesses.

local monitor = require("giroux.monitor")

local M = {}

local state = { buf = nil, items = {}, unsub = nil }

local function age_str(mtime)
  local d = os.time() - mtime
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
function M._line(it)
  local info
  if #it.pending > 0 then
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
  -- observe-only (no correlated tmux — a hand-started raw claude or a dead
  -- one). `R` resumes the latter from its transcript.
  local ctl = it.tmux and "▸" or " "
  return ("%s%s %-8s %-22s %-34s %4s  %s"):format(
    it.state,
    ctl,
    trunc(it.node, 8),
    trunc(it.project, 22),
    trunc(it.title or vim.fs.basename(it.path), 34),
    age_str(it.mtime),
    trunc(info, 44)
  )
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
  local lines = { ("giroux · %d session%s · %s"):format(#items, #items == 1 and "" or "s", os.date("%H:%M:%S")) }
  for _, it in ipairs(items) do
    lines[#lines + 1] = M._line(it)
  end
  for node, err in pairs(errs or {}) do
    lines[#lines + 1] = ("ERR %s: %s"):format(node, err)
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function item_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.items[row - 1] -- line 1 is the header
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
  map(km.open_feed, function()
    local it = item_at_cursor()
    if it then
      require("giroux.feed").open_path({ node = it.node, path = it.path })
    end
  end, "open feed")
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
      "⏎ feed · n dispatch · a attach · s steer · R resume (dead) · S stats · Q digest · r refresh · q close"
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

  -- Render live off the monitor: every active session is tailed, so the
  -- board reflects state changes within ~1s without a poll loop.
  state.unsub = monitor.subscribe(function(items)
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      render(items, {})
    end
  end)
  monitor.start(opts)
end

M._state = state
return M
