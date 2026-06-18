local nodes = require("giroux.nodes")

local function status(peers, backend)
  return vim.json.encode({ BackendState = backend or "Running", Peer = peers })
end

return {
  ["nodes: parse_tailscale keys on the MagicDNS name, not HostName"] = function()
    local json = status({
      a = { HostName = "Sams-Mac-mini", DNSName = "gintoki.tailnet.ts.net.", OS = "macOS", Online = true },
    })
    local m = nodes.parse_tailscale(json)
    assert(m.gintoki, "node keyed by DNSName short name, got: " .. vim.inspect(vim.tbl_keys(m)))
    assert(m.gintoki.host == "gintoki", "host is the ssh target")
    assert(m["Sams-Mac-mini"] == nil, "must not key on HostName")
  end,

  ["nodes: parse_tailscale keeps only online macOS peers by default"] = function()
    local json = status({
      a = { DNSName = "gintoki.x.ts.net.", OS = "macOS", Online = true },
      b = { DNSName = "neoeig.x.ts.net.", OS = "macOS", Online = true },
      c = { DNSName = "madao.x.ts.net.", OS = "macOS", Online = false }, -- offline
      d = { DNSName = "kagura.x.ts.net.", OS = "windows", Online = true }, -- not macOS
      e = { DNSName = "toshiro.x.ts.net.", OS = "iOS", Online = true }, -- not macOS
    })
    local m = nodes.parse_tailscale(json, { macos_only = true })
    assert(m.gintoki and m.neoeig, "online macOS peers kept")
    assert(not m.madao, "offline dropped")
    assert(not m.kagura and not m.toshiro, "non-macOS dropped")
  end,

  ["nodes: parse_tailscale tag filter"] = function()
    local json = status({
      a = { DNSName = "gintoki.x.ts.net.", OS = "macOS", Online = true, Tags = { "tag:agent-host" } },
      b = { DNSName = "neoeig.x.ts.net.", OS = "macOS", Online = true, Tags = { "tag:other" } },
      c = { DNSName = "madao.x.ts.net.", OS = "macOS", Online = true }, -- no tags
    })
    local m = nodes.parse_tailscale(json, { tag = "tag:agent-host" })
    assert(m.gintoki, "tagged peer kept")
    assert(not m.neoeig and not m.madao, "untagged peers dropped")
  end,

  ["nodes: parse_tailscale tolerates not-Running / bad json"] = function()
    assert(vim.tbl_isempty(nodes.parse_tailscale(status({}, "NeedsLogin"))))
    assert(vim.tbl_isempty(nodes.parse_tailscale("not json")))
    assert(vim.tbl_isempty(nodes.parse_tailscale("")))
  end,
}
