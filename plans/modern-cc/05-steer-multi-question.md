# Plan 05 (modern-cc): Answer multi-question + multiSelect AskUserQuestion from the board

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row in `plans/modern-cc/README.md`.
>
> **Drift check (run first)**: `git diff --stat 47b9665..HEAD -- lua/giroux/steer.lua tests/steer_spec.lua`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (the live-TUI key sequences for multiSelect/multi-question are
  the one genuinely-unverified part — Step 4 gates them behind a real capture)
- **Depends on**: none for the parse side. Owns `steer.lua` alone.
- **Category**: feature / correctness (steering)
- **Planned at**: 2026-07-08, HEAD `47b9665`

## Why this matters

`AskUserQuestion` grew from one question to an **array**, each independently
`multiSelect`. Real input shape (verified on disk):

```json
{ "questions": [ { "question": "...", "header": "...", "multiSelect": false,
                   "options": [ { "label": "...", "description": "..." } ] } ] }
```

giroux answers it from the board by reading the live tmux pane
(`AskUserQuestion` is never in the transcript while pending — it's written only
once answered), then sending keys to the TUI. But every piece of that path
assumes **one question, one digit**:

- `parse_question` (`steer.lua:80-134`) finds a single picker block and returns
  `{question, options}` — no notion of "question 2 of 3" or multiSelect.
- `answer` (`steer.lua:161-178`) sends a bare digit — correct for single-select,
  wrong for multiSelect (which needs toggle-then-submit).
- `pick` (`steer.lua:183-201`) opens one picker and sends one digit.

So a multi-question or multiSelect prompt — which you now hit regularly — gets
mis-answered or only partly answered from the roster. This plan makes answering
walk every question and honor multiSelect, while keeping the single-question
path byte-identical.

## Current state

`parse_question` anchors on the picker footer ("Enter to select"/"to navigate")
and scans upward, collecting `^%s*(%d+)%.%s+(.+)$` option lines until the
flush-left question line, stopping at the `☐` header chip (`steer.lua:96-133`).
It returns exactly one `{question, options}` and has **no** signal for:
- which question index is showing (the TUI renders one question at a time),
- how many questions total,
- whether the current question is multiSelect.

`answer` sends `tmux send-keys <digit>` (`steer.lua:167-176`). `pick` wires the
built-in picker's `on_choice` to `M.answer(it, o.n)` (`steer.lua:194-198`).

`read_question` (`steer.lua:140-155`) is the one capture-pane round-trip both
`pick` and the monitor's probe loop use; keep its signature stable — the monitor
calls it (`monitor.probe_questions`), so a breaking change there ripples.

Conventions: terse comments; commit terse/lowercase/module-prefixed, no AI
trailers. Example: `steer: answer multi-question + multiSelect prompts`.

## Commands you will need

| Purpose      | Command                          | Expected               |
|--------------|----------------------------------|------------------------|
| Tests (one)  | `nvim -l tests/run.lua steer`    | steer specs pass       |
| Tests (all)  | `nvim -l tests/run.lua`          | `... 0 failed`         |
| Smoke        | `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua` | `smoke ok` |
| Format       | `stylua --check lua/giroux/steer.lua tests/steer_spec.lua` | exit 0 |

## Scope

**In scope**:
- `lua/giroux/steer.lua` — multi-question aware parse + a multiSelect-capable
  answer/pick flow.
- `tests/steer_spec.lua` — parse tests for multi-question + multiSelect panes;
  keep the existing single-question tests green.

**Out of scope** (do NOT touch):
- `lua/giroux/pick.lua` — reuse its API; don't change it.
- `read_question`'s signature and the monitor's use of it — additive only
  (you may enrich the returned table, but a `{question, options}` shape must
  still be present so `monitor.probe_questions`' `q ~= nil` truthiness check
  keeps working; verify `monitor.lua`'s use before changing the return).
- The transcript `question` event (workstream 01 owns the parser; that event is
  the *answered* record, which the feed renders — this plan is about the *live*
  pane).

## Git workflow

- Branch: work on the initiative's integration branch (the orchestrator merges).
- One commit; message like `steer: answer multi-question + multiSelect prompts`.

## Steps

### Step 1: Teach `parse_question` the question index, total, and multiSelect

Extend the return to (backward-compatibly) carry the new fields, keeping
`question`/`options` exactly as today:

```
{ question, options, multi_select = <bool>, index = <int|nil>, total = <int|nil> }
```

- **multiSelect detection**: the multiSelect picker renders each option with a
  checkbox glyph (`☐`/`☑`/`◯`/`●`) rather than the single-select `❯` cursor +
  bare number. Detect it from the option lines / footer wording (a multiSelect
  footer typically says "Space to select" or "select multiple"). Capture the
  exact markers in Step 4 from a REAL pane before hardcoding them.
- **index/total**: the TUI shows a progress marker for multi-question prompts
  (e.g. "Question 1 of 2" or a chip). Parse it if present; leave `nil` when a
  single question (the common case) so the single-question path is unchanged.

Keep the existing footer-anchored upward scan; add the new detection alongside
it. **Do not** regress the current single-question parse — the existing
`steer_spec` parse tests must stay green unchanged.

**Verify**: `nvim -l tests/run.lua steer` → existing parse tests pass.

### Step 2: A multiSelect-capable pick flow

Refactor `M.pick` so that:
- **single-select** (`multi_select == false`, the current path): unchanged —
  open the picker, on choice send the digit via `M.answer`. Byte-identical
  behavior.
- **multiSelect**: open the picker allowing multiple selections (pick.lua's
  `on_choice` is single-shot; for multiSelect, drive it to collect a set — or,
  simplest and robust, present the options and let the user pick one-at-a-time
  toggling, then a final "submit"). Send the corresponding key sequence: for the
  real TUI, multiSelect is **toggle each chosen option (its digit or Space on
  the highlighted row) then Enter to submit**. Confirm the exact keys in Step 4.

Add `M.answer_multi(it, digits)` that sends the toggle keys then a final Enter
(mirror `M.answer`'s `send-keys` + `login_wrap` + error-notify shape at
`steer.lua:161-178`). Keep `M.answer` (single digit) exactly as-is for the
single path.

**Verify**: `nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke.lua`
→ `smoke ok`.

### Step 3: Walk multiple questions

When `parse_question` reports `total > 1`, answering the on-screen question
should advance the TUI to the next one; giroux then re-reads the pane and
presents the next question. Implement `M.pick` to, after a successful answer,
re-run `read_question` and (if another question is present) open the next
picker — a small recursive/looped continuation. Guard against an infinite loop
(bail after `total` iterations or when the pane no longer parses a question).

**Verify**: `nvim -l tests/run.lua steer` → passes.

### Step 4: Confirm the real key sequences against a live picker (GATE)

The multiSelect toggle key and the multi-question advance behavior are the
**only unverified** pieces. Before finalizing, capture a real picker:

```
tmux capture-pane -p -t <a session showing a multiSelect / multi-question prompt>
```

Confirm: the checkbox/cursor glyphs, the footer wording, whether a bare digit
toggles (multiSelect) vs selects (single), and how submit works (Enter). Adjust
the Step-1 detection markers and the Step-2/3 key sends to match. If you cannot
obtain a real multiSelect/multi-question pane, implement the single→multi parse
(testable, high-confidence) and mark the multiSelect *send* path as
best-effort + STOP-documented rather than guessing the keys.

**Verify**: the parse tests (Step 5) pass on captured real-pane fixtures.

### Step 5: Tests

In `tests/steer_spec.lua`, add (mirroring the existing `parse_question` tests):
- a **multiSelect** pane fixture → `parse_question` returns `multi_select == true`
  and all options;
- a **multi-question** pane fixture (question 1 of N marker) → `index`/`total`
  parsed, options for the shown question correct;
- a regression assert that a **single-question** pane still returns
  `multi_select == false`/`nil` and the same `{question, options}` as today.

Use real captured pane text (Step 4) as the fixture strings so the test pins the
actual TUI format, not a guess.

**Verify**: `nvim -l tests/run.lua` → `0 failed`; `stylua --check
lua/giroux/steer.lua tests/steer_spec.lua` → exit 0.

## Test plan

- New `steer_spec` cases: multiSelect parse, multi-question parse, single-question
  regression. All pure (feed pane text to `parse_question`) — no tmux needed.
- The send path (`answer_multi`, multi-question walk) is integration-shaped and
  covered by manual verification per Step 4; do not add a flaky test that shells
  out to tmux.

## Done criteria

ALL must hold:

- [ ] `nvim -l tests/run.lua` exits `0 failed`.
- [ ] `stylua --check lua/giroux/steer.lua tests/steer_spec.lua` exits 0.
- [ ] `parse_question` returns `multi_select` (and `index`/`total` when present)
      without regressing the single-question shape (existing tests unchanged).
- [ ] A single-select prompt is answered exactly as before (one digit).
- [ ] `read_question`'s return still satisfies `monitor.probe_questions` (its
      `q ~= nil` check) — the monitor's question probe is unbroken.
- [ ] No files outside `steer.lua`/`steer_spec.lua` modified.
- [ ] `plans/modern-cc/README.md` status row for 05 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The `parse_question`/`answer`/`pick` excerpts don't match the live code (drift).
- You cannot obtain a real multiSelect/multi-question pane to confirm the key
  sequences (Step 4) — ship the parse-side (high-confidence, tested) and report
  the send-side as needing a live capture, rather than guessing tmux keys that
  could mis-answer a prompt.
- Changing `read_question`/`parse_question`'s return breaks
  `monitor.probe_questions` — reconcile so the monitor's probe still works.

## Maintenance notes

- The single source of truth for the picker's on-screen format is the real TUI;
  when Claude Code changes the picker chrome, `parse_question`'s markers are the
  one place to update (same as the existing single-question anchor).
- If a future giroux wants to answer *without* opening the board picker (e.g. a
  one-key "accept the recommended option"), it hooks in at `M.answer`/
  `M.answer_multi`.
