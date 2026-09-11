# Plan 021: Scope LUKS detection to the boot volume

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/install-omarchy-quattro.sh bin/lib/hooks-merge.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

The wrapper refuses to run when it thinks the machine boots from LUKS but the
captured initramfs HOOKS contain no encryption hook (`hooks_conflict` in
`bin/lib/hooks-merge.sh:83-86`, exit at `bin/install-omarchy-quattro.sh:449-457`).
That refusal exists to protect an *encrypted boot*. But the detection sets
`LUKS_DETECTED=true` when **any** `crypto_LUKS` device exists, when **any**
`/etc/crypttab` line exists, or when the cmdline unlocks something — so a host
with an unencrypted root and a second LUKS disk (or a `noauto` data volume in
crypttab, or a USB drive plugged in during the run) is refused with a remedy
that cannot be applied: the HOOKS already match how the machine boots. The
install is blocked for a configuration the merge itself would handle correctly.

## Current state

- `bin/install-omarchy-quattro.sh:430-441`:
  ```bash
  CMDLINE="$(cat "$(host_path /proc/cmdline)" 2>/dev/null || true)"
  CMDLINE_CRYPT="$(cmdline_crypt_flavour "$CMDLINE")"

  LUKS_DETECTED=false
  if [[ -z $SYSROOT ]] && lsblk -o FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
      LUKS_DETECTED=true
  elif [[ -f $(host_path /etc/crypttab) ]] && grep -qvE '^\s*#|^\s*$' "$(host_path /etc/crypttab)" 2>/dev/null; then
      LUKS_DETECTED=true
  elif [[ $CMDLINE_CRYPT != none ]]; then
      LUKS_DETECTED=true
  fi
  ```
- `:443-457` then computes `CURRENT_HOOKS`, `CAPTURED_FLAVOUR` and calls
  `hooks_conflict "$CURRENT_HOOKS" "$CMDLINE_CRYPT" "$LUKS_DETECTED"`, exiting 1
  on a conflict.
- `bin/lib/hooks-merge.sh:80-90` (inside `hooks_conflict`):
  ```bash
  if [[ $luks == true && $crypt == none ]]; then
      echo "LUKS was detected but the captured HOOKS contain neither 'encrypt' nor 'sd-encrypt', so preserving them would not protect boot"
      return 0
  fi
  ```
- Under a sysroot the `lsblk` signal is skipped (`-z $SYSROOT`), so the
  fixtures steer detection through `proc/cmdline` and `etc/crypttab` — keep
  both readable paths working.
- `tests/fixtures/cachyos-limine-luks/` and `tests/fixtures/cachyos-sdboot-luks/`
  expect `luks=true`; their `proc/cmdline` files carry the unlock parameter
  (verify with `grep -rl 'rd.luks' tests/fixtures/*/proc/cmdline` before
  changing anything).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Dev-host smoke | `bin/install-omarchy-quattro.sh --dry-run --yes \| sed -n '/LUKS detected/p'` | `LUKS detected: true (cmdline unlock style: udev)` (dev host root is LUKS) |

## Scope

**In scope**: `bin/install-omarchy-quattro.sh` only.
**Out of scope**: `bin/lib/hooks-merge.sh` (its conflict rules stay as they
are), the fixtures' expected values (they must keep passing unchanged), plan
027 (snapper assertion) and plan 031 (HookDir) — different changes to the same
file; coordinate via the reviewer per the dependency note in `plans/README.md`.

## Git workflow

- Branch: `advisor/021-luks-boot-scoping`
- Commit message, e.g.: `Scope LUKS detection to the root device; warn on crypttab-only volumes`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Derive the root device's encryption state

Replace the `lsblk`-anywhere signal with one that walks the root device's
dependency chain:

```bash
root_luks=false
root_resolved=true
if [[ -z $SYSROOT ]]; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n $root_src ]]; then
        if lsblk -sno FSTYPE "$root_src" 2>/dev/null | grep -q crypto_LUKS; then
            root_luks=true
        fi
    else
        root_resolved=false
    fi
fi
```

Notes:
- `lsblk -s` lists the device and its parents, so this is true for
  LUKS → LVM → root chains and false for a LUKS data disk elsewhere.
- Under a sysroot, `lsblk` must not run; the fixture signals below cover it.

**Verify**: on the dev host, `findmnt -no SOURCE /` prints the root source and
`lsblk -sno FSTYPE "$(findmnt -no SOURCE /)" | grep crypto_LUKS` matches (the
dev host root is on LUKS).

### Step 2: Rebuild `LUKS_DETECTED` from root state, cmdline, and a warned crypttab

```bash
LUKS_DETECTED=false
if [[ $root_luks == true || $CMDLINE_CRYPT != none ]]; then
    LUKS_DETECTED=true
elif [[ -f $(host_path /etc/crypttab) ]] && grep -qvE '^\s*#|^\s*$' "$(host_path /etc/crypttab)" 2>/dev/null; then
    echo "Warning: /etc/crypttab lists encrypted volumes but the root device is not one and the kernel command line unlocks nothing; treating this machine as unencrypted at boot." >&2
fi
if [[ $root_resolved == false && -z $SYSROOT ]]; then
    echo "Warning: could not resolve the root device; LUKS detection falls back to the kernel command line only." >&2
fi
```

(The wrapper has no `warn` helper — it writes `echo "Warning: …" >&2`; keep that
style. Do not source `bin/lib/common.sh` for this; that is plan 032's change.)

Keep the `luks=` decision record and the printed `LUKS detected:` line format
unchanged (the fixtures and the plan summary depend on them).

**Verify**: `grep -n 'LUKS_DETECTED' bin/install-omarchy-quattro.sh` — every
remaining use reads the rebuilt value; `bash -n` exits 0.

### Step 3: Confirm the fixtures still steer detection

**Verify**: `tests/run.sh` → `0 failed`, in particular `cachyos-limine-luks: luks`,
`cachyos-sdboot-luks: luks` and `irreconcilable-hooks: hooks_conflict`.

### Step 4: Dev-host smoke

**Verify**: `bin/install-omarchy-quattro.sh --dry-run --yes | sed -n '/LUKS detected/p'`
→ `LUKS detected: true (cmdline unlock style: udev)` and the run exits 0.

## Test plan

- The three fixture assertions above are the regression net for the detection
  *logic*; they must pass unchanged.
- A fixture cannot exercise the new root-chain branch (`lsblk` is skipped under
  a sysroot). The dev-host smoke (Step 4) covers the positive case. If you have
  access to a VM with an unencrypted root and a second LUKS disk (the lab repo
  mentioned in `handoff.md`), record the observed behaviour in your report;
  otherwise say so explicitly.

## Done criteria

- [ ] `hooks_conflict` no longer triggers for a host whose root is unencrypted
      with an unrelated LUKS volume (reasoned from the code; the dev host only
      proves the positive case)
- [ ] Fixture suite `0 failed`, including both `luks=true` fixtures
- [ ] `warn` (not refuse) on a crypttab-only machine
- [ ] Lint gate exit 0
- [ ] No files outside `bin/install-omarchy-quattro.sh` are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- A fixture that expects `luks=true` starts failing because its `proc/cmdline`
  carries no unlock parameter — STOP and report; do not edit the fixture to
  make the code pass.
- `findmnt` is unavailable or `lsblk -s` behaves differently on the host.
- The code no longer matches the excerpts (drift).

## Maintenance notes

- If upstream Omarchy ever ships an initramfs that unlocks non-root volumes,
  revisit: this plan intentionally ties `LUKS_DETECTED` to *boot*.
- Reviewer: the refusal path itself is unchanged — only what feeds it. Confirm
  the `decide`/summary output stays byte-stable for LUKS machines.
