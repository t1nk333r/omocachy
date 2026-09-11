# Plan 025: Make `omacachy-doctor.sh --bundle` fail on an unreadable manifest

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/omacachy-doctor.sh bin/lib/profile.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11
- **Executed**: 2026-09-11 (landed at `4e94d26`); the Step 1 gate checks the real export layout — `packages` is an object of `explicit_native`/`explicit_foreign` arrays, plus `services.user_enabled`, not the flat array sketched here.

## Why this matters

`bin/omacachy-doctor.sh --bundle` is the post-migration gate the README sells;
the importer's `verify` stage takes its exit code as the migration's verdict.
But `profile_manifest` pipes `jq` through `2>/dev/null`, so a truncated,
half-copied or `{}` manifest yields empty streams and every versus-bundle loop
falls through to a PASS — including "every plugin in the bundle is present"
and "all local-only plugins restored", the load-bearing check the file's own
header names. A bundle whose metadata was never read reports green.

## Current state

- `bin/lib/profile.sh:241-245`:
  ```bash
  profile_manifest() {
      jq -r "$2 // empty" "$1/manifest.json" 2>/dev/null
  }
  ```
- `bin/omacachy-doctor.sh:241-250` and onward:
  ```bash
  if [[ -n $BUNDLE ]]; then
      echo ""
      echo "--- versus bundle ---"
      echo "bundle: $BUNDLE ($(profile_manifest "$BUNDLE" .source.host), $(profile_manifest "$BUNDLE" .created))"

      missing_plugins=()
      while IFS= read -r id; do
          [[ -z $id ]] && continue
          [[ -d "$PLUGIN_DIR/$id" ]] || missing_plugins+=("$id")
      done < <(profile_manifest "$BUNDLE" '.plugins[].id')
      if ((${#missing_plugins[@]})); then
          fail "..."
      else
          pass "every plugin in the bundle is present on this machine"
      fi
  ```
- The import does validate first (`bin/omacachy-profile-import.sh:120-121`):
  ```bash
  SCHEMA="$(profile_manifest "$BUNDLE" .schema)"
  [[ $SCHEMA == "$PROFILE_SCHEMA" ]] || die "bundle schema $SCHEMA, this script speaks $PROFILE_SCHEMA."
  ```
- The doctor's result gate is `((FAILED == 0)) || exit 1` (`:295`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Empty-manifest check | the command in Step 3 | exit 1, prints a FAIL line |

## Scope

**In scope**: `bin/omacachy-doctor.sh`, one regression case in `tests/run.sh`.
**Out of scope**: `profile_manifest` itself (other callers rely on its
tolerant behaviour after their own schema checks), the import's stages.

## Git workflow

- Branch: `advisor/025-doctor-bundle-gate`
- Commit message, e.g.: `Fail doctor --bundle on an unreadable manifest instead of passing vacuously`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the gate

At the top of the `if [[ -n $BUNDLE ]]` block (after the `bundle:` echo), add:

```bash
    if ! jq -e '.schema == 1 and (.payload.captured | type == "array") and (.plugins | type == "array") and (.packages | type == "array")' \
        "$BUNDLE/manifest.json" >/dev/null 2>&1; then
        fail "bundle manifest is missing, unreadable or not schema 1: $BUNDLE/manifest.json"
    else
        …existing versus-bundle checks…
    fi
```

Indent the existing checks into the `else` branch (mechanical re-indent; the
doctor's style is 4 spaces). Keep the section's human framing ("--- versus
bundle ---") unchanged.

**Verify**: `bash -n bin/omacachy-doctor.sh` → exit 0.

### Step 2: Same gate for the load-bearing plugin check

Inside the validated branch, nothing further is needed — the loops now only run
when the arrays exist. Confirm no other versus-bundle code reads the manifest
outside the `else` (grep for `profile_manifest` in the file).

**Verify**: `grep -n 'profile_manifest' bin/omacachy-doctor.sh` → every hit is
inside the validated branch.

### Step 3: Empty-manifest check

```bash
d=$(mktemp -d); printf '{}\n' >"$d/manifest.json"
bin/omacachy-doctor.sh --bundle "$d"; echo "exit=$?"
```

Expected: one `FAIL` line naming the manifest, `exit=1`, and no "every plugin
…" PASS line.

**Verify**: as above; then a second run against a real bundle directory
produced by `bin/omacachy-profile-export.sh --out <dir> --dry-run`… note the
dry run writes nothing, so instead copy any existing bundle under
`~/.local/state/omacachy/` if present, or construct a minimal valid one:

```bash
printf '{"schema":1,"source":{"host":"h","user":"u","home":"/home/u"},"payload":{"captured":[]},"plugins":[],"packages":[]}\n' >"$d/manifest.json"
bin/omacachy-doctor.sh --bundle "$d"; echo "exit=$?"
```

Expected: no manifest FAIL; the versus-bundle section runs (empty lists →
passes), and the exit code reflects the *machine's* other checks only.

### Step 4: Regression case in `tests/run.sh`

Add a case that runs the empty-manifest invocation above and asserts exit 1 and
the FAIL text (model on the harness's `ok`/`bad` pattern).

**Verify**: `tests/run.sh` → `0 failed`, including the new case.

## Test plan

- Step 4's case fails against the current doctor (exit 0, four PASS lines) and
  passes after Step 1 — that is the regression.
- The valid-minimal-bundle run in Step 3 proves the gate does not reject
  legitimate empty bundles.

## Done criteria

- [ ] Empty/truncated manifest → FAIL + exit 1, no vacuous PASS lines
- [ ] Valid minimal bundle → versus-bundle checks still run
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The doctor's manifest layout differs from the keys used in the gate
  (`jq '.schema'`, `.payload.captured`, `.plugins`, `.packages`) — re-derive
  from `bin/omacachy-profile-export.sh`'s `write_manifest` and report the
  mismatch instead of guessing.
- The code no longer matches the excerpts (drift).

## Maintenance notes

- If the import ever starts consuming a bundle field the doctor does not
  validate, add it to the gate in the same commit.
- Reviewer: confirm the FAIL line goes through the doctor's `fail` helper
  (counter + stderr), so the exit gate at `:295` picks it up.
