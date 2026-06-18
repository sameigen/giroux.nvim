-- Scripted, reproducible demo for the README GIF: the real giroux roster and
-- feed rendering synthetic transcripts, driven on a fixed timeline that ends
-- with :qa so asciinema records the same sequence every run. No Claude, no
-- API, no tokens, no tmux — the two pane-read seams (question detection and
-- answer-send) are stubbed so the recording is fully deterministic; every
-- other code path (discovery, tailing, state, rendering) is the real thing.
--
-- See scripts/demo.sh for the asciinema/agg wrapper.

-- ---------------------------------------------------------------------------
-- fixture: a temp claude_projects with three transcripts. Dir names are clean
-- "-Users-demo-<repo>" slugs so the roster shows tidy project names.

local root = vim.fn.tempname() .. "/giroux-demo"
local proj_a = root .. "/workhorse" -- one machine's ~/.claude/projects
local proj_b = root .. "/gpu-box" -- a second machine on the tailnet
vim.fn.mkdir(proj_a, "p")
vim.fn.mkdir(proj_b, "p")

local function J(t)
  return vim.json.encode(t)
end

---@return string path
local function transcript(base, repo, uuid, records)
  local dir = base .. "/-Users-demo-" .. repo
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. uuid .. ".jsonl"
  local lines = {}
  for _, r in ipairs(records) do
    lines[#lines + 1] = J(r)
  end
  vim.fn.writefile(lines, path)
  return path
end

local USAGE = { input_tokens = 4200, output_tokens = 320, cache_read_input_tokens = 18000 }

local function tool(name, input, id)
  return {
    type = "assistant",
    uuid = "u" .. id,
    message = {
      id = "m" .. id,
      role = "assistant",
      content = { { type = "tool_use", id = id, name = name, input = input } },
      model = "claude-sonnet-4-6",
      usage = USAGE,
    },
  }
end

local function text(t, stop)
  return {
    type = "assistant",
    uuid = "x" .. tostring(#t),
    message = {
      id = "mx" .. tostring(#t),
      role = "assistant",
      content = { { type = "text", text = t } },
      stop_reason = stop,
      model = "claude-sonnet-4-6",
      usage = USAGE,
    },
  }
end

-- hero: a migration investigation that ends idle; its (stubbed) pane holds the
-- live question, so the probe flips it to ?.
local hero = transcript(proj_a, "acme-api", "1111aaaa-0000-0000-0000-000000000001", {
  { type = "ai-title", aiTitle = "Investigate the failing staging migration" },
  {
    type = "user",
    uuid = "h1",
    message = { role = "user", content = "the staging migration is failing — can you dig in?" },
  },
  tool("Bash", { command = "tail -n 50 /var/log/migrate.log", description = "read the migration log" }, "Bash1"),
  {
    type = "user",
    uuid = "h2",
    message = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = "Bash1", content = 'ERROR: column "email" does not exist' } },
    },
  },
  tool("Read", { file_path = "db/migrations/0042_rename_email.sql" }, "Read1"),
  {
    type = "user",
    uuid = "h3",
    message = {
      role = "user",
      content = {
        {
          type = "tool_result",
          tool_use_id = "Read1",
          content = "ALTER TABLE users RENAME COLUMN email TO email_address;",
        },
      },
    },
  },
  tool("Edit", { file_path = "db/migrations/0043_add_email_address.sql" }, "Edit1"),
  {
    type = "user",
    uuid = "h4",
    message = { role = "user", content = { { type = "tool_result", tool_use_id = "Edit1", content = "ok" } } },
    toolUseResult = {
      filePath = "db/migrations/0043_add_email_address.sql",
      structuredPatch = {
        {
          lines = {
            "+ALTER TABLE users ADD COLUMN email_address text;",
            "+UPDATE users SET email_address = email;",
            "+-- drop email in a follow-up once readers are migrated",
          },
        },
      },
    },
  },
  text(
    "Found it — the rename runs before the backfill. I've drafted the safe, additive version; want that, or should I go more aggressive?",
    "end_turn"
  ),
  { type = "system", subtype = "turn_duration", uuid = "htd", durationMs = 18400, messageCount = 9 },
})
-- backdate the hero so it's idle long enough for the question-probe to fire on
-- the first discovery tick — it reads as `?` (needs you) at the top of the roster.
local uv = vim.uv or vim.loop
uv.fs_utime(hero, os.time(), os.time() - 30)

transcript(proj_a, "acme-web", "2222bbbb-0000-0000-0000-000000000002", {
  { type = "ai-title", aiTitle = "Add a dark-mode toggle to settings" },
  { type = "user", uuid = "w1", message = { role = "user", content = "add a dark mode toggle" } },
  tool("Edit", { file_path = "src/Settings.tsx" }, "Edit1"), -- unresolved -> ● working
})

transcript(proj_b, "acme-infra", "3333cccc-0000-0000-0000-000000000003", {
  { type = "ai-title", aiTitle = "Bump the Terraform AWS provider to 5.x" },
  { type = "user", uuid = "i1", message = { role = "user", content = "upgrade the aws provider to 5.x" } },
  text("Done — the plan is clean, no resource replacements.", "end_turn"),
  { type = "system", subtype = "turn_duration", uuid = "itd", durationMs = 9200, messageCount = 5 },
})

-- ---------------------------------------------------------------------------
-- giroux against the fixture; fast intervals for a snappy recording.

-- demo aesthetics: truecolor + a high-contrast built-in scheme (so the GIF
-- shows real editor colors, not agg's 16-color map), and no end-of-buffer ~.
vim.o.termguicolors = true
pcall(vim.cmd.colorscheme, "retrobox")
vim.opt.fillchars = { eob = " " }
vim.o.laststatus = 0

require("giroux").setup({
  nodes = {
    workhorse = { host = false, claude_projects = proj_a },
    ["gpu-box"] = { host = false, claude_projects = proj_b },
  },
  discover_interval = 2,
  -- keep the recording clean: no notification popups, and don't depend on osascript
  notify = { levels = { question = "statusline", dead = "statusline", end_of_turn = "statusline" } },
})

-- Show only the fixture nodes — never the recorder's real local ~/.claude/projects.
local nodes = require("giroux.nodes")
local _all = nodes.all
nodes.all = function()
  local t = _all()
  t["local"] = nil
  return t
end

-- Deterministic stubs for the two pane-read seams (no tmux in the recording).
local QUESTION = {
  question = "How should I fix it?",
  options = {
    { n = 1, label = "Safe: add column, backfill, then drop the old one" },
    { n = 2, label = "Direct: rename in place behind a brief write lock" },
    { n = 3, label = "Type something." },
    { n = 4, label = "Chat about this" },
  },
}
local answered = false
local steer = require("giroux.steer")
local tmuxctl = require("giroux.tmuxctl")
tmuxctl.target = function(_, session, cb) -- hero is steerable; others observe-only
  session.tmux = (session.path == hero and not answered) and "giroux/acme-api" or nil
  cb(session.tmux)
end
steer.read_question = function(it, cb)
  cb((it.path == hero and not answered) and QUESTION or nil)
end
steer.answer = function(_, digit)
  answered = true
  vim.notify(("giroux: answered option %s — sent to the agent"):format(digit))
  local fh = io.open(hero, "a")
  if fh then
    fh:write(
      J(text("On it — writing the three migrations now: add email_address, backfill from email, then drop email."))
        .. "\n"
    )
    fh:close()
  end
end

-- ---------------------------------------------------------------------------
-- timeline. Actions are called directly (reliable); the cursor is positioned
-- visibly first so the recording reads like real navigation.

local function cursor_to(pattern)
  local buf = vim.api.nvim_get_current_buf()
  local n = vim.api.nvim_buf_line_count(buf)
  for l = 1, n do
    if vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]:find(pattern) then
      pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      return l
    end
  end
end

-- send keys to whatever buffer is current (drives real buffer-local maps)
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "m", false)
end

local steps = {
  -- 1. the roster: sessions grouped by machine, attention-sorted, live glyphs
  {
    300,
    function()
      vim.cmd("Giroux")
    end,
  },
  {
    3200,
    function()
      cursor_to("staging migration") -- the ? session that needs you, floated to top
    end,
  },
  -- 2. drill into its feed
  {
    4400,
    function()
      require("giroux.feed").open_path({ node = "workhorse", path = hero })
    end,
  },
  -- 3. unfold a tool call to reveal the full command + output (lossless)
  {
    6200,
    function()
      cursor_to("^▸ read")
    end,
  },
  {
    6800,
    function()
      press("<Tab>")
    end,
  },
  -- 4. answer its live question right from the feed
  {
    8600,
    function()
      cursor_to("^%s+1%.")
    end,
  },
  {
    9400,
    function()
      steer.pick({ node = "workhorse", path = hero })
    end,
  },
  -- 5. the stat sheet: what it wrote/read, where its context came from, spend
  {
    11000,
    function()
      require("giroux.statsheet").open({
        node = "workhorse",
        path = hero,
        title = "Investigate the failing staging migration",
      })
    end,
  },
  {
    16000,
    function()
      vim.cmd("qa!")
    end,
  },
}

vim.ui.select = function(items, _, cb) -- auto-pick the safe option, briefly visible
  vim.defer_fn(function()
    cb(items[1], 1)
  end, 500)
end

if vim.env.GIROUX_DEMO_DEBUG == "1" then
  os.remove("/tmp/demo_dump.txt")
  local function dump(label)
    local fh = io.open("/tmp/demo_dump.txt", "a")
    if fh then
      fh:write("### " .. label .. " ###\n" .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") .. "\n\n")
      fh:close()
    end
  end
  vim.defer_fn(function()
    dump("FEED + fold + question")
  end, 7400)
  vim.defer_fn(function()
    dump("STAT SHEET")
  end, 11800)
end

for _, step in ipairs(steps) do
  vim.defer_fn(step[2], step[1])
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    vim.fn.delete(root, "rf")
  end,
})
