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
      elseif uname ~= "" then
        h.error(uname .. " — unsupported for now; giroux uses BSD stat/tail (macOS). Linux support is planned.")
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
      -- Emit a marked line: a login shell may print profile chatter to stdout,
      -- so key off the marker, not "non-empty output" (which a noisy ~/.zprofile
      -- would falsely satisfy — a false "token present").
      local _, tok = on_node('printf "giroux-auth:%s\\n" "${CLAUDE_CODE_OAUTH_TOKEN:+T}${ANTHROPIC_API_KEY:+K}"', true)
      if (tok or ""):find("giroux%-auth:[TK]") then
        h.ok("agent auth: token present in login env")
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
