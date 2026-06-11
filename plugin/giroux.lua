if vim.g.loaded_giroux then
  return
end
vim.g.loaded_giroux = true

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("giroux.nvim requires Neovim >= 0.11", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Giroux", function(cmd)
  require("giroux").open(cmd.args)
end, {
  nargs = "?",
  desc = "Open the giroux roster, or a session: :Giroux workhorse | :Giroux workhorse/7972",
})

vim.api.nvim_create_user_command("GirouxQA", function(c)
  require("giroux.feed").resolve(c.args, function(sel)
    if sel then
      require("giroux.qa").open(sel)
    end
  end)
end, { nargs = "?", desc = "Q&A digest of a session: your turns + answers, tool calls collapsed" })

vim.api.nvim_create_user_command("GirouxFeed", function(cmd)
  require("giroux.feed").open(cmd.args)
end, {
  nargs = "?",
  desc = "Live lossless feed for a session (defaults to the most recently active)",
})

vim.api.nvim_create_user_command("GirouxDispatch", function(cmd)
  require("giroux.dispatch").open({ headless = cmd.bang })
end, { bang = true, desc = "Dispatch an agent: node -> repo -> worktree -> tmux + claude (! = headless)" })

vim.api.nvim_create_user_command("GirouxAttach", function(cmd)
  require("giroux.feed").resolve(cmd.args, function(sel)
    if sel then
      require("giroux.steer").attach({ node = sel.node, path = sel.path })
    end
  end)
end, { nargs = "?", desc = "Attach to a session's tmux pane in a terminal tab (full TUI)" })

vim.api.nvim_create_user_command("GirouxSteer", function(cmd)
  require("giroux.feed").resolve(cmd.args, function(sel)
    if sel then
      require("giroux.steer").buffer({ node = sel.node, path = sel.path })
    end
  end)
end, { nargs = "?", desc = "Compose a message into a session without attaching (:w sends)" })

vim.api.nvim_create_user_command("GirouxClean", function(cmd)
  require("giroux.dispatch").clean({ node = cmd.args ~= "" and cmd.args or nil })
end, { nargs = "?", desc = "Reap giroux tmux sessions whose claude process has exited" })
