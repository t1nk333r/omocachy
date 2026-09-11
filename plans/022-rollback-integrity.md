# Plan 022: Make the generated rollback exist before the merge, and back up dangling symlinks

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/omacachy-profile-import.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

The import merges a bundle into a live `$HOME` and promises a generated undo.
Today the undo is written only *after* every path was merged. If a `tar` fails
mid-merge (`:195-197`), the script dies pointing at
`$BACKUP_DIR/rollback.sh` — a file that does not exist yet — and the only
record of what was touched (`$WORK/restored.tsv`) is deleted by the EXIT trap
(`:116`). The operator is left with a half-merged `$HOME`, an undifferentiated
backup tree and no list. Separately, `[[ -e "$HOME/$rel" ]]` (`:177`) is false
for a dangling symlink, so such a path is classified `new` and the rollback's
`rm -rf` deletes it without any backup ever having been taken.

## Current state

- `bin/omacachy-profile-import.sh`:
  - `:112-118` — `BUNDLE`, `WORK="$(mktemp -d ...)"`, `trap 'rm -rf "$WORK"' EXIT` at `:116`.
  - `:124-128` — `BACKUP_DIR="$STATE_DIR/backups/import-$TIMESTAMP"`, `REPORT_DIR=...`.
  - `:165-201` — the merge loop:
    ```bash
    [[ -e "$BUNDLE/home/$rel" ]] || continue
    if [[ -e "$HOME/$rel" ]]; then
        ...
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -a "$HOME/$rel" "$BACKUP_DIR/$rel"
        printf '%s\texisted\n' "$rel" >>"$WORK/restored.tsv"
    else
        printf '%s\tnew\n' "$rel" >>"$WORK/restored.tsv"
    fi
    ...
    ((rc == 0)) || die "restoring $rel failed (tar exit $rc); rollback: $BACKUP_DIR/rollback.sh"
    ```
  - `:218-224` (after the loop, after host-specific parking):
    ```bash
    cp -a "$WORK/restored.tsv" "$REPORT_DIR/restored.tsv"
    write_rollback
    ```
  - `:244-283` — `write_rollback()` bakes each entry into the generated script
    (`restore %q` / `drop %q`, from `$WORK/restored.tsv`) and writes
    `$BACKUP_DIR/rollback.sh`.
- The generated script's contract (its header comment): "Restores the paths
  that existed before the import and removes the ones it introduced. Nothing
  else is in scope."

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| End-to-end check | commands in Step 4 | rollback lists the merged paths |

## Scope

**In scope**: `bin/omacachy-profile-import.sh` only.
**Out of scope**: path validation of manifest entries (plan 020), the doctor
(plan 025) — different changes to the same file; coordinate via the reviewer.

## Git workflow

- Branch: `advisor/022-rollback-integrity`
- Commit message, e.g.: `Write the rollback before merging; back up dangling symlinks`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Keep the touched-path record in the backup directory

Replace `"$WORK/restored.tsv"` with `"$BACKUP_DIR/restored.tsv"` throughout
(creation at the top of `stage_configs`, both appends, the `cp` to
`$REPORT_DIR` may stay as a copy). Create `$BACKUP_DIR` before the first write
(it is created at `:150-151` when not in dry-run; the dry-run branch prints
instead — keep the dry-run behaviour unchanged).

**Verify**: `grep -n 'restored.tsv' bin/omacachy-profile-import.sh` → every
occurrence under `$BACKUP_DIR` or `$REPORT_DIR`, none under `$WORK`.

### Step 2: Generate the rollback up front and have it read its sibling list

Restructure `write_rollback` so the generated script reads
`"$BACKUP/restored.tsv"` at execution time instead of baking entries in:

Append the loop with a quoted heredoc inside the existing
`{ … } >"$BACKUP_DIR/rollback.sh"` block — nothing needs escaping:

```bash
cat <<'ROLLBACK'
while IFS=$'\t' read -r rel state; do
    [[ -n $rel ]] || continue
    if [[ $state == existed ]]; then restore "$rel"; else drop "$rel"; fi
done <"$BACKUP/restored.tsv"
ROLLBACK
```

Call `write_rollback` immediately after `mkdir -p "$BACKUP_DIR" "$REPORT_DIR"`
(the non-dry-run branch at `:150-151`), so the file exists before the first
merge, and keep the call site at `:223` removed (one generation point).

**Verify**: `bash -n bin/omacachy-profile-import.sh` → exit 0;
`grep -n 'write_rollback' bin/omacachy-profile-import.sh` → definition + one
call site *before* the merge loop.

### Step 3: Classify symlinks as pre-existing

Change the predicate at `:177` to:

```bash
if [[ -e "$HOME/$rel" || -L "$HOME/$rel" ]]; then
```

`cp -a` preserves the link; the rollback then restores the link instead of
deleting it.

**Verify**: `grep -n '\-e "$HOME/$rel" || -L' bin/omacachy-profile-import.sh` →
one match.

### Step 4: End-to-end check with a synthetic bundle and a throwaway HOME

```bash
cd /home/t1nk33r/Projects/omacachy/omacachy
d=$(mktemp -d); h=$(mktemp -d)
mkdir -p "$d/bundle/home/.config/hypr"
echo "old" >"$h/.config-hypr-placeholder"            # a path the bundle will shadow
echo "new" >"$d/bundle/home/.config/hypr/hyprland.lua"
cat >"$d/bundle/manifest.json" <<'EOF'
{"schema":1,"source":{"host":"test","user":"me","home":"/home/me"},"payload":{"captured":[".config/hypr/hyprland.lua"]}}
EOF
HOME="$h" bin/omacachy-profile-import.sh --bundle "$d/bundle" --only configs --yes
ls "$h/.local/state/omacachy/backups/"*/rollback.sh
"$h/.local/state/omacachy/backups/"*/rollback.sh --dry-run
```

Expect: the import completes; the rollback script exists under the backup dir;
its `--dry-run` lists `would remove …/.config/hypr/hyprland.lua` (the path did
not exist in `$h`).

**Verify**: the three commands above produce the stated output; exit 0.

### Step 5: Suite

**Verify**: `tests/run.sh` → `0 failed`; lint gate → exit 0.

## Test plan

- The Step 4 transcript is the acceptance evidence; paste the key lines into
  the commit message body or your report.
- If plan 029 has landed, add a `tests/run.sh` case that runs the same synthetic
  bundle into `$WORK`-rooted HOME and asserts the rollback exists *and* contains
  the appended entry (this is the regression for the ordering fix).

## Done criteria

- [ ] `write_rollback` runs before the first merge; the file exists on a
      mid-merge abort (Step 4 exercises the happy path; the ordering is
      visible in the code)
- [ ] `restored.tsv` lives next to `rollback.sh`, not in `$WORK`
- [ ] A dangling symlink under `$HOME` is backed up, not classified `new`
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside `bin/omacachy-profile-import.sh` are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

- The dry-run path (`:171-193`) changes observable output in a way the lab
  review cannot explain — STOP; dry-run output is the reviewed artefact.
- `write_rollback`'s generated script is consumed by anything else in the repo
  (grep first: `grep -rn 'rollback.sh' bin/ README.md plans/`) in a way the new
  self-reading form breaks.
- The code no longer matches the excerpts (drift).

## Maintenance notes

- The generated rollback now depends on `restored.tsv` staying beside it;
  `bin/omacachy-profile-export.sh` is unrelated, but any future "move the
  backup dir" feature must move both files together.
- Reviewer: check that a *successful* import still ends with the same human
  summary lines ("backed up N existing paths, added M new ones") and that the
  rollback's `--dry-run` output format is unchanged apart from the source of
  the entry list.
