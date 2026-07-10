---@module 'giroux.feed'
--- The live feed (:GirouxFeed). One buffer per session, append-only, riding
--- a tail -F stream through giroux.transcript. Tool calls render as one-line
--- heads whose bodies (full input/output) expand in place; results update
--- their call line with ✓/✗ + duration. The whole transcript is always
--- PARSED (pending-set correctness is non-negotiable); only the last
--- `backfill` events are RENDERED unless history is requested (`H`).

local transcript = require("giroux.transcript")
local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")
local vocab = require("giroux.state")

local M = {}

local ns = vim.api.nvim_create_namespace("giroux_feed") -- folds (one per tool/think head)
local deco_ns = vim.api.nvim_create_namespace("giroux_feed_deco") -- line highlights, signs

-- Highlight groups (default-linked; user colorscheme can override). Defined
-- on ColorScheme too, since :colorscheme runs `hi clear` and would otherwise
-- wipe these whenever the user switches themes at runtime.
local function define_hl()
  vim.api.nvim_set_hl(0, "GirouxStateWorking", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "GirouxStateQuestion", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "GirouxStateIdle", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "GirouxStateDone", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "GirouxStateDead", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "GirouxUserMsg", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "GirouxUserSign", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "GirouxUserTag", { link = "Comment", default = true })
end
define_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_hl })

-- giroux buffers use space-padded columns; the user's listchars (multispace:|,
-- eol:...) would render those as pipes. Force a clean display per-window.
local function clean_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].list = false
    -- feed is prose: wrap, but break on word boundaries and indent the
    -- continuation so wrapped lines stay readable under the fold gutter.
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].breakindentopt = "shift:2"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "yes:1" -- left-edge bar marks your turns
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = true
  end
end
M.clean_window = clean_window

local SPIN = { "|", "/", "-", "\\" }

-- Labels source from giroux.state, except two deliberate feed-only overrides:
-- "?" reads "QUESTION" (an alert banner, louder than the roster's "needs
-- you"), and "·" reads "connecting" (the feed's own stream handshake, not
-- the roster's "starting" — a session vs. a socket).
local STATE = {
  ["●"] = { label = vocab.LABEL["●"], hl = "GirouxStateWorking" },
  ["?"] = { label = "QUESTION", hl = "GirouxStateQuestion" },
  ["✓"] = { label = vocab.LABEL["✓"], hl = "GirouxStateDone" },
  ["○"] = { label = vocab.LABEL["○"], hl = "GirouxStateIdle" },
  ["✗"] = { label = vocab.LABEL["✗"], hl = "GirouxStateDead" },
  ["·"] = { label = "connecting", hl = "GirouxStateIdle" },
}

---@class giroux.Feed
---@field buf integer
---@field node string
---@field host string|nil
---@field path string
---@field parser giroux.transcript.Parser
---@field stream giroux.ssh.Stream|nil
---@field calls table<string, table> tool_use_id -> {mark, head, body, name, ts, agent_path}
---@field folds table<integer, {body: string[], expanded: boolean}> mark id -> fold
---@field title string|nil
---@field state string
---@field tokens integer
---@field model string|nil
---@field backfilling boolean
---@field pending_render giroux.transcript.Event[] events parsed but not rendered (tail-only mode)
local feeds = {} ---@type table<integer, giroux.Feed>

-- ---------------------------------------------------------------------------
-- pure renderers (unit-tested; no buffer access)

local function first_line(s)
  return (s:gsub("\r", "")):match("^[^\n]*") or s
end

local function lines_of(s)
  return vim.split(s or "", "\n", { plain = true })
end

---ISO ts -> epoch seconds (UTC-correct; fractional seconds kept for durations).
local function epoch(ts)
  return transcript.utc_epoch(ts)
end

---Head for a TaskUpdate call. `input` only ever carries {taskId, status} or
---{taskId, description} (a description-only edit, no status key — a real
---variant, see this plan's "Current state"); the human-readable subject only
---appears in the RESULT (toolUseResult = {task = {id, subject}}). Shows the
---subject once known, the bare taskId until then.
---@param input table tool_use input
---@param detail table|nil toolUseResult (nil before the result lands)
---@return string
function M._task_update_head(input, detail)
  local subject = type(detail) == "table" and type(detail.task) == "table" and detail.task.subject
  local who = subject or input.taskId or "?"
  return ("▸ %-5s %s: %s"):format("todo", input.status or "edit", who)
end

---Extract `meta.name` from a Workflow script — a JS module that opens
---`export const meta = { name: '...', ... }` (verified real shape). Falls
---back to the script's first line when the pattern isn't found (an
---older/unknown script shape) rather than showing nothing.
---@param script string|nil
---@return string
function M._workflow_name(script)
  if not script or script == "" then
    return "?"
  end
  local name = script:match("meta%s*=%s*{%s*name%s*:%s*['\"](.-)['\"]")
  return name or first_line(script)
end

---Split "mcp__<server>__<tool>" into server/tool. The server segment may
---itself contain underscores/hyphens (real examples:
---"mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation",
---"mcp__claude_ai_Google_Drive__authenticate") — split on the FIRST "__"
---after the "mcp__" prefix, which is always the true server/tool boundary
---in every real name observed. nil, nil when the name doesn't match (feeds
---the generic fallback).
---@param name string
---@return string|nil server, string|nil tool
function M._mcp_parts(name)
  local rest = name:match("^mcp__(.+)$")
  if not rest then
    return nil, nil
  end
  return rest:match("^(.-)__(.+)$")
end

---Head line for a tool_call event. Returns head, body.
---@return string head, string[] body
function M._call_head(e)
  local input = e.input or {}
  local function fmt(word, rest)
    return ("▸ %-5s %s"):format(word, rest)
  end
  if e.name == "Bash" then
    return fmt("bash", first_line(input.command or "?")), lines_of(input.command)
  elseif e.name == "Read" then
    return fmt("read", input.file_path or "?"), {}
  elseif e.name == "Edit" or e.name == "Write" or e.name == "NotebookEdit" then
    local word = e.name == "Write" and "write" or "edit"
    return fmt(word, input.file_path or "?"), {}
  elseif e.name == "Glob" or e.name == "Grep" then
    return fmt(e.name:lower(), (input.pattern or "?") .. " " .. (input.path or "")), {}
  elseif e.name == "WebFetch" then
    return fmt("web", input.url or "?"), { "prompt: " .. (input.prompt or "") }
  elseif e.name == "WebSearch" then
    return fmt("web", "search: " .. (input.query or "?")), {}
  elseif e.name == "Agent" or e.name == "Task" then
    return fmt("agent", input.description or input.subagent_type or "?"), lines_of(input.prompt)
  elseif e.name == "TaskCreate" then
    return fmt("todo", "+ " .. (input.subject or "?")), lines_of(input.description or "")
  elseif e.name == "TaskUpdate" then
    return M._task_update_head(input, nil), lines_of(input.description or "")
  elseif e.name == "TaskStop" then
    -- NB: real field is task_id (snake_case), unlike TaskUpdate's taskId
    return fmt("todo", "stop " .. (input.task_id or "?")), {}
  elseif e.name == "ToolSearch" then
    return fmt("search", input.query or "?"), { "max_results: " .. tostring(input.max_results or "?") }
  elseif e.name == "Workflow" then
    return fmt("workflow", M._workflow_name(input.script)), lines_of(input.script or "")
  elseif e.name == "ScheduleWakeup" then
    return fmt(
      "wake",
      ("in %ss — %s"):format(tostring(input.delaySeconds or "?"), first_line(input.reason or input.prompt or "?"))
    ),
      lines_of(input.prompt or "")
  elseif e.name == "SendMessage" then
    return fmt("→", (input.to or "?") .. ": " .. first_line(input.summary or "?")), lines_of(input.message or "")
  elseif e.name == "Skill" then
    return fmt("skill", input.skill or "?"),
      lines_of(type(input.args) == "string" and input.args or vim.inspect(input.args))
  elseif e.name == "Monitor" then
    -- `until` is a Lua reserved word: input.until is a SYNTAX ERROR, must index with a string key
    return fmt("watch", first_line(input["until"] or "?")),
      { "timeout: " .. tostring(input.timeoutSeconds or "?") .. "s" }
  elseif e.name == "StructuredOutput" then
    local keys = vim.tbl_keys(input)
    table.sort(keys)
    return fmt("output", table.concat(keys, ", ")), lines_of(vim.inspect(input))
  elseif e.name:match("^mcp__") then
    local server, tool = M._mcp_parts(e.name)
    if server then
      return fmt("mcp", server .. "/" .. tool), lines_of(vim.inspect(input))
    end
  end
  local keys = vim.tbl_keys(input)
  table.sort(keys)
  return fmt("tool", ("%s (%s)"):format(e.name, table.concat(keys, ", "))), lines_of(vim.inspect(input))
end

---Suffix once the result lands.
function M._result_suffix(call, e)
  local dur = ""
  local t0, t1 = epoch(call.ts), epoch(e.ts)
  if t0 and t1 and t1 >= t0 then
    dur = ("%.1fs "):format(t1 - t0)
  end
  if e.is_error then
    return ("  %serr"):format(dur)
  end
  -- Edit/Write: show ±lines from structuredPatch
  local d = e.detail
  if type(d) == "table" and type(d.structuredPatch) == "table" then
    local add, del = 0, 0
    for _, hunk in ipairs(d.structuredPatch) do
      for _, l in ipairs(hunk.lines or {}) do
        local c = l:sub(1, 1)
        if c == "+" then
          add = add + 1
        elseif c == "-" then
          del = del + 1
        end
      end
    end
    return ("  +%d -%d %sok"):format(add, del, dur)
  end
  return ("  %sok"):format(dur)
end

---Body lines for a landed result (appended to the call's fold body).
function M._result_body(call, e)
  local body = {}
  if call.body and #call.body > 0 and table.concat(call.body) ~= "" then
    vim.list_extend(body, call.body)
    body[#body + 1] = "─── result ───"
  end
  local d = e.detail
  if type(d) == "table" and type(d.structuredPatch) == "table" then
    for _, hunk in ipairs(d.structuredPatch) do
      body[#body + 1] = ("@@ -%d,%d +%d,%d @@"):format(
        hunk.oldStart or 0,
        hunk.oldLines or 0,
        hunk.newStart or 0,
        hunk.newLines or 0
      )
      vim.list_extend(body, hunk.lines or {})
    end
  elseif type(d) == "table" and d.stdout ~= nil then
    vim.list_extend(body, lines_of(d.stdout))
    if d.stderr and d.stderr ~= "" then
      body[#body + 1] = "─── stderr ───"
      vim.list_extend(body, lines_of(d.stderr))
    end
  elseif e.text and e.text ~= "" then
    vim.list_extend(body, lines_of(e.text))
  end
  return body
end

---Normalize a question event's `questions` array. Defends the hypothetical
---old/alternate single-question shape (a bare {question, options} pair at
---the top level of the event, e.g. e.question/e.options instead of a
---one-element e.questions array) in case an upstream parser change (or a
---not-yet-seen record) ever produces it — the current parser
---(transcript.lua:263-268) always sets `questions` as an array, so this
---branch is not reachable today, only a forward guard.
---@param e giroux.transcript.Event question event
---@return table[] questions
function M._question_list(e)
  if type(e.questions) == "table" and #e.questions > 0 then
    return e.questions
  end
  if e.question then
    return { { question = e.question, options = e.options or {} } }
  end
  return {}
end

---One-liner fold head for a question call: the question count (when >1)
---plus the first question's text.
---@param questions table[]
---@return string
function M._question_head(questions)
  local first = questions[1] and (questions[1].question or "?") or "?"
  if #questions > 1 then
    return ("▸ %-5s (%d) %s"):format("ask", #questions, first)
  end
  return ("▸ %-5s %s"):format("ask", first)
end

---Fold body for a question call: each question with its numbered options,
---and — once resolved — the chosen option inline. `answers`, when present,
---maps question text -> chosen label (the real toolUseResult shape; see
---this plan's "Current state" and tests/events_spec.lua:93-116). Pass nil
---for the initial (unresolved-echo) render.
---@param questions table[]
---@param answers table<string, string>|nil
---@return string[]
function M._question_lines(questions, answers)
  local out = {}
  for _, q in ipairs(questions) do
    out[#out + 1] = "? " .. (q.question or "?")
    for i, opt in ipairs(q.options or {}) do
      out[#out + 1] = ("    %d. %s — %s"):format(i, opt.label or "?", opt.description or "")
    end
    local a = answers and q.question and answers[q.question]
    if a then
      out[#out + 1] = "    → chosen: " .. tostring(a)
    end
  end
  return out
end

---Fold-head suffix for an answered question's tool_result: "answered" when
---the structured answers map is present, else the raw result text (defends
---an unexpected/old toolUseResult shape) — always shows something, never
---silently drops the result the way the pre-fold rendering did.
---@param e giroux.transcript.Event tool_result event
---@return string
function M._question_suffix(e)
  local d = e.detail
  if type(d) == "table" and type(d.answers) == "table" and next(d.answers) then
    return "  answered"
  end
  if e.text and e.text ~= "" then
    return "  " .. first_line(e.text)
  end
  return "  answered"
end

-- ---------------------------------------------------------------------------
-- buffer plumbing

local function buf_set(feed, fn)
  vim.bo[feed.buf].modifiable = true
  pcall(fn)
  vim.bo[feed.buf].modifiable = false
end

---@param prev_last integer line count BEFORE the append that triggered this
local function follow(feed, prev_last)
  local last = vim.api.nvim_buf_line_count(feed.buf)
  for _, win in ipairs(vim.fn.win_findbuf(feed.buf)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row >= prev_last - 1 then -- was at the old tail: keep following
      vim.api.nvim_win_set_cursor(win, { last, 0 })
    end
  end
end

local function append(feed, lines)
  if #lines == 0 then
    return nil
  end
  local mark_row
  local prev_last = vim.api.nvim_buf_line_count(feed.buf)
  buf_set(feed, function()
    local empty = prev_last == 1 and vim.api.nvim_buf_get_lines(feed.buf, 0, 1, false)[1] == ""
    local start = empty and 0 or prev_last
    vim.api.nvim_buf_set_lines(feed.buf, empty and 0 or -1, -1, false, lines)
    mark_row = start
  end)
  follow(feed, prev_last)
  return mark_row
end

---Append a foldable head; returns extmark id.
local function append_fold(feed, head, body)
  local row = append(feed, { head })
  local mark = vim.api.nvim_buf_set_extmark(feed.buf, ns, row, 0, {})
  feed.folds[mark] = { body = body or {}, expanded = false }
  return mark
end

local function mark_row(feed, mark)
  local pos = vim.api.nvim_buf_get_extmark_by_id(feed.buf, ns, mark, {})
  return pos and pos[1]
end

---Replace a head line and re-pin its mark (set_lines shifts marks down).
local function set_fold_head(feed, mark, head)
  local row = mark_row(feed, mark)
  if row then
    buf_set(feed, function()
      vim.api.nvim_buf_set_lines(feed.buf, row, row + 1, false, { head })
      vim.api.nvim_buf_set_extmark(feed.buf, ns, row, 0, { id = mark })
    end)
  end
end

local function toggle_fold(feed, mark)
  local fold = feed.folds[mark]
  local row = mark_row(feed, mark)
  if not fold or not row then
    return
  end
  buf_set(feed, function()
    if fold.expanded then
      vim.api.nvim_buf_set_lines(feed.buf, row + 1, row + 1 + #fold.render_count, false, {})
    else
      local body = {}
      for _, l in ipairs(fold.body) do
        body[#body + 1] = "  │ " .. l
      end
      vim.api.nvim_buf_set_lines(feed.buf, row + 1, row + 1, false, body)
      fold.render_count = body
    end
    fold.expanded = not fold.expanded
    local head = vim.api.nvim_buf_get_lines(feed.buf, row, row + 1, false)[1]
    local glyph = fold.expanded and "▾" or "▸"
    -- both glyphs are 3 UTF-8 bytes; Lua patterns are byte-classes, don't use them here
    vim.api.nvim_buf_set_lines(feed.buf, row, row + 1, false, { glyph .. head:sub(4) })
    vim.api.nvim_buf_set_extmark(feed.buf, ns, row, 0, { id = mark })
  end)
end

local function winbar(feed)
  local st = STATE[feed.state] or STATE["·"]
  local title = (feed.title or vim.fs.basename(feed.path)):gsub("%%", "%%%%")
  local model = (feed.model or "?"):gsub("^claude%-", "")
  local bar
  if feed.loading then
    local frame = SPIN[(feed.spin or 0) % #SPIN + 1]
    bar = ("%%#%s# %s loading %%*  %s  ·  reading %s"):format(st.hl, frame, title, feed.node)
  else
    local at = feed.last_ts and feed.last_ts:match("T(%d+:%d+:%d+)") or os.date("%H:%M:%S")
    bar = ("%%#%s# %s %s %%*  %s  ·  %s · %.1fk out  ·  last event %s"):format(
      st.hl,
      feed.state,
      st.label,
      title,
      model,
      feed.tokens / 1000,
      at
    )
  end
  for _, win in ipairs(vim.fn.win_findbuf(feed.buf)) do
    vim.wo[win].winbar = bar
  end
end

local function spin_tick(feed)
  if not feed.loading or not vim.api.nvim_buf_is_valid(feed.buf) then
    return
  end
  feed.spin = (feed.spin or 0) + 1
  winbar(feed)
  vim.defer_fn(function()
    spin_tick(feed)
  end, 120)
end

-- ---------------------------------------------------------------------------
-- event application

local function apply_event(feed, e)
  if e.kind == "user_text" then
    -- Your messages stand out via a full-line background tint (spans the
    -- whole width AND wrapped continuation lines) plus a sign-column bar on
    -- the first line — both wrap-proof, unlike text rules/gutters.
    local tlines = lines_of(e.text)
    local block = { "" }
    vim.list_extend(block, tlines)
    local start = append(feed, block)
    local first = start + 1
    for i = 0, #tlines - 1 do
      local opts = { line_hl_group = "GirouxUserMsg" }
      if i == 0 then
        opts.sign_text = "▌"
        opts.sign_hl_group = "GirouxUserSign"
        opts.virt_text = { { e.source == "queued" and "  you · queued" or "  you", "GirouxUserTag" } }
        opts.virt_text_pos = "eol"
      end
      local id = vim.api.nvim_buf_set_extmark(feed.buf, deco_ns, first + i, 0, opts)
      if i == 0 then
        feed.user_marks[#feed.user_marks + 1] = id
      end
    end
  elseif e.kind == "assistant_text" then
    feed.model = e.model or feed.model
    local out = { "" }
    vim.list_extend(out, lines_of(e.text))
    append(feed, out)
  elseif e.kind == "thinking" then
    local body = lines_of(e.text)
    append_fold(feed, ("▸ %-5s (%d lines)"):format("think", #body), body)
  elseif e.kind == "tool_call" then
    local head, body = M._call_head(e)
    local mark = append_fold(feed, head, body)
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, body = body, name = e.name, ts = e.ts, input = e.input }
    end
    feed.state = "●"
  elseif e.kind == "question" then
    local qs = M._question_list(e)
    local head = M._question_head(qs)
    local mark = append_fold(feed, head, M._question_lines(qs))
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, name = "AskUserQuestion", ts = e.ts, questions = qs }
    end
    feed.state = "?"
  elseif e.kind == "tool_result" then
    local call = e.id and feed.calls[e.id]
    if call and call.mark then
      local fold = feed.folds[call.mark]
      if call.name == "AskUserQuestion" then
        local d = e.detail
        local answers = type(d) == "table" and type(d.answers) == "table" and d.answers or nil
        if fold and not fold.expanded then
          fold.body = M._question_lines(call.questions or {}, answers)
        end
        set_fold_head(feed, call.mark, call.head .. M._question_suffix(e))
      else
        local head = call.name == "TaskUpdate" and M._task_update_head(call.input or {}, e.detail) or call.head
        if fold and not fold.expanded then
          fold.body = M._result_body(call, e)
        end
        set_fold_head(feed, call.mark, head .. M._result_suffix(call, e))
      end
    end
    -- subagent drill-in target
    if call and type(e.detail) == "table" and e.detail.agentId then
      call.agent_path = transcript.subagent_path(feed.path, e.detail.agentId)
    end
  elseif e.kind == "subagent" then
    local _ = e -- announcement already handled via tool_result detail
  elseif e.kind == "interrupt" then
    append(feed, { "", "-- interrupted --" })
    feed.state = "○"
  elseif e.kind == "stop" then
    feed.state = "○"
  elseif e.kind == "turn_end" then
    append(feed, {
      "",
      ("── end of turn · %.1fs · %d messages ──"):format((e.duration_ms or 0) / 1000, e.message_count or 0),
    })
    feed.state = "○"
  elseif e.kind == "usage" then
    feed.tokens = feed.tokens + (e.output or 0)
    feed.model = e.model or feed.model
  elseif e.kind == "api_error" then
    append(feed, {
      ("ERR api: %s%s"):format(
        first_line(e.text or "?"),
        e.retry_in_ms and (" (retry in %.0fs)"):format(e.retry_in_ms / 1000) or ""
      ),
    })
  elseif e.kind == "compact" then
    append(feed, {
      "",
      ("═══ compacted %s: %s → %s tokens ═══"):format(
        e.trigger or "?",
        tostring(e.pre_tokens),
        tostring(e.post_tokens)
      ),
    })
  elseif e.kind == "summary" then
    append_fold(feed, "▸ sum   " .. first_line(e.text or ""), lines_of(e.text))
  elseif e.kind == "session_meta" then
    if e.key == "ai-title" then
      feed.title = e.value
    end
  elseif e.kind == "queue" then
    if e.op == "enqueue" and e.text then
      append(feed, { "queued: " .. first_line(e.text) })
    end
  end
  -- local_command/other/unknown: not rendered (lossless in parser, quiet in feed)
end

function M._apply(feed, events)
  for _, e in ipairs(events) do
    apply_event(feed, e)
    feed.last_ts = e.ts or feed.last_ts
  end
  winbar(feed)
end

---Render (or refresh) the pane-sourced live question at the tail. A pending
---AskUserQuestion is never in the transcript, so without this the feed is
---silent under a `?`. Re-rendered in place when the question changes;
---removed once it's answered (the transcript then renders it normally).
---@param feed table
---@param q {question: string, options: {n: integer, label: string}[]}|nil
local function render_live_question(feed, q)
  if not vim.api.nvim_buf_is_valid(feed.buf) then
    return
  end
  local sig = q and (q.question .. "#" .. #q.options) or nil
  if sig == feed.live_q_sig then
    return -- unchanged
  end
  feed.live_q_sig = sig
  -- drop any prior live block
  if feed.live_q_mark then
    local pos = vim.api.nvim_buf_get_extmark_by_id(feed.buf, ns, feed.live_q_mark, { details = true })
    if pos[1] then
      buf_set(feed, function()
        vim.api.nvim_buf_set_lines(feed.buf, pos[1], pos[3].end_row or (pos[1] + 1), false, {})
      end)
    end
    feed.live_q_mark = nil
  end
  if not q then
    return
  end
  local lines = { "", "┄ live question · <CR> on an option to answer ┄", "? " .. q.question }
  for _, o in ipairs(q.options) do
    lines[#lines + 1] = ("    %d. %s"):format(o.n, o.label)
  end
  local prev = vim.api.nvim_buf_line_count(feed.buf)
  local start = append(feed, lines)
  if start then
    feed.live_q_mark = vim.api.nvim_buf_set_extmark(feed.buf, ns, start, 0, {
      end_row = math.min(start + #lines, vim.api.nvim_buf_line_count(feed.buf)),
    })
    for i = start, start + #lines - 1 do
      pcall(vim.hl.range, feed.buf, ns, "GirouxStateQuestion", { i, 0 }, { i, -1 })
    end
  end
  local _ = prev
end

---Poll the session's tmux pane for a live AskUserQuestion while the feed is
---open, and keep the rendered block in sync. Cheap: one capture every 3s,
---only meaningful for tmux-correlated sessions (others always return nil).
local function start_question_poll(feed)
  if feed.q_timer then
    return
  end
  feed.q_timer = vim.uv.new_timer()
  feed.q_timer:start(
    0,
    3000,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(feed.buf) then
        if feed.q_timer then
          feed.q_timer:stop()
          feed.q_timer:close()
          feed.q_timer = nil
        end
        return
      end
      require("giroux.steer").read_question({ node = feed.node, path = feed.path }, function(q)
        render_live_question(feed, q)
      end)
    end)
  )
end

-- ---------------------------------------------------------------------------
-- lifecycle

---Parse a chunk of transcript bytes into the feed (backfill-aware).
local function process_chunk(feed, chunk)
  if feed.skip_partial then
    local nl = chunk:find("\n", 1, true)
    if not nl then
      return -- still inside the partial first line
    end
    chunk = chunk:sub(nl + 1)
    feed.skip_partial = false
    feed.parser = transcript.parser({ start_offset = feed.parser:resume_offset() })
  end
  local events = feed.parser:feed(chunk)
  if feed.backfilling then
    feed.last_chunk_ns = vim.uv.hrtime()
    vim.list_extend(feed.pending_render, events)
  else
    M._apply(feed, events)
  end
end

---Own tail -F: the fallback transport when the monitor isn't tracking this
---session (inactive file, roster closed).
local function own_tail(feed, offset)
  local backoff = 1000
  local function connect(from)
    if not vim.api.nvim_buf_is_valid(feed.buf) then
      return
    end
    feed.stream = ssh.tail(feed.host, feed.path, from, function(chunk)
      backoff = 1000
      process_chunk(feed, chunk)
    end, function(_)
      if vim.api.nvim_buf_is_valid(feed.buf) then
        vim.defer_fn(function()
          backoff = math.min(backoff * 2, 30000)
          connect(feed.parser:resume_offset())
        end, backoff)
      end
    end)
  end
  connect(offset)
end

---Transport: ride the monitor's merged node stream when it tracks this
---session (no extra ssh channel — the MaxSessions fix); otherwise own tail.
---The historical window comes from a one-shot read either way; subscription
---lines that race the snapshot are buffered and replayed offset-guarded.
local function start_stream(feed, offset)
  local monitor = require("giroux.monitor")
  if not monitor.tracks(feed.node, feed.path) then
    return own_tail(feed, offset)
  end

  feed.sub_buffer = {}
  feed.unsub_lines = monitor.subscribe_lines(feed.node, feed.path, function(line, line_offset)
    if not vim.api.nvim_buf_is_valid(feed.buf) then
      return
    end
    if feed.sub_buffer then
      feed.sub_buffer[#feed.sub_buffer + 1] = { line, line_offset }
    elseif line_offset >= feed.parser:resume_offset() then
      process_chunk(feed, line .. "\n")
    end
  end, function()
    -- monitor stopped tracking (roster closed / session aged out): take over
    feed.unsub_lines = nil
    feed.sub_buffer = nil
    if vim.api.nvim_buf_is_valid(feed.buf) then
      own_tail(feed, feed.parser:resume_offset())
    end
  end)

  ssh.exec(feed.host, ("tail -c +%d %s 2>/dev/null"):format(offset + 1, ssh.shq(feed.path)), function(ok, stdout)
    if not vim.api.nvim_buf_is_valid(feed.buf) then
      return
    end
    if not ok then
      if feed.unsub_lines then
        feed.unsub_lines()
        feed.unsub_lines = nil
      end
      feed.sub_buffer = nil
      return own_tail(feed, offset)
    end
    if stdout ~= "" then
      process_chunk(feed, stdout)
    end
    feed.last_chunk_ns = feed.last_chunk_ns or vim.uv.hrtime() -- empty window: let the drain timer fire
    local buffered = feed.sub_buffer
    feed.sub_buffer = nil
    for _, item in ipairs(buffered or {}) do
      if item[2] >= feed.parser:resume_offset() then
        process_chunk(feed, item[1] .. "\n")
      end
    end
  end)
end

---Render only the tail of history: parse everything (correctness), render
---the last `backfill` events.
function M._drain_backfill(feed)
  local cfg = require("giroux").config
  local keep = cfg.backfill or 200
  local evs = feed.pending_render
  feed.pending_render = {}
  feed.backfilling = false
  local from = math.max(1, #evs - keep + 1)
  if from > 1 then
    append(feed, { ("┄┄ %d earlier events parsed, not rendered ┄┄"):format(from - 1) })
  end
  M._apply(feed, vim.list_slice(evs, from, #evs))
  -- Park the cursor at the bottom so the feed tails live (follow() only
  -- auto-scrolls when the cursor is already at the last line).
  local last = vim.api.nvim_buf_line_count(feed.buf)
  for _, win in ipairs(vim.fn.win_findbuf(feed.buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
  end
  -- a pending AskUserQuestion is never in the transcript; surface it from
  -- the pane so a `?` session shows something to answer.
  start_question_poll(feed)
end

---@param opts {node: string|nil, path: string}
function M.open_path(opts)
  local node_name, node = nodes.get(opts.node)
  assert(node, "unknown node: " .. tostring(opts.node))
  require("giroux.monitor").mark_seen(node_name, opts.path) -- reviewing demotes ✓ (done) → ○ (idle)
  local bufname = ("giroux://feed/%s/%s"):format(node_name, vim.fs.basename(opts.path):gsub("%.jsonl$", ""))
  local existing = vim.fn.bufnr(bufname)
  if existing ~= -1 and feeds[existing] then
    vim.api.nvim_set_current_buf(existing)
    winbar(feeds[existing])
    return feeds[existing]
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, bufname)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "giroux-feed"

  local feed = {
    buf = buf,
    node = node_name,
    host = node.host,
    path = opts.path,
    parser = transcript.parser(),
    calls = {},
    folds = {},
    user_marks = {},
    state = "·",
    tokens = 0,
    backfilling = true,
    pending_render = {},
  }
  feeds[buf] = feed

  local cfg = require("giroux").config
  local km = cfg.keymaps.feed
  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "giroux: " .. desc })
    end
  end
  map(km.toggle_fold, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})
    if marks[1] then
      toggle_fold(feed, marks[1][1])
    end
  end, "toggle fold")
  map(km.open_subagent, function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    -- answer-pick: <CR> on a rendered question option or the question line.
    -- The transcript shows only ANSWERED questions (Claude Code writes
    -- AskUserQuestion on resolve, never while pending), so the live question
    -- lives on the tmux pane — read it there and pick.
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if line:match("^%s*%d+%.%s") or line:match("^%? ") or line:match("live question") then
      require("giroux.steer").pick({ node = feed.node, path = feed.path })
      return
    end
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})
    if marks[1] then
      for _, call in pairs(feed.calls) do
        if call.mark == marks[1][1] and call.agent_path then
          M.open_path({ node = feed.node, path = call.agent_path })
          return
        end
      end
    end
  end, "open subagent feed / answer question option")
  map(km.close, function()
    M.close(buf)
  end, "close feed")
  map(km.attach, function()
    require("giroux.steer").attach({ node = feed.node, path = feed.path })
  end, "attach (tmux)")
  map(km.steer, function()
    require("giroux.steer").buffer({ node = feed.node, path = feed.path })
  end, "steer (compose + send)")
  map(km.qa, function()
    require("giroux.qa").open({ node = feed.node, path = feed.path, title = feed.title })
  end, "Q&A digest")
  map(km.peek or "K", function()
    -- peek the full current line (and a tool fold body) in a floating window,
    -- for when wrapped/long content is hard to read in place.
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local content = { line }
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})
    if marks[1] and feed.folds[marks[1][1]] then
      vim.list_extend(content, { "" })
      vim.list_extend(content, feed.folds[marks[1][1]].body)
    end
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, content)
    local width = math.min(120, vim.o.columns - 8)
    local height = math.min(#content, vim.o.lines - 8)
    local win = vim.api.nvim_open_win(pbuf, false, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = math.max(1, height),
      style = "minimal",
      border = "rounded",
    })
    vim.wo[win].wrap = true
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
      once = true,
      callback = function()
        pcall(vim.api.nvim_win_close, win, true)
      end,
    })
  end, "peek full line")

  -- Turn navigation: jump between YOU markers (the start of each of your
  -- turns). The conversation skeleton is the user's messages; tool calls
  -- between them are detail you page past.
  local function jump_turn(dir)
    local rows = {}
    for _, id in ipairs(feed.user_marks) do
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, deco_ns, id, {})
      if pos[1] then
        rows[#rows + 1] = pos[1] + 1 -- extmark rows are 0-based; cursor is 1-based
      end
    end
    table.sort(rows)
    if #rows == 0 then
      return
    end
    local cur = vim.api.nvim_win_get_cursor(0)[1]
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
  map(km.next_turn or "]]", function()
    jump_turn(1)
  end, "next turn (your message)")
  map(km.prev_turn or "[[", function()
    jump_turn(-1)
  end, "prev turn (your message)")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      M.close(buf)
    end,
  })
  -- windows that start showing this buffer later still get the bar + clean display
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      local f = feeds[buf]
      if f then
        clean_window(vim.api.nvim_get_current_win())
        winbar(f)
      end
    end,
  })

  vim.api.nvim_set_current_buf(buf)
  clean_window(vim.api.nvim_get_current_win())
  feed.loading = true
  buf_set(feed, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  connecting to " .. feed.node .. "…" })
  end)
  winbar(feed)
  spin_tick(feed)

  -- A turn's tool_use/result pairing is always local to recent bytes, so the
  -- pending-set (state proof) is correct from a tail window; reading only the
  -- last initial_tail bytes makes huge files open instantly. Older history is
  -- "parsed not rendered" regardless. start the parser at the window boundary.
  local cfg2 = require("giroux").config
  local window = cfg2.initial_tail or 262144
  ssh.exec(feed.host, ("wc -c < %s"):format(ssh.shq(feed.path)), function(ok, stdout)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local size = ok and tonumber(vim.trim(stdout)) or 0
    local from = math.max(0, size - window)
    feed.parser = transcript.parser({ start_offset = from })
    feed.skip_partial = from > 0 -- first line after a mid-file cut is partial
    -- clear the placeholder before the first render
    buf_set(feed, function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    end)
    start_stream(feed, from)
    -- The file may be live (growing past `size`) and the last line partial, so
    -- an exact byte match never trips. Drain once the initial burst goes quiet
    -- (caught up to EOF), or after a hard cap, whichever comes first.
    local opened_ns = vim.uv.hrtime()
    local function check()
      if not vim.api.nvim_buf_is_valid(buf) or not feed.loading then
        return
      end
      local now = vim.uv.hrtime()
      local quiet = feed.last_chunk_ns and (now - feed.last_chunk_ns) / 1e6 > 180
      local capped = (now - opened_ns) / 1e6 > 4000
      if quiet or capped then
        feed.loading = false
        M._drain_backfill(feed)
        winbar(feed)
        if opts.jump_text then -- drilled in from the Q&A digest: land on that turn
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            for i = #lines, 1, -1 do
              if lines[i]:find(opts.jump_text, 1, true) then
                vim.api.nvim_win_set_cursor(win, { i, 0 })
                vim.api.nvim_win_call(win, function()
                  vim.cmd("normal! zt")
                end)
                break
              end
            end
          end
        end
      else
        vim.defer_fn(check, 40)
      end
    end
    vim.defer_fn(check, 60)
  end)
  return feed
end

function M.close(buf)
  local feed = feeds[buf]
  if feed then
    if feed.stream then
      feed.stream.stop()
    end
    if feed.unsub_lines then
      feed.unsub_lines()
    end
    if feed.q_timer then
      feed.q_timer:stop()
      feed.q_timer:close()
      feed.q_timer = nil
    end
    feeds[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

---Stop the transport behind every open feed. Called on VimLeavePre so a
---feed's own fallback tail (the monitor-untracked case) doesn't orphan when
---nvim quits. Buffers are left alone — the editor is tearing them down anyway;
---only the live `ssh`/`tail` processes need stopping.
function M.cleanup()
  for _, feed in pairs(feeds) do
    if feed.stream then
      pcall(feed.stream.stop)
    end
    if feed.unsub_lines then
      pcall(feed.unsub_lines)
    end
  end
end

---Resolve `[node[/session-prefix]]` to the most recently active session and
---hand {node, path} to cb. Shared by :GirouxFeed and :GirouxQA.
---@param arg string|nil
---@param cb fun(sel: {node: string, path: string}|nil)
function M.resolve(arg, cb)
  local cfg = require("giroux").config
  local want_node, want_sess
  if arg and arg ~= "" then
    want_node, want_sess = arg:match("^([^/]+)/?(.*)$")
  end
  local all = nodes.all()
  local candidates = {}
  local waiting = 0
  for name, node in pairs(all) do
    if not want_node or want_node == name then
      waiting = waiting + 1
      -- portable stat: GNU (-c, Linux) with a BSD (-f, macOS) fallback.
      local find = (
        "find %s -name '*.jsonl' -not -path '*/subagents/*' -not -name journal.jsonl -mmin -%d 2>/dev/null"
        .. " | while IFS= read -r f; do stat -c '%%Y %%n' \"$f\" 2>/dev/null"
        .. " || stat -f '%%m %%N' \"$f\"; done | sort -rn | head -5"
      ):format(node.claude_projects, cfg.active_window)
      ssh.exec(node.host, find, function(ok, stdout)
        waiting = waiting - 1
        if ok then
          for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
            local mtime, path = line:match("^(%d+) (.+)$")
            if path and (not want_sess or want_sess == "" or vim.fs.basename(path):find(want_sess, 1, true) == 1) then
              candidates[#candidates + 1] = { mtime = tonumber(mtime), node = name, path = path }
            end
          end
        end
        if waiting == 0 then
          table.sort(candidates, function(a, b)
            return a.mtime > b.mtime
          end)
          if candidates[1] then
            cb({ node = candidates[1].node, path = candidates[1].path })
          else
            vim.notify("giroux: no active sessions found", vim.log.levels.WARN)
            cb(nil)
          end
        end
      end)
    end
  end
  if waiting == 0 then
    vim.notify("giroux: unknown node " .. tostring(want_node), vim.log.levels.WARN)
    cb(nil)
  end
end

---:GirouxFeed [node[/session-prefix]] — default: most recently active session.
function M.open(arg)
  M.resolve(arg, function(sel)
    if sel then
      M.open_path(sel)
    end
  end)
end

M._feeds = feeds
return M
