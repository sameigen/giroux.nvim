# giroux.nvim

[![ci](https://github.com/sameigen/giroux.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/sameigen/giroux.nvim/actions/workflows/ci.yml)
![neovim](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)
![license](https://img.shields.io/github/license/sameigen/giroux.nvim)

The captain for your Claude Code agents. Named for the Flyers legend —
opinionated, Claude-only, no abstraction layer.

![giroux roster → feed → answer a question](assets/demo.gif)

From one Neovim, observe and steer every Claude Code session across your
Tailscale network: the live transcript, every tool call, every bash command,
every diff — *more* visibility than the TUI itself gives you, never less.
Observation is lossless and non-invasive: giroux tails session transcripts;
it never gets between the agent and its work.

Companion to [parole.nvim](https://github.com/sameigen/parole.nvim):
giroux supervises the work, parole reviews it for release.

## The point

Wrappers die because they hide the tool calls. Giroux's core bet is the
opposite: the session transcript (`~/.claude/projects/**/<session>.jsonl`)
is a lossless feed of everything the agent does — full bash commands and
their output, edit diffs, web fetches, thinking, token spend. Giroux renders
that feed live, proves agent state from transcript + process evidence, and
(soon) makes steering a deliberate, in-editor act.

## Commands

| Command | What |
|---|---|
| `:Giroux` | The roster — every session on every node, live, attention-sorted |
| `:GirouxFeed [session]` | Live lossless feed (tool calls fold open, follows the tail) |
| `:GirouxQA [session]` | Q&A digest — your turns + answers, tool calls collapsed |
| `:GirouxDispatch` | New agent: node → repo → optional worktree → tmux + claude |
| `:GirouxAttach [session]` | Take over a session's TUI in a terminal tab |
| `:GirouxSteer [session]` | Queue a message into a session (`:w` sends) |
| `:GirouxClean [node]` | Reap detached giroux sessions idle > 30m |

### Roster keys
`<CR>` feed · `n` dispatch · `a` attach · `s` steer · `R` resume (dead) ·
`S` stat sheet · `Q` digest · `r` refresh · `q` close.
A `▸` marks a **steerable** session (live tmux); blank is observe-only.

### Feed keys
`<Tab>` fold · `K` peek line · `]]`/`[[` jump turns · `a` attach · `s` steer ·
`<CR>` drill into a subagent, or answer the live question option · `Q` digest · `q` close

## Capture (optional but recommended)

Source the wrapper so interactive `claude` sessions you start by hand land in
tmux and become steerable (headless/`-p` runs are untouched):

```sh
# ~/.zshrc
[ -f ~/path/to/giroux.nvim/scripts/claude-wrapper.zsh ] && source ~/path/to/giroux.nvim/scripts/claude-wrapper.zsh
```

## Status

**v0.1.** Observe + steer across macOS *and* Linux tailnet nodes: grouped roster
(by machine / repo / state, needs-you first), live `claude agents --json` state,
zero-config tailnet discovery, login-shell dispatch (no `/login` hangs), and a
zero-coupling handoff from [parole.nvim](https://github.com/sameigen/parole.nvim).
Built and tested (74 specs; the JSONL parser is gauntleted against 270+ real
transcripts, 0 crashes). Design rationale lives in [DESIGN.md](DESIGN.md), the
build map in [ARCHITECTURE.md](ARCHITECTURE.md), the phased plan in [PLAN.md](PLAN.md).

## Requirements

- Neovim ≥ 0.11, with `ssh` and `tmux` available
- **macOS and Linux nodes.** Discovery is portable (GNU `stat -c` with a BSD
  `stat -f` fallback) and `tail -F` works on both. `:checkhealth giroux` reports
  each node's platform.

## Setup

Configure the nodes to supervise:

```lua
require("giroux").setup({
  nodes = { workhorse = { host = "workhorse" } }, -- honors ~/.ssh/config
  discover = true,                  -- or: auto-discover online macOS tailnet peers
  -- discover_tag = "tag:agent-host",  -- scope discovery to a tailscale ACL tag
  tripwires = { read = { "**/legacy/**" } },  -- ping when an agent reads stale code
})
```

With `discover = true`, online macOS peers from `tailscale status --json` are
added automatically (keyed by their MagicDNS name), so the `nodes` table is
optional; explicit config always wins.

### Authentication (read this if dispatch hangs on `/login`)

giroux runs the dispatched `claude` under a **login shell**, so it picks up
auth and PATH from your profile. On macOS the login keychain is **locked in a
non-GUI SSH/tmux context**, so an agent there can't read it and blocks on
`/login` at the first message. Fix it once per node: run `claude setup-token`
and export the result in the node's `~/.zshenv`:

```sh
export CLAUDE_CODE_OAUTH_TOKEN="…"   # from `claude setup-token`
```

`:checkhealth giroux` flags a node that's missing this before it bites.

### Roster

`:Giroux` opens the board. Sessions are grouped (default: by machine); `Ctrl+S`
cycles machine → repo → state and the choice persists, `Enter` folds a group or
opens a session, and what needs you floats to the top.

> If `Ctrl+S` does nothing, your terminal is eating it as XON/XOFF flow control —
> add `stty -ixon` to your shell rc, or remap `keymaps.roster.regroup`.

## Tests

```
nvim -l tests/run.lua       # unit + integration specs
nvim -l scripts/smoke.lua   # every module loads, config merges
```
