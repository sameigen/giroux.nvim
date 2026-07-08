local todos = require("giroux.todos")
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

-- tool_use assistant record (mirrors tests/stats_spec.lua's helper).
local function tool_use(id, name, input)
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-07-08T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
    },
  }
end

-- tool_result user record; `detail` becomes toolUseResult.
local function result(id, detail)
  return {
    type = "user",
    uuid = "u" .. id,
    sessionId = "s",
    message = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = "ok" } } },
    toolUseResult = detail,
  }
end

-- A create+its-result pair exactly as the real corpus writes them (2026-07
-- census, ~/.claude/projects/.../81a2cdf3-*.jsonl): tool_use TaskCreate
-- carries no id; the id is assigned in the tool_result's {task={id,subject}}.
local function create(tool_use_id, real_id, subject, extra)
  extra = extra or {}
  local input = {
    subject = subject,
    description = extra.description or (subject .. " — details"),
    activeForm = extra.activeForm or ("Working: " .. subject),
  }
  return {
    tool_use(tool_use_id, "TaskCreate", input),
    result(tool_use_id, { task = { id = real_id, subject = subject } }),
  }
end

-- A TaskUpdate call + its (real-shape) result: {success, taskId, updatedFields, statusChange}.
-- This module never reads the result — included here only for realism.
local function update(tool_use_id, real_id, fields)
  local input = vim.tbl_extend("force", { taskId = real_id }, fields)
  return {
    tool_use(tool_use_id, "TaskUpdate", input),
    result(tool_use_id, { success = true, taskId = real_id, updatedFields = vim.tbl_keys(fields) }),
  }
end

local function flat(...)
  local out = {}
  for _, group in ipairs({ ... }) do
    vim.list_extend(out, group)
  end
  return out
end

return {
  ["todos: TaskCreate is invisible until its tool_result assigns the real id"] = function()
    local acc = todos.new()
    local recs = create("toolu_1", "1", "Ship the thing")
    local p = transcript.parser()
    for _, e in ipairs(p:feed(J(recs[1]) .. "\n")) do
      acc:add(e)
    end
    assert(acc:summary().total == 0, "uncommitted create must not count yet: " .. vim.inspect(acc:summary()))
    for _, e in ipairs(p:feed(J(recs[2]) .. "\n")) do
      acc:add(e)
    end
    local sum = acc:summary()
    assert(sum.total == 1 and sum.pending == 1, vim.inspect(sum))
  end,

  ["todos: create -> in_progress -> completed drives the counters"] = function()
    local evs = events(
      flat(
        create("toolu_1", "1", "Verify dev loop"),
        create("toolu_2", "2", "Install stylua"),
        update("toolu_3", "1", { status = "in_progress" }),
        update("toolu_4", "1", { status = "completed" }),
        update("toolu_5", "2", { status = "in_progress" })
      )
    )
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 2, vim.inspect(sum))
    assert(sum.done == 1, vim.inspect(sum))
    assert(sum.in_progress == 1, vim.inspect(sum))
    assert(sum.pending == 0, vim.inspect(sum))
    assert(sum.current == "Install stylua", vim.inspect(sum))
  end,

  ["todos: status deleted excludes from total"] = function()
    local evs = events(
      flat(
        create("toolu_1", "1", "Task A"),
        create("toolu_2", "2", "Task B"),
        update("toolu_3", "2", { status = "deleted" })
      )
    )
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 1, vim.inspect(sum))
    assert(sum.pending == 1, vim.inspect(sum))
  end,

  ["todos: TaskUpdate for an unknown id creates a placeholder (robust to a missed create)"] = function()
    local evs = events(update("toolu_9", "99", { status = "in_progress" }))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 1, vim.inspect(sum))
    assert(sum.in_progress == 1, vim.inspect(sum))
    assert(sum.current == "task 99", vim.inspect(sum)) -- no subject known -> id fallback
  end,

  ["todos: current falls back to the most recently touched task when none in_progress"] = function()
    local evs = events(
      flat(
        create("toolu_1", "1", "First"),
        create("toolu_2", "2", "Second"),
        update("toolu_3", "1", { status = "completed" })
      )
    )
    local sum = todos.aggregate(evs):summary()
    assert(sum.in_progress == 0, vim.inspect(sum))
    assert(sum.current == "First", vim.inspect(sum)) -- most recently touched (the completion)
  end,

  ["todos: description-only TaskUpdate (no status key) leaves status untouched"] = function()
    -- real corpus: {"taskId": "10", "description": "..."} with NO status field
    local evs = events(
      flat(
        create("toolu_1", "10", "Grouped roster"),
        update("toolu_2", "10", { status = "in_progress" }),
        update("toolu_3", "10", { description = "narrowed scope" })
      )
    )
    local sum = todos.aggregate(evs):summary()
    assert(sum.in_progress == 1, "status must survive a description-only update: " .. vim.inspect(sum))
    assert(sum.current == "Grouped roster", vim.inspect(sum))
  end,

  ["todos: TaskStop honors an explicit status; otherwise best-effort treated as deleted"] = function()
    local evs = events(flat(create("toolu_1", "1", "Task A"), { tool_use("toolu_2", "TaskStop", { taskId = "1" }) }))
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 0, "TaskStop with no status assumed deleted: " .. vim.inspect(sum))

    local evs2 = events(
      flat(
        create("toolu_3", "2", "Task B"),
        { tool_use("toolu_4", "TaskStop", { taskId = "2", status = "completed" }) }
      )
    )
    local sum2 = todos.aggregate(evs2):summary()
    assert(sum2.total == 1 and sum2.done == 1, "TaskStop with explicit status honors it: " .. vim.inspect(sum2))
  end,

  ["todos: missing input fields never crash (defensive)"] = function()
    local acc = todos.new()
    acc:add({ kind = "tool_call", name = "TaskCreate", id = "x" }) -- input is nil
    acc:add({ kind = "tool_result", id = "x", detail = nil })
    acc:add({ kind = "tool_call", name = "TaskUpdate", id = "y", input = {} }) -- no taskId
    acc:add({ kind = "tool_call", name = "TaskStop", id = "z", input = nil })
    local ok, sum = pcall(function()
      return acc:summary()
    end)
    assert(ok, tostring(sum))
    assert(sum.total == 1 and sum.current == "task x", vim.inspect(sum)) -- only the TaskCreate resolved
  end,

  ["todos: non-Task events are ignored, not counted"] = function()
    local evs = events({
      tool_use("e1", "Edit", { file_path = "/a.rs" }),
      result("e1", { structuredPatch = {} }),
    })
    local sum = todos.aggregate(evs):summary()
    assert(sum.total == 0, vim.inspect(sum))
    assert(sum.current == nil, vim.inspect(sum))
  end,
}
