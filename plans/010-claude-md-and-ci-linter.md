# Plan 010: Give executors a real CLAUDE.md and add a Lua linter to CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 482e989..HEAD -- CLAUDE.md .github/workflows/ci.yml`
> If either changed since this plan was written, re-read it before editing; on a
> mismatch with the excerpts below, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (the linter job may surface a backlog of existing hits — see Step 4)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `482e989`, 2026-07-08

## Why this matters

Two DX gaps:

1. **CLAUDE.md is too thin for an agent to execute against.** It's a
   one-paragraph intro plus a Hub section — no build/test/lint commands, none of
   the conventions. Those live only in `CONTRIBUTING.md`/`ARCHITECTURE.md`.
   Critically, `PLAN.md` states a working agreement — "Clean commit messages, no
   AI trailers" — that appears nowhere an executing agent reads first, so the
   default tooling will append AI co-author trailers and violate a stated repo
   rule. An agent driving this repo from CLAUDE.md gets no verify loop.
2. **CI has no Lua linter** — only `stylua --check` (formatting) and a typecheck
   at `Error` level. Whole classes of defects go uncaught (unused/shadowed
   locals, accidental globals, unreachable branches, arity slips) for a plugin
   whose bar is "never crash the parser." `stylua` reformats; it proves nothing
   about logic.

Both fixes are additive and cheap, and they compound: a better CLAUDE.md plus a
linter makes every future agent-driven change safer.

## Current state

`CLAUDE.md` (the project file at the repo root) currently contains only:
- A one-paragraph description of what giroux.nvim is + the shared-roadmap pointer.
- A "## Hub" section (ops-hub registration, `hub post` reminders, push reminder).

It does NOT contain: the test/smoke/gauntlet/stylua/typecheck commands, the "no
AI trailers" rule, or the core conventions (pure-logic-is-unit-tested; every
transcript field optional / never crash on unknown records; state is proven).
Those exist in:
- `CONTRIBUTING.md` "Development" (the commands) and "Conventions".
- `ARCHITECTURE.md` "Conventions worth keeping" / "Test & verify".
- `PLAN.md` "Working agreements" — "Clean commit messages, no AI trailers."

`.github/workflows/ci.yml` currently has three jobs — `stylua` (`--check`),
`typecheck` (nvim-typecheck-action, `level: Error`), and `test` (smoke + specs on
ubuntu stable/nightly + macos stable). There is no `.luacheckrc` or `selene.toml`
in the repo (only `.stylua.toml`). The verified test commands are:

```
nvim -l tests/run.lua          # unit + integration specs
nvim -l scripts/smoke.lua      # modules load, config merges
nvim -l scripts/gauntlet.lua <dir>  # stream real transcripts, 0 crashes
stylua --check lua/ tests/     # formatting
```

Conventions: keep CLAUDE.md terse (it's loaded into every agent's context).
Commit terse/lowercase/module-prefixed, no AI trailers. Example:
`dx: flesh out CLAUDE.md commands/conventions; add selene to CI`.

## Commands you will need

| Purpose         | Command                              | Expected on success    |
|-----------------|--------------------------------------|------------------------|
| Tests           | `nvim -l tests/run.lua`              | `... passed, 0 failed` |
| Smoke           | `nvim -l scripts/smoke.lua`          | exit 0                 |
| Format check    | `stylua --check lua/ tests/`         | exit 0                 |
| Lint (local, if installed) | `selene lua/ tests/`      | 0 warnings/errors (after tuning) |
| YAML sanity     | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` | no exception |

(`selene` may not be installed locally; the CI job is the real gate. Install via
`cargo install selene` only if you want a local run.)

## Scope

**In scope**:
- `CLAUDE.md` (expand with Commands + Conventions blocks; keep the existing intro
  + Hub section)
- `.github/workflows/ci.yml` (add a `lint` job)
- `selene.toml` + `vim.yml` (create — selene config with the Neovim `vim` global)

**Out of scope** (do NOT touch):
- `lua/` source — do NOT fix lint hits the new job surfaces in this plan (see
  STOP conditions). If the linter finds real issues, report them as a follow-up;
  keep this plan's diff to config + docs.
- `CONTRIBUTING.md` / `ARCHITECTURE.md` — they already carry this content; don't
  duplicate-edit them (CLAUDE.md points readers at them for depth).
- The existing `stylua`/`typecheck`/`test` CI jobs — leave them as-is.

## Git workflow

- Branch: `advisor/010-claude-md-and-ci-linter`
- One commit; message like `dx: expand CLAUDE.md; add a selene lint job to CI`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Expand CLAUDE.md

Add two sections after the intro (keep the existing intro and the "## Hub"
section verbatim). Keep it terse — this is loaded into context every session:

```markdown
## Commands

- Tests: `nvim -l tests/run.lua` (filter: `nvim -l tests/run.lua <name>`)
- Smoke (modules load, config merges): `nvim -l scripts/smoke.lua`
- Gauntlet (stream real transcripts, prove 0 crashes): `nvim -l scripts/gauntlet.lua <dir>`
- Format: `stylua --check lua/ tests/` (fix with `stylua lua/ tests/`)
- Lint: `selene lua/ tests/`
- Typecheck: runs in CI (nvim-typecheck-action on `lua/`, Error level)

## Conventions

- **Commit messages: no AI trailers** (PLAN.md working agreement). Terse,
  lowercase, module-prefixed — e.g. `monitor: freshness-gate the title spinner`.
- Pure logic is unit-tested without a buffer; buffer wiring is integration-tested
  headlessly. Add specs for new pure logic (CONTRIBUTING.md).
- Every top-level transcript field is optional — never crash on unknown records;
  emit an `unknown`/`other` event. The gauntlet is the bar.
- State is *proven*, not guessed (DESIGN.md §4).
- LuaCATS annotations on public functions.
- Deeper rationale: DESIGN.md (why), ARCHITECTURE.md (what/how), CONTRIBUTING.md.
```

**Verify**: `git grep -n "no AI trailers" CLAUDE.md` returns a match;
`git grep -n "tests/run.lua" CLAUDE.md` returns a match.

### Step 2: Create the selene config

`selene.toml` at the repo root:

```toml
std = "vim"
```

`vim.yml` (the std definition for the Neovim `vim` global). Provide a minimal
std that declares `vim` as a readable global with common fields, so selene
doesn't flag every `vim.*` use as an undefined global:

```yaml
---
base: lua51
globals:
  vim:
    any: true
```

`vim: { any: true }` treats `vim` and everything under it as valid — the
pragmatic setting for a Neovim plugin (a fully-typed std is overkill here and
LuaCATS already covers types). If selene requires the std file be named to match
`std = "vim"`, the file `vim.yml` in the repo root is discovered automatically.

**Verify**: if `selene` is installed locally, `selene lua/` runs (it may report
warnings — that's Step 4's concern). If not installed, proceed; the CI job is
the gate.

### Step 3: Add the CI lint job

Add a `lint` job to `.github/workflows/ci.yml`, parallel to `stylua`. Use the
established selene action or install via cargo. Example using the community
action pattern (mirror the structure of the existing `stylua` job):

```yaml
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: NTBBloodbath/selene-action@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          args: "lua/ tests/"
```

If you are not certain the `NTBBloodbath/selene-action` version tag resolves,
fall back to an explicit install step instead:

```yaml
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo install selene
      - run: selene lua/ tests/
```

Keep the `concurrency` block and triggers at the top of the file unchanged.

**Verify**: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
runs without error (valid YAML). The other jobs are unchanged in the diff.

### Step 4: Handle any lint backlog WITHOUT touching source

Run selene locally if you can (`selene lua/ tests/`). If it reports warnings,
DO NOT fix them by editing `lua/` in this plan (out of scope). Instead, tune
`selene.toml` to the level that keeps the job meaningful but green on the current
codebase — e.g. downgrade noisy lints the repo intentionally uses:

```toml
std = "vim"

[rules]
# Example: the parser deliberately has some unused function args in callbacks.
# Downgrade only what is genuinely noise, not real-bug lints. Document each.
unused_variable = "warn"
```

Prefer keeping real-bug lints (`shadowing`, `undefined_variable`, `unreachable`)
at `error`. If the backlog is large and mixed, set the whole job to report
warnings without failing the build for now (so the signal is visible but doesn't
block), and record the backlog count in your status row as a follow-up. The
goal: a lint job that runs and is green, surfacing new issues going forward.

**Verify**: `selene lua/ tests/` (if installed) exits 0 with your tuned config;
otherwise note that the CI run is the gate and the config is conservative.

### Step 5: Confirm nothing else broke

**Verify**:
- `nvim -l tests/run.lua` → `0 failed` (unchanged — no source touched).
- `nvim -l scripts/smoke.lua` → exit 0.
- `stylua --check lua/ tests/` → exit 0.
- `git status` shows only CLAUDE.md, ci.yml, selene.toml, vim.yml changed/added.

## Test plan

- No code tests (config + docs). The verification is: YAML parses, the existing
  suite/smoke stay green (proving no source changed), and CLAUDE.md contains the
  commands + the no-AI-trailers rule.
- If selene is available, a local `selene lua/ tests/` exits 0 under the tuned
  config.

## Done criteria

ALL must hold:

- [ ] `CLAUDE.md` contains the Commands block and the "no AI trailers" rule.
- [ ] `.github/workflows/ci.yml` has a `lint` job and is valid YAML.
- [ ] `selene.toml` + the `vim` std file exist.
- [ ] `nvim -l tests/run.lua` still `0 failed`; `nvim -l scripts/smoke.lua` exit 0.
- [ ] `git status` shows only the 4 in-scope files changed/added (no `lua/` edits).
- [ ] `plans/README.md` status row for 010 updated.

## STOP conditions

Stop and report (do not improvise) if:

- selene surfaces what look like **real bugs** (not style noise) — report them as
  new findings; do NOT fix source in this plan.
- The selene action tag you pick doesn't resolve and the cargo-install fallback
  is too slow/heavy for the operator's taste — report and let them choose.
- You cannot get a green lint job without disabling so many rules the job is
  meaningless — report the backlog size and recommend a separate cleanup plan.

## Maintenance notes

- The lint job is intentionally conservative at first; tighten rules over time as
  the backlog is cleaned.
- Reviewer should confirm CLAUDE.md stays terse — it's in every session's context.
- Follow-up (not here): raising the typecheck action from `Error` to include
  warnings, and fixing whatever real lint hits selene surfaces.
