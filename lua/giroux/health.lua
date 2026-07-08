---@module 'giroux.health'
--- :checkhealth giroux — local prerequisites, then each configured node:
--- reachable over ssh, tmux present, claude present, transcript dir readable.

local ssh = require("giroux.ssh")

local M = {}

local function run(argv)
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait()
  end)
  if not ok then
    return 1, "", tostring(res)
  end
  return res.code, res.stdout or "", res.stderr or ""
end

-- The node-side auth probe: pick the credential claude would use and validate
-- it against /v1/models (an auth check, no completion / no billing). The token
-- never leaves the node — only the resulting HTTP code comes back. A
-- CLAUDE_CODE_OAUTH_TOKEN goes as a Bearer (how Claude Code sends it), an
-- ANTHROPIC_API_KEY as x-api-key. /v1/models needs no beta header: a good
-- credential is a clean 200, a stale/revoked one a 401.
M.AUTH_PROBE = [[
kind=none; hdr=
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  kind=oauth; hdr="Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
  kind=apikey; hdr="x-api-key: $ANTHROPIC_API_KEY"
fi
if [ "$kind" = none ]; then printf 'giroux-auth:none:\n'
elif command -v curl >/dev/null 2>&1; then
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://api.anthropic.com/v1/models -H "$hdr" -H "anthropic-version: 2023-06-01")
  printf 'giroux-auth:%s:%s\n' "$kind" "$c"
else printf 'giroux-auth:%s:nocurl\n' "$kind"; fi
]]

---Classify the node auth probe into a health line. Pure — unit-tested.
---Returns nil for the no-credential case so the caller runs the keychain /
---credentials-file fallback (which needs node context).
---@param kind string "oauth"|"apikey"|"none"
---@param status string HTTP code, "nocurl", or "" (no response)
---@return "ok"|"warn"|"error"|nil level, string|nil msg
function M.auth_status(kind, status)
  if kind ~= "oauth" and kind ~= "apikey" then
    return nil
  end
  local label = kind == "oauth" and "CLAUDE_CODE_OAUTH_TOKEN" or "ANTHROPIC_API_KEY"
  local code = tonumber(status)
  if code == 200 then
    return "ok", "agent auth: " .. label .. " present and valid (HTTP 200)"
  elseif code == 401 or code == 403 then
    return "error",
      ("agent auth: %s present but REJECTED (HTTP %d) — the token is stale or revoked, so dispatched "):format(
        label,
        code
      ) .. "agents will hit /login. Regenerate with `claude setup-token`, update where it's exported " .. "(e.g. ~/.zshenv), then kill any long-lived `tmux` server on the node so new sessions pick it up."
  elseif status == "nocurl" then
    return "warn", "agent auth: " .. label .. " present, but curl is missing on the node — cannot validate it"
  elseif code then
    return "warn",
      ("agent auth: %s present but validation returned HTTP %d (network/proxy?) — could not confirm"):format(
        label,
        code
      )
  end
  return "warn", "agent auth: " .. label .. " present but validation got no response — could not confirm"
end

function M.check()
  local h = vim.health
  local nodes = require("giroux.nodes")

  h.start("giroux")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim >= 0.11")
  else
    h.error("Neovim >= 0.11 required")
  end
  for _, bin in ipairs({ "ssh", "tmux" }) do
    if vim.fn.executable(bin) == 1 then
      h.ok(bin .. " found")
    else
      h.error(bin .. " not found" .. (bin == "tmux" and " — capture, dispatch, and steering need it" or ""))
    end
  end
  if vim.fn.executable("tailscale") == 1 then
    h.ok("tailscale CLI found")
  else
    h.info("tailscale CLI not found (only needed for node auto-discovery)")
  end

  local zshrc = vim.fn.expand("~/.zshrc")
  if vim.fn.filereadable(zshrc) == 1 then
    vim.fn.system({ "grep", "-q", "claude-wrapper.zsh", zshrc })
    if vim.v.shell_error == 0 then
      h.ok("claude wrapper sourced in ~/.zshrc")
    else
      h.info(
        "claude wrapper not sourced in ~/.zshrc — hand-started sessions won't be steerable (scripts/claude-wrapper.zsh)"
      )
    end
  end

  nodes.refresh_sync() -- one-shot: populate discovered nodes synchronously so they appear here
  for name, node in pairs(nodes.all()) do
    h.start("giroux node: " .. name .. (node.host and (" (" .. node.host .. ")") or " (local)"))
    if node.host then
      local code = run({ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", node.host, "true" })
      if code ~= 0 then
        h.error(("unreachable over ssh (%s)"):format(node.host))
        goto continue
      end
      h.ok("reachable over ssh")
    end
    do
      ---@param cmd string
      ---@param login boolean|nil run under a login shell (matches dispatch: brew PATH + auth env)
      local function on_node(cmd, login)
        if login then
          cmd = ssh.login_wrap(cmd)
        end
        if node.host then
          return run({ "ssh", "-o", "BatchMode=yes", node.host, cmd })
        end
        return run({ "sh", "-c", cmd })
      end
      local _, uname = on_node("uname -s")
      uname = vim.trim(uname or "")
      if uname == "Darwin" then
        h.ok("macOS (BSD stat/tail)")
      elseif uname == "Linux" then
        h.ok("Linux (GNU stat/tail)")
      elseif uname ~= "" then
        h.warn(uname .. " — unverified; giroux supports macOS and Linux nodes")
      end
      -- probe under a login shell: dispatch/steer run that way, so this matches
      -- reality (Homebrew's /opt/homebrew/bin isn't on the bare ssh PATH).
      local tcode = on_node("command -v tmux", true)
      h[tcode == 0 and "ok" or "warn"](tcode == 0 and "tmux present" or "tmux missing — steering unavailable here")
      local ccode = on_node("command -v claude", true)
      h[ccode == 0 and "ok" or "warn"](
        ccode == 0 and "claude present" or "claude missing — dispatch unavailable here"
      )
      -- Auth: dispatched agents run under a login shell; without a token in the
      -- login env they fall back to the GUI keychain, which is locked over ssh —
      -- so claude hard-blocks on /login at the first message. (macOS-only risk;
      -- Linux reads ~/.claude/.credentials.json, which is readable anywhere.)
      -- We don't just check presence: a *present but stale* token is the trap —
      -- it reads as "configured" yet 401s mid-task — so the probe validates the
      -- token against /v1/models and keys off the marked line (a login shell may
      -- print profile chatter, so match the marker, not "non-empty output").
      local _, tok = on_node(M.AUTH_PROBE, true)
      local kind, status = (tok or ""):match("giroux%-auth:(%a*):(%w*)")
      local level, msg = M.auth_status(kind or "", status or "")
      if level then
        h[level](msg)
      elseif uname == "Darwin" then
        h.warn(
          "no CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY in the login env — dispatched agents will hit /login "
            .. "(the macOS keychain is locked over ssh). Fix: run `claude setup-token`, then add "
            .. "`export CLAUDE_CODE_OAUTH_TOKEN=…` to ~/.zshenv"
        )
      else
        local acode = on_node("test -r ~/.claude/.credentials.json && echo ok")
        h[acode == 0 and "ok" or "warn"](
          acode == 0 and "agent auth: credentials file present (~/.claude/.credentials.json)"
            or "no auth token and no ~/.claude/.credentials.json — run `claude setup-token` or `claude` (/login)"
        )
      end
      local dcode, dout = on_node("test -r " .. node.claude_projects .. " && echo ok")
      local readable = dcode == 0 and (dout or ""):find("ok") ~= nil
      h[readable and "ok" or "warn"](
        "transcript dir " .. (readable and "readable: " or "not readable: ") .. node.claude_projects
      )
    end
    ::continue::
  end
end

return M
