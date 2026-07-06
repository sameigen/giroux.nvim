# CLAUDE.md — giroux.nvim

giroux.nvim is a Neovim plugin for observing and steering Claude Code agent sessions
across a Tailscale network — it tails session transcripts for a lossless live feed
(tool calls, diffs, bash output) without getting between the agent and its work.
Shared roadmap with parole.nvim: `~/Code/personal/giroux-parole-roadmap.md`.

## Hub

This project is registered in Sam's ops hub: `~/Code/personal/hub`. Read
`projects/giroux.nvim.md` there for cross-project context, `STATUS.md` for the big picture.
- End substantive sessions with `~/Code/personal/hub/bin/hub post giroux.nvim "<one-paragraph digest of what changed>"`.
- When giroux.nvim's state meaningfully changes, update `~/Code/personal/hub/projects/giroux.nvim.md`
  (append to its Log, absolute dates only).
