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
    assert(cmd:find("trap 'kill $(jobs -p)", 1, true), "must reap tails, never kill 0")
    assert(cmd:find('tail -c +1 -F "/p/a.jsonl"', 1, true), "offset 0 -> byte 1")
    assert(cmd:find('tail -c +101 -F "/p/b.jsonl"', 1, true), "offset 100 -> byte 101")
    assert(cmd:find("fflush()", 1, true), "awk must flush per line")
    assert(cmd:find("wait$"), "foreground wait keeps the channel open")
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
    h.skip_unless(h.is_macos(), "discovery uses BSD stat -f (macOS); Linux support pending")
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

    -- live append flips state through the merged stream (no rediscovery)
    append(f1, { type = "system", subtype = "turn_duration", uuid = "t2", durationMs = 1, messageCount = 1 })
    assert(
      vim.wait(8000, function()
        return state_of(f1) == "○"
      end, 100),
      "live append must close the turn, got " .. tostring(state_of(f1))
    )

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
    h.skip_unless(h.is_macos(), "discovery uses BSD stat -f (macOS); Linux support pending")
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
}
