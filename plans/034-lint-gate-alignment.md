# Plan 034: Make the one-command gate's lint step honest

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- tests/run.sh handoff.md Jenkinsfile`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

`tests/run.sh` is the command the README names as the way to know the codebase
works, and the local lint gate is currently the *only* gate (`handoff.md`: the
Jenkins agent's handshake is broken). But its shellcheck step (a) silently
passes when shellcheck is missing — printing `skip shellcheck (not installed)`
and counting as success — and (b) runs `--severity=error` **without** `-x`,
while the documented local gate is `--severity=warning -x` and CI is
`--severity=error -x`. A green `tests/run.sh` can therefore mean "no static
analysis ran", and a lib-only regression that CI would flag passes locally.

## Current state

- `tests/run.sh:39-55`:
  ```bash
  run_lint() {
      head_ "lint"
      local f
      for f in "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh; do
          if bash -n "$f" 2>"$WORK/err"; then ok "bash -n $(basename "$f")"; else bad …; fi
      done
      if command -v shellcheck &>/dev/null; then
          if shellcheck --severity=error "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh >"$WORK/sc" 2>&1; then
              ok "shellcheck --severity=error"
          else
              bad "shellcheck --severity=error" "$(cat "$WORK/sc")"
          fi
      else
          echo "skip shellcheck (not installed)"
      fi
  }
  ```
- `handoff.md` lint-gate bullet documents:
  `bash -n bin/*.sh bin/lib/*.sh tests/run.sh` plus
  `shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh`.
- `Jenkinsfile:22-26` runs `shellcheck --severity=error -x bin/*.sh bin/lib/*.sh tests/run.sh`
  (the CI floor; unchanged by this plan).
- The current tree is clean at warning level: the maintainer ran
  `shellcheck --severity=warning -x …` on 2026-09-11 with no findings.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint section | `tests/run.sh lint` | `0 failed`, ok line names the warning-level invocation |
| Missing-shellcheck path | `SHELLCHECK_BIN=/bin/false tests/run.sh lint` | `1 failed` (or more), no "skip" |
| Everything | `tests/run.sh` | `N passed, 0 failed` |

## Scope

**In scope**: `tests/run.sh` (`run_lint` only), `handoff.md` (the lint bullet,
if it needs a word about the enforcement).
**Out of scope**: `Jenkinsfile` (CI keeps `--severity=error -x`), any source
script.

## Git workflow

- Branch: `advisor/034-lint-gate-alignment`
- Commit message, e.g.: `Fail the lint section when shellcheck is missing; align it with the documented gate`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Align the invocation and make the binary overridable

```bash
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
if command -v "$SHELLCHECK_BIN" &>/dev/null; then
    if "$SHELLCHECK_BIN" --severity=warning -x "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh >"$WORK/sc" 2>&1; then
        ok "shellcheck --severity=warning -x"
    else
        bad "shellcheck --severity=warning -x" "$(cat "$WORK/sc")"
    fi
elif [[ -n ${OMACACHY_SKIP_SHELLCHECK:-} ]]; then
    echo "skip shellcheck (OMACACHY_SKIP_SHELLCHECK set)"
else
    bad "lint: shellcheck not installed — install it, set SHELLCHECK_BIN, or set OMACACHY_SKIP_SHELLCHECK=1 to skip deliberately"
fi
```

`SHELLCHECK_BIN` makes the failure path testable without touching `PATH`;
`OMACACHY_SKIP_SHELLCHECK` is the explicit, visible escape hatch for
contributors on machines without shellcheck.

**Verify**: `bash -n tests/run.sh` → exit 0.

### Step 2: Prove both paths

**Verify**:
- `tests/run.sh lint` → ends `0 failed`; the ok line reads
  `shellcheck --severity=warning -x`;
- `SHELLCHECK_BIN=/bin/false tests/run.sh lint` → ends with `1 failed`;
- `OMACACHY_SKIP_SHELLCHECK=1 SHELLCHECK_BIN=/bin/false tests/run.sh lint` →
  prints the skip line and ends `0 failed`.

### Step 3: Make the handoff agree

In `handoff.md`'s lint-gate bullet, add one clause that `tests/run.sh` enforces
exactly this invocation (and that CI runs it at `--severity=error`). If the
bullet already says this, make no edit and say so in your report.

**Verify**: `grep -n 'shellcheck --severity=warning -x' handoff.md tests/run.sh`
→ one match in each.

### Step 4: Full suite

**Verify**: `tests/run.sh` → `N passed, 0 failed` (N unchanged from before this
plan apart from any cases other plans added).

## Test plan

- Steps 2's three runs are the acceptance; the `SHELLCHECK_BIN=/bin/false` run
  is the regression (today: `skip …`, `0 failed`).
- No Jenkinsfile change: the CI floor stays at error severity.

## Done criteria

- [ ] A missing/broken shellcheck yields a FAIL, not a silent skip, unless
      `OMACACHY_SKIP_SHELLCHECK` is set
- [ ] The local invocation matches the documented gate (`--severity=warning -x`)
- [ ] All three Step 2 runs behave as stated
- [ ] `tests/run.sh` `0 failed`; lint gate exit 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The tree is *not* clean at warning severity when you run it (new findings
  from another in-flight plan) — fix only findings your own changes introduced;
  otherwise STOP and report the findings rather than weakening the severity.

## Maintenance notes

- If shellcheck ever becomes a hard dependency in the Jenkins agent image only,
  keep the local escape hatch: contributors should be able to opt out
  *visibly*.
- Reviewer: the failure message must say exactly what to do (install, set
  `SHELLCHECK_BIN`, or skip deliberately) — this is the DX half of the fix.
