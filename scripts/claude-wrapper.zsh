# giroux.nvim — transparent tmux capture for interactive claude sessions.
#
# Sourced from ~/.zshrc. Interactive `claude ...` lands in a tmux session
# named giroux/<dir>-<id> with GIROUX_SESSION_ID injected, so giroux can
# observe AND steer it, and the session survives closing the terminal tab.
# Everything non-interactive passes through untouched.
#
# Escape hatch: `command claude ...` runs the raw binary.
# Test hook: GIROUX_WRAPPER_FORCE=1 skips the TTY check (used by specs).

claude() {
  emulate -L zsh

  # passthrough: already inside tmux (recursion-safe), or tmux missing
  if [[ -n "$TMUX" ]] || ! command -v tmux >/dev/null 2>&1; then
    command claude "$@"
    return $?
  fi
  # passthrough: headless/print/utility invocations are not sessions
  local a
  for a in "$@"; do
    case "$a" in
      -p|--print|-h|--help|-v|--version)
        command claude "$@"
        return $?
        ;;
    esac
  done
  case "${1:-}" in
    mcp|config|update|install|doctor|migrate-installer|setup-token|plugin|skill)
      command claude "$@"
      return $?
      ;;
  esac
  # passthrough: no TTY (piped, scripted, editor jobs)
  if [[ -z "$GIROUX_WRAPPER_FORCE" && ( ! -t 0 || ! -t 1 ) ]]; then
    command claude "$@"
    return $?
  fi

  local bin
  bin="$(whence -p claude)" || {
    command claude "$@"
    return $?
  }

  local id
  id="$(command uuidgen | tr 'A-Z' 'a-z')"
  id="${id%%-*}"
  local base="${${PWD:t}//[^a-zA-Z0-9_-]/-}"
  local name="giroux/${base}-${id[1,4]}"

  local cmd="${(q)bin}"
  for a in "$@"; do
    cmd+=" ${(q)a}"
  done

  # Start the session as an INTERACTIVE shell (job control on), then run claude
  # as a FOREGROUND JOB in it via send-keys — so C-z suspends claude to a shell
  # prompt and `fg` brings it back (the classic flow). Launching claude *as* the
  # pane command, like we used to, left no shell to suspend to, so C-z just
  # wedged the session. `$cmd` is the absolute binary, so this never re-enters
  # the wrapper.
  if ! command tmux new-session -d -s "$name" -e GIROUX_SESSION_ID="$id" -c "$PWD"; then
    command claude "$@"
    return $?
  fi
  command tmux send-keys -t "$name" "$cmd" Enter
  # minimal, per-session styling — never touches global tmux config
  command tmux set-option -t "$name" status on >/dev/null
  command tmux set-option -t "$name" status-left "#S " >/dev/null
  command tmux set-option -t "$name" status-left-length 60 >/dev/null
  command tmux set-option -t "$name" status-right "" >/dev/null
  command tmux set-option -t "$name" status-style "bg=default,fg=colour244" >/dev/null
  command tmux set-option -t "$name" mouse on >/dev/null
  command tmux set-option -t "$name" set-titles on >/dev/null
  command tmux set-option -t "$name" set-titles-string "#S" >/dev/null
  # Esc must reach the agent instantly (interrupt / Esc-Esc rewind)
  command tmux set-option -s escape-time 10 >/dev/null
  if [[ -n "$GIROUX_WRAPPER_FORCE" ]]; then
    print -r -- "$name"   # tests: report the session instead of attaching
    return 0
  fi
  command tmux attach-session -t "$name"
}
