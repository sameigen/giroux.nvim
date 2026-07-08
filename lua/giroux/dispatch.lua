---@module 'giroux.dispatch'
--- :GirouxDispatch / :GirouxClean / resume. Launches agents detached in tmux
--- with GIROUX_SESSION_ID injected. See PLAN.md §3 and ARCHITECTURE.md.

local ssh = require("giroux.ssh")
local nodes = require("giroux.nodes")

local M = {}

---@param s string
---@return string
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---Quote a path for the remote shell while still letting a leading `~/`
---expand there (tilde inside quotes is literal).
---@param p string
---@return string
local function shq_path(p)
  local rest = p:match("^~/(.*)$")
  if rest then
    return "~/" .. shq(rest)
  end
  return shq(p)
end

---Write-to-send compose split (the parole idiom): :w submits, :q aborts.
---@param title string
---@param on_submit fun(text: string)
local function compose(title, on_submit)
  vim.cmd("botright 10split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "giroux://dispatch/" .. title)
  vim.wo[0].winbar = "%#Title#" .. title .. "%#Comment#  — :w dispatches, :q aborts"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.bo[buf].modified = false
      vim.api.nvim_win_close(0, true)
      if vim.trim(text) == "" then
        vim.notify("giroux: empty context, dispatch aborted", vim.log.levels.WARN)
        return
      end
      on_submit(text)
    end,
  })
  vim.cmd.startinsert()
end

---Per-session tmux styling (minimal status, mouse, title), mirroring the
---wrapper. Returns the set-option commands for one session.
---@param name string tmux session name
---@return string[]
local function styling(name)
  local set = function(opt, val)
    return ("tmux set-option -t %s %s %s >/dev/null"):format(shq(name), opt, val)
  end
  return {
    set("status", "on"),
    set("status-left", "'#S '"),
    set("status-left-length", "60"),
    set("status-right", "''"),
    set("status-style", "'bg=default,fg=colour244'"),
    set("mouse", "on"),
    set("set-titles", "on"),
    set("set-titles-string", "'#S'"),
  }
end

---Launch `argv` as a FOREGROUND JOB inside an interactive login shell in a fresh
---tmux session — not as the pane command. The shell gives job control (C-z
---suspends the agent to a prompt, `fg` resumes) and sources the profile (PATH +
---CLAUDE_CODE_OAUTH_TOKEN, so no /login hardblock). The argv travels base64 and
---is run via `eval`, so a multiline prompt can't break `send-keys` (a newline
---would submit early) and no quoting layer can mangle it.
---@param name string tmux session name
---@param id string GIROUX_SESSION_ID
---@param dir string cwd
---@param argv string[] the agent command + args
---@return string
local function job_launch(name, id, dir, argv)
  local b64 = vim.base64.encode(table.concat(vim.tbl_map(shq, argv), " "))
  local run = ('eval "$(printf %%s %s | base64 -d)"'):format(shq(b64))
  local parts = {
    ("tmux new-session -d -s %s -e GIROUX_SESSION_ID=%s -c %s"):format(shq(name), shq(id), shq(dir)),
    ("tmux send-keys -t %s %s Enter"):format(shq(name), shq(run)),
  }
  vim.list_extend(parts, styling(name))
  return table.concat(parts, " && ")
end

---Build the remote launch command. Exposed for tests.
---@param name string tmux session name
---@param id string GIROUX_SESSION_ID
---@param dir string cwd for the agent
---@param prompt string
---@param headless boolean|nil append dispatch.headless_flags (:GirouxDispatch!)
---@return string
function M.launch_cmd(name, id, dir, prompt, headless)
  local d = require("giroux").config.dispatch
  local argv = {}
  vim.list_extend(argv, d.cmd)
  vim.list_extend(argv, d.flags or {})
  if headless then
    vim.list_extend(argv, d.headless_flags or {})
  end
  argv[#argv + 1] = prompt
  return job_launch(name, id, dir, argv)
end

---@param secs integer
---@return string compact age ("12m" | "3h" | "5d")
local function age_short(secs)
  if secs < 3600 then
    return ("%dm"):format(math.max(0, math.floor(secs / 60)))
  elseif secs < 86400 then
    return ("%dh"):format(math.floor(secs / 3600))
  end
  return ("%dd"):format(math.floor(secs / 86400))
end

---Picker label for a repo: "<parent>/<name>" (short + recognizable, and what
---you fuzzy-match on) plus a recency hint. Avoids the ~-vs-absolute mismatch a
---root-prefix strip would hit (the remote `find ~/x` returns absolute paths).
---@param it {path: string, mtime: integer}
---@return string
local function repo_label(it)
  local parent = vim.fs.basename(vim.fs.dirname(it.path))
  local disp = (parent ~= "" and parent ~= ".") and (parent .. "/" .. vim.fs.basename(it.path))
    or vim.fs.basename(it.path)
  if it.mtime and it.mtime > 0 then
    return ("%-46s %s"):format(disp, age_short(os.time() - it.mtime))
  end
  return disp
end

---Parse the `find_repos` stdout ("<mtime>\t<repo>\n"...) into a repo list. Pure.
---@param stdout string
---@return {path: string, mtime: integer}[]
function M._parse_repos(stdout)
  local repos = {}
  for line in vim.gsplit(vim.trim(stdout or ""), "\n", { trimempty = true }) do
    local mtime, path = line:match("^(%d+)\t(.+)$")
    if path then
      repos[#repos + 1] = { path = path, mtime = tonumber(mtime) or 0 }
    end
  end
  return repos
end

---Find repos under a node's roots (per-node `roots`, else the global), newest
---first. One ssh round-trip; emits "<mtime>\t<repo>" so the picker can sort by
---recency and show an age. stat is portable (GNU -c, BSD -f); the while-read
---(IFS=, -r) keeps repo paths with spaces intact.
---@param node_name string
---@param cb fun(repos: {path: string, mtime: integer}[])
local function find_repos(node_name, cb)
  local _, node = nodes.get(node_name)
  local cfg = require("giroux").config
  local roots = table.concat(vim.tbl_map(shq_path, node.roots or cfg.roots), " ")
  -- built by concatenation, not :format — the body has literal '%' (stat -c %Y,
  -- ${g%/.git}, printf %s) that would read as format directives.
  local cmd = "find "
    .. roots
    .. " -maxdepth 3 -name .git \\( -type d -o -type f \\) 2>/dev/null"
    .. " | while IFS= read -r g; do d=${g%/.git};"
    .. ' m=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null);'
    .. ' printf \'%s\\t%s\\n\' "${m:-0}" "$d"; done | sort -rn'
  ssh.exec(node.host, cmd, function(ok, stdout)
    cb(ok and M._parse_repos(stdout) or {})
  end)
end

---True when a captured pane is showing Claude's folder-trust dialog (the only
---prompt dispatch auto-accepts — dispatching IS the trust decision). Pure.
---@param pane string tmux capture-pane output
---@return boolean
function M._is_trust_prompt(pane)
  return pane:find("trust this folder", 1, true) ~= nil or pane:find("Quick safety check", 1, true) ~= nil
end

---Fresh directories (notably worktrees) hit Claude's folder-trust dialog
---before any transcript exists. Dispatching IS the trust decision — the
---human picked the directory and composed the context — so confirm it.
---@param node_name string
---@param name string tmux session
local function accept_trust(node_name, name)
  local _, node = nodes.get(node_name)
  local tries = 0
  local function poll()
    tries = tries + 1
    local probe = ("tmux capture-pane -p -t %s 2>/dev/null"):format(shq(name))
    ssh.exec(node.host, ssh.login_wrap(probe), function(ok, stdout)
      if not ok then
        return
      end
      if M._is_trust_prompt(stdout) then
        ssh.exec(node.host, ssh.login_wrap(("tmux send-keys -t %s Enter"):format(shq(name))), function() end)
      elseif tries < 5 then
        vim.defer_fn(poll, 2000)
      end
    end)
  end
  vim.defer_fn(poll, 2000)
end

---True when a discovered session `s` is the transcript a dispatch just created:
---its parent dir matches the cwd slug AND it was born at/after the dispatch
---(minus a 5s clock-skew grace). Pure.
---@param s {path: string, birth: integer|nil}
---@param slug string
---@param since integer dispatch epoch seconds
---@return boolean
function M._is_dispatched_session(s, slug, since)
  return vim.fs.basename(vim.fs.dirname(s.path)) == slug and (s.birth or 0) >= since - 5
end

---Poll discovery for the transcript a fresh dispatch creates, then open its
---feed and pull it onto the roster.
---@param node_name string
---@param dir string agent cwd
---@param since integer epoch seconds of the dispatch
local function follow_new_session(node_name, dir, since)
  local tmuxctl = require("giroux.tmuxctl")
  local slug = tmuxctl.slugify(dir)
  local tries = 0
  local function poll()
    tries = tries + 1
    require("giroux.sessions").list({ node = node_name }, function(list)
      for _, s in ipairs(list) do
        if M._is_dispatched_session(s, slug, since) then
          require("giroux.monitor").discover()
          require("giroux.feed").open_path({ node = node_name, path = s.path })
          return
        end
      end
      if tries < 15 then
        vim.defer_fn(poll, 2000)
      else
        vim.notify("giroux: dispatched, but no transcript appeared yet — check the roster", vim.log.levels.WARN)
      end
    end)
  end
  vim.defer_fn(poll, 2000)
end

---@param node_name string
---@param dir string
---@param headless boolean|nil
local function launch_in(node_name, dir, headless)
  compose("agent context — " .. vim.fs.basename(dir), function(prompt)
    local _, node = nodes.get(node_name)
    local id = vim.fn.system("uuidgen"):lower():gsub("%-.*", ""):gsub("%s", "")
    local base = vim.fs.basename(dir):gsub("[^%w_-]", "-")
    local name = ("%s/%s-%s"):format(require("giroux").config.dispatch.tmux_prefix, base, id:sub(1, 4))
    -- outer login-wrap so `tmux` resolves on non-interactive ssh (Homebrew PATH)
    ssh.exec(node.host, ssh.login_wrap(M.launch_cmd(name, id, dir, prompt, headless)), function(ok, _, stderr)
      if not ok then
        return vim.notify("giroux: dispatch failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
      end
      vim.notify(("giroux: dispatched %s on %s"):format(name, node_name))
      if headless then
        vim.notify(("giroux: headless run %s dispatched fire-and-forget"):format(name))
      else
        accept_trust(node_name, name)
        follow_new_session(node_name, dir, os.time())
      end
    end)
  end)
end

---@param node_name string
---@param repo string
---@param headless boolean|nil
local function maybe_worktree(node_name, repo, headless)
  require("giroux.pick").open({
    items = { "run in the repo", "fresh worktree" },
    title = "where should the agent work?",
    format = tostring,
    on_choice = function(choice)
      if not choice then
        return
      end
      if choice == "run in the repo" then
        return launch_in(node_name, repo, headless)
      end
      vim.ui.input({ prompt = "branch name: ", default = "agent/" }, function(branch)
        if not branch or vim.trim(branch) == "" then
          return
        end
        local _, node = nodes.get(node_name)
        local cfg = require("giroux").config
        local wt = ("%s/%s--%s"):format(cfg.dispatch.worktree_dir, vim.fs.basename(repo), branch:gsub("[^%w_-]", "-"))
        local cmd = ("mkdir -p %s && git -C %s worktree add -b %s %s"):format(
          shq_path(vim.fs.dirname(wt)),
          shq_path(repo),
          shq(branch),
          shq_path(wt)
        )
        ssh.exec(node.host, cmd, function(ok, _, stderr)
          if not ok then
            return vim.notify("giroux: worktree failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
          end
          -- worktree paths carry a leading ~ until the remote shell expands it;
          -- launch needs a real path, so resolve it for slug/correlation.
          ssh.exec(node.host, ("cd %s && pwd"):format(shq_path(wt)), function(ok2, pwd)
            launch_in(node_name, ok2 and vim.trim(pwd) or wt, headless)
          end)
        end)
      end)
    end,
  })
end

---Build the tmux command to resume an existing claude session by id.
---Exposed for tests.
---@param name string tmux session name
---@param gid string GIROUX_SESSION_ID (fresh, for steering correlation)
---@param dir string cwd
---@param session_id string the claude session id to --resume
---@return string
function M.resume_cmd(name, gid, dir, session_id)
  local d = require("giroux").config.dispatch
  local argv = {}
  vim.list_extend(argv, d.cmd)
  argv[#argv + 1] = "--resume"
  argv[#argv + 1] = session_id
  vim.list_extend(argv, d.flags or {})
  return job_launch(name, gid, dir, argv)
end

---Resume a dead/observe-only session from its transcript: re-launch
---`claude --resume <id>` in a fresh tmux session, back under observation.
---The cwd is read from the transcript itself (records carry `cwd`), not the
---lossy project slug.
---@param node_name string
---@param session giroux.Session
function M.resume(node_name, session)
  if session.tmux then
    return vim.notify("giroux: that session is live — use `a` to attach", vim.log.levels.WARN)
  end
  local _, node = nodes.get(node_name)
  local session_id = vim.fs.basename(session.path):gsub("%.jsonl$", "")
  -- pull the cwd out of the first record that carries one
  local read_cwd = ('grep -o \'"cwd":"[^"]*"\' %s | head -1'):format(shq(session.path))
  ssh.exec(node.host, read_cwd, function(ok, stdout)
    local dir = ok and stdout:match('"cwd":"([^"]*)"') or nil
    if not dir then
      return vim.notify("giroux: couldn't find the session's cwd in its transcript", vim.log.levels.ERROR)
    end
    local gid = vim.fn.system("uuidgen"):lower():gsub("%-.*", ""):gsub("%s", "")
    local base = vim.fs.basename(dir):gsub("[^%w_-]", "-")
    local name = ("%s/%s-%s"):format(require("giroux").config.dispatch.tmux_prefix, base, gid:sub(1, 4))
    ssh.exec(node.host, ssh.login_wrap(M.resume_cmd(name, gid, dir, session_id)), function(ok2, _, stderr)
      if not ok2 then
        return vim.notify("giroux: resume failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
      end
      vim.notify(("giroux: resumed %s as %s"):format(session_id:sub(1, 8), name))
      accept_trust(node_name, name)
      require("giroux.tmuxctl").invalidate(node_name)
      vim.defer_fn(function()
        require("giroux.monitor").discover()
      end, 2000)
    end)
  end)
end

M._repo_label = repo_label -- exposed for tests

M.IDLE_REAP_SECS = 1800 -- detached + silent this long = reapable

---Parse `tmux list-sessions` reap output: name TAB attached TAB activity.
---@param stdout string
---@param now integer
---@return {name: string, idle: integer}[] detached giroux sessions idle past the threshold
function M.parse_reapable(stdout, now)
  local out = {}
  for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
    local name, attached, activity = line:match("^([^\t]+)\t(%d)\t(%d+)$")
    if name and name:match("^giroux/") and attached == "0" then
      local idle = now - tonumber(activity)
      if idle >= M.IDLE_REAP_SECS then
        out[#out + 1] = { name = name, idle = idle }
      end
    end
  end
  return out
end

---Reap detached giroux tmux sessions that have been idle past the threshold
---(the launch runs claude as the session command, so a *running* agent keeps
---its session alive; a long-detached, silent one is finished or abandoned).
---Confirms before killing. Worktree pruning is a follow-up.
---@param opts {node: string|nil}|nil
function M.clean(opts)
  opts = opts or {}
  local tmuxctl = require("giroux.tmuxctl")
  local names = opts.node and { opts.node } or vim.tbl_keys(nodes.all())
  for _, node_name in ipairs(names) do
    local _, node = nodes.get(node_name)
    local cmd = "tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_activity}' 2>/dev/null"
    ssh.exec(node.host, ssh.login_wrap(cmd), function(ok, stdout)
      if not ok then
        return
      end
      local reapable = M.parse_reapable(stdout, os.time())
      if #reapable == 0 then
        vim.notify(("giroux: nothing idle to reap on %s"):format(node_name))
        return
      end
      local pick_items = { { all = true, label = "kill all " .. #reapable .. " idle" } }
      for _, r in ipairs(reapable) do
        pick_items[#pick_items + 1] = { r = r, label = ("%s (idle %dm)"):format(r.name, math.floor(r.idle / 60)) }
      end
      require("giroux.pick").open({
        items = pick_items,
        title = "reap on " .. node_name,
        format = function(it)
          return it.label
        end,
        on_choice = function(choice)
          if not choice then
            return
          end
          local targets = choice.all and reapable or { choice.r }
          for _, r in ipairs(targets) do
            ssh.exec(
              node.host,
              ssh.login_wrap(("tmux kill-session -t %s 2>/dev/null"):format(shq(r.name))),
              function() end
            )
          end
          tmuxctl.invalidate(node_name)
          vim.notify(("giroux: reaped %d session(s) on %s"):format(#targets, node_name))
          require("giroux.monitor").discover()
        end,
      })
    end)
  end
end

---Interactive dispatch: node → repo → (worktree?) → context → launch.
---@param opts {node: string|nil, headless: boolean|nil}|nil
function M.open(opts)
  opts = opts or {}
  local headless = opts.headless
  local all = nodes.all()
  local names = vim.tbl_keys(all)
  table.sort(names)
  local function with_node(node_name)
    find_repos(node_name, function(repos)
      if #repos == 0 then
        return vim.notify("giroux: no repos under roots on " .. node_name, vim.log.levels.WARN)
      end
      require("giroux.pick").open({
        items = repos,
        title = "repo on " .. node_name,
        format = repo_label,
        on_choice = function(it)
          if it then
            maybe_worktree(node_name, it.path, headless)
          end
        end,
      })
    end)
  end
  if opts.node then
    return with_node(opts.node)
  end
  if #names == 1 then
    return with_node(names[1])
  end
  require("giroux.pick").open({
    items = names,
    title = "dispatch on node",
    format = tostring,
    on_choice = function(node_name)
      if node_name then
        with_node(node_name)
      end
    end,
  })
end

return M
