---@module 'giroux.nodes'
--- Tailnet node resolution. config.nodes maps node name -> NodeConfig; the
--- implicit node "local" is this machine (host = nil). With config.discover on,
--- online tailnet peers are merged in from `tailscale status --json` (explicit
--- config always wins). Discovery is cached; M.all() reads it synchronously.

local ssh = require("giroux.ssh")

local M = {}

local discovered = {} ---@type table<string, {host: string, claude_projects: string, os: string|nil}>
local discovered_at = 0

---Parse `tailscale status --json` into node name -> entry. The node name is the
---MagicDNS short name (first label of DNSName) — that is the ssh target, NOT
---HostName, which is the device's local hostname and can be "localhost"/wrong.
---Only online peers; macOS-only by default (giroux's discovery is BSD today);
---optional ACL tag filter. Tolerant: bad JSON / not-Running yields {}.
---@param json string
---@param opts {tag?: string, macos_only?: boolean}|nil
---@return table<string, {host: string, claude_projects: string, os: string}>
function M.parse_tailscale(json, opts)
  opts = opts or {}
  local ok, st = pcall(vim.json.decode, json or "", { luanil = { object = true, array = true } })
  if not ok or type(st) ~= "table" or st.BackendState ~= "Running" then
    return {}
  end
  local out = {}
  for _, p in pairs(st.Peer or {}) do
    if type(p) == "table" and p.Online == true and type(p.DNSName) == "string" then
      local name = p.DNSName:match("^([^.]+)") -- MagicDNS short name = ssh target
      local os_ok = not opts.macos_only or p.OS == "macOS"
      local tag_ok = not opts.tag
      if opts.tag then
        for _, t in ipairs(p.Tags or {}) do
          if t == opts.tag then
            tag_ok = true
            break
          end
        end
      end
      if name and name ~= "" and os_ok and tag_ok then
        out[name] = { host = name, claude_projects = "~/.claude/projects", os = p.OS }
      end
    end
  end
  return out
end

---@return table<string, {host: string|nil, claude_projects: string, os: string|nil}>
function M.all()
  local cfg = require("giroux").config
  local nodes = { ["local"] = { host = nil, claude_projects = vim.fn.expand("~/.claude/projects") } }
  for name, nc in pairs(cfg.nodes or {}) do
    nodes[name] = {
      -- host = false means "run locally" (a second local root, used by tests)
      host = nc.host ~= false and (nc.host or name) or nil,
      claude_projects = nc.claude_projects or "~/.claude/projects",
    }
  end
  -- merge discovered tailnet peers; explicit config always wins
  if cfg.discover then
    for name, dn in pairs(discovered) do
      if not nodes[name] then
        nodes[name] = { host = dn.host, claude_projects = dn.claude_projects, os = dn.os }
      end
    end
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

---Refresh the discovered-node cache from `tailscale status --json` (runs
---locally). No-op (and clears the cache) when config.discover is off. cb() once.
---@param cb fun()|nil
local refreshing = false
local pending = {} ---@type fun()[] callbacks waiting on the in-flight refresh
function M.refresh(cb)
  local cfg = require("giroux").config
  if not cfg.discover then
    discovered = {}
    discovered_at = os.time()
    return cb and cb()
  end
  if cb then
    pending[#pending + 1] = cb
  end
  if refreshing then
    return -- coalesce overlapping calls; the in-flight refresh fires all queued cbs
  end
  refreshing = true
  ssh.exec(nil, "tailscale status --json 2>/dev/null", function(ok, stdout)
    refreshing = false
    discovered = ok and M.parse_tailscale(stdout, { tag = cfg.discover_tag, macos_only = true }) or {}
    discovered_at = os.time()
    local cbs = pending
    pending = {}
    for _, c in ipairs(cbs) do
      c() -- callers queued mid-flight (e.g. monitor.start) now see the populated cache
    end
  end)
end

---Synchronous refresh for one-shot, blocking consumers (e.g. :checkhealth),
---which can't wait on the async callback. Runs `tailscale status` locally.
function M.refresh_sync()
  local cfg = require("giroux").config
  if not cfg.discover then
    discovered = {}
    discovered_at = os.time()
    return
  end
  local ok, res = pcall(function()
    return vim.system({ "sh", "-c", "tailscale status --json 2>/dev/null" }, { text = true }):wait()
  end)
  if ok and res.code == 0 then
    discovered = M.parse_tailscale(res.stdout or "", { tag = cfg.discover_tag, macos_only = true })
  end
  discovered_at = os.time()
end

---Refresh discovery if it's enabled and the cache is older than 60s. Fire and
---forget — the next tick reads the freshened cache.
function M.maybe_refresh()
  local cfg = require("giroux").config
  if cfg.discover and (os.time() - discovered_at) > 60 then
    M.refresh()
  end
end

return M
