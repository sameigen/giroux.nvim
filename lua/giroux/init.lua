---@class giroux.NodeConfig
---@field host string ssh destination (defaults to the node name; honors ~/.ssh/config)
---@field claude_projects string remote transcript root (default "~/.claude/projects")
---@field flags string[]|nil override launch flags for dispatches to this node
---@field roots string[]|nil dirs scanned for repos when dispatching to THIS node (falls back to the global `roots`)

---@class giroux.DispatchConfig
---@field cmd string[] command to launch the agent, e.g. { "claude" }
---@field flags string[] launch flags; giroux is opinionated: skip permissions
---@field headless_flags string[] extra flags for :GirouxDispatch!
---@field tmux_prefix string tmux session name prefix for giroux-launched agents
---@field worktree_dir string remote dir where giroux-managed worktrees live

---@class giroux.NotifyConfig
---@field levels table<string, "macos"|"notify"|"statusline"|false> event -> channel
---@field macos_when_focused boolean also send macOS notifications while nvim is focused

---@class giroux.KeymapsConfig
---@field roster table<string, string|false> action -> lhs for the roster buffer; false disables
---@field feed table<string, string|false> action -> lhs for feed buffers; false disables

---@class giroux.Config
---@field nodes table<string, giroux.NodeConfig> tailnet nodes to supervise (explicit config always wins)
---@field discover boolean auto-discover online macOS tailnet peers via `tailscale status --json`
---@field discover_tag string|nil only discover peers carrying this tailscale ACL tag (e.g. "tag:agent-host")
---@field tmux_rename boolean rename wrapper-minted tmux sessions to the transcript's ai-title
---@field roots string[] remote directories scanned for repos when dispatching
---@field refresh_interval integer seconds between roster display heartbeats — re-renders so the clock + age columns stay live even when no data changes (0 disables)
---@field live_interval integer seconds between liveness polls (process truth + needs-you + tmux title spinner) between the heavier file-listing discoveries
---@field discover_interval integer seconds between full discovery passes (file listing); live tails + liveness polls fill the gaps
---@field active_window integer minutes of transcript mtime considered "live" when scanning
---@field subagents boolean surface spawned subagents (Agent/Task) nested under their parent on the roster (default true)
---@field backfill integer events rendered when opening a feed (history above is parsed, not drawn)
---@field initial_tail integer bytes read from a session's tail on feed open (state proof is local to recent bytes)
---@field dispatch giroux.DispatchConfig
---@field notify giroux.NotifyConfig
---@field keymaps giroux.KeymapsConfig
---@field tripwires {read?: string[], write?: string[]} glob patterns that escalate when an agent reads/writes them

local M = {}

---@type giroux.Config
M.defaults = {
  nodes = {},
  discover = false,
  discover_tag = nil,
  tmux_rename = true,
  roots = { "~/Code" },
  refresh_interval = 1,
  live_interval = 3,
  discover_interval = 10,
  active_window = 240,
  subagents = true,
  backfill = 4000,
  initial_tail = 1048576,
  dispatch = {
    cmd = { "claude" },
    flags = { "--dangerously-skip-permissions" },
    headless_flags = { "-p", "--output-format", "text" },
    tmux_prefix = "giroux",
    worktree_dir = "~/.cache/giroux/worktrees",
  },
  tripwires = { read = {}, write = {} },
  notify = {
    levels = {
      question = "macos",
      dead = "macos",
      end_of_turn = "statusline",
    },
    macos_when_focused = false,
  },
  keymaps = {
    roster = {
      open_feed = "<CR>",
      regroup = "<C-s>",
      attach = "a",
      steer = "s",
      dispatch = "n",
      diff = "v",
      qa = "Q",
      stats = "S",
      kill = "K",
      resume = "R",
      refresh = "r",
      close = "q",
      help = "?",
    },
    feed = {
      toggle_fold = "<Tab>",
      attach = "a",
      steer = "s",
      diff = "v",
      open_subagent = "<CR>",
      qa = "Q",
      peek = "K",
      next_turn = "]]",
      prev_turn = "[[",
      close = "q",
      help = "?",
    },
  },
}

---@type giroux.Config
M.config = vim.deepcopy(M.defaults)

---@param opts giroux.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Seed node discovery at setup so the cache is warm for entry points that read
  -- it synchronously (dispatch, :checkhealth, clean) — not only the live monitor.
  if M.config.discover then
    require("giroux.nodes").refresh()
  end
end

---Open the roster, or jump straight to a session's feed.
---@param arg string|nil node, or node/session-prefix
function M.open(arg)
  require("giroux.roster").open(arg)
end

return M
