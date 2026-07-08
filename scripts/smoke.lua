-- CI smoke test: every module loads, setup merges config.
local modules = {
  "giroux",
  "giroux.nodes",
  "giroux.ssh",
  "giroux.sessions",
  "giroux.monitor",
  "giroux.transcript",
  "giroux.roster",
  "giroux.pick",
  "giroux.feed",
  "giroux.steer",
  "giroux.dispatch",
  "giroux.stats",
  "giroux.qa",
  "giroux.statsheet",
  "giroux.health",
}
for _, m in ipairs(modules) do
  local ok, err = pcall(require, m)
  if not ok then
    io.stderr:write(("FAIL %s: %s\n"):format(m, err))
    os.exit(1)
  end
end

local giroux = require("giroux")
giroux.setup({ nodes = { workhorse = { host = "workhorse" } }, keymaps = { roster = { close = "x", diff = false } } })
assert(giroux.config.nodes.workhorse.host == "workhorse")
assert(giroux.config.refresh_interval == 1, "defaults must survive partial setup")
assert(giroux.config.dispatch.flags[1] == "--dangerously-skip-permissions", "opinionated default intact")
assert(giroux.config.keymaps.roster.close == "x", "keymap override applies")
assert(giroux.config.keymaps.roster.diff == false, "keymap can be disabled")
assert(giroux.config.keymaps.roster.open_feed == "<CR>", "untouched keymaps keep defaults")
print("smoke ok")
