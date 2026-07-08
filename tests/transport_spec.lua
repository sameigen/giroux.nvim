local ssh = require("giroux.ssh")
local h = require("helpers")

local function J(t)
  return vim.json.encode(t)
end

return {
  ["transport: multi_tail_cmd builds one channel over many files"] = function()
    local cmd = ssh.multi_tail_cmd({
      { path = "/p/a.jsonl", offset = 0 },
      { path = "/p/b.jsonl", offset = 100 },
    })
    -- kill 0 (the whole group), not `kill $(jobs -p)`: non-interactive dash has
    -- job control off so `jobs -p` is empty and reaps nothing (the Linux leak).
    -- Safe because the shell runs in its own group (remote: sshd; local: setsid).
    assert(cmd:find("trap 'kill 0", 1, true), "must reap the whole process group")
    assert(not cmd:find("jobs -p", 1, true), "jobs -p is empty in non-interactive dash — must not rely on it")
    assert(cmd:find('tail -c +1 -F "/p/a.jsonl"', 1, true), "offset 0 -> byte 1")
    assert(cmd:find('tail -c +101 -F "/p/b.jsonl"', 1, true), "offset 100 -> byte 101")
    assert(cmd:find("fflush()", 1, true), "awk must flush per line")
    assert(cmd:find("wait$"), "foreground wait keeps the channel open")
  end,

  ["transport: stopping a local stream reaps its tail/awk (no orphans)"] = function()
    h.skip_unless(h.is_unix() and h.has("ps"), "needs ps + tail -F (macOS or Linux)")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local f = root .. "/reap-me.jsonl"
    local fh = assert(io.open(f, "w"))
    fh:write("{}\n")
    fh:close()

    -- count the live tail/awk processes still referencing our file. (The sh -c
    -- wrapper line also matches while running; all must be gone after reap.)
    local function procs_for_file()
      local out = vim.system({ "ps", "-eo", "pid,command" }, { text = true }):wait()
      local n = 0
      for line in (out.stdout or ""):gmatch("[^\n]+") do
        if line:find(f, 1, true) and (line:find("tail", 1, true) or line:find("awk", 1, true)) then
          n = n + 1
        end
      end
      return n
    end

    -- host = nil -> local stream; M.stream spawns it detached so the trap's
    -- `kill 0` reaps the group on stop without signalling this nvim.
    local stream = ssh.multi_tail(nil, { { path = f, offset = 0 } }, function() end, function() end)
    assert(
      vim.wait(4000, function()
        return procs_for_file() >= 1
      end, 50),
      "the merged tail must actually spawn a tail for the file"
    )
    stream.stop()
    assert(
      vim.wait(4000, function()
        return procs_for_file() == 0
      end, 50),
      "stop() must reap the tail/awk — none may survive (the leak this fixes)"
    )
    vim.fn.delete(root, "rf")
  end,

  ["transport: a single local tail is reaped on stop (exec, not fork)"] = function()
    h.skip_unless(h.is_unix() and h.has("ps"), "needs ps + tail -F (macOS or Linux)")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local f = root .. "/solo.jsonl"
    local fh = assert(io.open(f, "w"))
    fh:write("{}\n")
    fh:close()
    local function procs()
      local out = vim.system({ "ps", "-eo", "command" }, { text = true }):wait()
      local n = 0
      for line in (out.stdout or ""):gmatch("[^\n]+") do
        if line:find(f, 1, true) and line:find("tail", 1, true) then
          n = n + 1
        end
      end
      return n
    end
    -- host=false is the codebase's *other* "local" sentinel (tests, local node);
    -- the feed's fallback tail uses this path. It must reap on stop, not orphan a
    -- forked child.
    local s = ssh.tail(false, f, 0, function() end, function() end)
    assert(
      vim.wait(4000, function()
        return procs() >= 1
      end, 50),
      "tail must spawn"
    )
    s.stop()
    assert(
      vim.wait(4000, function()
        return procs() == 0
      end, 50),
      "stop() must reap the single tail — none may survive"
    )
    vim.fn.delete(root, "rf")
  end,

  ["transport: demux reassembles split lines and routes by path"] = function()
    local got = {}
    local fn = ssh.demux(function(path, line)
      got[#got + 1] = { path, line }
    end)
    -- one line split across three chunks, then two complete lines in one chunk
    fn('/p/a.jsonl\t{"ty')
    fn('pe":"user"')
    fn('}\n/p/b.jsonl\t{"x":1}\n/p/a.jsonl\t{"y":2}\n')
    assert(#got == 3, "expected 3 lines, got " .. #got)
    assert(got[1][1] == "/p/a.jsonl" and got[1][2] == '{"type":"user"}')
    assert(got[2][1] == "/p/b.jsonl" and got[2][2] == '{"x":1}')
    assert(got[3][1] == "/p/a.jsonl" and got[3][2] == '{"y":2}')
  end,

  ["transport: monitor runs one merged stream per node, live"] = function()
    h.skip_unless(h.is_unix(), "needs a unix stat / tail -F (macOS or Linux)")
    local monitor = require("giroux.monitor")
    -- fake node: a temp claude_projects root, host=false = run locally
    local root = vim.fn.tempname()
    local proj = root .. "/-Users-test-Code-app"
    vim.fn.mkdir(proj, "p")
    local f1 = proj .. "/aaaaaaaa-0000-0000-0000-000000000001.jsonl"
    local f2 = proj .. "/aaaaaaaa-0000-0000-0000-000000000002.jsonl"
    local function append(file, rec)
      local fh = assert(io.open(file, "a"))
      fh:write(J(rec) .. "\n")
      fh:close()
    end
    append(f1, { type = "user", uuid = "u1", message = { role = "user", content = "work on it" } })
    append(f2, { type = "system", subtype = "turn_duration", uuid = "t1", durationMs = 1, messageCount = 1 })

    require("giroux").setup({ nodes = { fake = { host = false, claude_projects = root } } })
    local snapshots = {}
    local unsub = monitor.subscribe(function(list)
      snapshots[#snapshots + 1] = list
    end)
    monitor.start({ node = "fake" })

    local function state_of(path)
      local last = snapshots[#snapshots] or {}
      for _, s in ipairs(last) do
        if s.path == path then
          return s.state
        end
      end
    end
    assert(
      vim.wait(8000, function()
        return state_of(f1) == "●" and state_of(f2) == "○"
      end, 100),
      "expected ● (open turn) and ○ (closed turn), got " .. tostring(state_of(f1)) .. " " .. tostring(state_of(f2))
    )
    assert(monitor._state.node_streams.fake, "one merged stream for the node")
    local trackers = vim.tbl_count(monitor._state.trackers)
    assert(trackers == 2, "two trackers sharing it, got " .. trackers)

    -- live append flips state through the merged stream (no rediscovery). A
    -- *witnessed* working→idle is "done/unseen" (✓), not plain idle.
    append(f1, { type = "system", subtype = "turn_duration", uuid = "t2", durationMs = 1, messageCount = 1 })
    assert(
      vim.wait(8000, function()
        return state_of(f1) == "✓"
      end, 100),
      "witnessed turn close marks done/unseen (✓), got " .. tostring(state_of(f1))
    )
    -- the ✓ counts on the statusline badge…
    assert(require("giroux.notify").statusline():find("✓1", 1, true), "done counts on the badge")
    -- …and reviewing it (open feed → mark_seen) demotes ✓ → ○ and clears the badge
    monitor.mark_seen("fake", f1)
    assert(
      vim.wait(2000, function()
        return state_of(f1) == "○"
      end, 50),
      "mark_seen demotes done → idle, got " .. tostring(state_of(f1))
    )
    assert(not require("giroux.notify").statusline():find("✓", 1, true), "badge cleared after review")

    -- raw line subscription rides the same stream
    local lines, dropped = {}, false
    monitor.subscribe_lines("fake", f1, function(line, offset)
      lines[#lines + 1] = { line = line, offset = offset }
    end, function()
      dropped = true
    end)
    append(f1, { type = "user", uuid = "u2", message = { role = "user", content = "more" } })
    assert(
      vim.wait(8000, function()
        return #lines >= 1
      end, 100),
      "line subscriber must see the append"
    )
    assert(lines[1].line:find('"more"', 1, true), "subscriber gets the raw line")
    assert(type(lines[1].offset) == "number" and lines[1].offset > 0, "with its byte offset")

    unsub()
    assert(dropped, "stopping the monitor must fire on_drop")
    assert(next(monitor._state.node_streams) == nil, "streams torn down")
    vim.fn.delete(root, "rf")
    require("giroux").setup({})
  end,

  ["transport: feed rides the node stream, falls back when monitor stops"] = function()
    h.skip_unless(h.is_unix(), "needs a unix stat / tail -F (macOS or Linux)")
    local monitor = require("giroux.monitor")
    local feed_mod = require("giroux.feed")
    local root = vim.fn.tempname()
    local proj = root .. "/-Users-test-Code-app"
    vim.fn.mkdir(proj, "p")
    local f = proj .. "/bbbbbbbb-0000-0000-0000-000000000001.jsonl"
    local function append(rec)
      local fh = assert(io.open(f, "a"))
      fh:write(J(rec) .. "\n")
      fh:close()
    end
    append({ type = "user", uuid = "u1", message = { role = "user", content = "the first prompt" } })

    require("giroux").setup({ nodes = { fake = { host = false, claude_projects = root } } })
    local unsub = monitor.subscribe(function() end)
    monitor.start({ node = "fake" })
    assert(
      vim.wait(8000, function()
        return monitor.tracks("fake", f)
      end, 100),
      "monitor must track the session first"
    )

    local feed = feed_mod.open_path({ node = "fake", path = f })
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(feed.buf, 0, -1, false), "\n")
    end
    assert(
      vim.wait(8000, function()
        return text():find("the first prompt", 1, true) ~= nil
      end, 100),
      "feed must render the window snapshot"
    )
    assert(feed.stream == nil, "no own tail while riding the node stream")
    assert(feed.unsub_lines ~= nil, "subscribed to the monitor")

    append({
      type = "assistant",
      uuid = "a1",
      message = { id = "m1", role = "assistant", content = { { type = "text", text = "a live appended answer" } } },
    })
    assert(
      vim.wait(8000, function()
        return text():find("a live appended answer", 1, true) ~= nil
      end, 100),
      "live appends must arrive through the merged stream"
    )

    unsub() -- last roster subscriber gone -> monitor stops -> feed must take over
    assert(
      vim.wait(4000, function()
        return feed.stream ~= nil
      end, 100),
      "feed must fall back to its own tail when the monitor stops"
    )
    append({ type = "system", subtype = "turn_duration", uuid = "t1", durationMs = 1, messageCount = 1 })
    assert(
      vim.wait(8000, function()
        return text():find("turn", 1, true) ~= nil or feed.parser:resume_offset() > 0
      end, 100),
      "fallback tail must keep flowing"
    )

    feed_mod.close(feed.buf)
    vim.fn.delete(root, "rf")
    require("giroux").setup({})
  end,

  ["transport: a turn finished before we watched replays as idle, never done"] = function()
    h.skip_unless(h.is_unix(), "needs a unix stat / tail -F (macOS or Linux)")
    local monitor = require("giroux.monitor")
    local root = vim.fn.tempname()
    local proj = root .. "/-Users-test-Code-app"
    vim.fn.mkdir(proj, "p")
    local f = proj .. "/cccccccc-0000-0000-0000-000000000001.jsonl"
    local fh = assert(io.open(f, "a"))
    -- a full working→idle turn, written ENTIRELY before the monitor starts:
    -- on first sight this is pre-watch history, replayed with live=false.
    fh:write(J({ type = "user", uuid = "u1", message = { role = "user", content = "do it" } }) .. "\n")
    fh:write(J({ type = "system", subtype = "turn_duration", uuid = "t1", durationMs = 1, messageCount = 1 }) .. "\n")
    fh:close()

    require("giroux").setup({ nodes = { fake = { host = false, claude_projects = root } } })
    local snaps = {}
    local unsub = monitor.subscribe(function(list)
      snaps[#snaps + 1] = list
    end)
    monitor.start({ node = "fake" })
    local function state_of()
      for _, s in ipairs(snaps[#snaps] or {}) do
        if s.path == f then
          return s.state
        end
      end
    end
    assert(
      vim.wait(8000, function()
        return state_of() == "○"
      end, 100),
      "a replayed (historical) turn settles idle, got " .. tostring(state_of())
    )
    -- hold a few ticks: a spurious latch from replaying the ●→○ edge would flip ✓
    vim.wait(300, function()
      return false
    end, 100)
    assert(state_of() == "○", "a historical finish must never latch ✓, got " .. tostring(state_of()))
    assert(not require("giroux.notify").statusline():find("✓", 1, true), "no done badge for historical finishes")

    unsub()
    monitor.stop()
    vim.fn.delete(root, "rf")
    require("giroux").setup({})
  end,
}
