# Plan 016: Independent verification of plan 015, four corrections, and a CachyOS test seam

> **Executor instructions**: This plan was executed in the same session it was
> written; the "Verdicts" and "Changes" sections are the record of what was
> checked, what was wrong, and what landed. Every upstream claim was
> re-verified against the *installed* Omarchy 4.0.2 on the dev host (`omarchy
> 4.0.2-1`, `omarchy-settings 4.0.2-1`, `limine-mkinitcpio-hook 1.37.1-1`,
> `mkinitcpio 41.1-1`, `limine 12.6.0-1`, `pacman 7.x`) by reading package
> files on disk. Plan 015's own claims were treated as unproven until
> re-checked; two of them were wrong.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH if wrong (initramfs / ESP / login state on a LUKS machine) —
  mitigated by the fixture matrix, the dry-run purity check and the assertion
  suite
- **Depends on**: plan 012 (the wrapper), plan 015 (what this audits)
- **Category**: correctness, testing
- **Planned at**: omocachy `643bb57` (Reconcile Quattro wrapper against
  installed Omarchy 4.0.2), 2026-09-07; upstream stamp: omarchy **4.0.2-1**
- **Status**: DONE (this session). **Never run for real on a CachyOS host.**
  The fixture matrix proves the wrapper's *decision logic* takes the intended
  branch on CachyOS-shaped input; it does not prove the resulting system
  boots. That distinction is the release gate, not a formality.

## Verdicts on plan 015's four mechanisms

### 1. The Limine hook override — INCOMPLETE (dangerous ordering), rewritten

Plan 015 correctly removed the `/usr/bin/true` no-op: neutering
`/etc/pacman.d/hooks/90-mkinitcpio-install.hook` disables initramfs
regeneration outright, because that package-owned file *shadows* mkinitcpio's
own `/usr/share/libalpm/hooks/90-mkinitcpio-install.hook` (same name, later
`HookDir`). Verified: both files exist on the dev host and differ only in
`Exec` (`limine-mkinitcpio-install` vs `mkinitcpio install`) and one `Target`
(`usr/lib/modules/*/pkgbase` vs `.../vmlinuz`).

What 015 replaced it with — copy the stock hook over the packaged path, add
`NoUpgrade = etc/pacman.d/hooks/90-mkinitcpio-install.hook` — has three
defects:

1. **Ordering.** It ran at the *end* of the script, after the pacman
   transaction. But the damage happens *inside* that transaction:
   `limine-mkinitcpio-hook` arrives as an `omarchy` dependency on every
   machine and its hooks fire immediately.
   `/usr/share/libalpm/hooks/80-limine-efi-deploy.hook` is
   `When = PostTransaction`, `Target = limine`/`limine-mkinitcpio-hook`,
   `Exec = /usr/bin/limine-install` — i.e. a GRUB or systemd-boot machine gets
   the Limine EFI binary deployed to its ESP before the wrapper's late fix-up
   ever runs.
2. **File conflict.** Moving the copy earlier is not possible either: on a
   *fresh* host the path is not yet owned, and pacman aborts the whole
   transaction with "exists in filesystem" when it tries to extract
   `limine-mkinitcpio-hook`'s copy over an unowned file. `NoUpgrade` does not
   cover that case.
3. **`pacman -Qkk` noise.** The edit leaves one permanently-altered packaged
   file, so the assertion could only ever assert "clean *or* exactly this one
   path".

**Fix (landed):** a third pacman hook directory instead of any file edit.
`pacman.conf(5)`: *"Multiple directories can be specified with hooks in later
directories taking precedence over hooks in earlier directories"*, and the
`/etc/pacman.d/hooks` default is replaced as soon as any `HookDir` is named —
so both lines are written, in order:

```
HookDir = /etc/pacman.d/hooks/
HookDir = /etc/pacman.d/hooks-omocachy/
```

`/etc/pacman.d/hooks-omocachy/` receives a copy of *mkinitcpio's* stock
`90-mkinitcpio-install.hook` (shadowing the Limine variant that will land in
`/etc/pacman.d/hooks/`) and inert overrides for the three
`/usr/share/libalpm/hooks/*limine*` hooks. This now runs **before** the pacman
transaction, is re-asserted (idempotently) after the `pacman.conf` restore,
and touches no packaged file at all: `pacman -Qkk limine-mkinitcpio-hook`
stays clean, there is nothing for an upgrade to revert, and the initramfs is
still rebuilt on every kernel/driver upgrade. The `NoUpgrade` line is gone.

The `pacman.conf` backup is now taken *after* the `[omarchy]` stanza and the
`HookDir` lines are written, so the post-apply restore (which undoes
`install/post-install/pacman.sh:3-4`'s `cp -f pacman-stable.conf`) carries
them; a second idempotent re-assert covers the case where that invariant ever
changes.

### 2. `--skip-user-configs` — CORRECT for two of three, INCOMPLETE for the third

`--skip-user-configs` existed and correctly skipped the skel replay and
`omarchy-provision-user`. `omarchy-refresh-limine` was covered only
*transitively* (it is called by `omarchy-reinstall-configs`), and the
bootloader gate demanded by the brief was missing. Evidence, `/usr/bin/
omarchy-refresh-limine`:

```sh
sudo mv /boot/limine.conf /boot/limine.conf.bak
sudo cp "$OMARCHY_PATH/default/limine/limine.conf" /boot/limine.conf
sudo limine-update
sudo limine-snapper-sync
```

No bootloader check anywhere. On a GRUB machine `/boot/limine.conf` does not
exist, so `mv` fails; `omarchy-reinstall-configs` runs under
`set -euo pipefail`, so the *entire* user-seeding step aborts at that point —
before `omarchy-provision-user`, and with a non-zero exit that takes the
wrapper down with it.

**Fix (landed):** the flag is documented by name in `--help` and the README as
skipping all three steps explicitly. Independently of the flag, on a
non-Limine machine the replay now runs with a temporary `PATH` directory
holding a no-op `omarchy-refresh-limine` — scoped to that one call, removed
afterwards, nothing on disk touched. On Limine the real refresh runs and
`/boot/limine.conf` is restored from the pre-install backup, as before.

### 3. The HOOKS merge — CORRECT in shape, INCOMPLETE on refusal; now fixture-tested

The transforming drop-in from 015 is the right mechanism and its lexical
ordering claim holds: mkinitcpio sources `/etc/mkinitcpio.conf` then
`conf.d/*.conf` in lexical order, a later `HOOKS=` replaces the array
wholesale and a later `HOOKS+=` appends, so `zz-cachyos-keep-hooks.conf`
(after `omarchy_hooks.conf`, `omarchy_resume.conf`, `thunderbolt_module.conf`)
sees Omarchy's array *including* `HOOKS+=(resume)`. Proven, not assumed, by
`tests/run.sh hooks` case 6.

What was missing: **no refusal path**. A captured array mixing `systemd` +
`udev` or `encrypt` + `sd-encrypt` was merged anyway (the re-add loop would
happily produce both encryption hooks), and nothing compared the captured
flavour against what the kernel command line actually asks for.

**Fix (landed):** `bin/lib/hooks-merge.sh` — extracted so it can be tested without
the host — adds `hooks_conflict`, and the wrapper stops before writing
anything when:

- the array contains both `systemd` and `udev`;
- the array contains both `encrypt` and `sd-encrypt`;
- LUKS is detected and neither encryption hook is present (kept from 015);
- the array's encryption flavour disagrees with the cmdline
  (`cryptdevice=` = udev, `rd.luks.*` = systemd).

The re-add loop also drops opposite-flavour hooks defensively.

Fixture output, from `tests/run.sh hooks` (Omarchy's array is the constant
`base udev plymouth keyboard autodetect microcode modconf kms keymap
consolefont block encrypt filesystems fsck btrfs-overlayfs`):

| captured (with a `HOOKS+=` drop-in) | merged |
| --- | --- |
| `base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck` **+ `HOOKS+=(lvm2)`** | `base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt lvm2 filesystems fsck sd-btrfs-overlayfs` |
| `base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystems fsck` **+ `HOOKS+=(usr)`** | `base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt lvm2 resume usr filesystems fsck btrfs-overlayfs` |

Refusals:

| captured | cmdline | message |
| --- | --- | --- |
| `base systemd udev block encrypt filesystems` | — | "both 'systemd' and 'udev' — the two initramfs flavours are mutually exclusive" |
| `base systemd block encrypt sd-encrypt filesystems` | `rd.luks.*` | "both 'encrypt' and 'sd-encrypt' — two unlock paths for the same volume" |
| `base udev block encrypt filesystems` | `rd.luks.*` | "the captured HOOKS use the udev encryption hook but the kernel command line asks for the systemd one … already drifted apart" |
| `base systemd block filesystems` | — (LUKS) | "neither 'encrypt' nor 'sd-encrypt', so preserving them would not protect boot" |

Accepted behaviour, recorded so it is a decision and not a surprise: on a
machine with **no** encryption, the merged array still carries Omarchy's
`encrypt` hook (fixture `cachyos-grub-plain`). Without `cryptdevice=` the hook
is a no-op at boot, and dropping Omarchy's own additions is outside this
mechanism's contract.

### 4. The four post-install reconciliations — three CORRECT, several gaps closed

- **`/etc/os-release` + `/etc/nsswitch.conf`: CORRECT.** Verified in
  `/var/lib/pacman/local/omarchy-settings-4.0.2-1/install`: `_etc_overrides_apply`
  runs from *both* `post_install` and `post_upgrade` and does `rm -f
  /etc/os-release; cp -f …/etc-overrides/os-release /etc/os-release` plus the
  same for `nsswitch.conf`. Decision: **restore CachyOS's**, via
  `/etc/cachyos-preserved/` and a `PostTransaction` hook on the
  `omarchy-settings` target, because `ID=omarchy` is what makes CachyOS's own
  tooling and `cachyos-*` scripts mis-detect the host.
- **`/etc/security/faillock.conf`: gap closed.** Plan 015 left it to Omarchy
  with a comment but never backed it up, and named the wrong path
  (`/etc/faillock.conf`). The scriptlet writes
  `/etc/security/faillock.conf`. Decision: **accept Omarchy's**, because
  `install/config/increase-lockout-limit.sh` rewrites `/etc/pam.d/system-auth`
  and `/etc/pam.d/sddm-autologin` to the matching `deny=10 unlock_time=120`
  policy; restoring CachyOS's file alone would leave PAM and faillock
  disagreeing. It is now backed up to
  `/etc/security/faillock.conf.<backup-suffix>` with the restore command in a
  comment, and an assertion records the decision.
- **`/etc/default/limine`: CORRECT mechanism.** Re-verified
  `/usr/lib/limine/limine-common-functions` `load_config` (lines 99–129):
  `/usr/share/limine-entry-tool.d/*.conf` → `/etc/limine-entry-tool.conf` →
  `/etc/limine-entry-tool.d/*.conf` → **`/etc/default/limine` last**. The
  wrapper appends a delimited block there rather than editing the packaged
  `omarchy-{defaults,uki}.conf` drop-ins (which the next `omarchy-settings`
  upgrade would restore). Gaps closed: `BOOT_ORDER` now also detects plain
  `linux-lts`, and the assertion checks `ENABLE_UKI` and `BOOT_ORDER`, not
  only `TARGET_OS_NAME`.
- **The update guard: WRONG PATH in 015.** The hook is
  `/usr/share/libalpm/hooks/00-omarchy-update-guard.hook` (`pacman -Ql
  omarchy`), not `/etc/pacman.d/hooks/…`. Corrected in the script, the
  assertion and the README. It is now announced in the final message with both
  escape hatches (`omarchy update`, `OMARCHY_ALLOW_DIRECT_PACMAN=1`), and
  `--verify-only` exists precisely so a user can re-check the reconciliation
  after that first `omarchy update`.
- **Bootloader detection: CORRECT in principle, hardened.** 015 already put
  `bootctl` first and warned about the package probe. Two real defects were
  found and fixed: the ESP was never actually inspected (only `/boot` loader
  *configs*), and the new ESP scan initially reported every loader on every
  host because `nullglob` does not remove non-matching *literal* words from an
  array — only wildcard ones. Detection order is now `bootctl` LoaderInfo →
  ESP contents (`EFI/limine/*.efi`, `EFI/systemd/systemd-boot*.efi`,
  `EFI/*/grubx64.efi`, loader configs) → readable `/boot` configs → package
  probe (warned, and `limine` deliberately never probed). Fixture
  `cachyos-sdboot-luks` is exactly the trap: a systemd-boot ESP on a host with
  the `limine` package installed. It resolves to `systemd-boot`.

## Ported from the sibling project

`jeanmartins7/omarchy-on-cachyos` (`~/Projects/omocachy/omarchy-on-cachyos`,
HEAD `3c88548`) is not viable for v4 — it rsyncs a git clone over
`/usr/share/omarchy`, which is pacman-owned on 4.x. Three things from it were
worth taking, and only those:

- the `ERR`/`INT`/`TERM` traps, naming the step that failed
  (`bin/install-omarchy-v4-on-cachyos.sh:31-36`);
- a persistent install log — here `~/.local/state/omocachy/install-<ts>.log`
  (`OMOCACHY_LOG` overrides), not `/tmp`;
- `_diagnose_failure`'s log pattern scanner (`:293`), trimmed to the patterns
  that actually appear in a pacman/apply-system abort and pointed at the log.

## The CachyOS test seam

Nothing here has run on CachyOS, and a real CachyOS guest needs network egress
the owner has to authorise. So the CachyOS-only branches were made executable
without CachyOS:

- **`OMOCACHY_SYSROOT=<dir>`** redirects every *read* of host state —
  `/etc/os-release`, `/etc/cachyos-release`, `/etc/pacman.conf`,
  `/etc/pacman.d/*`, `/etc/mkinitcpio.conf` + `conf.d/*.conf`,
  `/etc/default/limine`, `/etc/skel`, `/etc/crypttab`, `/etc/sddm.conf`,
  `/proc/cmdline`, the ESP, `/var/lib/pacman/local` (package probes) and
  `/usr/share/libalpm/hooks`. Writes are untouched; the variable requires
  `--dry-run` and refuses otherwise. Unset, `host_path` is the identity and
  behaviour is byte-for-byte what it was.
- **`OMOCACHY_DECISIONS_FILE=<path>`** records `key=value` decisions so tests
  assert the branch taken, not log wording.
- **`tests/fixtures/*`** are sysroots; **`tests/run.sh`** is the entry point
  (`lint`, `hooks`, `matrix`, `purity`, or all four). 105 assertions,
  0 failures at the time of writing.

### Fixture → decisions

| fixture | bootloader (source) | LUKS / cmdline | merged HOOKS | rebuild | boot-hook policy | `/etc/default/limine` | skel |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `cachyos-limine-luks` (cachyos-v3 repos above `[core]`, `skel/.config/hypr`, `linux-cachyos-lts`) | `limine` (ESP contents) | yes / `rd.luks.uuid=` | `base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt lvm2 filesystems fsck sd-btrfs-overlayfs` | `limine-mkinitcpio` | limine-native | `TARGET_OS_NAME="CachyOS"; ENABLE_UKI=no; BOOT_ORDER="*, *lts, *fallback, Snapshots"` | replay + backup (hypr collision announced) |
| `cachyos-grub-plain` (stale `/etc/sddm.conf`) | `grub` (ESP contents) | no / none | `base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt usr filesystems fsck btrfs-overlayfs` | `/usr/bin/mkinitcpio -P` | hookdir-override | not written (not Limine) | replay, `refresh-limine` shadowed |
| `cachyos-sdboot-luks` (**`limine` package installed**) | `systemd-boot` (ESP contents) | yes / `rd.luks.name=` | `base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs` | `/usr/bin/mkinitcpio -P` | hookdir-override | not written | replay, `refresh-limine` shadowed |
| `omarchy-host-control` (this host's real `mkinitcpio.conf`+`conf.d`, sanitised cmdline) | `limine` (ESP contents) | yes / `cryptdevice=` | `base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt resume filesystems fsck btrfs-overlayfs` | `limine-mkinitcpio` | limine-native | `ENABLE_UKI=no; BOOT_ORDER="*, *fallback, Snapshots"` (no `TARGET_OS_NAME`: not CachyOS) | replay + backup |
| `irreconcilable-hooks` (udev/`encrypt` HOOKS, `rd.luks.uuid=` cmdline) | — | yes / `rd.luks.uuid=` | **refused, exit 1** | — | — | — | — |

The control fixture is there so a regression on the owner's own machine is
visible as a diff in that row. Note the one intentional difference from
Omarchy's own layout in the control row: `resume`, which
`omarchy_resume.conf` appends *after* `fsck`/`btrfs-overlayfs`, is re-inserted
before `filesystems`, which is where the udev `resume` hook belongs.

### Dry-run purity

`tests/run.sh purity` prepends a directory of failing stubs for `sudo`,
`pacman`, `pacman-key`, `cp`, `mv`, `rm`, `systemctl`, `mkinitcpio`,
`limine-mkinitcpio`, `limine-update`, `omarchy-apply-system`,
`omarchy-reinstall-configs`, `omarchy-provision-user` and
`omarchy-refresh-limine` to `PATH`, runs the dry run on two fixtures, and
requires that the violation log stay empty while the plan still prints
`DRYRUN: sudo …` lines. That is the dry-run contract, enforced rather than
asserted.

## Changes

- `bin/lib/hooks-merge.sh` (new): `has_word`, `effective_hooks`, `hooks_flavour`,
  `hooks_crypt_flavour`, `cmdline_crypt_flavour`, `hooks_conflict`,
  `render_keep_hooks_conf`, `merge_preview`. `merge_preview` *runs the
  rendered drop-in*, so the tests exercise the artifact rather than a second
  implementation.
- `bin/install-omarchy-quattro.sh`: `HookDir` boot-hook policy applied
  pre-transaction; `NoUpgrade`/packaged-file edit removed; HOOKS refusal path;
  ESP-based bootloader detection; `--verify-only`; faillock backup + decision;
  `linux-lts` in `BOOT_ORDER`; corrected update-guard path; `PATH`-scoped
  `omarchy-refresh-limine` shim; log + ERR/INT/TERM traps + failure scanner;
  `OMOCACHY_SYSROOT`/`OMOCACHY_DECISIONS_FILE` seams; extended assertions.
- `tests/run.sh`, `tests/fixtures/*` (new).
- `README.md`: `--skip-user-configs` semantics by name, `--verify-only`, the
  bootloader/HookDir section, the update-guard section, the testing section,
  and the unchanged "not validated on real CachyOS" status.

## Open / UNVERIFIED

1. **No CachyOS run.** Still true, and the single release gate. The matrix
   proves branch selection on CachyOS-shaped input; it does not prove the
   resulting system boots.
2. **`pacman`'s `HookDir` replacement semantics** are taken from
   `pacman.conf(5)` ("The default is /etc/pacman.d/hooks", "hooks in later
   directories taking precedence"), and both lines are written for that
   reason. Not exercised against a real transaction — no package was
   installed in this session.
3. **`omarchy update` behaviour after the install** is inferred from reading
   `/usr/bin/omarchy-update` and the migrations (`1787589206.sh`,
   `1788112314.sh` both only `sed` the `[omarchy]` stanza; nothing re-runs
   `install/post-install/pacman.sh`). `--verify-only` exists because that
   inference should be checked on the real machine, not trusted.
4. **`/var/lib/sddm/state.conf`'s shape** is still from mroboff #74; the dev
   host's copy is root-only and was not read.
