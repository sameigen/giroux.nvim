# Plan 011: Commit a transcript fixture corpus and run the gauntlet in CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- scripts/gauntlet.lua .github/workflows/ci.yml lua/giroux/transcript.lua`
> If any changed since this plan was written, re-read `scripts/gauntlet.lua` and
> the transcript parser before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

The JSONL transcript parser is the core product, and the gauntlet
(`scripts/gauntlet.lua`) — which streams every real transcript through it and
proves zero crashes — is described in CONTRIBUTING.md as "the bar." But it can
only run against the maintainer's private `~/.claude/projects`; there is **no
committed fixture corpus**, so the gauntlet never runs in CI. A parser
regression that only a real transcript shape triggers ships green, and no
teammate or agent can reproduce "0 crashes." Committing a small, scrubbed,
representative corpus and wiring a CI step turns the parser's strongest
regression guard into something reproducible on every push.

## Current state

`scripts/gauntlet.lua` (read it fully before starting) takes a dir/file arg,
recursively finds `*.jsonl` (excluding `journal.jsonl`), streams each in 64 KB
chunks through `transcript.parser()`, and:

- Counts events by kind, unknown records, and `undecodable` records.
- Prints a summary.
- **Exits 0 only if `totals.crashed == 0 AND totals.undecodable == 0`**
  (`scripts/gauntlet.lua:109`):
  ```lua
  os.exit((totals.crashed == 0 and totals.undecodable == 0) and 0 or 1)
  ```

The `assert(#files > 0, "no .jsonl files found in args")` at line 25 means it
errors if pointed at an empty dir.

**Critical constraint from that exit condition**: the committed corpus must be
**crash-free AND fully decodable** — every line must be valid JSON the parser
recognizes or gracefully classes as a known `unknown` type that is NOT
`undecodable`. A deliberately-truncated / non-JSON line would set
`undecodable > 0` and fail the gauntlet. So:
- The corpus proves the parser handles the **shapes** it will see (many record
  and content-block kinds, nested subagents, large lines, a `journal.jsonl` that
  must be *excluded*).
- Pathological-but-graceful cases (a truncated line, an unknown record type, a
  `vim.NIL` field) belong in `tests/transcript_spec.lua` **unit** tests, not the
  gauntlet corpus — do not put an undecodable line in the corpus.

The transcript format (from DESIGN.md §1 and ARCHITECTURE.md): each line is a
JSON record; assistant messages carry content blocks (`text`, `thinking`,
`tool_use` with full input, `tool_result` with full output), plus `usage`,
model, session metadata (`ai-title`), and user messages. Subagents live under
`<uuid>/subagents/agent-*.jsonl`; workflow-spawned agents under
`workflows/wf_*/`. Confirm the exact field names the parser reads by reading
`lua/giroux/transcript.lua` — **do not invent record shapes**; derive each
fixture line from what the parser actually decodes (grep the parser for the
record `type` values and block `type` values it branches on).

Conventions: no secrets or real content in fixtures (scrub or synthesize). Commit
terse/lowercase/module-prefixed, no AI trailers. Example:
`dx: commit a scrubbed transcript corpus; run the gauntlet in CI`.

## Commands you will need

| Purpose             | Command                                             | Expected            |
|---------------------|-----------------------------------------------------|---------------------|
| Gauntlet (fixtures) | `nvim -l scripts/gauntlet.lua tests/fixtures/transcripts` | `crashes: 0`, exit 0 |
| Tests               | `nvim -l tests/run.lua`                             | `... passed, 0 failed` |
| Smoke               | `nvim -l scripts/smoke.lua`                         | exit 0              |
| YAML sanity         | `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` | no exception |

## Scope

**In scope**:
- `tests/fixtures/transcripts/**` (create — the scrubbed/synthetic corpus)
- `.github/workflows/ci.yml` (add a `gauntlet` step to the existing `test` job,
  or a small dedicated job)
- Optionally `CONTRIBUTING.md` (one line: the gauntlet now has a committed
  fixture corpus and runs in CI) — only if it currently implies otherwise

**Out of scope** (do NOT touch):
- `scripts/gauntlet.lua` — the script is fine; don't change its exit logic. If
  you want to test undecodable handling, that's a unit test, not a gauntlet change.
- `lua/giroux/transcript.lua` — read it, don't edit it. If a synthetic line
  crashes the parser, that's a real bug: STOP and report (do not "fix" the
  fixture to dodge it — that would hide the bug).
- Real transcript content — never commit un-scrubbed real sessions (they contain
  file contents, paths, and potentially secrets).

## Git workflow

- Branch: `advisor/011-gauntlet-fixture-corpus`
- One commit; message like `dx: commit a scrubbed transcript corpus + gauntlet CI step`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Derive the record/block shapes the parser recognizes

Read `lua/giroux/transcript.lua` and list:
- The top-level record `type` values it branches on (e.g. `user`, `assistant`,
  session-meta records, summary records).
- The content-block `type` values (`text`, `thinking`, `tool_use`,
  `tool_result`, images, …).
- The metadata keys it emits `session_meta` for (e.g. `ai-title`, `last-prompt`).

Write these down; each becomes at least one line in a fixture. **Every fixture
line must be a shape the parser decodes without producing an `undecodable`
event.**

**Verify**: you have a concrete list tied to `transcript.lua` line references
(not guessed).

### Step 2: Author the fixture corpus

Create `tests/fixtures/transcripts/` with a handful of small synthetic
transcripts (hand-written JSONL, one JSON object per line), each targeting real
shapes. Suggested set:

- `basic-session.jsonl` — a user message, an assistant `text` + `thinking`
  block, a `tool_use` (Bash) + matching `tool_result`, a `usage` field, and an
  `ai-title` session-meta record. Covers the common path.
- `tools.jsonl` — one line each for the tool shapes the feed renders specially:
  an `Edit`/`Write` with a `structuredPatch` (so diff rendering has input), a
  `Read`, a `WebFetch`, an `AskUserQuestion` **tool_use paired with its
  tool_result** (per ARCHITECTURE.md, AskUserQuestion only appears when
  answered).
- `big-line.jsonl` — one record with a large (e.g. ~200 KB) base64-ish string
  field, to exercise the streaming/large-line path (DESIGN.md §3 notes ~400 KB
  lines exist). Generate the big field programmatically, don't hand-type it.
- `subagents/agent-1.jsonl` — a nested subagent transcript (a couple of records),
  to prove the recursive dir walk (`depth = 16`) picks it up.
- `workflows/wf_demo/journal.jsonl` — a Workflow journal line (different format);
  the gauntlet must **exclude** it (it filters `journal.jsonl`), proving the
  exclusion works. Put a genuinely non-transcript shape here.

Keep every file tiny and content-free (no real code, no paths that look like
secrets, no tokens). All content is placeholder text like `"hello"` /
`"ran the tests"`.

**Verify**: `nvim -l scripts/gauntlet.lua tests/fixtures/transcripts` prints
`crashes: 0`, `undecodable: 0`, and exits 0. If it reports `undecodable > 0`,
find the offending line and make it valid (or if it's the intentional
`journal.jsonl`, confirm it was excluded, not parsed).

### Step 3: Wire the gauntlet into CI

Add a step to the existing `test` job in `.github/workflows/ci.yml` (after the
`specs` step), so it runs on the same matrix that already has Neovim installed:

```yaml
      - name: gauntlet (parser survives the fixture corpus)
        run: nvim --headless --clean --cmd "set rtp+=." -l scripts/gauntlet.lua tests/fixtures/transcripts
```

(Mirror the invocation style of the existing `smoke`/`specs` steps in that job.)

**Verify**: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
runs clean. The other steps are unchanged in the diff.

### Step 4: Full local run + format

**Verify**:
- `nvim -l scripts/gauntlet.lua tests/fixtures/transcripts` → exit 0, `crashes: 0`.
- `nvim -l tests/run.lua` → `0 failed` (unchanged).
- `nvim -l scripts/smoke.lua` → exit 0.
- `git status` shows only the fixtures + ci.yml (+ optional CONTRIBUTING.md line).

## Test plan

- The corpus IS the test: the CI gauntlet step proves the parser survives every
  committed shape with 0 crashes / 0 undecodable.
- Do NOT add undecodable/crash fixtures to the corpus (they'd fail the gauntlet).
  If you want to also cover graceful degradation of malformed input, add a
  focused case to `tests/transcript_spec.lua` instead (optional, out of the
  gauntlet's scope) — a single truncated/garbage line fed to `parser:feed`
  should return an `unknown`/`undecodable` event and NOT raise.
- Verification: the gauntlet command exits 0.

## Done criteria

ALL must hold:

- [ ] `tests/fixtures/transcripts/` exists with ≥4 fixture files incl. a nested
      subagent and an excluded `journal.jsonl`.
- [ ] `nvim -l scripts/gauntlet.lua tests/fixtures/transcripts` exits 0 with
      `crashes: 0` and `undecodable: 0`.
- [ ] `.github/workflows/ci.yml` runs the gauntlet over the fixtures and is valid
      YAML.
- [ ] `nvim -l tests/run.lua` still `0 failed`; `nvim -l scripts/smoke.lua` exit 0.
- [ ] No real/un-scrubbed transcript content committed (fixtures are synthetic).
- [ ] No source files edited (`git status` shows only fixtures + ci.yml + optional doc).
- [ ] `plans/README.md` status row for 011 updated.

## STOP conditions

Stop and report (do not improvise) if:

- A synthetic fixture line **crashes** the parser — that's a real parser bug.
  Report it (with the line); do NOT edit the fixture to dodge it, and do NOT edit
  `transcript.lua` in this plan.
- You cannot construct a decodable fixture for a given shape without reading
  private real transcripts — synthesize from the parser's branch logic instead;
  if a shape is genuinely unclear, omit it and note the gap.
- The gauntlet's exit logic makes it impossible to include a shape you believe
  matters — report rather than changing the script.

## Maintenance notes

- When a new Claude Code release introduces a record/block type, add a fixture
  line for it here so the gauntlet covers it in CI.
- Reviewer should skim the fixtures to confirm they're synthetic and
  content-free (no real paths/secrets), and that `journal.jsonl` is genuinely a
  non-transcript shape (so its exclusion is actually exercised).
- The private full-corpus gauntlet (`~/.claude/projects`) remains the deeper
  bar; this committed corpus is the reproducible floor.
