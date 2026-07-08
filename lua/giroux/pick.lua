---@module 'giroux.pick'
--- A built-in type-to-filter picker. No dependency on the user's vim.ui.select
--- backend — giroux renders its own fuzzy window, so dispatch's repo list reads
--- the same everywhere (no more "type 1 of 41"). The ranking (M.rank) is pure
--- and unit-tested; the float is a thin shell around it. M.open returns a handle
--- whose methods drive the same paths the keymaps do, so it is testable headless.

local M = {}

local MAX = 15 -- result lines shown; matches are best-first so the head is enough

---Fuzzy-rank items against a query. Empty query keeps the caller's order (which
---dispatch pre-sorts newest-first). Pure.
---@generic T
---@param items T[]
---@param query string
---@param to_str fun(item: T): string text matched against
---@return T[]
function M.rank(items, query, to_str)
  query = vim.trim(query or "")
  if query == "" then
    return items
  end
  local rows = {}
  for i, it in ipairs(items) do
    rows[#rows + 1] = { text = to_str(it), i = i }
  end
  local matched = vim.fn.matchfuzzy(rows, query, { key = "text" })
  local out = {}
  for _, r in ipairs(matched) do
    out[#out + 1] = items[r.i]
  end
  return out
end

---@class giroux.pick.Opts
---@field items any[]
---@field title string|nil
---@field format fun(item: any): string display (and match) text for an item
---@field on_choice fun(choice: any|nil) called once, after the window closes

---Open the picker. Returns a handle ({set_query, move, choose, cancel}) so the
---flow is drivable without simulating keystrokes (tests + future callers).
---@param opts giroux.pick.Opts
function M.open(opts)
  local items = opts.items or {}
  local format = opts.format or tostring
  local on_choice = opts.on_choice or function() end
  local ns = vim.api.nvim_create_namespace("giroux_pick")

  local prev_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(90, math.max(44, math.floor(vim.o.columns * 0.6)))
  local height = math.min(MAX + 1, math.max(2, #items + 1))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "select") .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = false

  local results, sel, done = items, 1, false

  local function set_title()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, {
        title = (" %s — %d/%d  ⏎ pick · esc "):format(opts.title or "select", #results, #items),
        title_pos = "left",
      })
    end
  end

  local function redraw()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    results = M.rank(items, query, format)
    sel = math.min(math.max(sel, 1), math.max(#results, 1))
    local shown = {}
    for i = 1, math.min(#results, MAX) do
      shown[i] = "  " .. format(results[i])
    end
    if #results == 0 then
      shown = { "  (no matches)" }
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, shown) -- never touch line 1 (the query)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if #results > 0 and sel <= MAX then
      vim.api.nvim_buf_set_extmark(buf, ns, sel, 0, { line_hl_group = "Visual", hl_eol = true })
    end
    set_title()
  end

  -- Single exit point. Guarded so it fires on_choice exactly once: closing the
  -- window trips BufLeave -> cancel, which must be a no-op after a real choose.
  local function finish(pick)
    if done then
      return
    end
    done = true
    M._active = nil
    pcall(vim.cmd.stopinsert)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
    on_choice(pick) -- nil = nothing chosen / cancelled
  end

  local handle = {}
  function handle.set_query(q)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { q or "" })
      sel = 1
      redraw()
    end
  end
  function handle.move(d)
    sel = sel + d
    if sel < 1 then
      sel = math.max(1, math.min(#results, MAX))
    elseif sel > math.min(#results, MAX) then
      sel = 1
    end
    redraw()
  end
  function handle.choose()
    finish(results[sel])
  end
  function handle.cancel()
    finish(nil)
  end

  local function map(lhs, fn)
    for _, mode in ipairs({ "i", "n" }) do
      vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
    end
  end
  map("<CR>", handle.choose)
  map("<Esc>", handle.cancel)
  map("<C-c>", handle.cancel)
  map("<C-n>", function()
    handle.move(1)
  end)
  map("<Down>", function()
    handle.move(1)
  end)
  map("<C-p>", function()
    handle.move(-1)
  end)
  map("<Up>", function()
    handle.move(-1)
  end)

  -- live filter as the user types on line 1
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      sel = 1
      redraw()
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = handle.cancel })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  redraw()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd.startinsert()
  M._active = handle
  return handle
end

return M
