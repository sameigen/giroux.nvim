---@module 'giroux.notify'
--- Interrupt-worthy moments (question / dead / tripwire) routed through the
--- channels in config.notify.levels (statusline badge | vim.notify | macOS
--- osascript). Fires once per state-entry; seed() counts a pre-existing
--- condition on the badge without a banner. See PLAN.md §5.

local M = {}

local fired = {} ---@type table<string, boolean> dedupe key -> true
local badge = { question = 0, dead = 0, tripwire = 0, end_of_turn = 0 }

---The statusline badge, e.g. "  2  ✓3  ✗1". Empty when nothing is waiting.
---Put `%{v:lua.require'giroux.notify'.statusline()}` in your statusline.
---@return string
function M.statusline()
  local parts = {}
  -- ordered by urgency, matching the roster: needs-you, dead, done.
  if badge.question > 0 then
    parts[#parts + 1] = " " .. badge.question
  end
  if badge.dead > 0 then
    parts[#parts + 1] = "✗" .. badge.dead
  end
  if badge.end_of_turn > 0 then
    parts[#parts + 1] = "✓" .. badge.end_of_turn
  end
  if badge.tripwire > 0 then
    parts[#parts + 1] = "" .. badge.tripwire
  end
  return #parts > 0 and ("giroux " .. table.concat(parts, " ")) or ""
end

---@param event string
---@return "statusline"|"notify"|"macos"|false
local function channel(event)
  return require("giroux").config.notify.levels[event] or false
end

local function osascript(msg, title)
  local cfg = require("giroux").config.notify
  if vim.g.giroux_focused and not cfg.macos_when_focused then
    return
  end
  -- No osascript off macOS (e.g. a Linux node): degrade to vim.notify rather than
  -- crash. vim.system raises ENOENT for a missing command, which — since the
  -- default channel for question/dead is "macos" — would otherwise blow up the
  -- monitor's derive() on the first ✗/? on Linux.
  if vim.fn.executable("osascript") ~= 1 then
    return vim.notify("giroux: " .. msg, vim.log.levels.INFO)
  end
  pcall(vim.system, {
    "osascript",
    "-e",
    ('display notification %q with title %q sound name "Glass"'):format(msg, title or "giroux"),
  })
end

---Fire a notification for an event on a session, deduped per state-entry.
---@param event "question"|"dead"|"tripwire"
---@param session giroux.Session
---@param msg string
function M.fire(event, session, msg)
  local k = event .. "\0" .. (session.path or "?")
  if fired[k] then
    return
  end
  fired[k] = true
  badge[event] = (badge[event] or 0) + 1

  local ch = channel(event == "tripwire" and "question" or event) -- tripwires ride the question channel
  if ch == "macos" then
    osascript(msg, "giroux · " .. (session.title or session.project or ""))
  elseif ch == "notify" then
    vim.notify("giroux: " .. msg, event == "dead" and vim.log.levels.WARN or vim.log.levels.INFO)
  end
  -- "statusline" and any value: the badge is already bumped above
  vim.cmd.redrawstatus()
end

---Seed a latch + badge WITHOUT sending to any channel: for conditions that
---were already true when the monitor started (a session found dead on open
---is not a fresh page-worthy event, but it should still count on the badge).
---@param event "question"|"dead"|"tripwire"
---@param session giroux.Session
function M.seed(event, session)
  local k = event .. "\0" .. (session.path or "?")
  if fired[k] then
    return
  end
  fired[k] = true
  badge[event] = (badge[event] or 0) + 1
  vim.cmd.redrawstatus()
end

---Clear an event's latch for a session once its condition no longer holds, so
---the next entry can fire again and the badge counts only live conditions.
---@param event string
---@param session giroux.Session
function M.clear(event, session)
  local k = event .. "\0" .. (session.path or "?")
  if fired[k] then
    fired[k] = nil
    badge[event] = math.max(0, (badge[event] or 1) - 1)
    vim.cmd.redrawstatus()
  end
end

---Reset all latches (e.g. monitor stop).
function M.reset()
  fired = {}
  badge = { question = 0, dead = 0, tripwire = 0, end_of_turn = 0 }
  pcall(vim.cmd.redrawstatus)
end

return M
