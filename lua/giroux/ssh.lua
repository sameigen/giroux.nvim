---@module 'giroux.ssh'
--- Transport layer. Pure SSH, no daemon (DESIGN.md §10): one-shot execs and
--- long-lived byte streams (tail -F) over the user's ssh config, which is
--- expected to provide ControlMaster multiplexing. host = nil means local.

local M = {}

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
  local cmd = ("tail -c +%d -F '%s' 2>/dev/null"):format(offset + 1, path)
  return M.stream(host, cmd, on_chunk, on_exit)
end

---One merged tail over many files: a single channel per node instead of one
---per session (sshd MaxSessions). Each remote line is `<path>\t<line>`; awk
---provides portable per-line flushing (BSD and GNU). The trap reaps the
---backgrounded tails when the connection drops or the stream is stopped —
---`jobs -p`, never `kill 0` (locally that would be nvim's process group).
---@param files {path: string, offset: integer}[] offset = bytes already consumed
---@return string
function M.multi_tail_cmd(files)
  local parts = { "trap 'kill $(jobs -p) 2>/dev/null' EXIT HUP TERM INT;" }
  for _, f in ipairs(files) do
    parts[#parts + 1] = ('tail -c +%d -F "%s" 2>/dev/null | awk -v p="%s" \'{ print p "\\t" $0; fflush() }\' &'):format(
      f.offset + 1,
      f.path,
      f.path
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
