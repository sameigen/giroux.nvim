-- Gauntlet: stream every real transcript through the parser, prove zero
-- crashes and measure the unknown rate. Usage:
--   nvim -l scripts/gauntlet.lua <dir-or-file> [...]
-- Reads in 64KB chunks to exercise streaming paths, not whole-file shortcuts.

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(root)
local transcript = require("giroux.transcript")

local files = {}
for _, arg in ipairs(_G.arg or {}) do
  local stat = vim.uv.fs_stat(arg)
  if stat and stat.type == "directory" then
    for name, t in vim.fs.dir(arg, { depth = 16 }) do -- subagents nest: s/subagents/a/subagents/...
      -- workflows/*/journal.jsonl are Workflow-tool journals, not transcripts;
      -- agent-*.jsonl under workflows/ ARE transcripts (workflow-spawned agents)
      if t == "file" and name:match("%.jsonl$") and not name:match("journal%.jsonl$") then
        files[#files + 1] = arg .. "/" .. name
      end
    end
  elseif stat then
    files[#files + 1] = arg
  end
end
assert(#files > 0, "no .jsonl files found in args")

local totals = { files = 0, bytes = 0, events = 0, unknown = 0, undecodable = 0, other = 0, crashed = 0 }
local kinds = {}
local unknown_types = {}
local worst = {}

for _, path in ipairs(files) do
  local f = io.open(path, "rb")
  if f then
    totals.files = totals.files + 1
    local p = transcript.parser()
    local file_events, file_unknown = 0, 0
    local crashed = false
    while true do
      local chunk = f:read(65536)
      if not chunk then
        break
      end
      totals.bytes = totals.bytes + #chunk
      local ok, events = pcall(p.feed, p, chunk)
      if not ok then
        totals.crashed = totals.crashed + 1
        io.stderr:write(("CRASH %s\n  %s\n"):format(path, tostring(events)))
        crashed = true
        break
      end
      for _, e in ipairs(events) do
        file_events = file_events + 1
        kinds[e.kind] = (kinds[e.kind] or 0) + 1
        if e.kind == "unknown" then
          file_unknown = file_unknown + 1
          local key = e.rtype or "?"
          unknown_types[key] = (unknown_types[key] or 0) + 1
          if e.rtype == "undecodable" then
            totals.undecodable = totals.undecodable + 1
          end
        end
      end
    end
    f:close()
    if not crashed then
      totals.events = totals.events + file_events
      totals.unknown = totals.unknown + file_unknown
      if file_unknown > 0 then
        worst[#worst + 1] = ("%4d unknown  %s"):format(file_unknown, path)
      end
    end
  end
end

totals.other = kinds.other or 0
print(
  ("files: %d  bytes: %.1fMB  events: %d  crashes: %d"):format(
    totals.files,
    totals.bytes / 1024 / 1024,
    totals.events,
    totals.crashed
  )
)
print(
  ("unknown: %d (%.4f%%)  undecodable: %d  other(recognized): %d"):format(
    totals.unknown,
    totals.events > 0 and 100 * totals.unknown / totals.events or 0,
    totals.undecodable,
    totals.other
  )
)
local kn = vim.tbl_keys(kinds)
table.sort(kn, function(a, b)
  return kinds[a] > kinds[b]
end)
for _, k in ipairs(kn) do
  print(("  %-15s %d"):format(k, kinds[k]))
end
if next(unknown_types) then
  print("unknown record types:")
  for t, n in pairs(unknown_types) do
    print(("  %-30s %d"):format(t, n))
  end
end
for _, w in ipairs(worst) do
  print(w)
end
os.exit((totals.crashed == 0 and totals.undecodable == 0) and 0 or 1)
