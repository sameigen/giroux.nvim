---@module 'giroux.state'
--- The single source of truth for roster/monitor/feed state vocabulary: the
--- attention priority order and the glyph→label map. Duplicating these across
--- modules silently mis-sorts the roster against the monitor.

local M = {}

-- Attention priority: lower sorts first. ✓ (done/unseen) ranks under working
-- and above idle so "ready to review" floats up. See monitor.derive.
M.ORDER = { ["?"] = 1, ["✗"] = 2, ["●"] = 3, ["✓"] = 4, ["○"] = 5, ["~"] = 6, ["·"] = 7 }

M.LABEL = {
  ["?"] = "needs you",
  ["●"] = "working",
  ["✓"] = "done",
  ["○"] = "idle",
  ["✗"] = "dead",
  ["~"] = "stale",
  ["·"] = "starting",
}

---Sort rank for a state glyph (unknown glyphs sort last).
---@param glyph string
---@return integer
function M.rank(glyph)
  return M.ORDER[glyph] or 9
end

return M
