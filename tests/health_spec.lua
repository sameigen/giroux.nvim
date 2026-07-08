local health = require("giroux.health")

return {
  ["health: a valid token reads ok"] = function()
    local level, msg = health.auth_status("oauth", "200")
    assert(level == "ok", "200 is ok, got " .. tostring(level))
    assert(msg:find("valid", 1, true), "says valid: " .. msg)
    assert(msg:find("CLAUDE_CODE_OAUTH_TOKEN", 1, true), "names the var: " .. msg)
  end,

  ["health: a present-but-rejected token is an error, not a green"] = function()
    for _, code in ipairs({ "401", "403" }) do
      local level, msg = health.auth_status("oauth", code)
      assert(level == "error", code .. " must be an error (the false-green trap), got " .. tostring(level))
      assert(msg:find("REJECTED", 1, true), "calls it rejected: " .. msg)
      assert(msg:find("setup%-token"), "tells the user how to fix it: " .. msg)
    end
  end,

  ["health: an api key validates under its own label"] = function()
    local ok_level, ok_msg = health.auth_status("apikey", "200")
    assert(ok_level == "ok" and ok_msg:find("ANTHROPIC_API_KEY", 1, true), "api key label: " .. tostring(ok_msg))
    local bad_level = health.auth_status("apikey", "401")
    assert(bad_level == "error", "rejected api key is an error too")
  end,

  ["health: can't-validate degrades to warn, never a false ok or error"] = function()
    -- curl missing, an odd HTTP code, or no response at all: token is present but
    -- unconfirmed — warn, so we neither cry wolf (error) nor lie green (ok).
    local nocurl_level, nocurl_msg = health.auth_status("oauth", "nocurl")
    assert(nocurl_level == "warn", "nocurl -> warn")
    assert(nocurl_msg:find("curl", 1, true), "nocurl message mentions curl: " .. nocurl_msg)
    assert(select(1, health.auth_status("oauth", "500")) == "warn", "5xx -> warn")
    assert(select(1, health.auth_status("oauth", "")) == "warn", "no response -> warn")
  end,

  ["health: no credential defers to the caller's keychain fallback"] = function()
    assert(health.auth_status("none", "") == nil, "none -> nil (caller handles keychain/creds fallback)")
    assert(health.auth_status("", "") == nil, "unparsed -> nil")
  end,
}
