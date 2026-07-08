---@module 'giroux.todos'
--- Pure fold of Task* tool events into a live todo model. No IO, no buffer —
--- mirrors giroux.stats's accumulator shape (see stats.lua) so monitor.lua
--- can thread it exactly the way it already threads stats: one `todos.new()`
--- per tracker, `tr.todos:add(e)` per event, `tr.session.todos = tr.todos:summary()`.
---
--- Real corpus shapes (2026-07-08 census, live ~/.claude/projects transcripts):
---   TaskCreate tool_use input:     {subject, description, activeForm?}  -- NO id
---   TaskCreate tool_result detail: {task = {id, subject}}               -- id assigned HERE
---   TaskUpdate tool_use input:     {taskId, status?, description?, ...} -- status is
---     OPTIONAL: a real TaskUpdate call was observed carrying only
---     {taskId, description} with no status change at all.
---   TaskUpdate tool_result detail: {success, taskId, updatedFields, statusChange={from,to}}
---     -- NOT {task = ...}. This module never reads a TaskUpdate's tool_result;
---     -- taskId/status ride the tool_use input, which is always present the
---     -- moment the update takes effect.
---   TaskStop: present in the tool vocabulary but ZERO real invocations found
---     in the census (the string only ever appears inside tool-listing
---     metadata). Treated conservatively — see Acc:add.

local M = {}

---@class giroux.todos.Task
---@field id string
---@field subject string|nil
---@field description string|nil
---@field activeForm string|nil
---@field status string "pending"|"in_progress"|"completed"|"deleted"|string
---@field seq integer monotonic touch order, breaks "most recent" ties

---Tool names this module folds. Exported so other modules (feed's fold UX,
---monitor's dispatch) can detect a Task* event without re-listing the names.
---TaskGet/TaskList are deliberately excluded: read-only, never mutate a task.
M.TASK_TOOL_NAMES = { TaskCreate = true, TaskUpdate = true, TaskStop = true }

---@class giroux.todos.Acc
---@field tasks table<string, giroux.todos.Task>
---@field private pending_creates table<string, {subject: string|nil, description: string|nil, activeForm: string|nil}>
---@field private seq integer
local Acc = {}
Acc.__index = Acc

function M.new()
  return setmetatable({
    tasks = {},
    pending_creates = {},
    seq = 0,
  }, Acc)
end

---Fetch-or-create a task by id and bump its touch order. Robust to updates
---for unknown ids (create-on-update): the TaskCreate landed before this
---tracker attached, or a TaskUpdate references an id this stream never saw
---created.
---@param self giroux.todos.Acc
---@param id string
---@return giroux.todos.Task
local function touch(self, id)
  local t = self.tasks[id]
  if not t then
    t = { id = id, status = "pending", seq = 0 }
    self.tasks[id] = t
  end
  self.seq = self.seq + 1
  t.seq = self.seq
  return t
end

---@param e giroux.transcript.Event
function Acc:add(e)
  if e.kind == "tool_call" then
    if e.name == "TaskCreate" then
      -- buffer: the real task id isn't known until the tool_result lands
      -- (TaskCreate's own input never carries one — see module header).
      if e.id then
        local input = e.input or {}
        self.pending_creates[e.id] =
          { subject = input.subject, description = input.description, activeForm = input.activeForm }
      end
    elseif e.name == "TaskUpdate" then
      local input = e.input or {}
      local id = input.taskId and tostring(input.taskId)
      if id then
        local t = touch(self, id)
        if input.subject then
          t.subject = input.subject
        end
        if input.description then
          t.description = input.description
        end
        if input.status then -- optional: a description-only update omits it
          t.status = input.status
        end
      end
    elseif e.name == "TaskStop" then
      -- Unverified shape (no real invocation on disk as of 2026-07-08 — the
      -- string appears only inside tool-vocabulary listings). Best-effort:
      -- honor an explicit status if the input carries one, otherwise assume
      -- "stop" means "drop it from the active total". Revisit once a real
      -- TaskStop call is on disk.
      local input = e.input or {}
      local id = input.taskId and tostring(input.taskId)
      if id then
        touch(self, id).status = input.status or "deleted"
      end
    end
  elseif e.kind == "tool_result" then
    local created = e.id and self.pending_creates[e.id]
    if created then
      self.pending_creates[e.id] = nil
      local detail = e.detail
      local task_detail = type(detail) == "table" and detail.task or nil
      local id = (type(task_detail) == "table" and task_detail.id and tostring(task_detail.id)) or e.id
      local t = touch(self, id)
      t.subject = (type(task_detail) == "table" and task_detail.subject) or created.subject
      t.description = created.description
      t.activeForm = created.activeForm
    end
  end
end

---@return {total: integer, done: integer, in_progress: integer, pending: integer, current: string|nil}
function Acc:summary()
  local total, done, in_progress, pending = 0, 0, 0, 0
  local current, current_seq = nil, -1
  local latest, latest_seq = nil, -1
  for _, t in pairs(self.tasks) do
    if t.status ~= "deleted" then
      total = total + 1
      local label = t.subject or ("task " .. t.id)
      if t.status == "completed" then
        done = done + 1
      elseif t.status == "in_progress" then
        in_progress = in_progress + 1
        if t.seq > current_seq then
          current, current_seq = label, t.seq
        end
      else -- "pending" or an unrecognized status folds into pending
        pending = pending + 1
      end
      if t.seq > latest_seq then
        latest, latest_seq = label, t.seq
      end
    end
  end
  return { total = total, done = done, in_progress = in_progress, pending = pending, current = current or latest }
end

---Aggregate a list of events in one call (mirrors stats.aggregate).
---@param events giroux.transcript.Event[]
---@return giroux.todos.Acc
function M.aggregate(events)
  local acc = M.new()
  for _, e in ipairs(events) do
    acc:add(e)
  end
  return acc
end

return M
