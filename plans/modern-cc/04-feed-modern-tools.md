# Plan 04-feed: feed.lua — render the modern tool vocabulary + multi-question

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update/add the status row for this
> plan in `plans/modern-cc/README.md` if one exists by then.
>
> **Drift check (run first)**: `git diff --stat 47b9665..HEAD -- lua/giroux/feed.lua tests/feed_spec.lua`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 01 (soft — transcript's `question` event's `questions`
  array shape; this plan defends against its absence, see Step 4)
- **Consumed by**: none directly (pure rendering; workstream 06 does not need
  anything new from `feed.lua` for the session-field contract)
- **Category**: feature
- **Planned at**: commit `47b9665`, 2026-07-08, branch `feature/subagent-monitoring`.
  `lua/giroux/feed.lua` and `tests/feed_spec.lua` were both clean (no
  uncommitted changes) at read time — this plan's excerpts are read straight
  off that commit, not off a dirty tree.

## Why this matters

`feed.lua`'s tool formatter (`M._call_head`, `feed.lua:112-136`) special-cases
eight tool names (Bash/Read/Edit/Write/NotebookEdit/Glob/Grep/WebFetch/
WebSearch/Agent/Task) and dumps everything else through a generic
`vim.inspect` fallback: `▸ tool  <Name> (<sorted keys>)` with the full input
table as an expandable body. That fallback never crashes (CONTRIBUTING.md's
bar), but it is noise for tools that are now common in real sessions: a
verified census of this machine's own `~/.claude/projects` corpus
(2026-07-08) turned up `TaskCreate`/`TaskUpdate`/`TaskStop` (the session's
todo panel, hundreds of calls across active sessions), `ToolSearch`,
`Workflow`, `ScheduleWakeup`, `SendMessage`, `Skill`, `Monitor`, and a growing
zoo of `mcp__<server>__<tool>` calls (chrome-devtools, cloudflare, Google
Drive, discord, …) — all rendering today as `▸ tool  TaskCreate (activeForm,
description, subject)` with a `vim.inspect` dump instead of a scannable
one-liner. The live feed is supposed to be the one place you can watch an
agent's todo list update and its subagent handoffs happen at a glance; right
now it can't.

Separately, `AskUserQuestion` rendering (`M._question_lines`, `feed.lua:198-
207`) already loops over `e.questions` as an array — good, multi-question
sessions don't crash — but it has two real gaps found by reading the code
and the corpus together:

1. **The chosen answer is silently dropped.** `AskUserQuestion` only ever
   lands in the transcript once answered (ARCHITECTURE.md's "AskUserQuestion
   transcript finding") — its `tool_use` and paired `tool_result` are
   written together. But `apply_event`'s `question` branch
   (`feed.lua:372-377`) sets `feed.calls[e.id] = { mark = nil, ... }` — `mark`
   is `nil` because questions render as a flat `append()`, not a fold. The
   generic `tool_result` branch (`feed.lua:378-386`) only acts `if call and
   call.mark` — so the answer's `tool_result` event is parsed correctly
   (pending-set proof unaffected) but **never rendered**. You see the
   question and its options; you never see which one was picked. Verified
   against this machine's real corpus: `toolUseResult` for an answered
   question is `{questions: [...], answers: {<question text> = <chosen
   label>}}` — a map keyed by the question's own text, confirmed by both
   `tests/events_spec.lua:110-115` (`answers = { ["Which approach?"] =
   "tmux" }`) and by grepping real sessions (every real `answers` value found
   was a single string, e.g. `{"Which approach?": "tmux"}` — never an array,
   even where a question could plausibly be multiSelect).
2. Questions render as a flat block of lines (`append`), not the foldable
   one-liner + expandable-body idiom every other tool call uses — a
   multi-question `AskUserQuestion` (verified real shape: `questions` is an
   array, each with its own `multiSelect`) dumps all N questions' full option
   lists into the feed unconditionally, no fold to collapse them.

This plan fixes both: extends `M._call_head` with one-liners for the modern
tool vocabulary (grounding every format string in real records read off this
machine's own `~/.claude/projects` corpus, cited inline below), and converts
question rendering to the foldable idiom with the chosen answer(s) shown
against each question.

## Current state

`lua/giroux/feed.lua:112-136` — `M._call_head`, the per-tool one-liner
formatter (the `fmt` closure prepends `▸ ` and pads the verb to 5 chars):

```lua
function M._call_head(e)
  local input = e.input or {}
  local function fmt(word, rest)
    return ("▸ %-5s %s"):format(word, rest)
  end
  if e.name == "Bash" then
    return fmt("bash", first_line(input.command or "?")), lines_of(input.command)
  elseif e.name == "Read" then
    return fmt("read", input.file_path or "?"), {}
  elseif e.name == "Edit" or e.name == "Write" or e.name == "NotebookEdit" then
    local word = e.name == "Write" and "write" or "edit"
    return fmt(word, input.file_path or "?"), {}
  elseif e.name == "Glob" or e.name == "Grep" then
    return fmt(e.name:lower(), (input.pattern or "?") .. " " .. (input.path or "")), {}
  elseif e.name == "WebFetch" then
    return fmt("web", input.url or "?"), { "prompt: " .. (input.prompt or "") }
  elseif e.name == "WebSearch" then
    return fmt("web", "search: " .. (input.query or "?")), {}
  elseif e.name == "Agent" or e.name == "Task" then
    return fmt("agent", input.description or input.subagent_type or "?"), lines_of(input.prompt)
  end
  local keys = vim.tbl_keys(input)
  table.sort(keys)
  return fmt("tool", ("%s (%s)"):format(e.name, table.concat(keys, ", "))), lines_of(vim.inspect(input))
end
```

`lua/giroux/feed.lua:197-207` — the current question renderer (flat lines,
no fold, no answer):

```lua
---@param e giroux.transcript.Event question event
function M._question_lines(e)
  local out = { "" }
  for _, q in ipairs(e.questions or {}) do
    out[#out + 1] = "? " .. (q.question or "?")
    for i, opt in ipairs(q.options or {}) do
      out[#out + 1] = ("    %d. %s — %s"):format(i, opt.label or "?", opt.description or "")
    end
  end
  return out
end
```

`lua/giroux/feed.lua:365-390` — `apply_event`'s `tool_call` / `question` /
`tool_result` branches (this is the wiring that will change):

```lua
  elseif e.kind == "tool_call" then
    local head, body = M._call_head(e)
    local mark = append_fold(feed, head, body)
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, body = body, name = e.name, ts = e.ts }
    end
    feed.state = "●"
  elseif e.kind == "question" then
    append(feed, M._question_lines(e))
    if e.id then
      feed.calls[e.id] = { mark = nil, head = "?", body = {}, name = "AskUserQuestion", ts = e.ts }
    end
    feed.state = "?"
  elseif e.kind == "tool_result" then
    local call = e.id and feed.calls[e.id]
    if call and call.mark then
      local fold = feed.folds[call.mark]
      if fold and not fold.expanded then
        fold.body = M._result_body(call, e)
      end
      set_fold_head(feed, call.mark, call.head .. M._result_suffix(call, e))
    end
    -- subagent drill-in target
    if call and type(e.detail) == "table" and e.detail.agentId then
      call.agent_path = transcript.subagent_path(feed.path, e.detail.agentId)
    end
```

`append_fold`/`toggle_fold`/`set_fold_head` (`feed.lua:246-293`) are the
foldable one-liner + body idiom referenced throughout this plan — `▸`
collapsed / `▾` expanded, body lines prefixed `  │ ` on expand. Nothing in
this plan changes those helpers.

Relevant event shapes from `lua/giroux/transcript.lua` (unchanged by this
plan; ground truth for what `e` carries):

- `tool_call`: `---| "tool_call"      # {id, name, input, message_id}` (`transcript.lua:99`, exact text may differ slightly by line but the shape is `{id, name, input}`).
- `question`: `---| "question"       # {id, questions, message_id} AskUserQuestion tool_use (also enters pending)` (`transcript.lua:100`); built at `transcript.lua:263-268` — `questions = nz(input.questions) or {}` is **always an array** in the current parser (there is no code path today that ever sets a bare `e.question` singular field — the "old single-question shape" defended in Step 4 is a forward/backward guard against a future or as-yet-unseen record shape, not a currently-reachable one).
- `tool_result`: `---| "tool_result"    # {id, text, is_error, detail}` where `detail` = the raw `toolUseResult` (dict | string | list, `transcript.lua:336`). For an answered question, `detail` is `{questions: [...], answers: {<question text> = <chosen label>}}` (verified: `tests/events_spec.lua:93-116`, and independently against real sessions on this machine — every `answers` value observed was a plain string).

Real records this plan's format strings are grounded in (read directly off
this machine's `~/.claude/projects/*/*.jsonl`, 2026-07-08 — reproduce with
`jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="<Tool>") | .input' <file>`):

```
TaskCreate  {"subject":"P1: item-def registry in @2drs/data","description":"...","activeForm":"Building the item-def registry"}
TaskUpdate  {"taskId":"1","status":"in_progress"}                       -- status update
TaskUpdate  {"taskId":"10","description":"Tailnet auto-discovery..."}   -- description-only update, NO status key (real variant, not in the task brief)
TaskStop    {"task_id":"a20a93627050a3656"}                             -- snake_case task_id, NOT taskId — inconsistent with TaskUpdate, verified across 4 real records
TaskUpdate result (toolUseResult) {"task":{"id":"1","subject":"P1: item-def registry in @2drs/data"}}
ToolSearch  {"query":"select:WebFetch","max_results":3}
Workflow    {"script":"export const meta = {\n  name: 'fortunemill-full-audit',\n  description: '...',\n  phases: [...] ..."}
ScheduleWakeup {"delaySeconds":1500,"prompt":"<<autonomous-loop-dynamic>>","reason":"Fallback heartbeat in case a background auditor hangs..."}
SendMessage {"to":"a5da4f0d4dce2a1a7","summary":"REVISE: merge integration branch, apply preflight wording","message":"REVISE — one round...", "recipient":"a5da4f0d4dce2a1a7","content":"..."}  -- to/recipient and message/content are duplicated; use to/summary/message per the task brief
Skill       {"skill":"plannotator-annotate","args":"docs/architecture/e2e-trace-harness.md"}
Monitor     {"until":"Background workflow construct-design-panel (wf_...) has completed and the synthesis is available","timeoutSeconds":"1500"}  -- timeoutSeconds is a STRING here, not a number
mcp tool    {"name":"mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation","input":{"query":"Durable Objects CPU time limit..."}}
mcp tool    "mcp__chrome-devtools__evaluate_script", "mcp__claude_ai_Google_Drive__authenticate", "mcp__discord__list_guilds"  -- server segment may itself contain underscores/hyphens
```

`StructuredOutput` had zero real records in this corpus — its input schema
is caller-defined per task (arbitrary JSON), so Step 1 gives it a labeled
variant of the existing generic fallback rather than a bespoke format; see
the STOP/Maintenance notes if a real shape turns up later.

**Lua gotcha that will bite if missed**: `until` is a Lua reserved word.
`input.until` is a **syntax error** — you must write `input["until"]`. This
matters for the `Monitor` tool's field.

Repo conventions that apply here (CONTRIBUTING.md / ARCHITECTURE.md):
- Pure logic is unit-tested without a buffer; buffer wiring is integration-
  tested headlessly (`tests/feed_spec.lua`'s existing end-to-end test does
  this — extend the pattern, don't invent a new one).
- Every top-level transcript field is optional; unknown/malformed shapes
  degrade to a fallback rendering, never crash or throw.
- Terse comments; commit messages terse/lowercase/module-prefixed, no AI
  trailers.

## Commands you will need

| Purpose      | Command                                | Expected on success        |
|--------------|-----------------------------------------|-----------------------------|
| Tests (all)  | `nvim -l tests/run.lua`                | `... passed, 0 failed`      |
| Tests (one)  | `nvim -l tests/run.lua feed`           | the feed specs pass         |
| Smoke        | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` | exit 0, modules load |
| Format check | `stylua --check lua/ tests/`           | exit 0 (no diff)            |
| Format fix   | `stylua lua/ tests/`                   | rewrites files in place     |
| Gauntlet     | `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` | 0 crashes |

(Typecheck runs in CI via `nvim-typecheck-action` on `lua/` at Error level;
run it locally only if you have `lua-language-server` installed.)

## Scope

**In scope** (the only files you should modify):
- `lua/giroux/feed.lua`
- `tests/feed_spec.lua` (already exists — extend it, do not replace)

**Out of scope** (do NOT touch):
- `lua/giroux/transcript.lua` — the `question` event's `questions` array
  shape and the `tool_result`/`tool_call` event shapes are workstream 01's
  domain (soft dependency: if 01 changes the `question` event shape, Step 4's
  defensive normalizer absorbs it; do not edit `transcript.lua` to make that
  happen).
- `lua/giroux/monitor.lua` / `lua/giroux/sessions.lua` / `lua/giroux/roster.lua`
  — the session-field contract (`session.todos`, `session.queued`,
  `session.ctx_pct`, `session.model`, `session.mode`) is workstream 06's job.
  This plan is feed-buffer rendering only; it does not add or change any
  session field.
- `lua/giroux/qa.lua` / `lua/giroux/statsheet.lua` — separate renderers over
  the same events; not this plan's concern.
- `lua/giroux/steer.lua` — `steer.read_question`/`steer.pick` (the live
  pane-sourced question picker, `render_live_question` in `feed.lua:451-488`)
  is a **different** code path (a pending question that hasn't hit the
  transcript yet) from the answered-question rendering this plan touches.
  Leave `render_live_question`, `start_question_poll`, and the `km.open_subagent`
  keymap handler's live-question branch (`feed.lua:696-704`) untouched — this
  plan only changes how an *answered* `AskUserQuestion` event renders once it
  lands in the transcript.
- Do not change `M._result_suffix` / `M._result_body` (the generic tool
  result formatters) — TaskUpdate and AskUserQuestion get *new*, separate
  helpers; every other tool keeps using the existing generic ones unchanged.

## Git workflow

- Branch: `advisor/04-feed-modern-tools`
- One commit; message style like `feed: render modern tool vocabulary + answered multi-question folds`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extend `M._call_head` with the modern tool one-liners

In `lua/giroux/feed.lua`, add new `elseif` branches to `M._call_head`
(`feed.lua:112-136`) immediately after the existing `Agent`/`Task` branch and
before the final generic fallback. Also add three small pure helper
functions used by the new branches — place them just above `M._call_head`
(same "pure renderers" section, `feed.lua:88-136`).

Helpers (add above `M._call_head`):

```lua
---Head for a TaskUpdate call. `input` only ever carries {taskId, status} or
---{taskId, description} (a description-only edit, no status key — a real
---variant, see this plan's "Current state"); the human-readable subject only
---appears in the RESULT (toolUseResult = {task = {id, subject}}). Shows the
---subject once known, the bare taskId until then.
---@param input table tool_use input
---@param detail table|nil toolUseResult (nil before the result lands)
---@return string
function M._task_update_head(input, detail)
  local subject = type(detail) == "table" and type(detail.task) == "table" and detail.task.subject
  local who = subject or input.taskId or "?"
  return ("▸ %-5s %s: %s"):format("todo", input.status or "edit", who)
end

---Extract `meta.name` from a Workflow script — a JS module that opens
---`export const meta = { name: '...', ... }` (verified real shape). Falls
---back to the script's first line when the pattern isn't found (an
---older/unknown script shape) rather than showing nothing.
---@param script string|nil
---@return string
function M._workflow_name(script)
  if not script or script == "" then
    return "?"
  end
  local name = script:match("meta%s*=%s*{%s*name%s*:%s*['\"](.-)['\"]")
  return name or first_line(script)
end

---Split "mcp__<server>__<tool>" into server/tool. The server segment may
---itself contain underscores/hyphens (real examples:
---"mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation",
---"mcp__claude_ai_Google_Drive__authenticate") — split on the FIRST "__"
---after the "mcp__" prefix, which is always the true server/tool boundary
---in every real name observed. nil, nil when the name doesn't match (feeds
---the generic fallback).
---@param name string
---@return string|nil server, string|nil tool
function M._mcp_parts(name)
  local rest = name:match("^mcp__(.+)$")
  if not rest then
    return nil, nil
  end
  return rest:match("^(.-)__(.+)$")
end
```

New branches in `M._call_head` (insert after the `Agent`/`Task` `elseif`,
before `local keys = vim.tbl_keys(input)`):

```lua
  elseif e.name == "TaskCreate" then
    return fmt("todo", "+ " .. (input.subject or "?")), lines_of(input.description or "")
  elseif e.name == "TaskUpdate" then
    return M._task_update_head(input, nil), lines_of(input.description or "")
  elseif e.name == "TaskStop" then
    -- NB: real field is task_id (snake_case), unlike TaskUpdate's taskId
    return fmt("todo", "stop " .. (input.task_id or "?")), {}
  elseif e.name == "ToolSearch" then
    return fmt("search", input.query or "?"), { "max_results: " .. tostring(input.max_results or "?") }
  elseif e.name == "Workflow" then
    return fmt("workflow", M._workflow_name(input.script)), lines_of(input.script or "")
  elseif e.name == "ScheduleWakeup" then
    return fmt(
      "wake",
      ("in %ss — %s"):format(tostring(input.delaySeconds or "?"), first_line(input.reason or input.prompt or "?"))
    ),
      lines_of(input.prompt or "")
  elseif e.name == "SendMessage" then
    return fmt("→", (input.to or "?") .. ": " .. first_line(input.summary or "?")), lines_of(input.message or "")
  elseif e.name == "Skill" then
    return fmt("skill", input.skill or "?"),
      lines_of(type(input.args) == "string" and input.args or vim.inspect(input.args))
  elseif e.name == "Monitor" then
    -- `until` is a Lua reserved word: input.until is a SYNTAX ERROR, must index with a string key
    return fmt("watch", first_line(input["until"] or "?")), { "timeout: " .. tostring(input.timeoutSeconds or "?") .. "s" }
  elseif e.name == "StructuredOutput" then
    local keys = vim.tbl_keys(input)
    table.sort(keys)
    return fmt("output", table.concat(keys, ", ")), lines_of(vim.inspect(input))
  elseif e.name:match("^mcp__") then
    local server, tool = M._mcp_parts(e.name)
    if server then
      return fmt("mcp", server .. "/" .. tool), lines_of(vim.inspect(input))
    end
  end
```

Leave the trailing generic fallback (`local keys = vim.tbl_keys(input) ...`)
exactly as-is — it still catches truly unknown tools and, thanks to the last
`elseif`'s `if server then` guard, a malformed `mcp__` name that doesn't
split cleanly.

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ exit 0. `stylua --check lua/ tests/` will still fail until Step 6 is done
if it complains about the new code's formatting — run `stylua lua/ tests/`
now if you want a clean diff to review, or wait until Step 6.

### Step 2: Stash `input` on the tool_call record so results can use it

`M._task_update_head` needs `input` a second time when the result lands (to
recompute the head with the subject). The `tool_call` branch in
`apply_event` currently doesn't stash it. In `lua/giroux/feed.lua:365-371`,
change:

```lua
  elseif e.kind == "tool_call" then
    local head, body = M._call_head(e)
    local mark = append_fold(feed, head, body)
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, body = body, name = e.name, ts = e.ts }
    end
    feed.state = "●"
```

to:

```lua
  elseif e.kind == "tool_call" then
    local head, body = M._call_head(e)
    local mark = append_fold(feed, head, body)
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, body = body, name = e.name, ts = e.ts, input = e.input }
    end
    feed.state = "●"
```

(Only the added `, input = e.input` at the end of the table constructor.)

**Verify**: `git diff lua/giroux/feed.lua` shows only that one field added
to this branch. `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 3: Recompute the TaskUpdate head once its result lands

In the `tool_result` branch of `apply_event` (`feed.lua:378-386`), special-
case `TaskUpdate` so the head is recomputed with the now-known subject
before the generic ok/err/duration suffix is appended. Change:

```lua
  elseif e.kind == "tool_result" then
    local call = e.id and feed.calls[e.id]
    if call and call.mark then
      local fold = feed.folds[call.mark]
      if fold and not fold.expanded then
        fold.body = M._result_body(call, e)
      end
      set_fold_head(feed, call.mark, call.head .. M._result_suffix(call, e))
    end
```

to:

```lua
  elseif e.kind == "tool_result" then
    local call = e.id and feed.calls[e.id]
    if call and call.mark then
      local fold = feed.folds[call.mark]
      local head = call.name == "TaskUpdate" and M._task_update_head(call.input or {}, e.detail) or call.head
      if fold and not fold.expanded then
        fold.body = M._result_body(call, e)
      end
      set_fold_head(feed, call.mark, head .. M._result_suffix(call, e))
    end
```

(Every other tool's `call.name ~= "TaskUpdate"`, so `head == call.head` and
behavior is unchanged for them — this is additive.) Leave the
`agentId`/subagent drill-in lines below this block (`feed.lua:387-390`)
untouched — this step doesn't touch them.

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.

### Step 4: Convert question rendering to the foldable idiom

This is the multi-part change. In `lua/giroux/feed.lua`, replace
`M._question_lines` (`feed.lua:197-207`) with three functions: a shape
normalizer (the old-single-question defense), a head builder, and a body
builder whose signature changes from `(e)` to `(questions, answers)`:

```lua
---Normalize a question event's `questions` array. Defends the hypothetical
---old/alternate single-question shape (a bare {question, options} pair at
---the top level of the event, e.g. e.question/e.options instead of a
---one-element e.questions array) in case an upstream parser change (or a
---not-yet-seen record) ever produces it — the current parser
---(transcript.lua:263-268) always sets `questions` as an array, so this
---branch is not reachable today, only a forward guard.
---@param e giroux.transcript.Event question event
---@return table[] questions
function M._question_list(e)
  if type(e.questions) == "table" and #e.questions > 0 then
    return e.questions
  end
  if e.question then
    return { { question = e.question, options = e.options or {} } }
  end
  return {}
end

---One-liner fold head for a question call: the question count (when >1)
---plus the first question's text.
---@param questions table[]
---@return string
function M._question_head(questions)
  local first = questions[1] and (questions[1].question or "?") or "?"
  if #questions > 1 then
    return ("▸ %-5s (%d) %s"):format("ask", #questions, first)
  end
  return ("▸ %-5s %s"):format("ask", first)
end

---Fold body for a question call: each question with its numbered options,
---and — once resolved — the chosen option inline. `answers`, when present,
---maps question text -> chosen label (the real toolUseResult shape; see
---this plan's "Current state" and tests/events_spec.lua:93-116). Pass nil
---for the initial (unresolved-echo) render.
---@param questions table[]
---@param answers table<string, string>|nil
---@return string[]
function M._question_lines(questions, answers)
  local out = {}
  for _, q in ipairs(questions) do
    out[#out + 1] = "? " .. (q.question or "?")
    for i, opt in ipairs(q.options or {}) do
      out[#out + 1] = ("    %d. %s — %s"):format(i, opt.label or "?", opt.description or "")
    end
    local a = answers and q.question and answers[q.question]
    if a then
      out[#out + 1] = "    → chosen: " .. tostring(a)
    end
  end
  return out
end

---Fold-head suffix for an answered question's tool_result: "answered" when
---the structured answers map is present, else the raw result text (defends
---an unexpected/old toolUseResult shape) — always shows something, never
---silently drops the result the way the pre-fold rendering did.
---@param e giroux.transcript.Event tool_result event
---@return string
function M._question_suffix(e)
  local d = e.detail
  if type(d) == "table" and type(d.answers) == "table" and next(d.answers) then
    return "  answered"
  end
  if e.text and e.text ~= "" then
    return "  " .. first_line(e.text)
  end
  return "  answered"
end
```

Now wire these into `apply_event`. Change the `question` branch
(`feed.lua:372-377`) from:

```lua
  elseif e.kind == "question" then
    append(feed, M._question_lines(e))
    if e.id then
      feed.calls[e.id] = { mark = nil, head = "?", body = {}, name = "AskUserQuestion", ts = e.ts }
    end
    feed.state = "?"
```

to:

```lua
  elseif e.kind == "question" then
    local qs = M._question_list(e)
    local head = M._question_head(qs)
    local mark = append_fold(feed, head, M._question_lines(qs))
    if e.id then
      feed.calls[e.id] = { mark = mark, head = head, name = "AskUserQuestion", ts = e.ts, questions = qs }
    end
    feed.state = "?"
```

And extend the `tool_result` branch you edited in Step 3 to special-case
`AskUserQuestion` the same way TaskUpdate is special-cased — the fold body
needs the chosen answers merged in, which the generic `M._result_body` does
not know how to do:

```lua
  elseif e.kind == "tool_result" then
    local call = e.id and feed.calls[e.id]
    if call and call.mark then
      local fold = feed.folds[call.mark]
      if call.name == "AskUserQuestion" then
        local d = e.detail
        local answers = type(d) == "table" and type(d.answers) == "table" and d.answers or nil
        if fold and not fold.expanded then
          fold.body = M._question_lines(call.questions or {}, answers)
        end
        set_fold_head(feed, call.mark, call.head .. M._question_suffix(e))
      else
        local head = call.name == "TaskUpdate" and M._task_update_head(call.input or {}, e.detail) or call.head
        if fold and not fold.expanded then
          fold.body = M._result_body(call, e)
        end
        set_fold_head(feed, call.mark, head .. M._result_suffix(call, e))
      end
    end
```

(The `agentId` subagent drill-in lines stay below this `if`, unchanged —
`AskUserQuestion` results never carry `agentId` so that branch is a no-op
for them, same as today.)

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ exit 0. Do not run the full test suite yet — `tests/feed_spec.lua` still
calls the OLD `M._question_lines(e)` signature and will fail until Step 5.

### Step 5: Update the existing question test for the new signature

`tests/feed_spec.lua` has one test that calls `feed._question_lines`
directly with the old `(e)` signature (current file, lines 88-99):

```lua
  ["feed: question renders options as picker lines"] = function()
    local lines = feed._question_lines({
      questions = {
        {
          question = "Which way?",
          options = { { label = "tmux", description = "send-keys" }, { label = "sdk", description = "stream-json" } },
        },
      },
    })
    assert(lines[2] == "? Which way?", lines[2])
    assert(lines[3]:find("1. tmux — send%-keys"), lines[3])
  end,
```

Replace it with the new `(questions, answers)` signature (note: the body no
longer has a leading blank line — it's a fold body now, not a raw
`append()` — so the question is `lines[1]`, not `lines[2]`):

```lua
  ["feed: question fold lines render options, and the chosen answer once resolved"] = function()
    local qs = {
      {
        question = "Which way?",
        options = { { label = "tmux", description = "send-keys" }, { label = "sdk", description = "stream-json" } },
      },
    }
    local lines = feed._question_lines(qs, nil)
    assert(lines[1] == "? Which way?", lines[1])
    assert(lines[2]:find("1. tmux — send%-keys"), lines[2])
    assert(#lines == 3, "no chosen line before an answer lands: " .. #lines)

    lines = feed._question_lines(qs, { ["Which way?"] = "tmux" })
    assert(lines[#lines] == "    → chosen: tmux", lines[#lines])
  end,
```

**Verify**: `nvim -l tests/run.lua feed` → this test and the rest of the file
pass (some may still fail until Step 6 adds coverage for the new call heads —
that's expected at this point only if you added assertions ahead of code;
if you followed Steps 1-4 in order, everything up to here should already be
green).

### Step 6: Add specs for the new tool one-liners and the modern-tool corpus

Add new tests to `tests/feed_spec.lua`. Follow the existing flat-table style
(each entry a `["name"] = function() ... end`). Add these as new top-level
keys in the table the file returns (do not remove any existing test):

```lua
  ["feed: modern tool call heads — todo panel, search, workflow, wake, message, skill, watch, mcp"] = function()
    local head = feed._call_head({ name = "TaskCreate", input = { subject = "Ship the thing", description = "details" } })
    assert(head == "▸ todo  + Ship the thing", head)

    head = feed._call_head({ name = "TaskUpdate", input = { taskId = "10", status = "in_progress" } })
    assert(head == "▸ todo  in_progress: 10", head) -- no subject yet: falls back to taskId

    head = feed._call_head({ name = "TaskUpdate", input = { taskId = "10", description = "new description, no status key" } })
    assert(head == "▸ todo  edit: 10", head) -- real variant: description-only update, no status

    head = feed._call_head({ name = "TaskStop", input = { task_id = "abc123" } }) -- NB: snake_case in real data
    assert(head == "▸ todo  stop abc123", head)

    head = feed._call_head({ name = "ToolSearch", input = { query = "select:WebFetch", max_results = 3 } })
    assert(head == "▸ search select:WebFetch", head)

    head = feed._call_head({ name = "Workflow", input = { script = "export const meta = {\n  name: 'ship-it',\n  description: 'x'\n}" } })
    assert(head == "▸ workflow ship-it", head)

    head = feed._call_head({ name = "ScheduleWakeup", input = { delaySeconds = 1500, reason = "heartbeat" } })
    assert(head:find("▸ wake  in 1500s — heartbeat", 1, true), head)

    head = feed._call_head({ name = "SendMessage", input = { to = "agent-42", summary = "REVISE: fix the thing" } })
    assert(head == "▸ →   agent-42: REVISE: fix the thing", head)

    head = feed._call_head({ name = "Skill", input = { skill = "plannotator-annotate", args = "docs/x.md" } })
    assert(head == "▸ skill plannotator-annotate", head)

    head = feed._call_head({ name = "Monitor", input = { ["until"] = "background workflow done", timeoutSeconds = "1500" } })
    assert(head:find("▸ watch background workflow done", 1, true), head)

    head = feed._call_head({ name = "mcp__chrome-devtools__evaluate_script", input = { script = "1+1" } })
    assert(head == "▸ mcp   chrome-devtools/evaluate_script", head)

    -- real multi-underscore server segment (verified real tool name)
    head = feed._call_head({
      name = "mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation",
      input = { query = "x" },
    })
    assert(head == "▸ mcp   plugin_cloudflare_cloudflare-docs/search_cloudflare_documentation", head)

    -- unknown tool still falls back to the generic vim.inspect renderer, unaffected
    head = feed._call_head({ name = "SomeFutureTool", input = { a = 1 } })
    assert(head:find("tool  SomeFutureTool %(a%)"), head)
  end,

  ["feed: _task_update_head shows taskId before the result, subject after"] = function()
    local before = feed._task_update_head({ taskId = "7", status = "completed" }, nil)
    assert(before == "▸ todo  completed: 7", before)
    local after = feed._task_update_head({ taskId = "7", status = "completed" }, { task = { id = "7", subject = "Ship it" } })
    assert(after == "▸ todo  completed: Ship it", after)
  end,

  ["feed: _workflow_name parses meta.name, falls back to first line when absent"] = function()
    assert(feed._workflow_name("export const meta = {\n  name: 'fortunemill-full-audit',\n  description: 'x'\n}") == "fortunemill-full-audit")
    assert(feed._workflow_name('export const meta = { name: "double-quoted" }') == "double-quoted")
    assert(feed._workflow_name("// no meta block here\nconsole.log(1)") == "// no meta block here")
    assert(feed._workflow_name(nil) == "?")
    assert(feed._workflow_name("") == "?")
  end,

  ["feed: _mcp_parts splits server/tool, defends malformed names"] = function()
    local server, tool = feed._mcp_parts("mcp__chrome-devtools__evaluate_script")
    assert(server == "chrome-devtools" and tool == "evaluate_script", server .. "/" .. tostring(tool))
    server, tool = feed._mcp_parts("mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation")
    assert(server == "plugin_cloudflare_cloudflare-docs", server)
    assert(tool == "search_cloudflare_documentation", tool)
    server, tool = feed._mcp_parts("not_an_mcp_tool")
    assert(server == nil and tool == nil)
  end,

  ["feed: _question_list defends the old single-question shape"] = function()
    local qs = feed._question_list({ questions = { { question = "A?" }, { question = "B?" } } })
    assert(#qs == 2)
    qs = feed._question_list({ question = "solo?", options = { { label = "x" } } })
    assert(#qs == 1 and qs[1].question == "solo?", vim.inspect(qs))
    qs = feed._question_list({})
    assert(#qs == 0)
  end,

  ["feed: _question_head shows question count only when there's more than one"] = function()
    assert(feed._question_head({ { question = "solo?" } }) == "▸ ask   solo?")
    local h = feed._question_head({ { question = "first?" }, { question = "second?" } })
    assert(h == "▸ ask   (2) first?", h)
  end,
```

Also extend the existing end-to-end fixture test
(`"feed: end-to-end over a local fixture file"`, current `feed_spec.lua`) —
or add a new focused end-to-end test alongside it, whichever keeps the file
readable — so a real `TaskCreate` + a two-question `AskUserQuestion` (with
its answering `tool_result`) flow through `open_path` and land in the
buffer text. Model the new JSONL records on `fixture_lines()`'s existing
`J({...})` helper and the shapes above; assert the buffer contains:
- `"▸ todo  + <subject>"` for the TaskCreate line,
- `"▸ ask   (2)"` for the two-question fold head,
- `"→ chosen:"` for at least one answered question inside the expanded fold
  body (toggle the fold the same way the existing test does with `<Tab>`
  before asserting, mirroring the existing test's fold-expand pattern at the
  bottom of `"feed: end-to-end over a local fixture file"`).

**Verify**: `nvim -l tests/run.lua feed` → all feed specs pass, including the
new ones.

### Step 7: Full suite, gauntlet, format

**Verify**:
- `nvim -l tests/run.lua` → `... passed, 0 failed`; total passing count is
  higher than before Step 5 (net new tests from Steps 5-6).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` → 0 crashes (this plan touches rendering only, not parsing, but the gauntlet also exercises `feed.lua` indirectly if it's wired to render — confirm it still reports 0 crashes; if the gauntlet doesn't touch `feed.lua` at all, this is a no-op check and that's fine).
- `stylua --check lua/ tests/` → exit 0 (run `stylua lua/ tests/` first if it complains).

## Test plan

- `tests/feed_spec.lua`, extended:
  - Modern tool one-liners: `TaskCreate`, `TaskUpdate` (both status and
    description-only variants), `TaskStop` (snake_case `task_id`),
    `ToolSearch`, `Workflow` (real `meta.name` script shape), `ScheduleWakeup`,
    `SendMessage`, `Skill`, `Monitor` (including the `input["until"]`
    reserved-word gotcha), MCP tools (simple and multi-underscore server
    segment), and confirmation the unknown-tool fallback is unaffected.
  - `M._task_update_head` before/after the result lands (subject swap-in).
  - `M._workflow_name` real-shape parse + fallback-to-first-line when the
    `meta.name` pattern isn't found + nil/empty input.
  - `M._mcp_parts` simple + multi-underscore-server split + malformed-name
    defense.
  - `M._question_list` old-single-question defense (not reachable from the
    current parser, but must not crash if it ever is).
  - `M._question_head` single vs. multi-question count prefix.
  - `M._question_lines` options-only vs. with a matched chosen answer
    (signature change from `(e)` to `(questions, answers)` — the one
    pre-existing test that calls it is updated in Step 5, not just extended).
  - End-to-end: a fixture with `TaskCreate` and a two-question answered
    `AskUserQuestion` renders both as folds, with the chosen answer visible
    once expanded.
- Pattern: the existing flat-table style already in `tests/feed_spec.lua`
  (`require("giroux").setup({})` once at file scope, plain `assert`, no
  framework).
- Verification: `nvim -l tests/run.lua feed` → all feed specs pass; full
  `nvim -l tests/run.lua` → `0 failed`.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits with `0 failed`; total passing count
      increased.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` exits 0.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` reports 0 crashes.
- [ ] `stylua --check lua/ tests/` exits 0.
- [ ] `M._call_head` renders one-liners (not the generic `vim.inspect`
      fallback) for `TaskCreate`, `TaskUpdate`, `TaskStop`, `ToolSearch`,
      `Workflow`, `ScheduleWakeup`, `SendMessage`, `Skill`, `Monitor`,
      `StructuredOutput`, and `mcp__<server>__<tool>` tool names.
- [ ] An answered multi-question `AskUserQuestion` renders as a single
      foldable one-liner (`▸ ask   (N) ...`) whose expanded body shows each
      question, its options, and its chosen answer.
- [ ] A single-question `AskUserQuestion` still renders correctly (no
      regression from the multi-question generalization) — no `(1)` count
      prefix.
- [ ] `git grep -n "M\._question_lines(e)" lua/giroux/feed.lua tests/feed_spec.lua`
      returns nothing (old call-sites and the old signature are fully
      migrated).
- [ ] No files outside the in-scope list are modified (`git status`).
- [ ] `plans/modern-cc/README.md` status row for 04 updated, if that file
      exists by the time you finish (create a row; do not create the whole
      file if it doesn't exist yet — that's the aggregator's job).

## STOP conditions

Stop and report (do not improvise) if:

- The `M._call_head` / `M._question_lines` / `apply_event` excerpts above
  don't match the live code (drift).
- `transcript.lua`'s `question` event no longer sets `questions` as an array
  at all (e.g. workstream 01 removed it rather than adding to it) — the
  premise of `M._question_list`'s defense would need rethinking, not just
  applying as written.
- The real `toolUseResult.answers` shape for `AskUserQuestion` turns out to
  key by something other than the question's own text in some session you
  can find (this plan verified it two independent ways — the repo's own
  `tests/events_spec.lua` and a live corpus grep — but if you find a
  counterexample, stop rather than silently special-casing it further).
- Making `mcp__` names, `Workflow` script parsing, or any other new branch
  correct would require touching `transcript.lua` (it shouldn't — all of
  this plan's new logic operates on `e.name`/`e.input` as already parsed).

## Maintenance notes

- `StructuredOutput` has no real corpus example on this machine as of
  2026-07-08 — its input schema is caller-defined per task, so it currently
  gets a labeled variant of the generic fallback (`▸ output <sorted
  keys>`) rather than a bespoke one-liner. If a common/stable field (e.g. a
  `summary`) turns up in a future census, that's a one-branch follow-up in
  `M._call_head`, same pattern as the tools this plan adds.
- `TaskStop`'s `task_id` (snake_case) vs. `TaskUpdate`'s `taskId` (camelCase)
  is a genuine upstream inconsistency, not a typo in this plan — verified
  across 4 real records. If a future Claude Code release unifies the casing,
  `M._call_head`'s `TaskStop` branch is the single place to update (and
  should probably read `input.task_id or input.taskId` defensively at that
  point).
- `M._workflow_name`'s regex assumes `meta` is the first-or-near-top
  declaration and `name` is `meta`'s first key, matching every real script
  sampled. If a future Workflow script nests `meta` differently or puts
  `name` after other keys, the pattern still works (it doesn't require
  `name` to be first) — it only fails if `meta`'s literal text isn't
  `meta%s*=%s*{`, in which case the first-line fallback keeps the feed from
  showing nothing.
- The `mcp__` server/tool split takes the *first* `__` after the prefix as
  the boundary — true for every real MCP tool name sampled (chrome-devtools,
  cloudflare, Google Drive/Calendar, discord, plannotator, Notion, Sentry,
  Loper). If a future MCP server's own name contains a literal `__`, the
  split would misplace the boundary; low-probability, no real example found,
  not worth defending against speculatively.
- Reviewer should confirm the `AskUserQuestion` and `TaskUpdate` special
  cases in the `tool_result` branch don't regress the generic path for every
  other tool — the `else` branch should be byte-identical to the pre-change
  code (Step 3/4's diffs are additive `if`/`elseif` arms, not rewrites of
  the shared tail).
