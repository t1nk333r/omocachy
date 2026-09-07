#!/bin/bash
set -euo pipefail

# install-omarchy-quattro.sh — package-install wrapper for Omarchy 4
# ("Quattro"). Quattro ships as Arch packages applied by omarchy-apply-system.
# This script adds the omarchy repo, installs the packages, runs the apply
# stages, and reconciles the parts of that process that would otherwise
# clobber CachyOS state (pacman.conf, mirrorlist, mkinitcpio HOOKS, boot
# hooks, limine defaults, os-release, snapper, login state, user configs),
# then verifies the result with an assertion suite. Design rationale:
# plans/012-omarchy-quattro-install.md; the 4.0.2 evidence behind each
# reconciliation step: plans/015-quattro-4.0.2-reconciliation.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_KEY_ID="F0134EE680CAC571"
OMARCHY_REPO_SERVER='https://pkgs.omarchy.org/stable/$arch'
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_SUFFIX="omarchy-quattro-backup-$TIMESTAMP"

DRY_RUN=false
ASSUME_YES=false
SKIP_USER_CONFIGS=false
AUTOLOGIN=false

# run / run_root / write_root_file / append_root_file and the dry-run
# contract they implement live in bin/lib/common.sh, shared with the profile
# migration scripts.
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--yes] [--skip-user-configs] [--autologin]

  --dry-run            Print every state-changing command (prefixed DRYRUN:)
                       and the content of every file it would write, instead
                       of executing. Read-only detection (bootloader, LUKS,
                       GPU, current pacman/mkinitcpio state) still runs.
  --yes                Skip the confirmation prompt.
  --skip-user-configs  Touch nothing under \$HOME: no /etc/skel replay
                       (omarchy-reinstall-configs), no omarchy-provision-user,
                       no fish conf.d file, no uwsm env.d file from the GPU
                       scripts. For homes managed by a dotfiles tool.
  --autologin          Write /etc/sddm.conf.d/autologin.conf for \$USER
                       (Omarchy's ISO default). Off by default.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes) ASSUME_YES=true ;;
        --skip-user-configs) SKIP_USER_CONFIGS=true ;;
        --autologin) AUTOLOGIN=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

echo "=== install-omarchy-quattro.sh ==="
$DRY_RUN && echo "(dry-run mode: no privileged or state-changing commands will execute)"
echo ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Error: do not run this script as root. It calls sudo itself where needed." >&2
    exit 1
fi

if ! command -v pacman &>/dev/null; then
    echo "Error: pacman not found. This script targets an Arch-based system (CachyOS)." >&2
    exit 1
fi

# CachyOS detection: prefer the release file, fall back to the presence of a
# cachyos repo stanza in pacman.conf. Neither survives an omarchy-settings
# install by itself (it rewrites /etc/os-release to ID=omarchy), which is why
# /etc/os-release is deliberately not consulted here.
IS_CACHYOS=false
if [[ -f /etc/cachyos-release ]]; then
    IS_CACHYOS=true
elif grep -qE '^\[cachyos' /etc/pacman.conf 2>/dev/null; then
    IS_CACHYOS=true
fi

if ! $IS_CACHYOS; then
    echo "Warning: this does not look like a CachyOS system (no /etc/cachyos-release and no [cachyos*] repo in /etc/pacman.conf)."
    echo "This script's reconciliation logic (pacman.conf/mirrorlist restore, boot hook handling) assumes CachyOS."
    if ! $ASSUME_YES; then
        read -r -p "Continue anyway? [y/N] " reply
        [[ $reply =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
    fi
fi

REAPPLY=false
if pacman -Qq omarchy &>/dev/null; then
    REAPPLY=true
    echo "omarchy $(pacman -Q omarchy | awk '{print $2}') is already installed: this run is a re-apply (packages upgraded, reconciliation re-asserted)."
fi

# Bootloader detection. The installed-package probe is useless once omarchy is
# on the box: omarchy hard-depends on limine, so a GRUB machine re-running this
# script would be reported as Limine. Ask the firmware first (bootctl reads the
# LoaderInfo EFI variable, which Limine and systemd-boot both set, without
# root), then fall back to readable loader configs, and only then to packages.
BOOTLOADER="unknown"
BOOTLOADER_SOURCE=""
bootctl_product="$(bootctl status 2>/dev/null | grep -m1 'Product:' || true)"
case "${bootctl_product,,}" in
    *limine*)       BOOTLOADER="limine";       BOOTLOADER_SOURCE="bootctl: ${bootctl_product##*Product: }" ;;
    *systemd-boot*) BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="bootctl: ${bootctl_product##*Product: }" ;;
    *grub*)         BOOTLOADER="grub";         BOOTLOADER_SOURCE="bootctl: ${bootctl_product##*Product: }" ;;
esac
if [[ $BOOTLOADER == "unknown" ]]; then
    if [[ -r /boot/limine.conf ]]; then
        BOOTLOADER="limine"; BOOTLOADER_SOURCE="/boot/limine.conf present"
    elif [[ -r /boot/grub/grub.cfg ]]; then
        BOOTLOADER="grub"; BOOTLOADER_SOURCE="/boot/grub/grub.cfg present"
    elif [[ -r /boot/loader/loader.conf ]]; then
        BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="/boot/loader/loader.conf present"
    fi
fi
if [[ $BOOTLOADER == "unknown" ]]; then
    if pacman -Qq grub &>/dev/null; then
        BOOTLOADER="grub"; BOOTLOADER_SOURCE="package probe"
    elif command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; then
        BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="bootctl is-installed"
    elif pacman -Qq limine &>/dev/null; then
        BOOTLOADER="limine"; BOOTLOADER_SOURCE="package probe"
        echo "Warning: bootloader detected only by the limine package being installed. limine is also an omarchy dependency, so on a re-apply this is not proof that Limine boots this machine." >&2
    fi
fi

# LUKS detection: either a crypto_LUKS block device or a non-comment
# /etc/crypttab entry counts.
LUKS_DETECTED=false
if lsblk -o FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
    LUKS_DETECTED=true
elif [[ -f /etc/crypttab ]] && grep -vE '^\s*#|^\s*$' /etc/crypttab &>/dev/null; then
    LUKS_DETECTED=true
fi

# Resolve the EFFECTIVE mkinitcpio HOOKS the way mkinitcpio itself does:
# source /etc/mkinitcpio.conf, then every /etc/mkinitcpio.conf.d/*.conf in
# lexical order (later files win). Used both for the pre-install capture and
# for the post-install assertion. Runs in a subshell with -e/-u relaxed:
# package drop-ins are not written against this script's strict mode.
effective_hooks() {
    (
        set +eu
        HOOKS=()
        # shellcheck disable=SC1091
        [[ -f /etc/mkinitcpio.conf ]] && source /etc/mkinitcpio.conf 2>/dev/null
        shopt -s nullglob
        for f in /etc/mkinitcpio.conf.d/*.conf; do
            # shellcheck disable=SC1090
            source "$f" 2>/dev/null
        done
        echo "${HOOKS[*]}"
    )
}

has_word() {
    [[ " $2 " == *" $1 "* ]]
}

CURRENT_HOOKS="$(effective_hooks)"

# Initramfs flavour of the captured array. CachyOS installs boot LUKS with
# rd.luks.uuid= on the kernel cmdline, which only the systemd initramfs
# (sd-encrypt) understands; the udev `encrypt` hook wants cryptdevice= and
# would leave the root volume locked at the next rebuild (mroboff #74).
CAPTURED_SYSTEMD=false
for h in systemd sd-encrypt sd-vconsole; do
    has_word "$h" "$CURRENT_HOOKS" && CAPTURED_SYSTEMD=true
done

if $LUKS_DETECTED && ! has_word encrypt "$CURRENT_HOOKS" && ! has_word sd-encrypt "$CURRENT_HOOKS"; then
    echo "Error: LUKS was detected but the current effective mkinitcpio HOOKS contain neither encrypt nor sd-encrypt (HOOKS=($CURRENT_HOOKS))." >&2
    echo "Refusing to continue — treating this as the 'known good' HOOKS to preserve would not protect boot." >&2
    exit 1
fi

# GPU vendor: read-only lspci probe via this repo's own detector.
GPU_TYPE="$(bash "$SCRIPT_DIR/gpu-detect.sh")"

REPO_ALREADY_PRESENT=false
grep -qE '^\[omarchy\]' /etc/pacman.conf 2>/dev/null && REPO_ALREADY_PRESENT=true

# Service state that omarchy-apply-system changes and this script re-asserts:
# install/config/snapper.sh disables snapper-timeline.timer,
# install/hardware/network.sh disables iwd.service.
SNAPPER_TIMELINE_WAS_ENABLED=false
systemctl is-enabled --quiet snapper-timeline.timer 2>/dev/null && SNAPPER_TIMELINE_WAS_ENABLED=true
IWD_WAS_ENABLED=false
systemctl is-enabled --quiet iwd.service 2>/dev/null && IWD_WAS_ENABLED=true
NM_BACKEND_IWD=false
if grep -rhsE '^\s*wifi\.backend\s*=\s*iwd\s*$' /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/ 2>/dev/null | grep -q .; then
    NM_BACKEND_IWD=true
fi

PRE_OS_RELEASE_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"

echo "Plan summary:"
echo "  CachyOS system:            $IS_CACHYOS"
echo "  Re-apply (omarchy present): $REAPPLY"
echo "  Bootloader:                $BOOTLOADER${BOOTLOADER_SOURCE:+ ($BOOTLOADER_SOURCE)}"
echo "  LUKS detected:             $LUKS_DETECTED"
echo "  Current mkinitcpio HOOKS:  ($CURRENT_HOOKS)"
echo "  Initramfs flavour:         $($CAPTURED_SYSTEMD && echo systemd || echo udev)"
echo "  /etc/os-release ID:        $PRE_OS_RELEASE_ID"
echo "  GPU vendor:                $GPU_TYPE"
echo "  [omarchy] repo present:    $REPO_ALREADY_PRESENT"
echo "  snapper-timeline.timer:    $($SNAPPER_TIMELINE_WAS_ENABLED && echo enabled || echo disabled)"
echo "  iwd.service enabled:       $IWD_WAS_ENABLED (NetworkManager wifi.backend=iwd: $NM_BACKEND_IWD)"
echo "  Target user:               $USER"
echo "  Skip user configs:         $SKIP_USER_CONFIGS"
echo "  SDDM autologin:            $AUTOLOGIN"
echo ""
echo "This will: add the omarchy repo (if missing), install omarchy-settings/omarchy/omarchy-nvim,"
echo "run omarchy-apply-system, then reconcile pacman.conf, mirrorlist, mkinitcpio HOOKS, os-release,"
echo "nsswitch.conf, snapper, limine defaults, login state, boot-loader hooks"
if $SKIP_USER_CONFIGS; then
    echo "and leave \$HOME untouched (--skip-user-configs)."
else
    echo "and seed your user configs, so CachyOS state survives."
fi
echo ""

if ! $ASSUME_YES && ! $DRY_RUN; then
    read -r -p "Proceed? [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Repo + keyring
# ---------------------------------------------------------------------------

echo ""
echo "--- Repo + keyring ---"

# Bootstraps trust for the very first transaction that fetches omarchy-keyring
# itself (its post_install runs pacman-key --populate omarchy from there on).
run_root pacman-key --recv-keys "$OMARCHY_KEY_ID"
run_root pacman-key --lsign-key "$OMARCHY_KEY_ID"

if $REPO_ALREADY_PRESENT; then
    echo "[omarchy] repo already present in /etc/pacman.conf, skipping append."
else
    printf '\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$OMARCHY_REPO_SERVER" |
        append_root_file /etc/pacman.conf
fi

# ---------------------------------------------------------------------------
# Pre-install reconciliation
#
# This MUST happen before the pacman transaction that installs omarchy, not
# merely before omarchy-apply-system:
#   - omarchy-settings ships /etc/mkinitcpio.conf.d/omarchy_hooks.conf and
#     /etc/limine-entry-tool.d/omarchy-{defaults,uki}.conf, and the omarchy
#     package depends on limine-mkinitcpio-hook, whose pacman hook rebuilds
#     the initramfs and regenerates Limine entries in that SAME transaction.
#   - omarchy-settings' post_install scriptlet does `rm -f /etc/os-release;
#     cp -f .../etc-overrides/os-release /etc/os-release` (ID=omarchy) and
#     `cp -f .../nsswitch.conf /etc/nsswitch.conf`, on every install AND
#     upgrade. The backups and the persistent restore hook below must exist
#     before that first scriptlet fires.
# ---------------------------------------------------------------------------

echo ""
echo "--- Pre-install reconciliation ---"

backup_etc_file() {
    local src="$1" var="$2"
    if [[ -f $src ]]; then
        run_root cp -a "$src" "$src.$BACKUP_SUFFIX"
        printf -v "$var" '%s' "$src.$BACKUP_SUFFIX"
    else
        echo "No existing $src to back up."
        printf -v "$var" ''
    fi
}

PACMAN_CONF_BACKUP="/etc/pacman.conf.$BACKUP_SUFFIX"
run_root cp -a /etc/pacman.conf "$PACMAN_CONF_BACKUP"
backup_etc_file /etc/pacman.d/mirrorlist MIRRORLIST_BACKUP

SNAPPER_CONFIG=/etc/snapper/configs/root
backup_etc_file "$SNAPPER_CONFIG" SNAPPER_BACKUP
SNAPPER_CONFD=/etc/conf.d/snapper
backup_etc_file "$SNAPPER_CONFD" SNAPPER_CONFD_BACKUP
backup_etc_file /etc/os-release OS_RELEASE_BACKUP
backup_etc_file /etc/nsswitch.conf NSSWITCH_BACKUP

# /boot is 0700 on Limine installs, so existence cannot be tested unprivileged;
# on a Limine machine $ESP_PATH/limine.conf must exist for limine-update to
# work at all, so a failed copy is worth a warning rather than an abort.
LIMINE_CONF_BACKUP=""
if [[ $BOOTLOADER == "limine" ]]; then
    LIMINE_CONF_BACKUP="/etc/limine.conf.$BACKUP_SUFFIX"
    run_root cp -a /boot/limine.conf "$LIMINE_CONF_BACKUP" ||
        { echo "Warning: could not back up /boot/limine.conf." >&2; LIMINE_CONF_BACKUP=""; }
fi

# Persist the CachyOS identity across omarchy-settings upgrades. The scriptlet
# re-fires on every upgrade, so a one-off restore is not enough: a
# PostTransaction hook copies the preserved files back after each one. The
# preserved copies are taken once, from a host that is not yet ID=omarchy.
PRESERVE_DIR=/etc/cachyos-preserved
PRESERVE_HOOK=/etc/pacman.d/hooks/zz-cachyos-preserve-etc.hook
if [[ -f $PRESERVE_DIR/os-release ]]; then
    echo "Keeping existing $PRESERVE_DIR copies (os-release, nsswitch.conf)."
elif [[ $PRE_OS_RELEASE_ID == "omarchy" ]]; then
    echo "Warning: /etc/os-release already says ID=omarchy and no $PRESERVE_DIR copy exists; nothing pre-Omarchy left to preserve, skipping the preserve hook." >&2
else
    run_root mkdir -p "$PRESERVE_DIR"
    run_root cp -a /etc/os-release "$PRESERVE_DIR/os-release"
    run_root cp -a /etc/nsswitch.conf "$PRESERVE_DIR/nsswitch.conf"
fi
if [[ -f $PRESERVE_DIR/os-release || $PRE_OS_RELEASE_ID != "omarchy" ]]; then
    run_root mkdir -p /etc/pacman.d/hooks
    write_root_file "$PRESERVE_HOOK" <<EOF
# Written by omocachy install-omarchy-quattro.sh.
# omarchy-settings' post_install/post_upgrade scriptlet (_etc_overrides_apply)
# does \`rm -f /etc/os-release; cp -f .../etc-overrides/os-release /etc/os-release\`
# and \`cp -f .../etc-overrides/nsswitch.conf /etc/nsswitch.conf\` on every
# install and upgrade. Put the CachyOS files back after each such transaction.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings

[Action]
Description = Restoring CachyOS /etc/os-release and /etc/nsswitch.conf (omocachy)...
When = PostTransaction
Exec = /usr/bin/cp -f -t /etc $PRESERVE_DIR/os-release $PRESERVE_DIR/nsswitch.conf
EOF
fi

# HOOKS-preserving drop-in. "zz-" sorts after "omarchy_hooks.conf", so
# mkinitcpio sources it last and it sees the HOOKS array Omarchy set. Instead
# of replacing that array with the captured one (which would drop plymouth --
# a hard dependency of omarchy-settings whose `splash` cmdline expects the
# hook -- the btrfs-overlayfs snapshot-boot hook, and anything a later
# HOOKS+= drop-in adds), the file transforms it: map the udev flavour to the
# systemd flavour when the pre-install initramfs was systemd-based, then
# re-add any captured hook that went missing. Both overlayfs variants and
# sd-encrypt/sd-vconsole are shipped (limine-mkinitcpio-hook, systemd), and
# plymouth's install hook supports systemd (add_systemd_unit branch).
ZZ_HOOKS_CONF=/etc/mkinitcpio.conf.d/zz-cachyos-keep-hooks.conf

render_keep_hooks_conf() {
    cat <<EOF
# Written by omocachy install-omarchy-quattro.sh -- re-run the installer
# instead of editing; it re-captures the array below.
#
# Sourced by mkinitcpio after omarchy_hooks.conf (conf.d files load in
# lexical order and a later HOOKS= assignment replaces the array wholesale).
# omarchy-settings' file sets a udev/encrypt/keymap array tuned for the
# Omarchy ISO. On CachyOS that array breaks the next initramfs rebuild:
#   - CachyOS boots LUKS with rd.luks.uuid= on the kernel cmdline, which only
#     the systemd initramfs (sd-encrypt) unlocks; the udev \`encrypt\` hook
#     expects cryptdevice= and leaves the root volume locked.
#   - The systemd flavour needs the single sd-vconsole instead of
#     keymap+consolefont, and the snapshot-boot overlay hook has a systemd
#     variant (sd-btrfs-overlayfs, from limine-mkinitcpio-hook).
# Re-asserting the pre-install array wholesale would throw away plymouth (a
# hard dependency of omarchy-settings; its default/limine cmdline passes
# \`splash\`), so this file transforms the array Omarchy set instead.
#
# Effective HOOKS captured before the omarchy packages were installed:
_cachyos_captured=($CURRENT_HOOKS)

_cachyos_systemd=0
for _cachyos_h in systemd sd-encrypt sd-vconsole; do
  [[ " \${_cachyos_captured[*]} " == *" \$_cachyos_h "* ]] && _cachyos_systemd=1
done

# (a) Flavour-map Omarchy's array to the captured initramfs style. usr and
# resume are udev-only hooks (systemd's initramfs mounts /usr and resumes
# from hibernation itself); keep them only if the pre-install image had them.
_cachyos_result=()
for _cachyos_h in "\${HOOKS[@]}"; do
  if (( _cachyos_systemd )); then
    case \$_cachyos_h in
      udev) _cachyos_h=systemd ;;
      encrypt) _cachyos_h=sd-encrypt ;;
      keymap | consolefont) _cachyos_h=sd-vconsole ;;
      btrfs-overlayfs) _cachyos_h=sd-btrfs-overlayfs ;;
      usr | resume) [[ " \${_cachyos_captured[*]} " == *" \$_cachyos_h "* ]] || continue ;;
    esac
  fi
  [[ " \${_cachyos_result[*]} " == *" \$_cachyos_h "* ]] || _cachyos_result+=("\$_cachyos_h")
done

# (b) Re-add captured hooks Omarchy's array lacks (lvm2, mdadm_udev, resume,
# usr, ...): block-level ones go right before filesystems, the rest at the
# end. kms is the one hook never re-added: omarchy_hooks.conf drops it on
# purpose on NVIDIA-only machines.
_cachyos_block="lvm2 mdadm_udev mdadm dmraid encrypt sd-encrypt sd-encrypt-opensc resume usr btrfs sd-verity"
for _cachyos_h in "\${_cachyos_captured[@]}"; do
  [[ \$_cachyos_h == kms ]] && continue
  [[ " \${_cachyos_result[*]} " == *" \$_cachyos_h "* ]] && continue
  if [[ " \$_cachyos_block " == *" \$_cachyos_h "* && " \${_cachyos_result[*]} " == *" filesystems "* ]]; then
    _cachyos_tmp=()
    for _cachyos_r in "\${_cachyos_result[@]}"; do
      [[ \$_cachyos_r == filesystems ]] && _cachyos_tmp+=("\$_cachyos_h")
      _cachyos_tmp+=("\$_cachyos_r")
    done
    _cachyos_result=("\${_cachyos_tmp[@]}")
  else
    _cachyos_result+=("\$_cachyos_h")
  fi
done

HOOKS=("\${_cachyos_result[@]}")
unset _cachyos_captured _cachyos_systemd _cachyos_result _cachyos_tmp _cachyos_h _cachyos_r _cachyos_block
EOF
}

if [[ -n $CURRENT_HOOKS ]]; then
    run_root mkdir -p /etc/mkinitcpio.conf.d
    render_keep_hooks_conf | write_root_file "$ZZ_HOOKS_CONF"
else
    echo "Warning: could not determine current mkinitcpio HOOKS; skipping $ZZ_HOOKS_CONF." >&2
fi

# Limine defaults. omarchy-settings ships /etc/limine-entry-tool.d/
# omarchy-defaults.conf (TARGET_OS_NAME="Omarchy", BOOT_ORDER="*, *fallback,
# Snapshots") and omarchy-uki.conf (ENABLE_UKI=yes). limine-entry-tool's
# load_config (/usr/lib/limine/limine-common-functions:98-132) loads
# /usr/share/limine-entry-tool.d, then /etc/limine-entry-tool.conf, then
# /etc/limine-entry-tool.d/*.conf, and /etc/default/limine LAST, so keys set
# there win. On CachyOS the "Omarchy" OS name mismatches the /+CachyOS entry
# and makes limine-snapper-sync abort, UKI mode changes the boot layout under
# a running CachyOS, and the ISO BOOT_ORDER drops the *lts entry (mroboff
# #74). Only keys the file does not already set are appended, so an existing
# choice (e.g. ENABLE_UKI=yes) is left alone. TARGET_OS_NAME is only known
# for CachyOS; on another distro that key is left for the user.
LIMINE_DEFAULT=/etc/default/limine
if [[ $BOOTLOADER == "limine" ]]; then
    limine_key_set() {
        [[ -r $LIMINE_DEFAULT ]] && grep -qE "^\s*$1=" "$LIMINE_DEFAULT"
    }
    limine_block=""
    if $IS_CACHYOS; then
        limine_key_set TARGET_OS_NAME || limine_block+='TARGET_OS_NAME="CachyOS"'$'\n'
    elif ! limine_key_set TARGET_OS_NAME; then
        echo "Note: not CachyOS, so TARGET_OS_NAME is not written to $LIMINE_DEFAULT; set it yourself if limine-snapper-sync cannot find your OS entry."
    fi
    limine_key_set ENABLE_UKI || limine_block+='ENABLE_UKI=no'$'\n'
    if ! limine_key_set BOOT_ORDER; then
        if pacman -Qq linux-cachyos-lts &>/dev/null; then
            limine_block+='BOOT_ORDER="*, *lts, *fallback, Snapshots"'$'\n'
        else
            limine_block+='BOOT_ORDER="*, *fallback, Snapshots"'$'\n'
        fi
    fi
    if [[ -n $limine_block ]]; then
        {
            printf '\n# >>> omocachy install-omarchy-quattro.sh >>>\n'
            printf '# /etc/default/limine loads last (limine-common-functions load_config), so these\n'
            printf '# override the omarchy-settings drop-ins in /etc/limine-entry-tool.d/omarchy-*.conf\n'
            printf '# (TARGET_OS_NAME="Omarchy", ENABLE_UKI=yes, BOOT_ORDER without *lts).\n'
            printf '%s# <<< omocachy <<<\n' "$limine_block"
        } | append_root_file "$LIMINE_DEFAULT"
    else
        echo "$LIMINE_DEFAULT already sets TARGET_OS_NAME, ENABLE_UKI and BOOT_ORDER; leaving it alone."
    fi
fi

# SDDM: /etc/sddm.conf (if present) outranks every file in /etc/sddm.conf.d/,
# and Omarchy's SDDM theme/session config ships as package-owned
# sddm.conf.d/*.conf files. Remove any stale /etc/sddm.conf before those
# land so they actually take effect (PR #28 / plan 006 rationale).
if [[ -f /etc/sddm.conf ]]; then
    echo "Removing stale /etc/sddm.conf so package-shipped sddm.conf.d drop-ins win."
    run_root rm -f /etc/sddm.conf
fi

# ---------------------------------------------------------------------------
# Install packages
# ---------------------------------------------------------------------------

echo ""
echo "--- Installing omarchy packages ---"
# On a re-apply the omarchy package's 00-omarchy-update-guard.hook is already
# installed (PreTransaction, AbortOnFail); omarchy-update-pacman-guard:8 lets a
# direct -Syu through only with OMARCHY_ALLOW_DIRECT_PACMAN=1.
run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed --noconfirm omarchy-settings omarchy omarchy-nvim

# omarchy-apply-system is written against the ISO's package set, not against
# the omarchy metapackage's dependencies: install/config/enable-services.sh
# does a bare `systemctl enable cups.service` (also avahi-daemon,
# docker.socket, power-profiles-daemon, linux-modules-cleanup from
# kernel-modules-hook) and aborts the whole apply with "Unit cups.service
# does not exist" on a minimal CachyOS (observed on a fresh CachyOS 260809
# server-profile install, plan 016). The ISO pacstraps
# install/omarchy-base.packages first; do the same. That list is the desktop
# app set only — kernels, drivers and the bootloader live in
# omarchy-other.packages, which is deliberately not touched.
OMARCHY_BASE_LIST=/usr/share/omarchy/install/omarchy-base.packages
if [[ -r $OMARCHY_BASE_LIST ]]; then
    mapfile -t omarchy_base_pkgs < <(grep -vE '^\s*(#|$)' "$OMARCHY_BASE_LIST")
    if pacman -Qq tealdeer &>/dev/null; then
        # Omarchy's tldr conflicts with CachyOS's tealdeer (README §4.2).
        mapfile -t omarchy_base_pkgs < <(printf '%s\n' "${omarchy_base_pkgs[@]}" | grep -vx tldr)
        echo "tealdeer is installed; leaving Omarchy's tldr out of the base package set."
    fi
    echo "Installing Omarchy's base package set (${#omarchy_base_pkgs[@]} packages from $OMARCHY_BASE_LIST)."
    run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm "${omarchy_base_pkgs[@]}"
elif $DRY_RUN; then
    echo "DRYRUN: install every package listed in $OMARCHY_BASE_LIST (shipped by the omarchy package; tldr skipped when tealdeer is installed)"
else
    echo "Warning: $OMARCHY_BASE_LIST not found; omarchy-apply-system may fail enabling services whose packages are absent." >&2
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

echo ""
echo "--- Running omarchy-apply-system ---"
run_root omarchy-apply-system --install-user "$USER" --first-install

# ---------------------------------------------------------------------------
# Post-apply pacman reconciliation
#
# Ordered immediately after apply-system returns, and before GPU dispatch:
# install/post-install/pacman.sh (run inside apply-system) does
# `cp -f .../pacman-stable.conf /etc/pacman.conf` and the matching mirrorlist,
# wiping the CachyOS repos. amd-rocm.sh's own `sudo pacman -S rocm-core ...`
# call needs those repos back BEFORE it runs, so this cannot wait until the
# very end of the script.
# ---------------------------------------------------------------------------

echo ""
echo "--- Post-apply pacman.conf/mirrorlist reconciliation ---"
run_root cp -a "$PACMAN_CONF_BACKUP" /etc/pacman.conf
if [[ -n $MIRRORLIST_BACKUP ]]; then
    run_root cp -a "$MIRRORLIST_BACKUP" /etc/pacman.d/mirrorlist
fi
# Defense in depth: the backup already contains [omarchy] (it was taken after
# the repo/keyring step above), but re-check/append in case that invariant
# ever changes.
if $DRY_RUN; then
    echo "DRYRUN: ensure [omarchy] stanza present in restored /etc/pacman.conf"
else
    if ! grep -qE '^\[omarchy\]' /etc/pacman.conf; then
        printf '\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$OMARCHY_REPO_SERVER" |
            append_root_file /etc/pacman.conf
    fi
fi
run_root pacman -Sy --noconfirm

# ---------------------------------------------------------------------------
# Post-apply /etc reconciliation
# ---------------------------------------------------------------------------

echo ""
echo "--- Post-apply /etc reconciliation ---"
# os-release/nsswitch.conf: the preserve hook above already put them back
# during the transaction when it applied; this covers the first run on a host
# where the hook was skipped, and is a no-op otherwise.
[[ -n $OS_RELEASE_BACKUP ]] && run_root cp -a "$OS_RELEASE_BACKUP" /etc/os-release
[[ -n $NSSWITCH_BACKUP ]] && run_root cp -a "$NSSWITCH_BACKUP" /etc/nsswitch.conf
# install/config/snapper.sh rewrites /etc/conf.d/snapper to SNAPPER_CONFIGS="root"
# and disables snapper-timeline.timer; /etc/snapper/configs/root is restored
# later, after the GPU step, together with its assertion.
[[ -n $SNAPPER_CONFD_BACKUP ]] && run_root cp -a "$SNAPPER_CONFD_BACKUP" "$SNAPPER_CONFD"
if $SNAPPER_TIMELINE_WAS_ENABLED; then
    run_root systemctl enable --now snapper-timeline.timer
fi
# install/hardware/network.sh disables iwd.service unconditionally; with
# NetworkManager's wifi.backend=iwd that kills Wi-Fi.
if $NM_BACKEND_IWD; then
    run_root systemctl enable --now iwd.service
elif $IWD_WAS_ENABLED; then
    echo "iwd.service was enabled but NetworkManager does not use wifi.backend=iwd; leaving it disabled as omarchy-apply-system left it."
fi
# faillock.conf is deliberately left to Omarchy: install/config/
# increase-lockout-limit.sh pairs it with matching PAM edits.

# ---------------------------------------------------------------------------
# Login (SDDM)
#
# Upstream 4.0.2 ships only 10-theme.conf and 10-wayland.conf via
# omarchy-settings; install/login/sddm.sh only trims PAM keyring lines. The
# remembered-user and autologin state come from the Omarchy ISO, not from any
# package. The Omarchy SDDM theme has no username field, so a fresh CachyOS
# without a remembered user cannot log in at all (mroboff #74).
# ---------------------------------------------------------------------------

echo ""
echo "--- Login (SDDM) ---"
run_root mkdir -p /etc/sddm.conf.d
write_root_file /etc/sddm.conf.d/99-omarchy-login.conf <<'EOF'
[Users]
RememberLastUser=true
RememberLastSession=true
EOF
if $AUTOLOGIN; then
    write_root_file /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USER
Session=omarchy.desktop
EOF
fi
# /var/lib/sddm is sddm:sddm 0750, so the file's existence cannot be tested
# unprivileged; the test and the conditional write run together as root so an
# existing remembered user is never overwritten. File shape per mroboff #74
# (this host's copy is root-only and was not read).
SDDM_STATE=/var/lib/sddm/state.conf
run_root sh -c 'test -e "$1" || { mkdir -p "$(dirname "$1")" && printf "[Last]\nUser=%s\nSession=%s\n" "$2" "$3" >"$1"; }' \
    sh "$SDDM_STATE" "$USER" /usr/local/share/wayland-sessions/omarchy.desktop

# ---------------------------------------------------------------------------
# User-level seeding for the existing user (skipped with --skip-user-configs)
#
# omarchy-apply-system's --install-user only drives root-owned hardware setup
# (omarchy-apply-hardware). Per-user config seeding is a separate, user-run
# step: /etc/skel only fires at useradd, so an already-existing user is
# re-synced via omarchy-reinstall-configs (replays /etc/skel over $HOME) and
# then omarchy-provision-user --first-install (== "omarchy finalize user",
# runtime tweaks /etc/skel can't do: xdg dirs, skill symlinks, install/user/*).
# ---------------------------------------------------------------------------

seed_user_configs() {
    # Omarchy's user tools need OMARCHY_PATH (omarchy-plymouth-set:84 dies
    # with "OMARCHY_PATH: unbound variable" otherwise). A desktop session
    # gets it from Omarchy's ~/.bashrc, which this very step is about to
    # install; a fresh CachyOS user (fish or bash) running this over ssh has
    # nothing. Source Omarchy's own bootstrap rather than hard-coding it.
    local env_bootstrap=/usr/share/omarchy/default/bash/env-bootstrap
    if [[ -r $env_bootstrap ]]; then
        set +u
        # shellcheck disable=SC1090
        source "$env_bootstrap"
        set -u
    else
        export OMARCHY_PATH=/usr/share/omarchy
    fi

    if [[ -d /etc/skel ]]; then
        local home_backup_dir="$HOME/.omarchy-quattro-backup-$TIMESTAMP" entry name
        if $DRY_RUN; then
            echo "DRYRUN: back up \$HOME entries shadowed by /etc/skel to $home_backup_dir before omarchy-reinstall-configs"
        else
            mkdir -p "$home_backup_dir"
            shopt -s dotglob nullglob
            for entry in /etc/skel/*; do
                name="$(basename "$entry")"
                if [[ -e "$HOME/$name" ]]; then
                    cp -a "$HOME/$name" "$home_backup_dir/$name"
                fi
            done
            shopt -u dotglob nullglob
            echo "Backed up pre-existing \$HOME entries shadowed by /etc/skel to $home_backup_dir"
        fi
    else
        echo "No /etc/skel found; skipping pre-seeding backup (nothing omarchy-reinstall-configs would overwrite)."
    fi

    if command -v omarchy-reinstall-configs &>/dev/null; then
        run omarchy-reinstall-configs
        # omarchy-reinstall-configs calls omarchy-refresh-limine, which does
        # `mv /boot/limine.conf /boot/limine.conf.bak; cp default/limine/
        # limine.conf /boot/limine.conf; limine-update` with no bootloader
        # check -- replacing the CachyOS loader config with Omarchy's branded
        # one. Put the pre-install file back and regenerate the entries.
        if [[ -n $LIMINE_CONF_BACKUP ]]; then
            run_root cp -a "$LIMINE_CONF_BACKUP" /boot/limine.conf
            run_root limine-update
        fi
    else
        echo "Warning: omarchy-reinstall-configs not found on PATH; skipping user config resync." >&2
    fi

    if command -v omarchy-provision-user &>/dev/null; then
        # --first-install at runtime forces OMARCHY_SETUP_CONTEXT=iso-chroot
        # (omarchy-provision-user:69-73), and install/user/mise-work.sh then
        # hard-fails when the ISO's /opt/packages Node tarball is absent
        # (mroboff #74). The provision-owner context is the first-boot path:
        # same first-install marking, headless theme set, and Node falls back
        # to the network with a warning instead of aborting.
        run env OMARCHY_SETUP_CONTEXT=provision-owner omarchy-provision-user --first-install
    else
        echo "Warning: omarchy-provision-user not found on PATH; skipping user finalization." >&2
    fi

    # Fish integrations (mise + zoxide): Omarchy only wires these for Bash
    # (default/bash/init). Lives in the user's fish config so it survives
    # upstream changes.
    local fish_conf_dir="$HOME/.config/fish/conf.d"
    local fish_conf_file="$fish_conf_dir/omocachy.fish"
    if $DRY_RUN; then
        echo "DRYRUN: write $fish_conf_file"
    else
        mkdir -p "$fish_conf_dir"
        cat >"$fish_conf_file" <<'EOF'
# Added by omocachy
# Omarchy's tools (omarchy-shell, omarchy-plymouth-set, ...) require
# OMARCHY_PATH; Omarchy only exports it from its bash rc.
set -q OMARCHY_PATH; or set -gx OMARCHY_PATH /usr/share/omarchy
if status is-interactive
    command -q mise; and mise activate fish | source
    command -q zoxide; and zoxide init fish | source
end
EOF
    fi
}

echo ""
echo "--- User-level config seeding ---"
if $SKIP_USER_CONFIGS; then
    echo "Skipped (--skip-user-configs): no /etc/skel replay, omarchy-provision-user, or fish conf.d file."
    echo "Deploy your own dotfiles, then run 'omarchy-provision-user' yourself if you want Omarchy's user finalization."
else
    seed_user_configs
fi

# GPU dispatch: this repo's vendor dispatcher (nvidia.sh respects whatever
# CachyOS driver is present; amd-rocm.sh installs the AMDGPU/ROCm profile).
# Runs after the pacman.conf restore above so its own internal `sudo pacman
# -S` calls see the CachyOS repos. OMOCACHY_SKIP_USER_CONFIGS tells the
# vendor scripts to print their session-env lines instead of writing
# ~/.config/uwsm/env.d/50-omocachy-gpu.
echo ""
echo "--- GPU setup ---"
case "$GPU_TYPE" in
    nvidia) echo "Detected NVIDIA GPU -> dispatch target: bin/nvidia.sh (via gpu-setup.sh)" ;;
    amd)    echo "Detected AMD GPU -> dispatch target: bin/amd-rocm.sh (via gpu-setup.sh)" ;;
    none)   echo "No GPU detected -> gpu-setup.sh will no-op" ;;
esac
run env OMOCACHY_SKIP_USER_CONFIGS="$($SKIP_USER_CONFIGS && echo 1 || echo 0)" bash "$SCRIPT_DIR/gpu-setup.sh"

# ---------------------------------------------------------------------------
# Remaining post-apply reconciliation
# ---------------------------------------------------------------------------

echo ""
echo "--- Snapper reconciliation ---"
if [[ -n $SNAPPER_BACKUP ]]; then
    run_root cp -a "$SNAPPER_BACKUP" "$SNAPPER_CONFIG"
else
    echo "No pre-install snapper backup was taken; leaving Omarchy's $SNAPPER_CONFIG in place."
fi

echo ""
echo "--- Bootloader reconciliation ---"
MKINITCPIO_INSTALL_HOOK=/etc/pacman.d/hooks/90-mkinitcpio-install.hook
NOUPGRADE_LINE="NoUpgrade = ${MKINITCPIO_INSTALL_HOOK#/}"
if [[ $BOOTLOADER == "limine" ]]; then
    echo "limine is the active bootloader; leaving Omarchy's limine integration (limine-snapper-sync, limine-mkinitcpio-hook) active."
else
    echo "Active bootloader is '$BOOTLOADER', not limine; disabling Omarchy's limine integration."
    run_root systemctl disable --now limine-snapper-sync.service

    # limine-mkinitcpio-hook (an omarchy dependency, so it arrives regardless
    # of bootloader) ships four pacman hooks (`pacman -Ql limine-mkinitcpio-hook`):
    #   /etc/pacman.d/hooks/90-mkinitcpio-install.hook   (limine-mkinitcpio-install)
    #   /usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook
    #   /usr/share/libalpm/hooks/80-limine-efi-deploy.hook (limine-install)
    #   /usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook
    # The first one is package-owned IN /etc/pacman.d/hooks and, by living
    # there, already shadows mkinitcpio's own /usr/share/libalpm/hooks/
    # 90-mkinitcpio-install.hook (pacman.conf(5): a later HookDir wins for a
    # same-named hook). Neutering it with a no-op would therefore disable
    # initramfs regeneration on kernel/driver upgrades altogether. Instead it
    # is replaced with a copy of mkinitcpio's stock hook (Exec
    # /usr/share/libalpm/scripts/mkinitcpio install) and protected with
    # NoUpgrade so the next limine-mkinitcpio-hook upgrade leaves a .pacnew
    # instead of restoring the Limine variant. `pacman -Qkk` reports exactly
    # this one altered file afterwards; the assertion suite expects that.
    # The other three live in /usr/share/libalpm/hooks, so a same-named no-op
    # in /etc/pacman.d/hooks overrides them without touching package files.
    STOCK_MKINITCPIO_HOOK=/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
    run_root mkdir -p /etc/pacman.d/hooks
    if [[ -f $STOCK_MKINITCPIO_HOOK ]]; then
        run_root cp -f "$STOCK_MKINITCPIO_HOOK" "$MKINITCPIO_INSTALL_HOOK"
        if grep -qxF "$NOUPGRADE_LINE" /etc/pacman.conf; then
            echo "$NOUPGRADE_LINE already in /etc/pacman.conf."
        else
            run_root sed -i "/^\[options\]/a $NOUPGRADE_LINE" /etc/pacman.conf
        fi
    else
        echo "Warning: $STOCK_MKINITCPIO_HOOK not found (mkinitcpio not installed?); leaving $MKINITCPIO_INSTALL_HOOK as shipped." >&2
    fi
    for base in 60-limine-mkinitcpio-remove-pre.hook 80-limine-efi-deploy.hook 90-limine-mkinitcpio-remove-post.hook; do
        write_root_file "/etc/pacman.d/hooks/$base" <<EOF
# Written by omocachy install-omarchy-quattro.sh: overrides
# /usr/share/libalpm/hooks/$base (limine-mkinitcpio-hook) on a
# machine whose bootloader is $BOOTLOADER, not Limine. Delete to restore stock behaviour.
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = var/lib/omocachy/never-matches

[Action]
Description = Disabled by omocachy (non-limine bootloader)
When = PostTransaction
Exec = /usr/bin/true
EOF
    done
fi

echo ""
echo "--- Rebuilding initramfs ---"
# /usr/local/bin/mkinitcpio (limine-mkinitcpio-hook) is an interactive wrapper
# that prompts after -P; it would hang under --yes. Use the absolute binary on
# non-Limine machines and limine-mkinitcpio (rebuild + entry update) on Limine.
if [[ $BOOTLOADER == "limine" ]]; then
    run_root limine-mkinitcpio
else
    run_root /usr/bin/mkinitcpio -P
fi

# ---------------------------------------------------------------------------
# Assertion suite
# ---------------------------------------------------------------------------

echo ""
echo "--- Assertion suite ---"

ASSERT_FAILED=false

# assert DESCRIPTION CHECK_FUNCTION: dry-run only lists the description; a
# real run calls the function and reports PASS/FAIL on its exit status.
assert() {
    local desc="$1" check="$2"
    if $DRY_RUN; then
        echo "WOULD ASSERT: $desc"
        return 0
    fi
    if "$check"; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc" >&2
        ASSERT_FAILED=true
    fi
}

check_repos() {
    grep -qE '^\[omarchy\]' /etc/pacman.conf || return 1
    ! $IS_CACHYOS || grep -qE '^\[cachyos' /etc/pacman.conf
}
check_os_release() {
    ! $IS_CACHYOS || [[ $(. /etc/os-release && echo "${ID:-}") == "cachyos" ]]
}
check_hooks() {
    [[ -f $ZZ_HOOKS_CONF ]] || return 1
    local now
    now="$(effective_hooks)"
    if $LUKS_DETECTED; then
        if $CAPTURED_SYSTEMD; then
            has_word sd-encrypt "$now" || return 1
        else
            has_word encrypt "$now" || return 1
        fi
    fi
    has_word plymouth "$now" || return 1
    has_word btrfs-overlayfs "$now" || has_word sd-btrfs-overlayfs "$now"
}
check_limine_hook_pkg() {
    # -Qkk warnings name each altered path as "warning: pkg: /path (reason)".
    local altered
    altered="$(pacman -Qkk limine-mkinitcpio-hook 2>&1 >/dev/null | awk -F': ' '/^warning: /{print $3}' | awk '{print $1}' | sort -u)"
    if [[ $BOOTLOADER == "limine" ]]; then
        [[ -z $altered ]]
    else
        [[ -z $altered || $altered == "$MKINITCPIO_INSTALL_HOOK" ]]
    fi
}
check_limine_service() {
    [[ $BOOTLOADER == "limine" ]] || ! systemctl is-enabled --quiet limine-snapper-sync.service 2>/dev/null
}
check_limine_default() {
    [[ $BOOTLOADER != "limine" ]] || ! $IS_CACHYOS || grep -qE '^\s*TARGET_OS_NAME=' "$LIMINE_DEFAULT" 2>/dev/null
}
check_services() {
    systemctl is-enabled --quiet sddm.service 2>/dev/null && systemctl is-enabled --quiet NetworkManager.service 2>/dev/null
}
check_sddm_conf() {
    # A fresh CachyOS install (or any tool) may recreate /etc/sddm.conf after
    # the pre-install removal above; it silently outranks every sddm.conf.d
    # drop-in, so its absence is part of the contract, not just a setup step.
    [[ ! -f /etc/sddm.conf ]]
}
check_snapper() {
    [[ -z $SNAPPER_BACKUP ]] || cmp -s "$SNAPPER_BACKUP" "$SNAPPER_CONFIG"
}
check_cli() {
    command -v omarchy &>/dev/null
}

assert "[omarchy] present in /etc/pacman.conf, and the CachyOS repos still present on a CachyOS host" check_repos
assert "/etc/os-release says ID=cachyos on a CachyOS host (omarchy-settings scriptlet reverted)" check_os_release
assert "$ZZ_HOOKS_CONF exists and the effective HOOKS keep the captured LUKS flavour (if LUKS), plymouth, and an overlayfs hook" check_hooks
assert "pacman -Qkk limine-mkinitcpio-hook is clean (Limine) or reports only the NoUpgrade-managed 90-mkinitcpio-install.hook" check_limine_hook_pkg
assert "non-limine machine has limine-snapper-sync.service disabled" check_limine_service
assert "/etc/default/limine sets TARGET_OS_NAME on a CachyOS Limine host" check_limine_default
assert "sddm enabled; NetworkManager enabled" check_services
assert "/etc/sddm.conf absent (sddm.conf.d drop-ins take effect)" check_sddm_conf
assert "/etc/snapper/configs/root matches the pre-install backup" check_snapper
assert "the v4 CLI entrypoint (omarchy) is present" check_cli

if $ASSERT_FAILED; then
    echo "" >&2
    echo "One or more post-install assertions failed. See FAIL lines above." >&2
    exit 1
fi

echo ""
echo "Done."
echo ""
echo "Note: the omarchy package installs 00-omarchy-update-guard.hook, which aborts any direct"
echo "'pacman -Syu' (and tools that wrap it). Update with 'omarchy update', or set"
echo "OMARCHY_ALLOW_DIRECT_PACMAN=1 in the environment of a direct pacman/paru/yay upgrade."
