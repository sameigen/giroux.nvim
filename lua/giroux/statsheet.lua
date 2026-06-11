---@module 'giroux.statsheet'
--- The stat sheet (S on a roster/feed line). Full parse of one session ->
--- giroux://stats buffer: Written / Read / Web / Spend, fugitive-status
--- shaped. Files are actionable: <CR> opens (rsync cache later; local now).

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")
local stats = require("giroux.stats")

local M = {}

local function fmt_tokens(n)
  if n >= 1e6 then
    return ("%.1fM"):format(n / 1e6)
  elseif n >= 1e3 then
    return ("%.1fk"):format(n / 1e3)
  end
  return tostring(n)
end

---Build the stat-sheet lines from a summary. Returns lines + a row->path map.
---@param sum table Acc:summary()
---@return string[] lines, table<integer,string> targets
function M.render(sum, title)
  local lines = { title or "stat sheet", "" }
  local targets = {}

  local function section(header)
    lines[#lines + 1] = header
  end
  local function file_row(path, suffix)
    lines[#lines + 1] = ("  %s%s"):format(path, suffix or "")
    targets[#lines] = path
  end

  -- Written
  local wpaths = vim.tbl_keys(sum.written)
  table.sort(wpaths)
  section(("Written (%d file%s)"):format(#wpaths, #wpaths == 1 and "" or "s"))
  for _, p in ipairs(wpaths) do
    local w = sum.written[p]
    file_row(p, ("   +%d -%d  ×%d"):format(w.add, w.del, w.n))
  end
  if #wpaths == 0 then
    lines[#lines + 1] = "  —"
  end
  lines[#lines + 1] = ""

  -- Read (context provenance), newest first
  local rpaths = vim.tbl_keys(sum.read)
  table.sort(rpaths, function(a, b)
    return sum.read[a] > sum.read[b]
  end)
  section(("Read — where context came from (%d path%s)"):format(#rpaths, #rpaths == 1 and "" or "s"))
  for _, p in ipairs(rpaths) do
    file_row(p, sum.read[p] > 1 and ("   ×%d"):format(sum.read[p]) or "")
  end
  if #rpaths == 0 then
    lines[#lines + 1] = "  —"
  end
  lines[#lines + 1] = ""

  -- Web
  if #sum.web > 0 then
    section(("Web (%d)"):format(#sum.web))
    for _, u in ipairs(sum.web) do
      lines[#lines + 1] = "  " .. u
    end
    lines[#lines + 1] = ""
  end

  -- Subagents
  if #sum.subagents > 0 then
    section(("Subagents (%d)"):format(#sum.subagents))
    for _, a in ipairs(sum.subagents) do
      local st = a.stats or {}
      lines[#lines + 1] = ("  %s  %s  (r%d w%d b%d)"):format(
        a.agent_type or "?",
        a.status or "?",
        st.readCount or 0,
        st.editFileCount or 0,
        st.bashCount or 0
      )
    end
    lines[#lines + 1] = ""
  end

  -- Spend
  local t = sum.tokens
  local total_in = t.input + t.cache_read + t.cache_creation
  local cache_ratio = total_in > 0 and (100 * t.cache_read / total_in) or 0
  section("Spend")
  lines[#lines + 1] = ("  out %s · in %s · cache-read %s (%.0f%% hit)"):format(
    fmt_tokens(t.out),
    fmt_tokens(t.input),
    fmt_tokens(t.cache_read),
    cache_ratio
  )
  lines[#lines + 1] = ("  models: %s"):format(table.concat(sum.models, ", "))
  local tool_parts = {}
  local tnames = vim.tbl_keys(sum.tools)
  table.sort(tnames, function(a, b)
    return sum.tools[a] > sum.tools[b]
  end)
  for _, name in ipairs(tnames) do
    tool_parts[#tool_parts + 1] = ("%s×%d"):format(name, sum.tools[name])
  end
  lines[#lines + 1] = "  tools: " .. table.concat(tool_parts, " ")

  return lines, targets
end

---@param opts {node: string|nil, path: string, title: string|nil}
function M.open(opts)
  local node_name, node = nodes.get(opts.node)
  assert(node, "unknown node: " .. tostring(opts.node))
  local bufname = ("giroux://stats/%s/%s"):format(node_name, vim.fs.basename(opts.path):gsub("%.jsonl$", ""))
  local buf = vim.fn.bufnr(bufname)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "giroux-stats"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  parsing " .. node_name .. "…" })
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].list = false
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].cursorline = true

  -- full parse over SSH: cat | parse locally (gauntlet: ~250MB/s)
  local acc = stats.new()
  local parser = transcript.parser()
  local strm = ssh.stream(node.host, ("cat '%s'"):format(opts.path), function(chunk)
    for _, e in ipairs(parser:feed(chunk)) do
      acc:add(e)
    end
  end, function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines, targets = M.render(acc:summary(), opts.title or vim.fs.basename(opts.path))
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.b[buf].giroux_targets = targets
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local path = (vim.b[buf].giroux_targets or {})[row]
      if path and vim.uv.fs_stat(path) then
        vim.cmd.edit(vim.fn.fnameescape(path))
      elseif path then
        vim.notify("giroux: " .. path .. " (remote open not yet wired)", vim.log.levels.INFO)
      end
    end, { buffer = buf, nowait = true, desc = "giroux: open file" })
    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, nowait = true })
  end)
  return buf, strm
end

return M
