---@module 'giroux.nodes'
--- Tailnet node resolution. config.nodes maps node name -> NodeConfig; the
--- implicit node "local" is this machine (host = nil). Discovery via
--- `tailscale status` comes later; explicit config wins today.

local M = {}

---@return table<string, {host: string|nil, claude_projects: string}>
function M.all()
  local cfg = require("giroux").config
  local nodes = { ["local"] = { host = nil, claude_projects = vim.fn.expand("~/.claude/projects") } }
  for name, nc in pairs(cfg.nodes) do
    nodes[name] = {
      -- host = false means "run locally" (a second local root, used by tests)
      host = nc.host ~= false and (nc.host or name) or nil,
      claude_projects = nc.claude_projects or "~/.claude/projects",
    }
  end
  return nodes
end

---@param name string|nil node name; nil/"" -> "local"
---@return string name, {host: string|nil, claude_projects: string}|nil
function M.get(name)
  if not name or name == "" then
    name = "local"
  end
  return name, M.all()[name]
end

return M
