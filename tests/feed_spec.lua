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

  ["feed: question renders options as picker lines"] = function()
    local lines = feed._question_lines({
      questions = {
        {
          question = "Which way?",
          options = { { label = "tmux", description = "send-keys" }, { label = "sdk", description = "stream-json" } },
        },
      },
    })
    assert(lines[2] == "? Which way?", lines[2])
    assert(lines[3]:find("1. tmux — send%-keys"), lines[3])
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
}
