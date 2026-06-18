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

---True on a BSD-stat platform (macOS). Some integration specs (real zsh
---wrapper, BSD stat formatting) are macOS-specific.
---@return boolean
function M.is_macos()
  return vim.uv.os_uname().sysname == "Darwin"
end

---True where giroux's local discovery/tail paths work — macOS or Linux (both
---now supported: portable GNU/BSD stat + `tail -F`).
---@return boolean
function M.is_unix()
  local sys = vim.uv.os_uname().sysname
  return sys == "Darwin" or sys == "Linux"
end

return M
