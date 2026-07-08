---@module 'giroux.ssh'
--- Transport layer. Pure SSH, no daemon (DESIGN.md §10): one-shot execs and
--- long-lived byte streams (tail -F) over the user's ssh config, which is
--- expected to provide ControlMaster multiplexing. host = nil means local.

local M = {}

---Single-quote a string for POSIX sh: literal for everything except `'`, which
---is closed, escaped, and reopened. The ONLY safe wrap for a semi-trusted path
---(a transcript filename) that ends up in a remote shell command — never use
---double quotes, which keep $(), backticks and \ live.
---@param s string
---@return string
function M.shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---Wrap a command to run under a LOGIN shell on the target, so the user's
---profile is sourced (~/.zshenv / ~/.zprofile): Homebrew PATH — so tmux and
---claude are found over non-interactive ssh — and CLAUDE_CODE_OAUTH_TOKEN — so
---dispatched agents authenticate WITHOUT an unlockable GUI keychain (the macOS
---keychain is locked in non-GUI ssh, which is why claude hard-blocks on /login
---at first API call). Quote-safe: single-quoted with embedded quotes escaped.
---@param cmd string
---@return string
function M.login_wrap(cmd)
  return ("${SHELL:-/bin/sh} -lc '%s'"):format((cmd:gsub("'", [['\'']])))
end

---@param host string|nil ssh destination, nil = run locally
---@param cmd string shell command
---@param opts {login?: boolean}|nil login = run under a login shell (PATH+auth)
---@return string[] argv
function M.argv(host, cmd, opts)
  if opts and opts.login then
    cmd = M.login_wrap(cmd)
  end
  if host then
    return { "ssh", "-o", "BatchMode=yes", host, cmd }
  end
  return { "sh", "-c", cmd }
end

---One-shot command. cb(ok, stdout, stderr) on the main loop.
---@param host string|nil
---@param cmd string
---@param cb fun(ok: boolean, stdout: string, stderr: string)
---@param opts {login?: boolean}|nil
function M.exec(host, cmd, cb, opts)
  vim.system(M.argv(host, cmd, opts), { text = true }, function(out)
    vim.schedule(function()
      cb(out.code == 0, out.stdout or "", out.stderr or "")
    end)
  end)
end

---@class giroux.ssh.Stream
---@field stop fun()
---@field running fun(): boolean

---Long-lived byte stream of `cmd` stdout. on_chunk(data) on the main loop;
---on_exit(code) when the process dies (caller owns restart policy).
---@param host string|nil
---@param cmd string
---@param on_chunk fun(data: string)
---@param on_exit fun(code: integer)|nil
---@return giroux.ssh.Stream
function M.stream(host, cmd, on_chunk, on_exit)
  local stopped = false
  local proc
  proc = vim.system(M.argv(host, cmd), {
    -- A LOCAL stream (host nil OR false — both are "local" in this codebase)
    -- runs in its OWN process group (libuv setsid). That isolates it from nvim's
    -- group so the merged-tail trap can `kill 0` to reap its backgrounded
    -- `tail`/`awk` children on stop or disconnect without signalling nvim itself
    -- (see multi_tail_cmd). The cost is that a detached child outlives a hard
    -- nvim exit, so a VimLeavePre hook stops streams on quit. A REMOTE stream's
    -- local process is just `ssh`; its trap runs on the far side in an
    -- already-isolated group, reaped by the SIGHUP a dropped link delivers — so
    -- no local detach is needed (or wanted: we kill the ssh).
    detach = not host,
    stdout = function(_, data)
      if data and not stopped then
        vim.schedule(function()
          if not stopped then
            on_chunk(data)
          end
        end)
      end
    end,
  }, function(out)
    if not stopped and on_exit then
      vim.schedule(function()
        if not stopped then
          on_exit(out.code)
        end
      end)
    end
  end)
  return {
    stop = function()
      stopped = true
      pcall(proc.kill, proc, 15)
    end,
    running = function()
      return not stopped and not proc:is_closing()
    end,
  }
end

---Streaming tail of a remote/local file from a byte offset (0-based).
---@param host string|nil
---@param path string
---@param offset integer bytes already consumed
function M.tail(host, path, offset, on_chunk, on_exit)
  -- `exec` so the shell REPLACES itself with tail instead of forking it: some
  -- shells (dash) fork a single command, and then killing the shell on stop()
  -- would orphan the child tail (`tail -F` never exits on its own). With exec
  -- the tail IS the spawned process, so proc:kill (local) or the ssh dying
  -- (remote → SIGHUP) reaps it cleanly.
  local cmd = ("exec tail -c +%d -F %s 2>/dev/null"):format(offset + 1, M.shq(path))
  return M.stream(host, cmd, on_chunk, on_exit)
end

---One merged tail over many files: a single channel per node instead of one
---per session (sshd MaxSessions). Each remote line is `<path>\t<line>`; awk
---provides portable per-line flushing (BSD and GNU). The trap reaps the
---backgrounded tails when the connection drops or the stream is stopped via
---`kill 0` — the whole process group, the ONLY portable reap: a
---non-interactive `dash` (Linux `/bin/sh`) has job control off, so `jobs -p`
---is empty and a `kill $(jobs -p)` trap reaps nothing, orphaning every tail.
---`kill 0` is safe because the shell runs in its OWN group: remotely sshd
---isolates the command, and locally M.stream spawns it detached (setsid). A
---bare `tail | awk` pipeline also needs the group kill — killing only awk
---(`$!`) leaves the quiet `tail -F` writing nothing and never dying.
---@param files {path: string, offset: integer}[] offset = bytes already consumed
---@return string
function M.multi_tail_cmd(files)
  local parts = { "trap 'kill 0 2>/dev/null' EXIT HUP TERM INT;" }
  for _, f in ipairs(files) do
    parts[#parts + 1] = ("tail -c +%d -F %s 2>/dev/null | awk -v p=%s '{ print p \"\\t\" $0; fflush() }' &"):format(
      f.offset + 1,
      M.shq(f.path),
      M.shq(f.path)
    )
  end
  parts[#parts + 1] = "wait"
  return table.concat(parts, " ")
end

---Chunk handler that reassembles complete `<path>\t<line>` lines from an
---arbitrary byte stream and demuxes them. Transcript JSONL never contains a
---raw TAB (JSON strings must escape control chars), so the first TAB is an
---unambiguous separator.
---@param on_line fun(path: string, line: string)
---@return fun(chunk: string)
function M.demux(on_line)
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local from = 1
    while true do
      local nl = buf:find("\n", from, true)
      if not nl then
        break
      end
      local line = buf:sub(from, nl - 1)
      from = nl + 1
      local tab = line:find("\t", 1, true)
      if tab then
        on_line(line:sub(1, tab - 1), line:sub(tab + 1))
      end
    end
    if from > 1 then
      buf = buf:sub(from)
    end
  end
end

---Merged follow of many files on one host over one channel.
---@param host string|nil
---@param files {path: string, offset: integer}[]
---@param on_line fun(path: string, line: string)
---@param on_exit fun(code: integer)|nil
---@return giroux.ssh.Stream
function M.multi_tail(host, files, on_line, on_exit)
  return M.stream(host, M.multi_tail_cmd(files), M.demux(on_line), on_exit)
end

return M
