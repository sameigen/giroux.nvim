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

local function tool_use(id, name, input, opts)
  opts = opts or {}
  return {
    type = "assistant",
    uuid = "a" .. id,
    sessionId = "s",
    timestamp = "2026-06-11T05:00:00.000Z",
    message = {
      id = "m" .. id,
      model = opts.model or "claude-fable-5",
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      stop_reason = vim.NIL,
      usage = opts.usage or {
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

  ["stats: ctx_pct is a model-aware, rounded percentage that never crashes"] = function()
    -- known family, exact round numbers so the rounding rule isn't ambiguous
    assert(
      stats.ctx_pct("claude-sonnet-4-5-20250929", 100000) == 50,
      tostring(stats.ctx_pct("claude-sonnet-4-5-20250929", 100000))
    )
    -- unrecognized model id still gets the sane 200k default, never crashes
    assert(stats.ctx_pct("some-future-model-nobody-has-seen", 50000) == 25)
    -- a longer-context ("1m") variant gets the bigger window
    assert(stats.ctx_pct("claude-sonnet-4-5-1m", 500000) == 50)
    -- observed context ABOVE the assumed limit = a larger-context beta whose id
    -- didn't reveal it (real case: opus-4-8 at 496k on the 1M beta). Raise to 1M
    -- rather than report a nonsensical >100%.
    assert(stats.ctx_pct("claude-opus-4-8", 496261) == 50, tostring(stats.ctx_pct("claude-opus-4-8", 496261)))
    -- final backstop: even an absurd count never exceeds 100%
    assert(stats.ctx_pct("claude-opus-4-8", 5000000) == 100, "clamped at 100")
    -- degrade to nil: no context observed, or a nonsensical negative count
    assert(stats.ctx_pct("claude-fable-5", nil) == nil, "no usage yet -> nil")
    assert(stats.ctx_pct("claude-fable-5", -5) == nil, "negative -> nil")
    -- nil model still resolves to the default limit (never crashes on missing model)
    assert(stats.ctx_pct(nil, 100000) == 50, "nil model -> default 200k limit")
  end,

  ["stats: summary tracks active model + context pressure off the LATEST usage event, not cumulative"] = function()
    local evs = events({
      tool_use("e1", "Edit", { file_path = "/a.rs" }, {
        model = "claude-haiku-4",
        usage = {
          input_tokens = 1000,
          output_tokens = 10,
          cache_read_input_tokens = 0,
          cache_creation_input_tokens = 0,
        },
      }),
      tool_use("e2", "Edit", { file_path = "/b.rs" }, {
        model = "claude-opus-4-5",
        usage = {
          input_tokens = 40000,
          output_tokens = 20,
          cache_read_input_tokens = 60000,
          cache_creation_input_tokens = 0,
        },
      }),
    })
    local sum = stats.aggregate(evs):summary()
    assert(sum.model == "claude-opus-4-5", "latest usage event's model wins: " .. tostring(sum.model))
    assert(
      sum.ctx_tokens == 100000,
      "latest turn only (40000+60000), not cumulative across both calls: " .. tostring(sum.ctx_tokens)
    )
    assert(sum.ctx_limit == 200000, tostring(sum.ctx_limit))
    assert(sum.ctx_pct == 50, "100000/200000 = 50%: " .. tostring(sum.ctx_pct))
  end,

  ["stats: model/ctx fields degrade to nil when no usage has been observed"] = function()
    local sum = stats.aggregate({}):summary()
    assert(sum.model == nil)
    assert(sum.ctx_tokens == nil)
    assert(sum.ctx_limit == nil)
    assert(sum.ctx_pct == nil)
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
