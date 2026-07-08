# Plan 008: Sync stale docs with the shipped v0.1 reality

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- ARCHITECTURE.md CONTRIBUTING.md doc/giroux.txt README.md`
> If any changed since this plan was written, re-verify the specific claims
> below against the live code before editing; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

Several docs describe a build that no longer matches the code — and one of the
errors is *dangerous*. `ARCHITECTURE.md` says the merged-tail reap uses
`trap 'kill $(jobs -p)'` and "never `kill 0`", but the code deliberately does
the **opposite** (`ssh.lua` uses `kill 0` precisely because `jobs -p` is empty in
non-interactive dash and leaks orphaned tails on Linux). A contributor who
"fixes" `ssh.lua` to match the doc would reintroduce the exact leak the code
exists to prevent. Beyond that: `CONTRIBUTING.md` and `doc/giroux.txt` still say
the plugin is "macOS-only" (Linux shipped in v0.1, turning away supported
users), `ARCHITECTURE.md` calls `health.lua` and `:GirouxClean` "stubs" (both
are implemented), spec counts are stale everywhere (74/39 vs the real 95), and
`doc/giroux.txt` documents `refresh_interval = 30` when the default is now `1`
(a 30× cadence difference for anyone copying it). Wrong docs are worse than
missing ones; this plan makes the docs honest. It's mechanical and low-risk.

## Current state — the specific claims to fix

Verify each against the live code as you go (commands given). Do NOT bulk
find/replace; fix each claim deliberately.

### A. The dangerous `kill 0` contradiction (highest priority)

`ARCHITECTURE.md` Transport section (~lines 88-94) states the reap uses
`trap 'kill $(jobs -p)'` and "never `kill 0`". The code says the opposite —
`lua/giroux/ssh.lua:128-129`:

```lua
function M.multi_tail_cmd(files)
  local parts = { "trap 'kill 0 2>/dev/null' EXIT HUP TERM INT;" }
```

with a comment block above it (ssh.lua:115-125) explaining `kill 0` is the ONLY
portable reap because non-interactive dash has job control off so `jobs -p` is
empty. The existing test agrees (`tests/transport_spec.lua:14-18`).

**Fix**: Rewrite that ARCHITECTURE.md paragraph to describe `kill 0` + the
own-process-group rationale (remote: sshd isolates; local: `setsid`), matching
the `ssh.lua` comment and the test. Verify the code first:
`git grep -n "kill 0" lua/giroux/ssh.lua`.

### B. "macOS-only" is wrong (Linux shipped)

- `doc/giroux.txt:43` — "macOS nodes today (uses BSD `stat`); Linux support is planned"
- `CONTRIBUTING.md:8-11` — "It is **macOS-only today** … Linux support is tracked in PLAN.md"

Contradicted by `README.md:75-88` ("macOS *and* Linux"), `PLAN.md:37-42`, and
`git log` (`6d7e61c feat: support Linux nodes`). Portable stat lives in the code
(`git grep -n "stat -c\|stat -f" lua/giroux`).

**Fix**: Update both to "macOS and Linux nodes" with the portable-stat note,
matching README's wording.

### C. `health.lua` / `:GirouxClean` "stub" claims

`ARCHITECTURE.md:55` — "`health.lua` | `:checkhealth giroux` (stub)"; but
`health.lua` is a 182-line auth/node prober (`git grep -n "AUTH_PROBE\|auth_status" lua/giroux/health.lua`).
`ARCHITECTURE.md:116` — "`:GirouxClean` is still a stub"; but `dispatch.clean` is
implemented (`git grep -n "function M.clean" lua/giroux/dispatch.lua`).

**Fix**: Rewrite the `health.lua` row to describe the real prober; remove the
`:GirouxClean`-is-a-stub line from Known Issues (note the *actual* remaining gap:
worktree pruning is still a follow-up — see `dispatch.lua` comment "Worktree
pruning is a follow-up").

### D. `pick.lua` missing from the module map

`ARCHITECTURE.md` module table (~lines 38-55) lists every module but not the new
`lua/giroux/pick.lua`.

**Fix**: Add a `pick.lua` row: a built-in type-to-filter picker (pure
`M.rank`; float is a thin shell), used by dispatch's repo list — no dependency
on the user's `vim.ui.select` backend.

### E. Stale counts

- `ARCHITECTURE.md:80` — "(39 currently)" specs.
- `ARCHITECTURE.md:64` — "264 files / 121MB" (gauntlet corpus; leave the corpus
  numbers unless you re-run the gauntlet — they describe a historical run, not a
  claim about the repo. Only fix if clearly labeled as current.)
- `README.md:79` — "74 specs" and "270+ real transcripts".
- `doc/giroux.txt` — any "specs" count.

Get the real spec count: `nvim -l tests/run.lua` prints `<N> passed, 0 failed`.
Use that N (95 at the time of writing; re-run to confirm before editing).

**Fix**: Update spec counts to the current `N passed`. For the README's "74
specs; … 270+ real transcripts", update the spec count; leave the transcript
corpus figure unless you have a fresh gauntlet number.

### F. `refresh_interval` default drift

`doc/giroux.txt:221` documents `refresh_interval = 30`; the default is now `1`
(`lua/giroux/init.lua:48`), and there's a new undocumented `live_interval = 3`
(`init.lua:49`).

**Fix**: In `doc/giroux.txt`'s Configuration section, set `refresh_interval` to
`1` and add `live_interval` with a one-line description (copy the `@field`
descriptions from `init.lua:28-29`).

Conventions: match each doc's existing tone and formatting (`doc/giroux.txt` is
Vim help format — keep the `*tags*`, column alignment, and `==` rules;
`ARCHITECTURE.md` is prose + a table). No AI trailers in the commit.

## Commands you will need

| Purpose            | Command                                   | Expected            |
|--------------------|-------------------------------------------|---------------------|
| Real spec count    | `nvim -l tests/run.lua`                   | `<N> passed, 0 failed` |
| Confirm kill 0     | `git grep -n "kill 0" lua/giroux/ssh.lua` | shows the trap line |
| Confirm Linux stat | `git grep -n "stat -c\|stat -f" lua/giroux` | shows portable stat |
| Confirm health     | `git grep -n "AUTH_PROBE" lua/giroux/health.lua` | shows the prober |
| Confirm clean      | `git grep -n "function M.clean" lua/giroux/dispatch.lua` | shows it |
| Smoke (unaffected) | `nvim -l scripts/smoke.lua`               | exit 0              |

## Scope

**In scope** (docs only):
- `ARCHITECTURE.md`
- `CONTRIBUTING.md`
- `doc/giroux.txt`
- `README.md`

**Out of scope** (do NOT touch):
- Any file under `lua/`, `tests/`, `plugin/`, `scripts/` — this is a docs-only
  plan. If a doc claim and the code disagree, the CODE is the source of truth;
  fix the doc, never the code.
- `DESIGN.md` / `PLAN.md` — these are historical design/plan records with dated
  headers ("Working notes, 2026-06-11"); leave them as the dated record they are.
- The gauntlet corpus numbers (264 files / 121MB) unless you actually re-ran it.

## Git workflow

- Branch: `advisor/008-doc-sync`
- One commit; message like `docs: sync ARCHITECTURE/help/CONTRIBUTING to shipped v0.1 (kill 0, Linux, health, counts)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the `kill 0` contradiction in ARCHITECTURE.md (A)

Confirm `git grep -n "kill 0" lua/giroux/ssh.lua`, read `ssh.lua:115-139` for the
rationale, then rewrite the ARCHITECTURE.md Transport paragraph to match. The
corrected text must say the reap uses `kill 0` (the whole process group), that
`jobs -p` is empty in non-interactive dash (the Linux orphan-tail leak), and
that it's safe because the shell runs in its own group (sshd remotely, `setsid`
locally).

**Verify**: `git grep -n "kill \$(jobs -p)\|never .kill 0" ARCHITECTURE.md`
returns nothing (the wrong claim is gone).

### Step 2: Fix "macOS-only" in doc/giroux.txt and CONTRIBUTING.md (B)

**Verify**: `git grep -ni "macos-only\|macOS nodes today" doc/giroux.txt CONTRIBUTING.md`
returns nothing.

### Step 3: Un-stub health/clean and add pick.lua in ARCHITECTURE.md (C, D)

**Verify**: `git grep -n "stub" ARCHITECTURE.md` returns nothing referring to
`health.lua` or `:GirouxClean`; `git grep -n "pick.lua" ARCHITECTURE.md` now
returns a row.

### Step 4: Update spec counts and refresh_interval (E, F)

Run `nvim -l tests/run.lua`, note N, update the counts in ARCHITECTURE.md /
README.md / doc/giroux.txt. Update `refresh_interval` to 1 and add
`live_interval` in doc/giroux.txt.

**Verify**: `git grep -n "39 currently\|74 specs" ARCHITECTURE.md README.md`
returns nothing; `git grep -n "refresh_interval = 30" doc/giroux.txt` returns
nothing.

### Step 5: Sanity check

**Verify**: `nvim -l scripts/smoke.lua` → exit 0 (docs don't affect it, but
confirms you didn't accidentally edit code). `git status` shows only the four
docs modified.

## Test plan

No code tests (docs only). Verification is the `git grep` checks above proving
each stale claim is gone and the corrected fact is present. The suite/smoke must
remain green (unchanged), confirming no code was touched.

## Done criteria

ALL must hold:

- [ ] `git grep -n "jobs -p" ARCHITECTURE.md` returns nothing (or only in a
      correctly-framed "why NOT jobs -p" explanation matching the code).
- [ ] `git grep -ni "macos-only" doc/giroux.txt CONTRIBUTING.md` returns nothing.
- [ ] `git grep -n "stub" ARCHITECTURE.md` returns nothing about health/clean.
- [ ] `git grep -n "pick.lua" ARCHITECTURE.md` returns a module-map row.
- [ ] Spec counts in README.md / ARCHITECTURE.md match `nvim -l tests/run.lua`.
- [ ] `git grep -n "refresh_interval = 30" doc/giroux.txt` returns nothing;
      `live_interval` is documented.
- [ ] `nvim -l scripts/smoke.lua` exits 0; only the 4 docs changed (`git status`).
- [ ] `plans/README.md` status row for 008 updated.

## STOP conditions

Stop and report (do not improvise) if:

- The code no longer matches what this plan asserts (e.g. `ssh.lua` doesn't use
  `kill 0`) — then the doc claim might be right and this plan is stale; report.
- A doc claim you're about to "fix" turns out to still be accurate — leave it and
  note it in the status row.
- You're tempted to change code to match a doc — DON'T; the code is the truth.

## Maintenance notes

- ARCHITECTURE.md carries a dated "state of the build as of 2026-06-11" header —
  consider bumping that date to reflect this sync, and treat the Known Issues
  list as something to prune whenever an issue ships.
- Reviewer should spot-check the `kill 0` paragraph against `ssh.lua`'s comment —
  they must tell the same story.
- The remaining real gap after this sync: `:GirouxClean` doesn't yet prune
  worktrees (a direction item), so Known Issues should mention *that*, not claim
  the whole command is a stub.
