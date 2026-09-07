# omocachy

Install [DHH's Omarchy](https://omarchy.org) — an opinionated, Hyprland-based
desktop — on top of [CachyOS](https://cachyos.org), a performance-optimized
Arch Linux distribution, without either one clobbering the other.

The project provides an Omarchy 4 installation path, a profile migration for
an Omarchy machine you are moving away from, and an optional debloater:

| Path | Script | Status |
|------|--------|--------|
| **Omarchy 4 "Quattro"** (packages) | `bin/install-omarchy-quattro.sh` | **Recommended** |
| Capture an existing Omarchy desktop profile | `bin/omocachy-profile-export.sh` | Run on the machine you are leaving |
| Restore it onto the CachyOS machine | `bin/omocachy-profile-import.sh` | Run after the installer |
| Check the result (also standalone) | `bin/omocachy-doctor.sh` | Read-only |
| Optional debloater: per-item picker (Omarchy 4) | `bin/debloat-quattro.sh` | Opt-in, v4 only |

This README assumes an experienced Arch user — comfortable with the shell and
with Arch terms like AUR.

## 1. What This Project Does and Does Not Do

The installer takes an **already-installed CachyOS system** and puts Omarchy
on top of it, resolving the places where the two distributions' defaults
collide (see §4). It detects your GPU vendor and configures drivers
accordingly (see §5). If you are coming from a machine that already runs
Omarchy, §6 carries your own desktop profile — the Quickshell layer, shell
and tooling config, package and mise tool lists — across to it.

What none of these scripts do:

1. Install CachyOS or any other Linux operating system
2. Partition, format, or encrypt hard disks
3. Install or configure a boot loader
4. Install a display manager package (SDDM must already be present — see
   §2.3 — before Omarchy's install step configures it further)
5. Copy your documents or any other user data (§6 migrates a desktop
   profile, not a home directory)

All of the above happen when you install CachyOS itself.

## 2. Prerequisites: How to Install CachyOS First

Install CachyOS before running anything here (see
[cachyos.org](https://www.cachyos.org) for instructions), with these choices:

1. **File system**: BTRFS with Snapper as the snapshot manager. This aligns
   with CachyOS's default recommendation and is required for Omarchy to
   function properly.
2. **Shell**: Fish (the CachyOS default). The installers assume it.
3. **Desktop environment**: either a minimal install with no desktop, or the
   CachyOS Hyprland Desktop Environment (which also installs SDDM as the
   display manager). Do not install GNOME or KDE. Omarchy's packages
   reconfigure SDDM for Wayland and its `omarchy` session; this repo's
   installer clears any pre-existing `/etc/sddm.conf` first so that
   reconfiguration actually takes effect, and writes the remembered-user
   state Omarchy's theme needs (see §4.4). Autologin is opt-in
   (`--autologin`).
4. **Full disk encryption**: your choice. Omarchy-the-distribution always
   encrypts; CachyOS makes it optional, and this project works either way.
5. **Bootloader**: any. Limine gets the most seamless Omarchy 4 integration
   (see §3); GRUB and systemd-boot are handled safely.

Other configuration choices are up to you — but note this project has not
been extensively tested beyond the maintainers' own machines.

## 3. Installing Omarchy 4 (Quattro) — Recommended

Omarchy 4 is no longer a source tree with an `install.sh`. It ships as Arch
packages (`omarchy`, `omarchy-settings`, `omarchy-keyring`, `omarchy-nvim`)
that a script called `omarchy-apply-system` applies from an ISO chroot.
`bin/install-omarchy-quattro.sh` is therefore a **package-install wrapper**,
not a clone-and-patch script: it adds the omarchy pacman repo, installs the
packages, runs `omarchy-apply-system` on your live CachyOS system, and
reconciles everything in that process that would otherwise clobber CachyOS
state.

```bash
git clone https://github.com/d7eeem/omocachy.git
cd omocachy
bin/install-omarchy-quattro.sh --dry-run   # review the exact plan first
bin/install-omarchy-quattro.sh             # then run it for real
```

**Dry run first.** `--dry-run` performs all read-only detection for real
(bootloader, LUKS, GPU vendor, current boot hooks, existing repos, service
state) but prints every state-changing or privileged command with a `DRYRUN:`
prefix — and the full content of every file it would write — instead of
executing it, so you can review the plan before committing. `--yes` skips
the confirmation prompt (safe to combine with `--dry-run`).

**Two more flags:**

- `--skip-user-configs` keeps the wrapper out of `$HOME` entirely: no
  `/etc/skel` replay (`omarchy-reinstall-configs`), no
  `omarchy-provision-user`, no fish `conf.d` file, and the GPU scripts print
  their session-environment lines instead of writing
  `~/.config/uwsm/env.d/50-omocachy-gpu`. Use it when a dotfiles tool owns
  your home; deploy your dotfiles afterwards and run `omarchy-provision-user`
  yourself if you want Omarchy's user finalization.
- `--autologin` writes `/etc/sddm.conf.d/autologin.conf` for your user
  (Omarchy's ISO default). Off by default.

**What the wrapper does:**

1. Adds the `[omarchy]` repo to `/etc/pacman.conf` with
   `SigLevel = Required DatabaseOptional` (the stable channel signs every
   package but not the repo database) and imports/locally signs the Omarchy
   packaging key.
2. Backs up and pre-arms everything the next steps would clobber (see the
   guarantees below), then installs `omarchy-settings`, `omarchy`, and
   `omarchy-nvim` via `pacman -Syu --needed`, followed by Omarchy's own
   `install/omarchy-base.packages` list (the desktop app set the ISO
   pacstraps — `cups`, `avahi`, `docker`, `power-profiles-daemon`, ...).
   `omarchy-apply-system` is written against that set: on a minimal CachyOS
   it otherwise aborts at `systemctl enable cups.service`. `tldr` is left out
   when CachyOS's `tealdeer` is installed (§4.2). Kernels, drivers and the
   bootloader live in `omarchy-other.packages`, which is never installed.
3. Runs `omarchy-apply-system --install-user "$USER" --first-install` as
   root — Omarchy's own config/hardware/login/post-install stages.
4. Restores CachyOS state, writes the SDDM login state, and — unless
   `--skip-user-configs` — seeds your existing user the way Omarchy handles a
   pre-existing (non-`useradd`-created) user: `omarchy-reinstall-configs`
   (resyncs shipped defaults from `/etc/skel`) then `omarchy-provision-user
   --first-install` (run in Omarchy's first-boot context so it does not
   abort looking for the ISO's bundled Node tarball), with Omarchy's own
   `env-bootstrap` sourced first so `OMARCHY_PATH` is set even though your
   shell has never seen Omarchy's `.bashrc`.
5. Writes the Fish integration file (`OMARCHY_PATH`, mise, zoxide),
   dispatches GPU setup (see §5), rebuilds the initramfs once, and runs the
   assertion suite.

**Reconciliation guarantees.** Omarchy's install stages are safe on a stock
Omarchy machine but destructive on CachyOS if left alone. Each of these was
verified against an installed Omarchy 4.0.2 (evidence in
`plans/015-quattro-4.0.2-reconciliation.md`):

- **CachyOS pacman repos are preserved.** `omarchy-apply-system` overwrites
  `/etc/pacman.conf` *and* `/etc/pacman.d/mirrorlist` with Omarchy's own
  versions partway through. The wrapper backs both up beforehand and
  restores them immediately afterward, re-appending the `[omarchy]` stanza.
- **Boot hooks are transformed, not replaced.** `omarchy-settings` ships
  `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which replaces your
  `HOOKS=(...)` with a udev/`encrypt` array. CachyOS boots LUKS with
  `rd.luks.uuid=`, which only the systemd `sd-encrypt` hook understands, so
  that array is unbootable at the next rebuild. Before installing anything the
  wrapper captures your *effective* HOOKS and writes
  `/etc/mkinitcpio.conf.d/zz-cachyos-keep-hooks.conf`, which sorts after
  Omarchy's file and *transforms* the array Omarchy set: it maps it to your
  initramfs flavour (`udev→systemd`, `encrypt→sd-encrypt`,
  `keymap consolefont→sd-vconsole`, `btrfs-overlayfs→sd-btrfs-overlayfs`) and
  re-adds any pre-install hook that went missing (`lvm2`, `mdadm_udev`,
  `resume`, ...), while keeping what Omarchy needs (`plymouth` is a hard
  dependency; `kms` is not re-added where Omarchy deliberately drops it).
  `--dry-run` prints the rendered file. The rebuild runs once, at the end,
  via `limine-mkinitcpio` (Limine) or `/usr/bin/mkinitcpio -P`.
- **Host identity is preserved.** `omarchy-settings`' install scriptlet
  rewrites `/etc/os-release` to `ID=omarchy` and replaces `/etc/nsswitch.conf`
  on every install *and upgrade*. The wrapper backs both up, restores them
  after the apply, keeps copies in `/etc/cachyos-preserved/`, and installs a
  pacman `PostTransaction` hook that restores them after every future
  `omarchy-settings` upgrade. `/etc/security/faillock.conf` is left to
  Omarchy (its PAM edits depend on it).
- **Snapper is preserved.** Omarchy overwrites `/etc/snapper/configs/root`
  and `/etc/conf.d/snapper` and disables `snapper-timeline.timer`; the
  wrapper restores both files and re-enables the timer if it was enabled.
- **iwd is preserved when NetworkManager uses it.** Omarchy disables
  `iwd.service`; the wrapper re-enables it if `wifi.backend=iwd` is
  configured.
- **Limine entry-tool defaults stay CachyOS.** `omarchy-settings` ships
  `/etc/limine-entry-tool.d/omarchy-{defaults,uki}.conf`
  (`TARGET_OS_NAME="Omarchy"`, `ENABLE_UKI=yes`, a `BOOT_ORDER` without the
  `*lts` entry), which would rename your boot entries, switch you to UKI mode
  and break `limine-snapper-sync`. `/etc/default/limine` loads last, so the
  wrapper appends a delimited block there with `TARGET_OS_NAME="CachyOS"`,
  `ENABLE_UKI=no` and a `BOOT_ORDER` that includes `*lts` when
  `linux-cachyos-lts` is installed — only for keys the file does not already
  set. On Limine, `/boot/limine.conf` is also backed up and put back (then
  `limine-update`) after `omarchy-reinstall-configs`, which otherwise
  replaces it with Omarchy's branded one.
- **You can log in.** Omarchy's SDDM theme has no username field; the
  remembered-user state comes from the Omarchy ISO, not from any package. The
  wrapper writes `/etc/sddm.conf.d/99-omarchy-login.conf`
  (`RememberLastUser/Session=true`) and, if absent, `/var/lib/sddm/state.conf`
  pointing at your user and the `omarchy` session. Any stale
  `/etc/sddm.conf` is removed first (§4.4).
- **User configs are backed up, not silently clobbered.**
  `omarchy-reinstall-configs` replays `/etc/skel` over your `$HOME`; the
  wrapper first backs up every `$HOME` entry that `/etc/skel` would shadow
  (or, with `--skip-user-configs`, never runs it).

**Bootloader handling.** The `omarchy` package hard-depends on `limine`,
`limine-mkinitcpio-hook`, and `limine-snapper-sync` — they arrive via pacman
regardless of your actual bootloader, which is also why the wrapper detects
the bootloader from the firmware (`bootctl status`) and loader configs rather
than from installed packages. If Limine is your active bootloader, Omarchy's
Limine integration is left fully active. If it is not (GRUB, systemd-boot),
the wrapper disables `limine-snapper-sync.service`, replaces
`limine-mkinitcpio-hook`'s `/etc/pacman.d/hooks/90-mkinitcpio-install.hook`
with a copy of mkinitcpio's stock hook (protected by a `NoUpgrade` line in
`/etc/pacman.conf`, so upgrades leave a `.pacnew`), and overrides its three
`/usr/share/libalpm/hooks/*limine*` hooks with same-named no-ops in
`/etc/pacman.d/hooks/`. Initramfs regeneration on kernel and driver upgrades
keeps working; nothing Limine-specific runs.

**Verification.** After the apply, a hard-failing assertion suite checks:
`[omarchy]` and (on CachyOS) the `[cachyos*]` repos present;
`/etc/os-release` still `ID=cachyos`; the HOOKS drop-in exists and the
*effective* HOOKS keep your LUKS unlock flavour, `plymouth` and an overlayfs
hook; `pacman -Qkk limine-mkinitcpio-hook` is clean (Limine) or reports only
the `NoUpgrade`-managed hook; `limine-snapper-sync` disabled on non-Limine
machines; `/etc/default/limine` carries `TARGET_OS_NAME` on a CachyOS Limine
host; `sddm` and `NetworkManager` enabled; no `/etc/sddm.conf`; the snapper
config matches its backup; and the `omarchy` CLI exists.

**After the install: updates.** The `omarchy` package installs a
`PreTransaction` pacman hook that aborts any direct `pacman -Syu` (and every
tool that wraps one — `paru`, `yay`, `topgrade`, `cachyos-update`). Update
with `omarchy update`, or set `OMARCHY_ALLOW_DIRECT_PACMAN=1` in the
environment of the upgrade command. The wrapper prints this reminder when it
finishes and uses the same variable for its own re-runs.

**Status: validated on one real CachyOS install** (2026-09-07, plan 016): a
fresh CachyOS 260809 "minimal" (server profile, no desktop) VM with btrfs,
Limine, snapper and the systemd initramfs, no LUKS. The wrapper ran end to
end with all ten assertions passing, the machine rebooted through the
transformed HOOKS drop-in into Omarchy's SDDM greeter with `ID=cachyos`
intact, and a Hyprland/Quickshell session came up. Not yet covered: a LUKS
install, GRUB/systemd-boot, and real GPUs (the VM has none). Treat your own
first run accordingly: take a snapshot, read the dry-run, keep a live USB
handy.

## 4. How CachyOS/Omarchy Conflicts Are Resolved

The philosophy of this project is a strong, stable blend of CachyOS and
Omarchy that changes as little as possible in either. Software and
configuration are only touched where the two distributions' defaults
actually conflict, resolved as follows:

1. **Shell**: CachyOS defaults to Fish, Omarchy to Bash. Fish stays your
   default interactive shell.
2. **TLDR client**: CachyOS ships Tealdeer (Rust). The wrapper installs only
   `omarchy`, `omarchy-settings` and `omarchy-nvim`, none of which depend on
   Omarchy's `tldr`, so there is no file conflict at install time. Note that
   `omarchy reinstall pkgs` (and the ISO package list) does pull `tldr` and
   will conflict with Tealdeer; pick one when that happens.
3. **Mise and zoxide on Fish**: Omarchy wires mise activation only for Bash
   and installs zoxide without initializing it for Fish. The installer
   writes `~/.config/fish/conf.d/omocachy.fish` activating both — a file
   that survives upstream changes to Omarchy's own activation scripts
   (skipped with `--skip-user-configs`).
4. **Login system (SDDM)**: CachyOS's Hyprland option provides the SDDM
   package itself (§2.3); Omarchy then configures it and runs unmodified.
   The SDDM theme/Wayland config ships as package-owned `/etc/sddm.conf.d/`
   drop-ins and `sddm.sh` only trims the PAM keyring lines. Because a legacy
   `/etc/sddm.conf` outranks every file in `/etc/sddm.conf.d/`
   (`man 5 sddm.conf`), the installer deletes any pre-existing
   `/etc/sddm.conf` so Omarchy's drop-ins actually take effect. Omarchy's
   theme has no username field and relies on SDDM remembering the last user,
   which the ISO sets up but no package does; the wrapper writes that state
   (`99-omarchy-login.conf`, `/var/lib/sddm/state.conf`) and offers
   `--autologin` for the ISO's autologin default.
5. **Full disk encryption**: left entirely to your CachyOS install choice
   (§2.4); everything here works with or without LUKS — including CachyOS's
   systemd-initramfs `rd.luks.uuid=` style, which the HOOKS transform in §3
   exists to preserve.
6. **Host identity, snapshots, boot entries**: kept CachyOS's (`ID=cachyos`,
   your snapper config and timeline timer, Limine entry names and non-UKI
   layout) as described under "Reconciliation guarantees" in §3. Omarchy's
   own tooling (`omarchy update`, theme and plymouth refreshes) keeps working
   on top of that.

## 5. GPU Drivers

The installer uses the same vendor dispatch (`bin/gpu-detect.sh` →
`bin/gpu-setup.sh`):

- **NVIDIA**: detect and respect whatever NVIDIA driver CachyOS already has
  installed — no pinning or downgrading. Only if no driver is present is one
  installed via CachyOS's `chwd`, scoped to GPU device classes.
- **AMD**: installs the AMDGPU driver profile via `chwd` plus the ROCm
  runtime and VA-API packages (`bin/amd-rocm.sh`). VA-API only — Mesa
  removed VDPAU support upstream.
- **Session environment**: both vendor scripts write their variables to
  `~/.config/uwsm/env.d/50-omocachy-gpu` (uwsm sources `uwsm/env.d/*`), never
  to your own `~/.config/uwsm/env`. With `--skip-user-configs` they print
  the lines for you to place instead.
- **Hybrid NVIDIA+AMD**: the NVIDIA path wins (see the detection order in
  `bin/gpu-detect.sh`).
- **Intel-only**: left untouched.

### Hardware video acceleration in browsers (NVIDIA)

For NVDEC hardware decode in **Chromium**:

1. Add to `~/.config/chromium-flags.conf`:

   ```
   --enable-features=VaapiOnNvidiaGPUs
   ```

2. Install the
   [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk)
   and disable the **VP8** and **AV1** codecs.

For full hardware acceleration in **Firefox**:

1. Install the
   [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/)
   and disable the **VP8** and **AV1** codecs.
2. Add these overrides to your `user.js`:

   ```js
   // FORCE NVIDIA HARDWARE ACCELERATION
   user_pref("media.hardware-video-decoding.force-enabled", true);
   user_pref("media.hardware-video-encoding.force-enabled", true);
   user_pref("layers.acceleration.force-enabled", true);
   user_pref("webgl.force-enabled", true);
   user_pref("media.ffmpeg.vaapi.enabled", true);
   user_pref("media.rdd-ffmpeg.enabled", true);
   user_pref("media.av1.enabled", true);
   user_pref("widget.dmabuf.force-enabled", true);
   user_pref("gfx.x11-egl.force-enabled", true);
   ```

## 6. Bringing an Existing Omarchy Machine With You

Installing Omarchy 4 gives you Omarchy's *defaults*. If you are moving from a
machine that already runs Omarchy, the desktop you actually use lives in your
`$HOME`: `~/.config/omarchy/shell.json` (bar layout, plugin list, idle and
lock rules), the Quickshell `plugins/` tree, themes, your Hyprland Lua
config, mise tool versions, the packages you installed by hand, the user
units you enabled. Three scripts carry that across:

```bash
# 1. on the machine you are leaving (read-only; writes only into --out)
bin/omocachy-profile-export.sh --out /run/media/usb --archive

# 2. on the CachyOS machine, AFTER bin/install-omarchy-quattro.sh
bin/omocachy-profile-import.sh --bundle /run/media/usb/omocachy-profile-<host>-<ts>.tar.zst --dry-run
bin/omocachy-profile-import.sh --bundle /run/media/usb/omocachy-profile-<host>-<ts>.tar.zst

# 3. any time, on either machine
bin/omocachy-doctor.sh --bundle /run/media/usb/omocachy-profile-<host>-<ts>.tar.zst
```

### What a bundle contains

`share/profile-paths.conf` is the capture list (relative to `$HOME`, edit it
or pass `--paths FILE`): `~/.config/omarchy`, `~/.config/hypr`, `uwsm`, the
shells (fish/bash), `mise`, terminals and TUI config, `~/.config/systemd/user`,
`~/.local/bin`. Alongside the payload the bundle records the explicit package
list (native and foreign/AUR separately), your mise tools, the enabled user
units, and a plugin table — id, whether it has a git remote, and which commit.

What it deliberately does not contain: credential stores (`~/.ssh`,
`~/.gnupg`, `~/.config/gh`, ...), regenerable state (mise runtimes, caches,
`node_modules`, each plugin checkout's git-ignored build output) and your
documents. A profile bundle is not a backup tool.

`--slim` drops theme wallpapers (on the maintainer's machine: 520 MB of
themes down to 348 MB). `--archive` also writes a `.tar.zst` plus `.sha256`
for transport.

**Treat a bundle as sensitive.** Plugin settings live in `shell.json`, API
keys included, so the bundle directory is created `0700` and the archive
`0600`. `SUMMARY.md` counts the credential-shaped paths that were dropped
(`system/secrets-removed.txt`), the ones deliberately kept because they are
scripts or assets (`system/secret-exemptions.txt`), and the captured files
that carry credentials inline (`system/inline-secrets.txt`).

### What the import does, and how to undo it

Stages, selectable with `--only`/`--skip`: `configs`, `packages`, `mise`,
`services`, `verify`.

- **Nothing is deleted.** The payload is *merged* into `$HOME`: files the
  bundle does not carry are left alone.
- **Everything it would shadow is backed up first**, to
  `~/.local/state/omocachy/backups/import-<ts>/`, together with a generated
  `rollback.sh` (which itself supports `--dry-run`) that restores exactly the
  paths that existed and removes exactly the ones the import introduced.
- **Host-specific files are not restored on top of working ones.**
  `~/.config/hypr/monitors.lua` and `~/.config/uwsm/env.d/50-omocachy-gpu`
  describe the *old* machine — a foreign monitor layout can leave you without
  a usable display. They are parked as `<name>.from-<source-host>` for you to
  merge by hand; `--restore-host-specific` overrides that.
- **Packages are filtered by policy, out loud.** Kernels and headers,
  bootloaders, the NVIDIA/mesa driver stack, `omarchy*`/`quickshell*`,
  base-system packages, `cachyos-*` metapackages and `tldr` are never
  installed by the importer — the first three because they are boot- or
  driver-critical and belong to your CachyOS install and `chwd`, the rest
  because the installer or CachyOS already provides them. Each skip is
  printed with its reason. Everything else is installed from your configured
  repos in one pacman transaction, with names no repo has routed to
  `paru`/`yay`; failures are reported, never silent.
- **Offline is handled.** With no network the `packages` and `mise` stages
  skip and leave their lists in
  `~/.local/state/omocachy/reports/import-<ts>/`; re-run later with
  `--only packages,mise`.
- **User units are re-enabled** when the target actually has the unit; units
  whose packages are missing are listed instead of failing.

Log out and back in (or run `omarchy-restart-shell`) afterwards to pick up
the restored Quickshell layer.

### The doctor

`bin/omocachy-doctor.sh` is read-only and exits non-zero on failure, so it
works as a post-migration gate. It checks the system layer (`ID=cachyos`
survived, `[omarchy]` and `[cachyos*]` repos, `omarchy`/`omarchy-settings`,
a `quickshell` provider, no stale `/etc/sddm.conf`, the mkinitcpio HOOKS
drop-in), the desktop profile (`shell.json` parses; **every plugin id it
references resolves to a directory** — a missing plugin makes the shell drop
that part of its graph with no visible error; `hyprctl configerrors`;
`omarchy-shell` IPC), and tooling (mise tools installed, fish integration,
GPU session env matching the *detected* vendor). With `--bundle` it also
diffs the machine against a bundle and treats a missing local-only plugin —
one with no git remote anywhere — as a hard failure, because the bundle is
its only copy.

## 7. Optional: Debloating

Omarchy ships a large default app selection. This project offers an optional
per-item debloater for the Omarchy 4 install path.

### Per-item picker (`bin/debloat-quattro.sh`)

Omarchy 4's built-in `omarchy-remove-preinstalls` is all-or-nothing: one
confirm removes every preinstalled web app, every TUI wrapper, all
agent/mise CLI stubs, and a fixed package list in one shot.
`bin/debloat-quattro.sh` is a per-item alternative — it enumerates the same
candidates (packages, web apps, TUIs, agent CLI stubs) and lets you pick
exactly which ones to remove via a `gum` checklist, one category at a time.
Agent CLI stubs are selectable individually. When a selected app, web app, or
TUI has a matching Hyprland binding, the picker can also remove that binding
after the selected removals succeed; it makes a backup first.

It is derived from `basecamp/omarchy`'s own scripts
(`omarchy-remove-preinstalls` and the `omarchy-webapp-remove-all` /
`omarchy-tui-remove-all` enumeration logic), which are MIT-licensed, with
attribution in the script header. Actual removal is delegated to Omarchy's
own tools (`omarchy-pkg-drop`, `omarchy-webapp-remove`, `omarchy-tui-remove`)
so behavior tracks upstream rather than reimplementing it.

Because Omarchy's `preinstalls-removed` state flag is binary (it doesn't
represent partial removal), the script only sets it if you select
*everything* offered across every category; otherwise it leaves the flag
unset and tells you so, since some Hyprland keybindings/menu entries may
still expect the untouched items.

```bash
bin/debloat-quattro.sh --dry-run   # review what would be removed first
bin/debloat-quattro.sh             # then run it for real
```

To restore everything at any time, run Omarchy's own
`omarchy-install-preinstalls`.

## 8. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

Use these scripts at your own risk. Always back up your system and important
data before running installation scripts.

## 9. How to Contribute

We welcome contributions! Here's how:

1. **Fork the repository**: click "Fork" on GitHub
2. **Create a feature branch**: `git checkout -b feature/your-feature-name`
3. **Make your changes**
4. **Commit**: `git commit -m "Add descriptive commit message"`
5. **Push to your fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request** with a clear description

### Contribution guidelines

- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation when adding features
- Report bugs via GitHub Issues
