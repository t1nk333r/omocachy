# Plan 020: Harden the bundle trust boundary (manifest paths, archive integrity, remotes)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer if they said they maintain the index).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/omacachy-profile-import.sh bin/omacachy-profile-export.sh bin/lib/profile.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

A profile bundle is the one artefact this project moves between machines (USB
stick, email attachment, "here is my setup" share). The import trusts it
completely: every `payload.captured[]` entry from `manifest.json` is used as a
filesystem path with no validation, the archive is extracted with a bare
`tar -xf`, and the `.sha256` the exporter writes is never read. A `..` entry in
a tampered manifest passes both existing existence gates and drives
`mkdir -p`/`cp -a` outside the backup directory; the generated `rollback.sh`
then runs `rm -rf "$HOME_DIR/$1"` on the same unchecked string. This plan adds
the validation and the integrity check; it changes no legitimate bundle's
behaviour (the repo's own exporter emits relative, `..`-free paths).

## Current state

- `bin/omacachy-profile-import.sh` — restores a bundle into `$HOME`.
  - `:112-118` sets `BUNDLE=$(profile_resolve_bundle ...)`; `:120-121` checks
    the schema; `:129`:
    ```bash
    mapfile -t CAPTURED < <(profile_manifest "$BUNDLE" '.payload.captured[]')
    ```
  - `:176-190` (inside `stage_configs`):
    ```bash
    [[ -e "$BUNDLE/home/$rel" ]] || continue
    if [[ -e "$HOME/$rel" ]]; then
        ...
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -a "$HOME/$rel" "$BACKUP_DIR/$rel"
    ```
  - `:207-216` parks host-specific files at `target="$HOME/$hs.from-$SRC_HOST"`
    where `SRC_HOST` comes from the manifest (`:123`).
  - `:265-283` generates `rollback.sh`; its `restore()`/`drop()` bodies run
    `rm -rf "$HOME_DIR/$1"` on entries recorded `%q`-quoted at `:276-277`.
- `bin/lib/profile.sh` — shared policy/helpers.
  - `:228-236` `profile_resolve_bundle`:
    ```bash
    mkdir -p "$workdir"
    tar -C "$workdir" -xf "$arg" || return 1
    inner="$(find "$workdir" -maxdepth 2 -name manifest.json -printf '%h\n' -quit)"
    ```
  - `:183` `remote="$(git -C "$p" remote get-url origin ...)"`; `:241-245`
    `profile_manifest() { jq -r "$2 // empty" "$1/manifest.json" 2>/dev/null; }`
  - `:133-152` `profile_read_paths` — the exporter-side list reader (its output
    is the contract for what a legitimate manifest entry looks like: a
    non-empty relative path).
- `bin/omacachy-profile-export.sh:436` writes the digest the import never reads:
  ```bash
  (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum "$(basename "$ARCHIVE_PATH")" >"$ARCHIVE_PATH.sha256")
  ```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Tampered-manifest repro | see Step 5 | import exits 1, prints the offending entry |

## Scope

**In scope**: `bin/lib/profile.sh`, `bin/omacachy-profile-import.sh`,
`bin/omacachy-profile-export.sh` (remote scrubbing only), `tests/run.sh` (one
regression case).

**Out of scope**: the doctor (plan 025), the secret sweep (plan 026), the
package policy (plan 024), the rollback *ordering* fix (plan 022) — do not
touch those here even though the code is adjacent.

## Git workflow

- Branch: `advisor/020-bundle-trust-boundary`
- Commit message, e.g.: `Validate bundle-supplied paths and verify archive digests`
  with a body explaining the escape arithmetic (`..` → `cp`/`rm -rf` outside
  `$HOME`) and the new refusals.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a path validator to `bin/lib/profile.sh`

Add below `profile_read_paths` (same file, documented in the same voice):

```bash
# True when $1 can be used safely as a path relative to $HOME: non-empty,
# relative, no '.'/'..' component, no leading '/'. The component walk is the
# authority — it mirrors what profile_read_paths emits, so a bundle produced
# by this repo always passes.
profile_rel_path_ok() {
    local p="$1" part
    [[ -n $p && $p != /* ]] || return 1
    local IFS=/
    for part in $p; do
        [[ -n $part && $part != . && $part != .. ]] || return 1
    done
    return 0
}
```

**Verify**: `bash -n bin/lib/profile.sh` → exit 0.

### Step 2: Reject unsafe manifest entries in the import

In `bin/omacachy-profile-import.sh`, directly after the `mapfile` at `:129`,
validate and refuse:

```bash
bad=()
for rel in "${CAPTURED[@]}"; do
    profile_rel_path_ok "$rel" || bad+=("$rel")
done
if ((${#bad[@]})); then
    printf 'Refusing bundle: %d unsafe path(s) in payload.captured:\n' "${#bad[@]}" >&2
    printf '  %q\n' "${bad[@]}" >&2
    exit 1
fi
```

Also sanitise the parking target: replace `target="$HOME/$hs.from-$SRC_HOST"`
with a sanitised host, e.g. `SRC_HOST_SAFE="${SRC_HOST//[^A-Za-z0-9._-]/_}"`, and
use that in the target (and in the dry-run echo).

**Verify**: `grep -n 'profile_rel_path_ok' bin/omacachy-profile-import.sh` → the
validation loop; `bash -n bin/omacachy-profile-import.sh` → exit 0.

### Step 3: Guard the generated rollback

In `write_rollback`, emit the same check inside the generated script's
`restore()`/`drop()` before any `rm -rf`/`cp`:

```bash
echo '    case "$1" in *..*|/*) echo "rollback: refusing unsafe path $1" >&2; return 1 ;; esac'
```

Generate it once, before the `restore %q`/`drop %q` lines. (With Step 2 in
place this is defence in depth; it is what makes a hand-edited
`restored.tsv` harmless.)

**Verify**: `sed -n '/refusing unsafe path/p' bin/omacachy-profile-import.sh` →
one match inside `write_rollback`.

### Step 4: Verify the digest and extract safely

In `profile_resolve_bundle` (`bin/lib/profile.sh:228-236`), for the archive
branch only:

1. If `$arg.sha256` exists: `(cd "$(dirname "$arg")" && sha256sum -c --quiet "$(basename "$arg").sha256")` — on failure print
   `digest mismatch for <archive>; re-copy the bundle and re-run` and `return 1`.
   If it does not exist, print `note: no .sha256 next to <archive>; cannot verify integrity` (do not fail; bundles are also transported by other means).
2. Before extracting, reject unsafe members:
   ```bash
   while IFS= read -r member; do
       profile_rel_path_ok "${member%%/*}" || profile_rel_path_ok "$member" || { printf 'unsafe archive member: %s\n' "$member" >&2; return 1; }
   done < <(tar -tf "$arg")
   ```
   (Keep it simple and strict: any member that is absolute or contains a `..`
   component refuses the bundle.)
3. Extract with `tar -C "$workdir" --no-same-owner --no-same-permissions -xf "$arg"`.

**Verify**: build a two-file archive with a `..` member in a scratch dir:
```bash
d=$(mktemp -d); mkdir -p "$d/a"; echo x >"$d/a/f"; tar -C "$d/a" -cf "$d/bad.tar" ../f 2>/dev/null || tar -C "$d" -cf "$d/bad.tar" --transform='s|^|../|' f
```
then run the extraction path (e.g. `bash -c 'source bin/lib/profile.sh; profile_resolve_bundle "$d/bad.tar" "$d/out"'`) → refuses with the member named. Also verify the happy path still resolves a good archive.

### Step 5: Strip userinfo from recorded remotes

- In `bin/lib/profile.sh` `profile_plugin_rows` (`:183`), pipe the remote
  through a scrubber:
  ```bash
  remote="$(git -C "$p" remote get-url origin 2>/dev/null | sed 's|^\([a-z+][a-z+]*://\)[^/@]*@|\1|' || echo '-')"
  ```
- In `bin/omacachy-profile-export.sh`, apply the same `sed` where the yadm
  origin URL is captured (search `yadm_remote`).

**Verify**: `grep -n 'sed .*@' bin/lib/profile.sh bin/omacachy-profile-export.sh` → both sites; a manual check: `printf 'https://u:t@h/r\n' | sed 's|^\([a-z+][a-z+]*://\)[^/@]*@|\1|'` → `https://h/r`.

### Step 6: Regression case in `tests/run.sh`

Add a case under the existing sections (or a new `guard` section if plan 029
has landed) that builds a bundle directory in `$WORK` whose `manifest.json`
has `{"schema":1,"payload":{"captured":[".."]}}`, runs the import with
`--dry-run --bundle <dir> --only configs`, and asserts the run exits 1 and its
output contains `unsafe path`. Use the harness's `ok`/`bad` helpers.

**Verify**: `tests/run.sh` → `0 failed`, including the new case.

## Test plan

- The new `tests/run.sh` case above is the regression: it must fail against the
  current code and pass after Step 2.
- Happy path: an untouched bundle from `bin/omacachy-profile-export.sh --out`
  still imports in `--dry-run` mode (run it in the lab VM if available; on a
  dev host at least confirm the dry run prints the merge plan and exits 0).

## Done criteria

- [ ] A `..` entry in `payload.captured` makes the import exit 1 with the
      offending entry printed — demonstrated by the new test case
- [ ] `--sha256` mismatch refuses; absent `.sha256` prints a note and proceeds
- [ ] Archive members are validated before extraction; extraction uses
      `--no-same-owner --no-same-permissions`
- [ ] Imported remotes never carry `user:pass@`
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `tar --version` lacks `--no-same-owner`/`--no-same-permissions` (GNU tar on
  Arch has both; a different tar is a STOP).
- `profile_read_paths` emits anything the new validator rejects (that would
  break legitimate bundles — report the path instead of loosening silently).
- The code no longer matches the excerpts (drift).

## Maintenance notes

- The validator is the single place to extend if bundles ever carry absolute
  paths by design; today nothing does.
- Reviewer: check the refusals happen *before* any `$HOME` write and before
  `mkdir -p "$BACKUP_DIR/..."`; a refusal that has already created directories
  is a bug in this change.
- Deferred: verifying the payload's merkle/manifest consistency (per-file
  digests); the archive digest covers transport tampering already.
