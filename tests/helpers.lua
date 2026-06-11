-- Shared test helpers.
local M = {}

---Skip the current spec (raises a SKIP sentinel the runner recognizes) when
---a precondition is false — e.g. a tool or platform the spec needs.
---@param cond any
---@param reason string
function M.skip_unless(cond, reason)
  if not cond then
    error("SKIP: " .. reason, 0)
  end
end

---@param bin string
---@return boolean
function M.has(bin)
  return vim.fn.executable(bin) == 1
end

---True on a BSD-stat platform (macOS), which giroux's stat -f / tail -F
---integration paths require until Linux support lands.
---@return boolean
function M.is_macos()
  return vim.uv.os_uname().sysname == "Darwin"
end

return M
