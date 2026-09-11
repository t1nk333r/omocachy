# Plan 030: Reconcile the docs and add an Omarchy version baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- README.md handoff.md plans/README.md tests/run.sh bin/install-omarchy-quattro.sh tests/fixtures/omarchy-host-control/expected.decisions`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: none (plan 019 fixes one doc mention; skip what it already fixed)
- **Category**: docs
- **Planned at**: commit `e80b564`, 2026-09-11
- **Executed**: 2026-09-11 (landed at `3d41803`); the validation-status contradiction resolved toward the README — plan 017's §"Still unverified" shows both items RESOLVED and `git blame` puts the stale header line before them, so handoff's gate line (and plan 017's header) were corrected instead.

## Why this matters

The repo's release-gate mechanism *is* its documentation, and the docs now
contradict each other and the machine: the wrapper was reconciled against
Omarchy 4.0.2 while the dev host and upstream run 4.0.3, with no version probe
anywhere; README says the plan-017 fixes "were re-run on a guest" while
`handoff.md` and plan 017 say the opposite; `tests/run.sh:13` still claims
nothing has ever run on real CachyOS; the README lists four fixture sysroots
where five exist; `--restore-host-specific` carries three different statuses;
and `plans/README.md` still describes a "~300 lines of Bash (no tests)" v3
repo. A zero-context executor reading these gets a false model of the project.

## Current state

- `README.md:142-144` — "Each of these was verified against an installed
  Omarchy 4.0.2 (evidence in `plans/015-…`)".
- `README.md:393` — "Every fix those runs produced was re-run on a guest
  afterwards, including … the PATH-pinned hook produced no `limine.conf` and no
  UKI across a kernel reinstall …".
- `handoff.md` §Release gates — "The plan-017 fixes have not been re-run on a
  guest — they landed after the last real run (2026-09-07)."
- `plans/017-real-cachyos-run-corrections.md` — "Status: DONE (123 test
  assertions green; fixes themselves not yet re-run on the guest — see plan
  'Still unverified')."
- `tests/run.sh:13` — "Nothing in this repo has ever been run on real CachyOS."
- `README.md` fixture list names four sysroots; `tests/fixtures/` has five
  (`cachyos-grub-plain`, `cachyos-limine-luks`, `cachyos-sdboot-luks`,
  `irreconcilable-hooks`, `omarchy-host-control`).
- `--restore-host-specific`: documented as working at `README.md:560-561`,
  implemented at `bin/omocachy-profile-import.sh:69`+`:207`, "code-reviewed but
  not executed" at `plans/018-omarchy-profile-migration.md:281`, backlog at
  `handoff.md:147-148`.
- `plans/README.md:9` — "Repo context for executors: ~300 lines of Bash (no
  tests, no package manager)"; `:55-59`/`:119-122` build dependency notes on
  `fetch-omarchy.sh`, `patch_or_die`, `TESTED_OMARCHY_REF` (v3-era, none on
  main); `handoff.md:27-29` says v3 lives on the local `v3` branch.
- `bin/install-omarchy-quattro.sh:11-12` cites "the 4.0.2 evidence", `:35-40`
  defines `OMARCHY_REFERENCE_HOOKS` as "The HOOKS array omarchy-settings 4.0.2
  ships", `:1151` prints a merge preview derived from it; `check_*`/plan
  summary contain no version comparison. `pkg_version omarchy-settings` exists
  (`:266-278`) and is used at `:312`.
- Dev host, 2026-09-11: `omarchy 4.0.3-1`, `omarchy-settings 4.0.3-1`.
- `tests/fixtures/omarchy-host-control/expected.decisions` first line claims
  the owner's host is "Omarchy 4.0.2".

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Version warning | `bin/install-omarchy-quattro.sh --dry-run --yes \| sed -n '/[Rr]econciled/p'` | a line naming 4.0.2 and the installed version |

## Scope

**In scope**: `README.md`, `handoff.md`, `plans/README.md`, `tests/run.sh`
(comment only), `tests/fixtures/omarchy-host-control/expected.decisions`
(comment only), and one small addition to `bin/install-omarchy-quattro.sh`
(a constant + warning + one preview line).

**Out of scope**: re-auditing Omarchy 4.0.3's actual drop-ins (that is a
separate, larger audit — note it as the follow-up); the plan-017 capability
claims themselves (only their mutually inconsistent *status* is edited).

## Git workflow

- Branch: `advisor/030-docs-and-version-truth`
- Commit message, e.g.: `Reconcile validation status across docs; warn on Omarchy version drift`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Baseline constant + drift warning

Near `OMARCHY_REFERENCE_HOOKS` (`:35-40`) add:

```bash
# The Omarchy release this reconciliation was last verified against
# (plans/015/016). A newer installed version is not an error — the HOOKS
# transform is deliberately version-tolerant — but the other facts
# (drop-ins, scriptlets, ISO closure) may have moved with it.
OMARCHY_RECONCILED_VERSION="4.0.2"
```

After `REAPPLY` is computed and before the plan summary, add:

```bash
if installed_omarchy_version="$(pkg_version omarchy-settings)" && [[ -n $installed_omarchy_version && $installed_omarchy_version != "$OMARCHY_RECONCILED_VERSION" ]]; then
    echo "Warning: this wrapper was reconciled against Omarchy $OMARCHY_RECONCILED_VERSION; this machine has $installed_omarchy_version. Re-read plans/016-*.md's verification steps before trusting the reconciliation." >&2
fi
```

(No `decide` record — the fixture expectations must not change. Under a
sysroot `pkg_version` reads the fixture database; the fixtures carry 4.0.2, so
the warning stays silent there.)

Also change the merge-preview line (`:1151`) to name the version, e.g.
`Predicted merged HOOKS against omarchy-settings $OMARCHY_RECONCILED_VERSION's array: (…)`.

**Verify**: `bash -n` exit 0; `tests/run.sh` `0 failed`; on the dev host the
dry run prints the warning (Step 5).

### Step 2: Resolve the validation-status contradiction

Read `plans/017-real-cachyos-run-corrections.md` §Still unverified and the
README paragraph at `:375-395`. Make the README state exactly what plan 017
states: which fixes were re-run on a guest, which were not, and the date.
Do not soften either side; if the plan's evidence is ambiguous, keep the more
conservative claim (handoff's) and say so in the commit body.

**Verify**: `grep -n 're-run' README.md handoff.md plans/017-*.md` → all three
agree (same claim, same scope).

### Step 3: The remaining stale text

1. `tests/run.sh:13` — replace "Nothing in this repo has ever been run on real
   CachyOS." with a pointing note: "Real-CachyOS evidence lives in `plans/016`,
   `plans/017` and `handoff.md`; this matrix proves decision logic only."
2. README fixture list — make it five, naming `irreconcilable-hooks` (the HOOKS
   refusal case).
3. `--restore-host-specific` — one status everywhere: implemented and
   documented; **not yet exercised on a real migration** (cite
   `plans/018-*.md`). Apply to README, handoff backlog line, and plan 018's
   status note (keep the plan's "code-reviewed but not executed" wording as the
   canonical one).
4. `plans/README.md` — add a short header note above the table: plans 001–014
   describe the v3 line now isolated on branch `v3`; `main` is the Omarchy 4
   package wrapper; the v3 dependency notes below are historical. Fix the
   "~300 lines of Bash (no tests…)" context line to today's numbers (nine
   scripts + `bin/lib/`, `tests/run.sh` with a fixture matrix).
5. `tests/fixtures/omarchy-host-control/expected.decisions` — change the
   "Omarchy 4.0.2" comment to "4.0.x".

**Verify**: `grep -rn '4\.0\.2' README.md plans/README.md tests/fixtures/omarchy-host-control/expected.decisions` → every remaining mention is qualified as the *reconciled baseline*, not as the current version.

### Step 4: Note the 4.0.3 follow-up

In `handoff.md` §Where validation stands (or the nearest gates section), add
one line: the installed Omarchy has moved to 4.0.3; the reconciliation's
facts (drop-ins, scriptlets, ISO closure) should be re-audited against it —
tracked as the next validation item, not a defect.

**Verify**: `grep -n '4\.0\.3' handoff.md` → the new line.

### Step 5: Full verification

**Verify**: `tests/run.sh` → `0 failed`; lint gate → exit 0;
`bin/install-omarchy-quattro.sh --dry-run --yes | sed -n '/[Rr]econciled/p'` on
the dev host prints the drift warning; the same command with
`OMOCACHY_SYSROOT=tests/fixtures/cachyos-limine-luks` prints none (fixture is
4.0.2).

## Test plan

- The suite must stay green: the warning adds output, and the harness's
  `expected.stderr` needles are contains-only, so extra lines are safe; no
  decision keys change.
- No new automated test: this is a documentation/consistency change with one
  mechanical guard; the greps above are the checks.

## Done criteria

- [ ] The drift warning fires on the dev host and not under a 4.0.2 fixture
- [ ] README, handoff and plan 017 state the same validation status
- [ ] README lists five fixtures; `tests/run.sh:13` no longer claims "never run
      on real CachyOS"
- [ ] `--restore-host-specific` has one status across the three files
- [ ] `plans/README.md` has the v3/isolation banner and a corrected context line
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] `plans/README.md` status row for this plan updated

## STOP conditions

- Plan 017's evidence trail contradicts both the README and handoff — STOP and
  report the three texts verbatim rather than choosing one.
- The version warning would require a new `decide` key (it must not).

## Maintenance notes

- When the 4.0.3 re-audit lands, bump `OMARCHY_RECONCILED_VERSION`, update
  `OMARCHY_REFERENCE_HOOKS` if the shipped array moved, and refresh the fixture
  package stubs — the warning is the reminder mechanism, not a substitute.
- Reviewer: the constant must stay next to `OMARCHY_REFERENCE_HOOKS` so the two
  version facts are read together.
