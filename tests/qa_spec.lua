local qa = require("giroux.qa")
local transcript = require("giroux.transcript")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end
local function events(records)
  local p = transcript.parser()
  local out = {}
  for _, r in ipairs(records) do
    vim.list_extend(out, p:feed(J(r) .. "\n"))
  end
  return out
end
local function user(text)
  return {
    type = "user",
    uuid = "u" .. text:sub(1, 3),
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = { role = "user", content = text },
  }
end
local function asst(blocks)
  return {
    type = "assistant",
    uuid = "a" .. tostring(#blocks),
    sessionId = "s",
    timestamp = "2026-06-11T05:00:01.000Z",
    message = {
      id = "m" .. tostring(math.random and 1 or 1),
      model = "claude-fable-5",
      role = "assistant",
      content = blocks,
      stop_reason = vim.NIL,
      usage = { input_tokens = 1, output_tokens = 1 },
    },
  }
end

return {
  ["qa: builds exchanges, collapses tools, keeps prose"] = function()
    local evs = events({
      user("first question"),
      asst({ { type = "text", text = "let me look" } }),
      asst({ { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls" } } }),
      asst({ { type = "tool_use", id = "t2", name = "Edit", input = { file_path = "/x" } } }),
      asst({ { type = "text", text = "done, here is the answer" } }),
      user("second question"),
      asst({ { type = "text", text = "second answer" } }),
    })
    local ex = qa._build(evs)
    assert(#ex == 2, "two exchanges, got " .. #ex)
    assert(ex[1].user == "first question")
    assert(vim.deep_equal(ex[1].answer, { "let me look", "done, here is the answer" }), vim.inspect(ex[1].answer))
    assert(ex[1].tool_n == 2 and ex[1].tools.Bash == 1 and ex[1].tools.Edit == 1)
    assert(ex[2].user == "second question" and ex[2].answer[1] == "second answer")
  end,

  ["qa: render shows turns, answers, collapsed tools; turns navigable"] = function()
    local ex = qa._build(events({
      user("my question here"),
      asst({ { type = "text", text = "my answer" } }),
      asst({ { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls" } } }),
    }))
    local lines, decos, turns = qa._render(ex)
    local text = table.concat(lines, "\n")
    assert(text:find("my question here", 1, true), text)
    assert(text:find("my answer", 1, true))
    assert(text:find("⋯ 1 tool: bash×1", 1, true), "tool calls must collapse to a count: " .. text)
    assert(#turns == 1 and turns[1].text == "my question here")
    -- the turn's first line carries the user decoration
    local has_user = false
    for _, d in ipairs(decos) do
      if d.line_hl == "GirouxUserMsg" and d.sign then
        has_user = true
      end
    end
    assert(has_user, "turn must carry user line decoration")
  end,

  ["qa: question options surface in the digest"] = function()
    local ex = qa._build(events({
      user("pick one"),
      asst({
        {
          type = "tool_use",
          id = "tq",
          name = "AskUserQuestion",
          input = { questions = { { question = "which?", options = { { label = "A", description = "a" } } } } },
        },
      }),
    }))
    local lines = qa._render(ex)
    local text = table.concat(lines, "\n")
    assert(text:find("? which?", 1, true), text)
    assert(text:find("1. A — a", 1, true), text)
  end,
}
