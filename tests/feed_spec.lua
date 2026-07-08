local feed = require("giroux.feed")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end

-- synthetic session fixture (census-shaped, no secrets)
local function fixture_lines()
  return {
    J({ type = "mode", mode = "normal", sessionId = "s1" }),
    J({ type = "ai-title", aiTitle = "Test drive", sessionId = "s1" }),
    J({
      type = "user",
      uuid = "u1",
      sessionId = "s1",
      timestamp = "2026-06-11T05:00:00.000Z",
      message = { role = "user", content = "hello agent" },
    }),
    J({
      type = "assistant",
      uuid = "a1",
      sessionId = "s1",
      timestamp = "2026-06-11T05:00:01.000Z",
      message = {
        id = "msg_1",
        model = "claude-fable-5",
        role = "assistant",
        content = { { type = "tool_use", id = "toolu_1", name = "Bash", input = { command = "echo hi\necho there" } } },
        stop_reason = vim.NIL,
        usage = { input_tokens = 10, output_tokens = 20, cache_read_input_tokens = 0, cache_creation_input_tokens = 0 },
      },
    }),
    J({
      type = "user",
      uuid = "u2",
      sessionId = "s1",
      timestamp = "2026-06-11T05:00:03.500Z",
      message = {
        role = "user",
        content = { { type = "tool_result", tool_use_id = "toolu_1", content = "hi\nthere", is_error = false } },
      },
      toolUseResult = { stdout = "hi\nthere", stderr = "", interrupted = false },
    }),
    J({
      type = "system",
      subtype = "turn_duration",
      uuid = "td",
      sessionId = "s1",
      durationMs = 3500,
      messageCount = 3,
    }),
  }
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- modern-tool session fixture: a TaskCreate call and a two-question
-- AskUserQuestion, both answered (census-shaped, no secrets).
local function modern_fixture_lines()
  return {
    J({ type = "mode", mode = "normal", sessionId = "s2" }),
    J({
      type = "assistant",
      uuid = "m1",
      sessionId = "s2",
      timestamp = "2026-07-08T14:00:00.000Z",
      message = {
        id = "msg_m1",
        model = "claude-fable-5",
        role = "assistant",
        content = {
          {
            type = "tool_use",
            id = "toolu_tc",
            name = "TaskCreate",
            input = { subject = "Ship the thing", description = "details" },
          },
          {
            type = "tool_use",
            id = "toolu_ask",
            name = "AskUserQuestion",
            input = {
              questions = {
                {
                  question = "which deploy target?",
                  header = "Target",
                  multiSelect = false,
                  options = {
                    { label = "staging", description = "safe rollout" },
                    { label = "prod", description = "risky rollout" },
                  },
                },
                {
                  question = "which regions?",
                  header = "Regions",
                  multiSelect = true,
                  options = {
                    { label = "us-east", description = "primary" },
                    { label = "eu-west", description = "secondary" },
                  },
                },
              },
            },
          },
        },
        stop_reason = vim.NIL,
      },
    }),
    J({
      type = "user",
      uuid = "m2",
      sessionId = "s2",
      timestamp = "2026-07-08T14:00:01.000Z",
      message = {
        role = "user",
        content = { { type = "tool_result", tool_use_id = "toolu_tc", content = "task created", is_error = false } },
      },
      toolUseResult = { task = { id = "1", subject = "Ship the thing" } },
    }),
    J({
      type = "user",
      uuid = "m3",
      sessionId = "s2",
      timestamp = "2026-07-08T14:00:02.000Z",
      message = {
        role = "user",
        content = {
          {
            type = "tool_result",
            tool_use_id = "toolu_ask",
            content = 'Your questions have been answered: "which deploy target?"="staging", "which regions?"="us-east, eu-west"',
            is_error = false,
          },
        },
      },
      toolUseResult = {
        answers = { ["which deploy target?"] = "staging", ["which regions?"] = "us-east, eu-west" },
      },
    }),
    J({
      type = "system",
      subtype = "turn_duration",
      uuid = "td2",
      sessionId = "s2",
      durationMs = 2000,
      messageCount = 3,
    }),
  }
end

return {
  ["feed: call heads render per-tool glyphs"] = function()
    local head, body = feed._call_head({ name = "Bash", input = { command = "cargo test --workspace\nmore" } })
    assert(head == "▸ bash  cargo test --workspace", head)
    assert(#body == 2)
    head = feed._call_head({ name = "Edit", input = { file_path = "/src/api.rs" } })
    assert(head == "▸ edit  /src/api.rs", head)
    head = feed._call_head({ name = "WebFetch", input = { url = "https://docs.rs/axum" } })
    assert(head == "▸ web   https://docs.rs/axum", head)
    head = feed._call_head({ name = "Agent", input = { description = "Explore repo", prompt = "go" } })
    assert(head == "▸ agent Explore repo", head)
    head = feed._call_head({ name = "FutureTool", input = { alpha = 1, beta = 2 } })
    assert(head:find("tool  FutureTool %(alpha, beta%)"), head)
  end,

  ["feed: result suffix computes duration, diffstat, errors"] = function()
    local call = { ts = "2026-06-11T05:00:01.000Z" }
    local s = feed._result_suffix(call, { ts = "2026-06-11T05:00:04.200Z", is_error = false })
    assert(s:find("3.2s ok"), s)
    s = feed._result_suffix(call, { ts = "2026-06-11T05:00:02.000Z", is_error = true })
    assert(s:find("err"), s)
    s = feed._result_suffix(call, {
      ts = "2026-06-11T05:00:02.000Z",
      detail = { structuredPatch = { { lines = { "+new", "+new2", "-old", " ctx" } } } },
    })
    assert(s:find("+2 -1", 1, true), s)
  end,

  ["feed: question fold lines render options, and the chosen answer once resolved"] = function()
    local qs = {
      {
        question = "Which way?",
        options = { { label = "tmux", description = "send-keys" }, { label = "sdk", description = "stream-json" } },
      },
    }
    local lines = feed._question_lines(qs, nil)
    assert(lines[1] == "? Which way?", lines[1])
    assert(lines[2]:find("1. tmux — send%-keys"), lines[2])
    assert(#lines == 3, "no chosen line before an answer lands: " .. #lines)

    lines = feed._question_lines(qs, { ["Which way?"] = "tmux" })
    assert(lines[#lines] == "    → chosen: tmux", lines[#lines])
  end,

  ["feed: modern tool call heads — todo panel, search, workflow, wake, message, skill, watch, mcp"] = function()
    local head =
      feed._call_head({ name = "TaskCreate", input = { subject = "Ship the thing", description = "details" } })
    assert(head == "▸ todo  + Ship the thing", head)

    head = feed._call_head({ name = "TaskUpdate", input = { taskId = "10", status = "in_progress" } })
    assert(head == "▸ todo  in_progress: 10", head) -- no subject yet: falls back to taskId

    head = feed._call_head({
      name = "TaskUpdate",
      input = { taskId = "10", description = "new description, no status key" },
    })
    assert(head == "▸ todo  edit: 10", head) -- real variant: description-only update, no status

    head = feed._call_head({ name = "TaskStop", input = { task_id = "abc123" } }) -- NB: snake_case in real data
    assert(head == "▸ todo  stop abc123", head)

    head = feed._call_head({ name = "ToolSearch", input = { query = "select:WebFetch", max_results = 3 } })
    assert(head == "▸ search select:WebFetch", head)

    head = feed._call_head({
      name = "Workflow",
      input = { script = "export const meta = {\n  name: 'ship-it',\n  description: 'x'\n}" },
    })
    assert(head == "▸ workflow ship-it", head)

    head = feed._call_head({ name = "ScheduleWakeup", input = { delaySeconds = 1500, reason = "heartbeat" } })
    assert(head:find("▸ wake  in 1500s — heartbeat", 1, true), head)

    head = feed._call_head({ name = "SendMessage", input = { to = "agent-42", summary = "REVISE: fix the thing" } })
    assert(head == "▸ →   agent-42: REVISE: fix the thing", head)

    head = feed._call_head({ name = "Skill", input = { skill = "plannotator-annotate", args = "docs/x.md" } })
    assert(head == "▸ skill plannotator-annotate", head)

    head =
      feed._call_head({ name = "Monitor", input = { ["until"] = "background workflow done", timeoutSeconds = "1500" } })
    assert(head:find("▸ watch background workflow done", 1, true), head)

    head = feed._call_head({ name = "mcp__chrome-devtools__evaluate_script", input = { script = "1+1" } })
    assert(head == "▸ mcp   chrome-devtools/evaluate_script", head)

    -- real multi-underscore server segment (verified real tool name)
    head = feed._call_head({
      name = "mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation",
      input = { query = "x" },
    })
    assert(head == "▸ mcp   plugin_cloudflare_cloudflare-docs/search_cloudflare_documentation", head)

    -- unknown tool still falls back to the generic vim.inspect renderer, unaffected
    head = feed._call_head({ name = "SomeFutureTool", input = { a = 1 } })
    assert(head:find("tool  SomeFutureTool %(a%)"), head)
  end,

  ["feed: _task_update_head shows taskId before the result, subject after"] = function()
    local before = feed._task_update_head({ taskId = "7", status = "completed" }, nil)
    assert(before == "▸ todo  completed: 7", before)
    local after = feed._task_update_head(
      { taskId = "7", status = "completed" },
      { task = { id = "7", subject = "Ship it" } }
    )
    assert(after == "▸ todo  completed: Ship it", after)
  end,

  ["feed: _workflow_name parses meta.name, falls back to first line when absent"] = function()
    assert(
      feed._workflow_name("export const meta = {\n  name: 'fortunemill-full-audit',\n  description: 'x'\n}")
        == "fortunemill-full-audit"
    )
    assert(feed._workflow_name('export const meta = { name: "double-quoted" }') == "double-quoted")
    assert(feed._workflow_name("// no meta block here\nconsole.log(1)") == "// no meta block here")
    assert(feed._workflow_name(nil) == "?")
    assert(feed._workflow_name("") == "?")
  end,

  ["feed: _mcp_parts splits server/tool, defends malformed names"] = function()
    local server, tool = feed._mcp_parts("mcp__chrome-devtools__evaluate_script")
    assert(server == "chrome-devtools" and tool == "evaluate_script", server .. "/" .. tostring(tool))
    server, tool = feed._mcp_parts("mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation")
    assert(server == "plugin_cloudflare_cloudflare-docs", server)
    assert(tool == "search_cloudflare_documentation", tool)
    server, tool = feed._mcp_parts("not_an_mcp_tool")
    assert(server == nil and tool == nil)
  end,

  ["feed: _question_list defends the old single-question shape"] = function()
    local qs = feed._question_list({ questions = { { question = "A?" }, { question = "B?" } } })
    assert(#qs == 2)
    qs = feed._question_list({ question = "solo?", options = { { label = "x" } } })
    assert(#qs == 1 and qs[1].question == "solo?", vim.inspect(qs))
    qs = feed._question_list({})
    assert(#qs == 0)
  end,

  ["feed: _question_head shows question count only when there's more than one"] = function()
    assert(feed._question_head({ { question = "solo?" } }) == "▸ ask   solo?")
    local h = feed._question_head({ { question = "first?" }, { question = "second?" } })
    assert(h == "▸ ask   (2) first?", h)
  end,

  ["feed: end-to-end over a local fixture file"] = function()
    local path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(fixture_lines(), path)
    local f = feed.open_path({ node = nil, path = path })
    -- event loop: wait for backfill drain + render
    local ok = vim.wait(5000, function()
      return not f.backfilling and buf_text(f.buf):find("end of turn") ~= nil
    end, 50)
    assert(ok, "feed did not render within 5s:\n" .. buf_text(f.buf))
    local text = buf_text(f.buf)
    assert(text:find("hello agent", 1, true), text)
    -- user message is decorated via extmark (line_hl + sign), not inline text
    local deco = vim.api.nvim_get_namespaces()["giroux_feed_deco"]
    local marks = vim.api.nvim_buf_get_extmarks(f.buf, deco, 0, -1, { details = true })
    local has_userhl = false
    for _, m in ipairs(marks) do
      if m[4] and m[4].line_hl_group == "GirouxUserMsg" then
        has_userhl = true
      end
    end
    assert(has_userhl, "user message must carry the GirouxUserMsg line highlight")
    assert(text:find("▸ bash  echo hi", 1, true), text)
    assert(text:find("2.5s ok", 1, true), "result suffix missing:\n" .. text)
    assert(text:find("── end of turn · 3.5s · 3 messages ──", 1, true), text)
    assert(f.title == "Test drive")
    assert(f.tokens == 20)
    assert(f.state == "○", "state should prove end-of-turn, got " .. f.state)

    -- fold expands to command + result
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)) do
      if l:find("▸ bash  echo hi", 1, true) then
        row = i
      end
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    text = buf_text(f.buf)
    assert(text:find("▾ bash  echo hi", 1, true), "fold glyph should flip:\n" .. text)
    assert(text:find("│ echo there", 1, true), "expanded body missing:\n" .. text)
    assert(text:find("│ hi", 1, true), "result stdout missing in fold:\n" .. text)

    feed.close(f.buf)
    vim.fn.delete(path)
  end,

  ["feed: end-to-end — TaskCreate and an answered two-question AskUserQuestion render as folds"] = function()
    local path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(modern_fixture_lines(), path)
    local f = feed.open_path({ node = nil, path = path })
    local ok = vim.wait(5000, function()
      return not f.backfilling and buf_text(f.buf):find("end of turn") ~= nil
    end, 50)
    assert(ok, "feed did not render within 5s:\n" .. buf_text(f.buf))
    local text = buf_text(f.buf)
    assert(text:find("▸ todo  + Ship the thing", 1, true), text)
    assert(text:find("▸ ask   (2)", 1, true), text)

    -- expand the question fold and confirm the chosen answer(s) show up
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)) do
      if l:find("▸ ask   (2)", 1, true) then
        row = i
      end
    end
    assert(row, "question fold head not found:\n" .. text)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    text = buf_text(f.buf)
    assert(text:find("▾ ask   (2)", 1, true), "question fold glyph should flip:\n" .. text)
    assert(text:find("→ chosen:", 1, true), "expanded question body missing a chosen answer:\n" .. text)

    feed.close(f.buf)
    vim.fn.delete(path)
  end,
}
