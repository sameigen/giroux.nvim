---@module 'giroux.steer'
--- The steering plane on tmuxctl correlation: send, buffer (compose split),
--- attach (TUI in a terminal tab), answer/pick (answer-pick off the pane).
--- Uncorrelated sessions degrade to observe-only. See PLAN.md §4.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local tmuxctl = require("giroux.tmuxctl")

local M = {}

---@param s string
---@return string
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---Shell command that types `text` into a tmux session's input box and
---submits it. Multiline-safe: the text travels base64 through paste-buffer,
---so nothing is interpreted as keys. The `=`-pinned target is non-negotiable:
---tmux -t prefix-matches otherwise, and a renamed sibling session sharing a
---name prefix would receive the keys. Exposed for tests.
---@param target string tmux session name
---@param text string
---@return string
function M.send_cmd(target, text)
  local b64 = vim.base64.encode(text)
  local t = shq(tmuxctl.exact(target))
  return ("printf '%%s' %s | base64 -d | tmux load-buffer -b giroux-steer - && tmux paste-buffer -d -b giroux-steer -t %s && tmux send-keys -t %s Enter"):format(
    shq(b64),
    t,
    t
  )
end

---Resolve a roster/feed session to its tmux target, or explain why not.
---Always re-resolves (snapshot + agents map are cached, so this is cheap):
---a remembered it.tmux can be stale after a rename/kill, and keys must only
---ever go to a pane proven to belong to this transcript RIGHT NOW.
---@param it giroux.Session
---@param cb fun(target: string|nil)
function M.resolve(it, cb)
  tmuxctl.target(it.node, it, function(target)
    if not target then
      vim.notify(
        "giroux: no tmux session correlates — observe-only (start sessions via the claude wrapper or :GirouxDispatch)",
        vim.log.levels.WARN
      )
    end
    cb(target)
  end)
end

---Queue a message into a session.
---@param it giroux.Session
---@param text string
---@param after fun()|nil
function M.send(it, text, after)
  M.resolve(it, function(target)
    if not target then
      return
    end
    local _, node = nodes.get(it.node)
    ssh.exec(node.host, ssh.login_wrap(M.send_cmd(target, text)), function(ok, _, stderr)
      if not ok then
        return vim.notify("giroux: send failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
      end
      vim.notify(("giroux: sent to %s"):format(target))
      if after then
        after()
      end
    end)
  end)
end

---Parse a captured tmux pane for a live AskUserQuestion picker. Returns the
---question text and numbered options, or nil. The transcript can't supply
---this — Claude Code writes an AskUserQuestion record only once it's been
---answered (verified: 24/24 corpus records resolved) — so a *pending*
---question exists only on screen. `AskUserQuestion` now sends an ARRAY of
---questions, each independently multiSelect; this also reports `multi_select`
---and, when the TUI shows a "Question N of M" progress marker, `index`/
---`total` — additive, `nil`/`false` for the common single-question case, so
---the `{question, options}` shape callers key on (`monitor.probe_questions`'
---`q ~= nil` check) is unchanged. NOTE: the multiSelect checkbox glyphs and
---the "Question N of M" wording below are inferred from the plan's chrome
---description, not a captured live pane (none was available — see plan 05
---Step 4 STOP); confirm against a real multiSelect/multi-question pane before
---trusting this in production. Exposed for tests.
---@param pane string tmux capture-pane output
---@return {question: string, options: {n: integer, label: string}[], multi_select: boolean, index: integer|nil, total: integer|nil}|nil
function M.parse_question(pane)
  local lines = vim.split(pane, "\n", { plain = true })
  -- anchor on the picker footer; everything above it up to the question is
  -- the picker. Numbered *prose* the agent wrote sits further up and must
  -- not be mistaken for options. A multiSelect footer swaps "Enter to select"
  -- for "Space to select"/"confirm" wording but keeps "to navigate", so the
  -- anchor still finds it.
  local footer
  for i = #lines, 1, -1 do
    if lines[i]:find("Enter to select", 1, true) or lines[i]:find("to navigate", 1, true) then
      footer = i
      break
    end
  end
  if not footer then
    return nil
  end

  -- multi-question progress marker ("Question 1 of 2"). Independent of the
  -- footer-anchored option scan below since its on-screen position isn't
  -- pinned; nil/nil (unchanged) when it's not present, i.e. the common
  -- single-question case.
  local index, total
  for _, raw in ipairs(lines) do
    local i, t = raw:match("[Qq]uestion%s+(%d+)%s+of%s+(%d+)")
    if i then
      index, total = tonumber(i), tonumber(t)
      break
    end
  end

  ---@param raw string
  ---@return integer?, string?
  local function as_option(raw)
    -- strip the single-select cursor and the multiSelect checkbox/radio glyphs
    local line = raw:gsub("❯", ""):gsub(">", ""):gsub("☐", ""):gsub("☑", ""):gsub("◯", ""):gsub("●", "")
    local n, label = line:match("^%s*(%d+)%.%s+(.+)$")
    return n and tonumber(n), label and vim.trim(label)
  end

  ---@param raw string
  ---@return boolean
  local function has_checkbox(raw)
    return raw:find("☐", 1, true) ~= nil
      or raw:find("☑", 1, true) ~= nil
      or raw:find("◯", 1, true) ~= nil
      or raw:find("●", 1, true) ~= nil
  end

  -- footer wording is one multiSelect signal; a checkbox/radio glyph on an
  -- actual option row (below) is the other, and wins even if the footer
  -- didn't say so.
  local multi_select = lines[footer]:find("Space to select", 1, true) ~= nil
    or lines[footer]:find("select multiple", 1, true) ~= nil

  local options, question = {}, nil
  local gap = 0 -- consecutive non-option lines (descriptions/rules) tolerated
  for i = footer - 1, 1, -1 do
    local raw = lines[i]
    local n, label = as_option(raw)
    local is_rule = raw:match("^%s*[─%-]+%s*$") ~= nil
    if n then
      options[#options + 1] = { n = n, label = label }
      if has_checkbox(raw) then
        multi_select = true -- checkbox/radio glyph on an option row = multiSelect
      end
      gap = 0
    elseif raw:match("☐") then
      break -- the header chip caps the top of the picker
    elseif #options > 0 and vim.trim(raw) ~= "" and not is_rule and not raw:match("^%s") then
      -- first flush-left, non-rule, non-option line after options began:
      -- that's the question text.
      question = vim.trim(raw)
      break
    else
      gap = gap + 1 -- descriptions, rules, blanks within the picker
      if gap > 6 then
        break -- drifted out of the picker block
      end
    end
  end
  if #options == 0 then
    return nil
  end
  table.sort(options, function(a, b)
    return a.n < b.n
  end)
  return { question = question or "?", options = options, multi_select = multi_select, index = index, total = total }
end

---Read the live question off a session's tmux pane (on-demand, one capture).
---Silent: no correlation warning (used by the monitor's probe loop too).
---@param it giroux.Session
---@param cb fun(q: {question: string, options: {n: integer, label: string}[], multi_select: boolean, index: integer|nil, total: integer|nil}|nil)
function M.read_question(it, cb)
  local target = it.tmux
  local function with_target(t)
    if not t then
      return cb(nil)
    end
    local _, node = nodes.get(it.node)
    local cmd = ("tmux capture-pane -p -t %s 2>/dev/null"):format(shq(tmuxctl.exact(t)))
    ssh.exec(node.host, ssh.login_wrap(cmd), function(ok, stdout)
      cb(ok and M.parse_question(stdout) or nil)
    end)
  end
  if target then
    return with_target(target)
  end
  tmuxctl.target(it.node, it, with_target) -- silent correlation
end

---Answer an open AskUserQuestion by option number: the TUI selects
---instantly on a bare digit (verified against the real picker).
---@param it giroux.Session
---@param digit string|integer 1-9
function M.answer(it, digit)
  M.resolve(it, function(target)
    if not target then
      return
    end
    local _, node = nodes.get(it.node)
    ssh.exec(
      node.host,
      ssh.login_wrap(("tmux send-keys -t %s %s"):format(shq(tmuxctl.exact(target)), tostring(digit))),
      function(ok, _, stderr)
        if not ok then
          return vim.notify("giroux: answer failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
        end
        vim.notify(("giroux: answered option %s on %s"):format(digit, target))
      end
    )
  end)
end

---Answer an open multiSelect AskUserQuestion by toggling each chosen option
---then submitting. BEST-EFFORT / UNVERIFIED (plan 05 Step 4 STOP): no live
---multiSelect pane was available to capture, so this key sequence is inferred
---rather than confirmed — it mirrors single-select's "bare digit selects" by
---sending each chosen digit in turn (assuming a bare digit toggles that row in
---a multiSelect picker) then Enter to submit. Confirm against a real
---multiSelect picker before relying on this; until then it may mis-answer or
---only partly answer the prompt.
---@param it giroux.Session
---@param digits (string|integer)[] option numbers to toggle on, in any order
function M.answer_multi(it, digits)
  M.resolve(it, function(target)
    if not target then
      return
    end
    local _, node = nodes.get(it.node)
    local keys, shown = {}, {}
    for _, d in ipairs(digits) do
      keys[#keys + 1] = tostring(d)
      shown[#shown + 1] = tostring(d)
    end
    keys[#keys + 1] = "Enter"
    ssh.exec(
      node.host,
      ssh.login_wrap(("tmux send-keys -t %s %s"):format(shq(tmuxctl.exact(target)), table.concat(keys, " "))),
      function(ok, _, stderr)
        if not ok then
          return vim.notify("giroux: answer failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
        end
        vim.notify(("giroux: answered options %s on %s"):format(table.concat(shown, ","), target))
      end
    )
  end)
end

---Drive a multiSelect picker: pick.lua's `on_choice` is single-shot, so
---toggling reopens it with a running "chosen" set, plus a trailing submit
---row, until the user submits. BEST-EFFORT (plan 05 Step 4 STOP): this UI
---loop itself is plain giroux.pick usage (safe), but what it sends on submit
---(`M.answer_multi`) is unverified against the real TUI.
---@param it giroux.Session
---@param q {question: string, options: {n: integer, label: string}[]}
---@param chosen table<integer, boolean>
---@param on_done fun()|nil called after an answer is sent (question-walk continuation)
local function pick_multi(it, q, chosen, on_done)
  local items = {}
  for _, o in ipairs(q.options) do
    items[#items + 1] = o
  end
  local submit = { is_submit = true }
  items[#items + 1] = submit
  require("giroux.pick").open({
    items = items,
    title = q.question .. " — toggle, then Submit",
    format = function(o)
      if o.is_submit then
        return "» Submit selection"
      end
      return ("[%s] %d. %s"):format(chosen[o.n] and "x" or " ", o.n, o.label)
    end,
    on_choice = function(o)
      if not o then
        return
      end
      if o.is_submit then
        local digits = {}
        for n in pairs(chosen) do
          digits[#digits + 1] = n
        end
        table.sort(digits)
        if #digits == 0 then
          return vim.notify("giroux: no options selected, nothing sent", vim.log.levels.WARN)
        end
        M.answer_multi(it, digits)
        if on_done then
          on_done()
        end
        return
      end
      chosen[o.n] = not chosen[o.n] or nil -- toggle
      pick_multi(it, q, chosen, on_done) -- reopen: toggle another, or submit
    end,
  })
end

---Answer-pick entry: read the live question off the pane and let the user
---pick option(s) (the built-in picker), then send the answer.
---`AskUserQuestion` now sends an array of questions: when the pane reports
---`total > 1`, answering re-reads the pane and walks to the next question,
---bailing once `total` questions have been answered or the pane no longer
---parses one (guards a stuck TUI / a bad `total`). The single-question,
---single-select path is byte-identical to before this plan: open the picker,
---send one digit via `M.answer`. BEST-EFFORT beyond that (plan 05 Step 4
---STOP): the re-capture timing for the multi-question walk and the
---multiSelect submit are unverified against a live pane — see
---`M.answer_multi`.
---@param it giroux.Session
---@param _seen integer|nil questions answered so far in this walk (internal; omit)
function M.pick(it, _seen)
  local seen = (_seen or 0) + 1
  M.read_question(it, function(q)
    if not q then
      if _seen then
        return -- mid-walk: pane no longer shows a question, the walk is over
      end
      return vim.notify("giroux: no live question on this session's screen", vim.log.levels.WARN)
    end
    local function continue_walk()
      if q.total and q.total > 1 and seen < q.total then
        -- best-effort: give the TUI a beat to redraw the next question
        vim.defer_fn(function()
          M.pick(it, seen)
        end, 150)
      end
    end
    if q.multi_select then
      pick_multi(it, q, {}, continue_walk)
      return
    end
    require("giroux.pick").open({
      items = q.options,
      title = q.question,
      format = function(o)
        return ("%d. %s"):format(o.n, o.label)
      end,
      on_choice = function(o)
        if o then
          M.answer(it, o.n)
          continue_walk()
        end
      end,
    })
  end)
end

---Steer buffer: compose in a scratch split, :w sends, :q aborts.
---@param it giroux.Session
function M.buffer(it)
  M.resolve(it, function(target)
    if not target then
      return
    end
    vim.cmd("botright 10split")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, "giroux://steer/" .. target)
    vim.wo[0].winbar = "%#Title#steer → " .. target .. "%#Comment#  — :w sends, :q aborts"
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        vim.bo[buf].modified = false
        vim.api.nvim_win_close(0, true)
        if vim.trim(text) == "" then
          return vim.notify("giroux: empty message, not sent", vim.log.levels.WARN)
        end
        M.send(it, text)
      end,
    })
    vim.cmd.startinsert()
  end)
end

---Terminal-mode keymaps for an attached session. Pure data so it is testable.
---<C-z> is deliberately NOT mapped: now that giroux launches claude as a job in
---an interactive shell, ^Z suspends claude to that shell (for a remote session,
---a shell ON that machine) where you can work and `fg` back — so we let it pass
---straight through to the pane. <C-q> drops to nvim normal mode to browse the
---terminal scrollback and visual-select → y to copy (the path tmux's nested
---mouse copy-mode fights), then `i` resumes. <Esc> belongs to the agent.
---@return {lhs: string, rhs: string, desc: string}[]
function M.attach_keymaps()
  return {
    { lhs = "<Esc>", rhs = "<Esc>", desc = "Esc belongs to the agent (interrupt / rewind)" },
    { lhs = "<C-q>", rhs = "<C-\\><C-n>", desc = "leave terminal mode — scroll/copy, then i to resume" },
  }
end

---Close the attach terminal's own window(s) and return to the board. Close by
---window handle — do NOT convert a tabpage handle to a tab number (they
---diverge as tabs are opened/closed elsewhere); nvim_win_close on the
---terminal's last window drops its tab too. Exposed for tests.
---@param buf integer
function M._close_own_tab(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

---Attach the real TUI in a terminal tab. Esc belongs to the agent; C-z suspends
---claude to a shell (do work, `fg` to resume); C-q → nvim normal mode (scroll +
---copy, i resumes); C-b d detaches.
---@param it giroux.Session
function M.attach(it)
  M.resolve(it, function(target)
    if not target then
      return
    end
    local _, node = nodes.get(it.node)
    local cmd
    if node.host then
      cmd = { "ssh", "-t", node.host, ssh.login_wrap(("tmux attach-session -t %s"):format(shq(tmuxctl.exact(target)))) }
    else
      cmd = { "tmux", "attach-session", "-t", tmuxctl.exact(target) }
    end
    vim.cmd.tabnew()
    local buf = vim.api.nvim_get_current_buf()
    for _, m in ipairs(M.attach_keymaps()) do
      vim.keymap.set("t", m.lhs, m.rhs, { buffer = buf, desc = "giroux: " .. m.desc })
    end
    vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        vim.schedule(function()
          M._close_own_tab(buf)
        end)
      end,
    })
    vim.cmd.startinsert()
    vim.notify(
      "giroux: attached — Esc → agent · C-z suspends claude to a shell (do work, then `fg`) · "
        .. "C-q → nvim normal mode (scroll/copy, i resumes) · C-b d detaches",
      vim.log.levels.INFO
    )
  end)
end

return M
