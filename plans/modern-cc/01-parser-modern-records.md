# modern-cc Plan 01: Parser — queue-operation, question arrays, new system subtypes, block fallback

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/modern-cc/README.md` if one exists by the time you execute (create
> it with a one-line status table if it doesn't — see plan 02+ for the
> pattern, or `plans/README.md` for the older sibling initiative's format).
>
> **Drift check (run first)**: `git diff --stat 47b96658977ef64ae415a57a9b33f87930fdaf48..HEAD -- lua/giroux/transcript.lua tests/transcript_spec.lua tests/events_spec.lua tests/fixtures/transcripts/edge-cases.jsonl lua/giroux/feed.lua`
> If any of these changed since this plan was written, re-read the "Current
> state" excerpts below against the live files before proceeding; on a
> mismatch, treat it as a STOP condition (this plan's central claim is that
> the parser **already** implements most of the target behavior — if the
> live code has moved, that claim needs re-verification, not blind execution).

## Status

- **Priority**: P1 (foundation of the modern-cc initiative's data layer — the
  `todos.lua`, `stats.lua`/session-field, and roster/feed integration plans
  all read events this plan proves-in, even though none of them are a hard
  dependency of this plan)
- **Effort**: S
- **Risk**: LOW (this plan is additive-only: new fixture lines + new tests;
  see "Current state" for why no `lua/giroux/transcript.lua` **logic** change
  turned out to be required)
- **Depends on**: none
- **Category**: tests / fixture-coverage (not a bugfix — see below)
- **Planned at**: commit `47b96658977ef64ae415a57a9b33f87930fdaf48`, 2026-07-08

## Why this matters

giroux's parser (`lua/giroux/transcript.lua`) was grounded in a census of 154
real transcripts across Claude Code 2.1.85–2.1.172 (2026-06-11, see the
module's own doc comment at `transcript.lua:6-16`). Claude Code has since
grown task/todo tools, a queued-input mechanism, richer permission modes, and
multi-question `AskUserQuestion`. The parser must never crash or mis-classify
these as `undecodable` (the gauntlet, `scripts/gauntlet.lua`, enforces
`crashed == 0 and undecodable == 0` — see `scripts/gauntlet.lua:109`), and
downstream consumers (a queued-input counter, a richer question UI) need the
**full** shape of these events, not a lossy summary.

This plan's job was to teach the parser that vocabulary. Reading the live
code (below) found that **the parser already speaks nearly all of it** —
`queue-operation` is already a first-class `"queue"` event, `AskUserQuestion`
already carries its full `questions` array, and every new `system` subtype
and content-block type named in this initiative's brief already degrades
gracefully to `"other"` rather than `"unknown"`. What's missing is **proof**:
zero of this behavior has fixture coverage in the gauntlet corpus or a unit
test pinning it, so a future refactor could silently break any of it and ship
green. This plan closes that gap — it is a regression-proofing plan, not a
feature-building one, and says so plainly rather than inventing busywork.

## Current state

### The parser already emits `queue-operation` as a first-class event

`Parser:on_line` (`lua/giroux/transcript.lua:442-479`), the `queue-operation`
branch (lines 458-465):

```lua
  elseif rtype == "queue-operation" then
    out[#out + 1] = {
      kind = "queue",
      offset = line.offset,
      ts = nz(rec.timestamp),
      op = nz(rec.operation),
      text = nz(rec.content),
    }
```

This exactly matches the real shape given for this initiative
(`{type:"queue-operation", operation:"enqueue"|..., timestamp, sessionId,
content}`): `op` is `rec.operation` passed through **verbatim**, so any
future operation value (`"dequeue"`, `"remove"`, whatever CC ships next) flows
through untouched — a consumer can already do `op == "enqueue" and +1 or -1`
style counting without any parser change. There's a second, older/adjacent
path at lines 466-473 (`attachment` records whose `attachment.type ==
"queued_command"`) that also produces a `kind = "queue"` event with a
hardcoded `op = "enqueue"` — a different, pre-existing mechanism, not part of
this initiative's brief, left untouched.

The `EventKind` alias already documents this (`transcript.lua:112`):
`"queue" # {op, text}`.

**This event is already a live consumer contract**, not a future one: `feed.lua:429-432`
renders it today:

```lua
  elseif e.kind == "queue" then
    if e.op == "enqueue" and e.text then
      append(feed, { "queued: " .. first_line(e.text) })
    end
```

This is the load-bearing reason the field names **must stay `op`/`text`** —
not `operation`/`content_preview` as this initiative's brief informally
suggested (that was illustrative, not a mandate; the brief also says "never
change any existing event shape consumers rely on," and this one already has
a consumer). `first_line` (`feed.lua:90-92`) calls `s:gsub(...)` on `e.text`
without a type guard — if a future `queue-operation.content` were ever
non-string this would error in `feed.lua`, not `transcript.lua`, but that's
speculative: the given real shape states `content` is the queued user input
(a string), and `transcript.lua`'s own `tool_result` content handling
(`transcript.lua:344-356`) shows the established precedent for adding a
`type(c) == "string"` guard *if* a future census ever finds otherwise. Not
applied here — no evidence it's needed (see Maintenance notes).

### `AskUserQuestion` already carries the full `questions` array, un-flattened

`on_assistant`'s `tool_use` branch (`transcript.lua:258-277`), the
`AskUserQuestion` special case (lines 263-268):

```lua
        if name == "AskUserQuestion" then
          local input = nz(block.input) or {}
          out[#out + 1] = envelope(
            { kind = "question", offset = offset, id = id, questions = nz(input.questions) or {}, message_id = mid },
            rec
          )
```

`questions = nz(input.questions) or {}` passes the **whole array** through
untouched — each entry keeps its own `question`, `header`, `multiSelect`, and
`options`, exactly as the real shape describes ("an ARRAY of questions, each
independently `multiSelect`"). Nothing here flattens to a single question.
The `EventKind` alias already documents the plural field
(`transcript.lua:100-101`): `"question" # {id, questions, message_id}`.

The only test of this today, `tests/events_spec.lua:93-116`
(`"events: AskUserQuestion becomes question + pending_question"`), builds a
**single**-question array and never asserts the array survives being length
> 1 or that `multiSelect` differs per-question — so "un-flattened" is true of
the code but unproven by the suite. Closed in Step 3 below.

### New `system` subtypes and the `"fallback"` content block already degrade to `"other"`, never `"unknown"`

`on_system` (`transcript.lua:402-438`) special-cases five subtypes
(`turn_duration`, `api_error`, `away_summary`, `compact_boundary`,
`model_refusal_fallback`) and then, verbatim (lines 435-437):

```lua
  else -- stop_hook_summary, local_command, scheduled_task_fire, informational, ...
    out[#out + 1] = envelope({ kind = "other", offset = offset, rtype = "system", subtype = sub }, rec)
  end
```

The comment on that `else` **already names `scheduled_task_fire` and
`stop_hook_summary`** as expected fallback cases — this file was written
anticipating them. Both route to `kind = "other"` with `rtype = "system"` and
`subtype = <the real subtype string>`, never to `kind = "unknown"` (that kind
is reserved for `rtype`s the top-level `on_line` dispatch itself doesn't
recognize at all — see `transcript.lua:476-478` — a `system` record always
recognizes `rtype == "system"` and hands off to `on_system`, so it can never
produce `unknown` regardless of `subtype`).

Symmetrically, `on_assistant`'s content-block loop (`transcript.lua:246-278`)
ends with the same pattern for unrecognized block types (lines 275-276):

```lua
      else -- e.g. "fallback" blocks; future block types
        out[#out + 1] = envelope({ kind = "other", offset = offset, rtype = "assistant", subtype = btype }, rec)
      end
```

— again, the comment **already names `"fallback"` blocks** explicitly.
`on_user`'s content-block loop has the identical fallback shape for the user
side (lines 393-395, `rtype = "user"`), in case a `"fallback"` block ever
appears in a user message instead.

**Fixture coverage already exists for three of these four shapes.** Reading
`tests/fixtures/transcripts/edge-cases.jsonl` (24 lines):

- line 6: `{"type":"queue-operation",...,"operation":"enqueue","content":"run lint next"}`
- line 7: `{"type":"attachment",...,"attachment":{"type":"queued_command",...}}`
- line 18: `{"type":"assistant",...,"content":[{"type":"fallback","text":"unsupported block"}]}`
- line 23: `{"type":"system","subtype":"stop_hook_summary",...,"content":"stop hook ran"}`

**Missing**: a `scheduled_task_fire` system-subtype fixture line, and a
multi-question `AskUserQuestion` fixture line (the existing one at
`tests/fixtures/transcripts/tools.jsonl:10` has exactly one question, no
`header`, and `multiSelect` unset). Closed in Step 2.

**Test coverage already exists but is thin.** `tests/events_spec.lua`
(**not** `tests/transcript_spec.lua` — see the note right below) already has:
- `"events: queue operations and queued_command attachments"` (lines
  281-310) — asserts `.kind == "queue"` and `.text`, but **never asserts
  `.op`** for either the `enqueue` or the hardcoded-attachment path, and never
  exercises a non-`"enqueue"` operation value.
- `"events: unknown types and garbage never crash, never drop"` (lines
  246-255) — proves the *generic* unrecognized-block-degrades-to-`other`
  mechanism (using a made-up `"warp-block"` type), but never exercises the
  literal `"fallback"` type name, and never exercises an unrecognized
  `system` subtype at all (only an unrecognized top-level `rtype`,
  `"hologram-sync"`, which is a different code path — `on_line`'s own
  `else`, `transcript.lua:476-478` — not `on_system`'s `else`).

Closed in Step 3.

### A note on which test file: `tests/transcript_spec.lua` vs `tests/events_spec.lua`

This plan's brief said "unit specs in transcript_spec.lua," but reading both
files shows the repo already splits `transcript.lua`'s two layers across two
spec files:

- `tests/transcript_spec.lua` (69 lines, 7 tests) tests **only** `M.lines` /
  `Lines:feed` — Layer 1, the byte-chunk-to-line assembler (offsets, partial
  tails, CRLF, resume). It has zero references to `M.parser`, `Parser:feed`,
  or any event `kind`.
- `tests/events_spec.lua` (332 lines, 14 tests) tests **only** `M.parser` /
  `Parser:feed` — Layer 2, the record-to-event parser. Every existing test
  for `queue`, `question`, `tool_call`, `tool_result`, `usage`, etc. lives
  here, with shared `J()` (JSON-encode), `assistant_rec()`, and `result_rec()`
  helpers already built to the real census shapes.

All of this plan's new shapes are Layer-2 (parser/event) concerns, so the new
tests belong in `tests/events_spec.lua`, extending its existing helpers, not
in `tests/transcript_spec.lua`. This plan therefore edits
`tests/events_spec.lua` instead of/in addition to `tests/transcript_spec.lua`
— a deliberate, grounded deviation from the literal brief, in favor of the
convention the live repo has already established. `tests/transcript_spec.lua`
is untouched by this plan.

### What is explicitly *not* this plan's job (and needs no parser change)

- **`TaskCreate` / `TaskUpdate` / `TaskStop`** (the coming `todos.lua`
  workstream's data source): these are ordinary `tool_use` / `tool_result`
  records. `TaskCreate`'s `{subject, description, activeForm?}` input and
  `TaskUpdate`'s `{taskId, status}` input already flow through the generic
  `tool_call` branch (`transcript.lua:269-274`, `input = nz(block.input)`,
  untouched, any tool name); `TaskUpdate`'s `toolUseResult = {task: <...>}`
  already flows through the generic `tool_result` branch's `detail` field
  (`transcript.lua:336-364`, `detail = nz(rec.toolUseResult)`, untouched).
  `todos.lua` can fold directly off existing `tool_call`/`tool_result` events
  filtered by `name` — no new parser event kind needed. Not touched here.
- **`ToolSearch`, `Workflow`, `ScheduleWakeup`, `SendMessage`, `Skill`,
  `Monitor`, `StructuredOutput`, and `mcp__<server>__<tool>` tool names**:
  same generic `tool_call` branch, driven purely by `block.name` — the parser
  has never special-cased tool names except `AskUserQuestion`, and doesn't
  need to for any of these. Any "friendlier icon/label" work for these tool
  names is a `feed.lua` rendering concern, not a parsing one, and is out of
  this plan's owned files.
- **`permission-mode` session_meta values** (`default|plan|acceptEdits|auto`):
  already parsed generically by the `SESSION_META` table
  (`transcript.lua:197-204`) and `on_line`'s session-meta branch
  (`transcript.lua:456-457`, `value = nz(rec[SESSION_META[rtype]])`) — the
  value is passed through verbatim, unvalidated, so any new enum member needs
  no parser change either. `tests/fixtures/transcripts/edge-cases.jsonl:2`
  and `tests/events_spec.lua:153` already exercise this generically.

## Commands you will need

| Purpose               | Command                                                                          | Expected on success                          |
|------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------|
| Tests (all)            | `nvim -l tests/run.lua`                                                          | `... passed, 0 failed`                        |
| Tests (events only)    | `nvim -l tests/run.lua events`                                                   | events specs pass, count includes the new 4   |
| Smoke                  | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`               | exit 0                                        |
| Gauntlet (fixtures)    | `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` | `crashes: 0`, `undecodable: 0`, exit 0 |
| Format check           | `stylua --check lua/ tests/`                                                     | exit 0 (fix with `stylua lua/ tests/`)        |

(Bare `nvim -l scripts/smoke.lua` / `gauntlet.lua` without `--cmd "set rtp+=."`
cannot find the `giroux` module — always use the `--cmd` form for those two.)

## Scope

**In scope** (the only files this plan touches):
- `lua/giroux/transcript.lua` — **read-only in practice**: Step 1 confirms no
  logic change is needed. If Step 1's verification surfaces a real
  discrepancy from this plan's "Current state" claims, a minimal *additive*
  fix belongs here (see STOP conditions for the boundary between "fix it" and
  "stop and report").
- `tests/events_spec.lua` — add 4 new tests (Step 3). This is transcript.lua's
  own Layer-2 companion spec file (see "A note on which test file" above);
  treat it as owned by this plan, not a different workstream's file.
- `tests/fixtures/transcripts/edge-cases.jsonl` — append 2 new lines (Step 2).

**Out of scope** (do NOT touch):
- `tests/transcript_spec.lua` — Layer 1 only; nothing in this plan's brief
  touches the byte/line assembler. Leave it exactly as-is.
- `lua/giroux/feed.lua`, `lua/giroux/qa.lua`, `lua/giroux/stats.lua`,
  `lua/giroux/monitor.lua`, `lua/giroux/roster.lua`, `lua/giroux/steer.lua` —
  render/act/session-state layers owned by other modern-cc workstreams. This
  plan proves the *events* exist in the right shape; it does not wire them
  into a session field, a roster column, or a feed line.
- A new `todos.lua` — a separate workstream's file; this plan only confirms
  (does not build) that its data source (`tool_call`/`tool_result` for
  `TaskCreate`/`TaskUpdate`/`TaskStop`) needs no parser change.
- Any other fixture file (`tools.jsonl`, `basic-session.jsonl`, `big-line.jsonl`,
  `subagents/agent-1.jsonl`, `workflows/**`) — the 2 new lines both belong
  naturally in `edge-cases.jsonl` (the existing home for one-off record-shape
  coverage); don't spread this plan's fixtures across files.
- Renaming any existing event `kind` or field (`"queue"`'s `op`/`text`,
  `"question"`'s `questions`, `"other"`'s `rtype`/`subtype`) to match this
  initiative brief's illustrative names (`"queued"`, `operation`,
  `content_preview`) — `feed.lua:429-432` is a live consumer of the current
  names; renaming is a breaking change to a different workstream's file and
  explicitly against this plan's own charter ("WITHOUT changing any existing
  event shape consumers rely on").

## Git workflow

- Branch: `advisor/modern-cc-01-parser-modern-records`
- One commit if Step 1 needs no code fix (the expected outcome); two commits
  only if Step 1 legitimately surfaces and fixes a real gap (fixture/test
  commit, then a separate minimal parser-fix commit) — see STOP conditions
  before deciding a "fix" is actually in scope.
- Commit message style: `transcript: pin queue/question/fallback/subtype coverage with fixtures + tests` (terse, lowercase, module-prefixed, no AI trailers).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the parser matches this plan's "Current state" claims (no edit expected)

Re-read the five code sites cited above directly in the live file and confirm
each still matches verbatim:

```sh
grep -n 'kind = "queue"' lua/giroux/transcript.lua                 # expect 2 hits: ~460, ~470
grep -n 'kind = "question"' lua/giroux/transcript.lua              # expect 1 hit: ~266
grep -n 'questions = nz(input.questions)' lua/giroux/transcript.lua # expect 1 hit: ~266
grep -n 'stop_hook_summary, local_command, scheduled_task_fire' lua/giroux/transcript.lua # expect 1 hit: ~435
grep -n 'e.g. "fallback" blocks' lua/giroux/transcript.lua         # expect 1 hit: ~275
```

If all five greps return the expected hit (allow ±5 lines of drift from
unrelated edits elsewhere in the file), **no source change is needed** — proceed
to Step 2. If any grep comes back empty or the surrounding logic has changed
shape (e.g. `questions` is no longer passed through whole, or the `on_system`/
block-loop `else` branches were removed or now emit `"unknown"` instead of
`"other"`), STOP per the STOP conditions below — do not paper over a real
regression by adjusting this plan's tests to match broken behavior.

**Verify**: all 5 greps return the expected line (number may drift slightly,
content must not).

### Step 2: Add two fixture lines to `tests/fixtures/transcripts/edge-cases.jsonl`

Append exactly these two lines after the current line 24 (the sidechain
assistant record), keeping the file's existing one-record-per-line, no
trailing-whitespace style:

```json
{"type":"system","subtype":"scheduled_task_fire","timestamp":"2026-07-08T14:00:17.000Z","content":"nightly maintenance routine woke the session"}
{"type":"assistant","timestamp":"2026-07-08T14:00:18.000Z","uuid":"a24","message":{"id":"msg_24","model":"claude-basic","content":[{"type":"tool_use","id":"toolu_ask2","name":"AskUserQuestion","input":{"questions":[{"question":"which deploy target?","header":"Target","multiSelect":false,"options":[{"label":"staging","description":"safe rollout"},{"label":"prod","description":"risky rollout"}]},{"question":"which regions?","header":"Regions","multiSelect":true,"options":[{"label":"us-east","description":"primary"},{"label":"eu-west","description":"secondary"}]}]}}]}}
```

Both lines are pre-validated single-line JSON (no reformatting needed). The
first exercises the previously-fixture-uncovered `scheduled_task_fire`
subtype through `on_system`'s fallback branch. The second is a **standalone**
`tool_use` (no paired `tool_result` needed — this fixture file already mixes
paired and unpaired records freely, and the gauntlet only cares about
crash/undecodable counts, not resolved pending state) carrying **two**
questions with differing `multiSelect` and distinct `header`s, exercising the
un-flattened array through the gauntlet corpus, not just a hand-built unit
test.

**Verify**:
```sh
nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts
```
Expect `crashes: 0` and `undecodable: 0` (unchanged), and in the per-kind
breakdown, `question` and `other` counts each one higher than before your
change (compare against a run before Step 2 if you want the exact deltas —
not required, just `crashes: 0`/`undecodable: 0` staying true is the bar).

### Step 3: Add 4 regression tests to `tests/events_spec.lua`

Add these as new entries in the flat table returned by the file (after the
existing `"events: streaming chunk boundaries produce identical events"`
entry, before the closing `}`), reusing the file's existing `J()`,
`assistant_rec()`, and `result_rec()` helpers — do not add new ones:

```lua
  ["events: AskUserQuestion carries the full multi-question array, un-flattened"] = function()
    local p = transcript.parser()
    local q = {
      questions = {
        {
          question = "which deploy target?",
          header = "Target",
          multiSelect = false,
          options = { { label = "staging", description = "safe" }, { label = "prod", description = "risky" } },
        },
        {
          question = "which regions?",
          header = "Regions",
          multiSelect = true,
          options = { { label = "us-east", description = "" }, { label = "eu-west", description = "" } },
        },
      },
    }
    local evs = p:feed(J(assistant_rec({ { type = "tool_use", id = "toolu_q2", name = "AskUserQuestion", input = q } })))
    assert(evs[1].kind == "question")
    assert(#evs[1].questions == 2, "array must not collapse to one question, got " .. #evs[1].questions)
    assert(evs[1].questions[1].multiSelect == false and evs[1].questions[2].multiSelect == true, "each question keeps its own multiSelect")
    assert(evs[1].questions[1].header == "Target" and evs[1].questions[2].header == "Regions")
    assert(evs[1].questions[2].options[1].label == "us-east")
  end,

  ["events: queue-operation preserves `op` for both enqueue and non-enqueue values"] = function()
    local p = transcript.parser()
    local evs = {}
    vim.list_extend(
      evs,
      p:feed(J({ type = "queue-operation", operation = "enqueue", sessionId = "s1", timestamp = "t1", content = "run lint" }))
    )
    -- exact non-enqueue operation string is unverified against a real census; this
    -- proves generic pass-through, not a specific value (see plan notes).
    vim.list_extend(
      evs,
      p:feed(J({ type = "queue-operation", operation = "dequeue", sessionId = "s1", timestamp = "t2", content = "run lint" }))
    )
    assert(evs[1].kind == "queue" and evs[1].op == "enqueue", "op must be captured, got " .. tostring(evs[1].op))
    assert(evs[2].kind == "queue" and evs[2].op == "dequeue", "non-enqueue op must pass through untouched, got " .. tostring(evs[2].op))
  end,

  ["events: literal \"fallback\" content block classifies other, never unknown"] = function()
    local p = transcript.parser()
    local evs = p:feed(J(assistant_rec({ { type = "fallback", text = "unsupported block" } })))
    assert(evs[1].kind == "other", "fallback block must degrade to other, got " .. evs[1].kind)
    assert(evs[1].rtype == "assistant" and evs[1].subtype == "fallback")
  end,

  ["events: scheduled_task_fire and stop_hook_summary system subtypes classify other, never unknown"] = function()
    local p = transcript.parser()
    local evs = {}
    vim.list_extend(
      evs,
      p:feed(J({ type = "system", subtype = "scheduled_task_fire", sessionId = "s1", timestamp = "t", content = "woke on schedule" }))
    )
    vim.list_extend(
      evs,
      p:feed(J({ type = "system", subtype = "stop_hook_summary", sessionId = "s1", timestamp = "t", content = "stop hook ran" }))
    )
    for _, e in ipairs(evs) do
      assert(e.kind == "other", "new system subtype must never be unknown, got " .. e.kind)
      assert(e.rtype == "system")
    end
    assert(evs[1].subtype == "scheduled_task_fire" and evs[2].subtype == "stop_hook_summary")
  end,
```

**Verify**: `nvim -l tests/run.lua events` → all events specs pass, including
the 4 new ones (14 existing + 4 = 18 in this file).

### Step 4: Full suite, gauntlet, and format

**Verify**:
- `nvim -l tests/run.lua` → `0 failed`; total pass count +4 over the pre-change
  baseline (113 at commit `47b96658977ef64ae415a57a9b33f87930fdaf48`, so
  expect 117 — re-count with `grep -c '\] = function()' tests/*_spec.lua |
  awk -F: '{s+=$2} END{print s}'` if the baseline has drifted from sibling
  work landing in parallel).
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.
- `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` → `crashes: 0`, `undecodable: 0`, exit 0.
- `stylua --check lua/ tests/` → exit 0 (only relevant if Step 1 touched
  `transcript.lua`; the new fixture lines are JSONL, not Lua, and are not
  formatted by stylua).

## Test plan

- `tests/events_spec.lua` gains 4 tests (Step 3): multi-question array
  survives un-flattened with per-question `multiSelect`/`header`; `queue`
  events preserve `op` for both `enqueue` and a non-`enqueue` value (the
  existing test never asserted `.op` at all); a literal `"fallback"` content
  block and the `scheduled_task_fire`/`stop_hook_summary` system subtypes all
  classify as `"other"`, explicitly never `"unknown"`.
- `tests/fixtures/transcripts/edge-cases.jsonl` gains 2 lines (Step 2) so the
  CI gauntlet — which runs against the committed corpus, not just hand-built
  unit fixtures — also exercises `scheduled_task_fire` and the multi-question
  array shape, catching a regression even if someone edits `events_spec.lua`'s
  assertions incorrectly.
- Verification: `nvim -l tests/run.lua events`, then the full suite +
  gauntlet + smoke (Step 4).

## Done criteria

ALL must hold:

- [ ] Step 1's five greps confirm the parser's existing behavior matches this
      plan's claims (or a STOP was correctly raised instead of proceeding).
- [ ] `tests/fixtures/transcripts/edge-cases.jsonl` has exactly 2 new lines
      appended (26 total content lines), both valid single-line JSON.
- [ ] `tests/events_spec.lua` has exactly 4 new tests, using the file's
      existing `J()`/`assistant_rec()`/`result_rec()` helpers, no new helpers
      added.
- [ ] `tests/transcript_spec.lua` is byte-for-byte unchanged (`git diff
      tests/transcript_spec.lua` empty).
- [ ] `nvim -l tests/run.lua` → `0 failed`; pass count +4 over baseline.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` → exit 0.
- [ ] `nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts` → `crashes: 0`, `undecodable: 0`, exit 0.
- [ ] `stylua --check lua/ tests/` → exit 0.
- [ ] `git diff lua/giroux/transcript.lua` is empty, UNLESS Step 1 legitimately
      surfaced a real discrepancy — in which case the diff is minimal,
      additive, and documented in the commit message and a note here.
- [ ] No files outside the in-scope list are modified (`git status`).

## STOP conditions

Stop and report (do not improvise) if:

- Any of Step 1's five greps fails to find the expected code, or finds it
  materially changed (e.g. `on_system`'s or the block-loop's `else` branches
  now emit `"unknown"` instead of `"other"`, or `questions` is no longer
  passed through as a whole array) — this plan's premise (mostly-already-done)
  would be wrong and needs fresh analysis, not a forced fit.
- The new fixture lines from Step 2 cause `crashes > 0` or `undecodable > 0`
  in the gauntlet — that means a real shape isn't handled as gracefully as
  this plan claims. Report the exact gauntlet output; do not alter the
  fixture to dodge the failure (that would hide a genuine parser gap), and do
  not silently patch `transcript.lua` beyond a minimal, additive fix without
  flagging it clearly in the commit message.
- `feed.lua:429-432`'s `"queue"` handling no longer reads `e.op`/`e.text` (i.e.
  someone renamed the fields in a parallel workstream) — re-verify the field
  names are still safe to keep before writing tests that assert on them; do
  not rename `transcript.lua`'s fields to chase a moved consumer without
  understanding why it moved.
- You find yourself wanting to add a new distinct event `kind` (e.g.
  `"scheduled_wake"`) instead of routing through `"other"` — that's a
  legitimate design option this plan considered and rejected (see Maintenance
  notes) because no consumer need is documented yet; if you have a concrete
  consumer need, report it rather than deciding unilaterally in a
  regression-proofing plan.
- `tests/events_spec.lua`'s helper functions (`J`, `assistant_rec`,
  `result_rec`) have a materially different signature than shown in "Current
  state" — adapt the new tests' call sites only if the change is mechanical;
  STOP if it's not obvious how to adapt without guessing at new semantics.

## Maintenance notes

- **Field names are the contract, not the initiative brief's illustrative
  names.** `"queue"` events are `{op, text}` (plus `ts`), consumed today by
  `feed.lua:429-432`. Any later workstream building `session.queued` (the
  SESSION-FIELD CONTRACT's pending-input counter) must read `e.op`/`e.text`,
  not `operation`/`content_preview` — those were illustrative naming in the
  brief, not what shipped.
- **Two independent "enqueue" mechanisms exist** (`queue-operation` records
  and `attachment`/`queued_command` records, `transcript.lua:458-473`) and
  both currently produce `kind = "queue", op = "enqueue"` events. If a future
  census finds these ever co-occur for the *same* queued item (double-count
  risk for a naive net-count consumer), that's a `session.queued` aggregation
  concern for whichever workstream builds it — not a parser bug; the parser
  is correctly reporting two independently-written records.
- **Considered and rejected: type-guarding `queue`'s `text` field.**
  `tool_result` content already gets a `type(c) == "string"` guard
  (`transcript.lua:344-356`) because real tool results can be block-lists.
  `queue-operation.content` has no such guard (`transcript.lua:464`,
  `text = nz(rec.content)`) because the given real shape asserts it's always
  the queued string. If a future census ever finds a non-string `content` on
  a `queue-operation` record, add the same guard here — and note that
  `feed.lua:90-92`'s `first_line()` would otherwise error on a non-string
  `e.text`.
- **Considered and rejected: a distinct `scheduled_task_fire` event kind.**
  Routing it through `"other"` (with `rtype/subtype` preserving the real
  subtype string) matches how every other not-yet-consumer-needed `system`
  subtype is handled (`compact_boundary`/`api_error`/`away_summary`/
  `model_refusal_fallback` are the only subtypes broken out into distinct
  kinds, precisely because each already has a real downstream consumer). If a
  later workstream wants a "woke on schedule" feed line or notification, it
  can filter `kind == "other" and rtype == "system" and subtype ==
  "scheduled_task_fire"` — no parser change required to add that consumer
  later.
- **`todos.lua` (a separate workstream) needs no parser change.** `TaskCreate`/
  `TaskUpdate`/`TaskStop` are plain `tool_call`/`tool_result` events today;
  fold on `e.name` and `e.input`/`e.detail.task`. If that workstream's plan
  claims otherwise, it should re-verify against the live parser rather than
  assume new parser work is needed.
- **The `?` (question) roster state still cannot be proven from the transcript
  alone** — see ARCHITECTURE.md's "AskUserQuestion transcript finding":
  `AskUserQuestion` only lands in the JSONL once answered, so the pending-set
  can't prove a *live* question; that's unchanged by this plan. What this
  plan adds is that *once* a question event does appear (live, via the tmux
  pane parse, or replayed from history), its full multi-question shape is now
  proven to survive the parser — useful for a richer question UI regardless
  of how liveness is detected.
- Future contributors adding parser event coverage: extend
  `tests/events_spec.lua` (Layer 2 — records/events), not
  `tests/transcript_spec.lua` (Layer 1 — byte/line assembly only). The split
  is real and load-bearing; don't merge the files or add Layer-2 tests to the
  Layer-1 spec.
