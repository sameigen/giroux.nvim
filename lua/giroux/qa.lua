---@module 'giroux.qa'
--- The Q&A digest (:GirouxQA, or Q from feed/roster). A distilled transcript:
--- your turns and the agent's prose answers, with the tool calls between them
--- collapsed to a one-line count. Built for skimming "what did I ask 15 turns
--- ago and what came of it" without wading through tool output. <CR> on a
--- turn drops into the full feed at that point (the live/steerable surface).

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local transcript = require("giroux.transcript")

local M = {}

local ns = vim.api.nvim_create_namespace("giroux_qa")
for name, link in pairs({
  GirouxUserMsg = "Visual",
  GirouxUserSign = "Special",
  GirouxUserTag = "Comment",
  GirouxQATools = "Comment",
  GirouxQATurn = "Title",
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

local function lines_of(s)
  return vim.split(s or "", "\n", { plain = true })
end

---Group the event stream into exchanges: one per user turn, accumulating the
---agent's prose answer and a tool tally until the next turn.
---@param events giroux.transcript.Event[]
---@return table[] exchanges
function M._build(events)
  local out, cur = {}, nil
  local function flush()
    if cur then
      out[#out + 1] = cur
    end
  end
  for _, e in ipairs(events) do
    if e.kind == "user_text" then
      flush()
      cur = { user = e.text, source = e.source, answer = {}, tools = {}, tool_n = 0, ts = e.ts }
    elseif e.kind == "assistant_text" then
      cur = cur or { answer = {}, tools = {}, tool_n = 0 }
      vim.list_extend(cur.answer, lines_of(e.text))
    elseif e.kind == "tool_call" then
      if cur then
        cur.tools[e.name] = (cur.tools[e.name] or 0) + 1
        cur.tool_n = cur.tool_n + 1
      end
    elseif e.kind == "question" then
      if cur then
        cur.question = e.questions
      end
    end
  end
  flush()
  return out
end

local TOOL_SHORT = {
  Edit = "edit",
  Write = "write",
  Bash = "bash",
  Read = "read",
  WebFetch = "web",
  WebSearch = "web",
  Grep = "grep",
  Glob = "glob",
  Agent = "agent",
}

local function tool_summary(ex)
  local order, parts = {}, {}
  for name in pairs(ex.tools) do
    order[#order + 1] = name
  end
  table.sort(order, function(a, b)
    return ex.tools[a] > ex.tools[b]
  end)
  for _, name in ipairs(order) do
    parts[#parts + 1] = ("%s×%d"):format(TOOL_SHORT[name] or name:lower(), ex.tools[name])
  end
  return ("⋯ %d tool%s: %s"):format(ex.tool_n, ex.tool_n == 1 and "" or "s", table.concat(parts, " "))
end

---@return string[] lines, table[] decos, table[] turns  (turns: {row, text} 0-based)
function M._render(exchanges)
  local lines, decos, turns = {}, {}, {}
  local function add(s)
    lines[#lines + 1] = s
    return #lines - 1
  end
  for _, ex in ipairs(exchanges) do
    if #lines > 0 then
      add("")
    end
    if ex.user then
      local ulines = lines_of(ex.user)
      for i, ul in ipairs(ulines) do
        local row = add(ul)
        if i == 1 then
          decos[#decos + 1] = {
            row = row,
            sign = "▌",
            sign_hl = "GirouxUserSign",
            line_hl = "GirouxUserMsg",
            tag = ex.source == "queued" and "  you · queued" or "  you",
          }
          turns[#turns + 1] = { row = row, text = ul }
        else
          decos[#decos + 1] = { row = row, line_hl = "GirouxUserMsg" }
        end
      end
    end
    for _, al in ipairs(ex.answer) do
      add(al)
    end
    if ex.question then
      for _, q in ipairs(ex.question) do
        add("? " .. (q.question or ""))
        for i, opt in ipairs(q.options or {}) do
          add(("    %d. %s — %s"):format(i, opt.label or "?", opt.description or ""))
        end
      end
    end
    if ex.tool_n > 0 then
      decos[#decos + 1] = { row = add("  " .. tool_summary(ex)), line_hl = "GirouxQATools" }
    end
  end
  if #lines == 0 then
    add("  (no turns yet)")
  end
  return lines, decos, turns
end

local function apply(buf, lines, decos)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, d in ipairs(decos) do
    local opts = {}
    if d.line_hl then
      opts.line_hl_group = d.line_hl
    end
    if d.sign then
      opts.sign_text = d.sign
      opts.sign_hl_group = d.sign_hl
    end
    if d.tag then
      opts.virt_text = { { d.tag, "GirouxUserTag" } }
      opts.virt_text_pos = "eol"
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, d.row, 0, opts)
  end
end

---@param opts {node: string|nil, path: string, title: string|nil}
function M.open(opts)
  local node_name, node = nodes.get(opts.node)
  assert(node, "unknown node: " .. tostring(opts.node))
  local bufname = ("giroux://qa/%s/%s"):format(node_name, vim.fs.basename(opts.path):gsub("%.jsonl$", ""))
  local buf = vim.fn.bufnr(bufname)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "giroux-qa"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  distilling " .. node_name .. "…" })
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].list = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].cursorline = true
  vim.wo[win].winbar = ("Q&A · %s"):format((opts.title or vim.fs.basename(opts.path)):gsub("%%", "%%%%"))

  local parser = transcript.parser()
  local events = {}
  ssh.stream(node.host, ("cat '%s'"):format(opts.path), function(chunk)
    vim.list_extend(events, parser:feed(chunk))
  end, function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines, decos, turns = M._render(M._build(events))
    apply(buf, lines, decos)
    vim.b[buf].giroux_turns = turns

    local function turn_rows()
      local rows = {}
      for _, t in ipairs(vim.b[buf].giroux_turns or {}) do
        rows[#rows + 1] = t.row + 1
      end
      return rows
    end
    local function jump(dir)
      local rows, cur = turn_rows(), vim.api.nvim_win_get_cursor(0)[1]
      local target
      if dir > 0 then
        for _, r in ipairs(rows) do
          if r > cur then
            target = r
            break
          end
        end
      else
        for i = #rows, 1, -1 do
          if rows[i] < cur then
            target = rows[i]
            break
          end
        end
      end
      if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
        vim.cmd("normal! zt")
      end
    end
    vim.keymap.set("n", "]]", function()
      jump(1)
    end, { buffer = buf, nowait = true, desc = "giroux: next turn" })
    vim.keymap.set("n", "[[", function()
      jump(-1)
    end, { buffer = buf, nowait = true, desc = "giroux: prev turn" })
    vim.keymap.set("n", "<CR>", function()
      -- drill into the live feed at this turn
      local cur = vim.api.nvim_win_get_cursor(0)[1]
      local jump_text
      for _, t in ipairs(vim.b[buf].giroux_turns or {}) do
        if t.row + 1 <= cur then
          jump_text = t.text
        end
      end
      require("giroux.feed").open_path({ node = node_name, path = opts.path, jump_text = jump_text })
    end, { buffer = buf, nowait = true, desc = "giroux: open feed at this turn" })
    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, nowait = true })
  end)
  return buf
end

return M
