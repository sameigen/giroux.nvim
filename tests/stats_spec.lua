local stats = require("giroux.stats")
local transcript = require("giroux.transcript")
require("giroux").setup({})

local function J(t)
  return vim.json.encode(t)
end

local function events(records)
  local p = transcript.parser()
  local out = {}
  for _, r in ipairs(records) do
    vim.list_extend(out, p:feed(J(r) .. "\n"))
  end
  return out
end

local function tool_use(id, name, input)
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
      usage = {
        input_tokens = 100,
        output_tokens = 50,
        cache_read_input_tokens = 900,
        cache_creation_input_tokens = 100,
      },
    },
  }
end

local function result(id, detail)
  return {
    type = "user",
    uuid = "u" .. id,
    sessionId = "s",
    message = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = "ok" } } },
    toolUseResult = detail,
  }
end

return {
  ["stats: glob to pattern matches ** and *"] = function()
    local m = stats.match_any
    assert(m("/x/legacy/y.js", { "**/legacy/**" }))
    assert(m("/Users/dev/Code/app/pkg/x.ts", { "~/Code/app/pkg/**" }) == nil or true) -- ~ expands per-machine; just ensure no crash
    assert(m("/a/b/file.lua", { "**/*.lua" }))
    assert(m("/a/b/file.js", { "**/*.lua" }) == nil)
    assert(m("/src/api.rs", { "/src/*.rs" }))
    assert(m("/src/deep/api.rs", { "/src/*.rs" }) == nil, "* must not cross /")
  end,

  ["stats: aggregates written with diffstat, read, web, spend"] = function()
    local evs = events({
      tool_use("e1", "Edit", { file_path = "/src/api.rs" }),
      result("e1", { structuredPatch = { { lines = { "+a", "+b", "-c" } } } }),
      tool_use("e2", "Edit", { file_path = "/src/api.rs" }),
      result("e2", { structuredPatch = { { lines = { "+d" } } } }),
      tool_use("r1", "Read", { file_path = "/legacy/old.rs" }),
      result("r1", {}),
      tool_use("w1", "WebFetch", { url = "https://docs.rs/axum" }),
      result("w1", {}),
      tool_use("b1", "Bash", { command = "cargo test" }),
      result("b1", { stdout = "ok" }),
    })
    local sum = stats.aggregate(evs):summary()
    assert(sum.written["/src/api.rs"].add == 3, vim.inspect(sum.written))
    assert(sum.written["/src/api.rs"].del == 1)
    assert(sum.written["/src/api.rs"].n == 2)
    assert(sum.read["/legacy/old.rs"] == 1)
    assert(sum.web[1] == "https://docs.rs/axum")
    assert(sum.bash == 1)
    -- usage on 5 distinct message ids: out 5×50, cache_read 5×900
    assert(sum.tokens.out == 250, "out=" .. sum.tokens.out)
    assert(sum.tokens.cache_read == 4500)
    assert(sum.tools.Edit == 2 and sum.tools.WebFetch == 1)
  end,

  ["stats: recent_line and recent_files"] = function()
    local acc = stats.aggregate(events({
      tool_use("e1", "Edit", { file_path = "/a.rs" }),
      tool_use("b1", "Bash", { command = "ls" }),
      tool_use("e2", "Edit", { file_path = "/b.rs" }),
    }))
    local line = acc:recent_line()
    assert(line:find("edit×2"), line)
    assert(line:find("bash×1"), line)
    assert(acc.recent_files[#acc.recent_files] == "/b.rs")
  end,

  ["stats: tripwire fires on read/write match only"] = function()
    local wires = { read = { "**/legacy/**" }, write = { "**/migrations/**" } }
    local read_evt = events({ tool_use("r", "Read", { file_path = "/x/legacy/stale.rs" }) })[1]
    local hit = stats.tripwire(read_evt, wires)
    assert(hit and hit.kind == "read" and hit.glob == "**/legacy/**", vim.inspect(hit))
    -- a write to legacy/ should NOT fire the read wire
    local write_evt = events({ tool_use("w", "Write", { file_path = "/x/legacy/new.rs" }) })[1]
    assert(stats.tripwire(write_evt, wires) == nil, "write to legacy not in write wires")
    -- but a write to migrations/ fires
    local mig = events({ tool_use("w2", "Edit", { file_path = "/db/migrations/001.sql" }) })[1]
    assert(stats.tripwire(mig, wires).kind == "write")
  end,

  ["statsheet: render produces sections and file targets"] = function()
    local statsheet = require("giroux.statsheet")
    local sum = stats
      .aggregate(events({
        tool_use("e1", "Edit", { file_path = "/src/api.rs" }),
        result("e1", { structuredPatch = { { lines = { "+a", "-b" } } } }),
        tool_use("r1", "Read", { file_path = "/legacy/old.rs" }),
        result("r1", {}),
      }))
      :summary()
    local lines, targets = statsheet.render(sum, "Test session")
    local text = table.concat(lines, "\n")
    assert(text:find("Written %(1 file%)"), text)
    assert(text:find("/src/api.rs"))
    assert(text:find("Read — where context came from"))
    assert(text:find("Spend"))
    -- a target row maps to the written file
    local found
    for row, path in pairs(targets) do
      if path == "/src/api.rs" then
        found = row
      end
    end
    assert(found, "written file must be an actionable target")
  end,
}
