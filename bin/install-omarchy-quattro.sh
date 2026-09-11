#!/bin/bash
set -Eeuo pipefail

# install-omarchy-quattro.sh — package-install wrapper for Omarchy 4
# ("Quattro"). Quattro ships as Arch packages applied by omarchy-apply-system.
# This script adds the omarchy repo, installs the packages, runs the apply
# stages, and reconciles the parts of that process that would otherwise
# clobber CachyOS state (pacman.conf, mirrorlist, mkinitcpio HOOKS, boot
# hooks, limine defaults, os-release, snapper, login state, user configs),
# then verifies the result with an assertion suite. Design rationale:
# plans/012-omarchy-quattro-install.md; the 4.0.2 evidence behind each
# reconciliation step: plans/015-quattro-4.0.2-reconciliation.md and
# plans/016-quattro-verification-and-sysroot-seam.md.
#
# Test seams (all default to "off", so normal operation is unchanged):
#   OMOCACHY_SYSROOT=<dir>          read host state from <dir> instead of /
#                                   (requires --dry-run; see tests/run.sh)
#   OMOCACHY_DECISIONS_FILE=<path>  append key=value decision records
#   OMOCACHY_LOG=<path>             install log location

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_LIB="$SCRIPT_DIR/lib/hooks-merge.sh"
if [[ ! -r $HOOKS_LIB ]]; then
    echo "Error: $HOOKS_LIB not found. Run this script from a full omocachy checkout." >&2
    exit 1
fi
# shellcheck source=bin/lib/hooks-merge.sh
source "$HOOKS_LIB"

OMARCHY_KEY_ID="F0134EE680CAC571"
OMARCHY_REPO_SERVER='https://pkgs.omarchy.org/stable/$arch'
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_SUFFIX="omarchy-quattro-backup-$TIMESTAMP"

# The HOOKS array omarchy-settings 4.0.2 ships in
# /etc/mkinitcpio.conf.d/omarchy_hooks.conf. Used only to PREVIEW the merge
# before the packages are installed; the drop-in itself transforms whatever
# array is actually present at rebuild time, so a future Omarchy release
# changing this list changes the result on disk, not the mechanism.
OMARCHY_REFERENCE_HOOKS="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"

DRY_RUN=false
ASSUME_YES=false
SKIP_USER_CONFIGS=false
AUTOLOGIN=false
VERIFY_ONLY=false

# ---------------------------------------------------------------------------
# Sysroot test seam. Every READ of host state goes through host_path so the
# decision logic can be exercised against a fixture tree (tests/fixtures/*)
# on a machine that is not CachyOS. Writes are untouched: they are what
# --dry-run already prints, and --dry-run is mandatory under a sysroot.
# Unset OMOCACHY_SYSROOT => host_path is the identity and behaviour is
# byte-for-byte what it was before the seam existed.
# ---------------------------------------------------------------------------
SYSROOT="${OMOCACHY_SYSROOT:-}"
SYSROOT="${SYSROOT%/}"
host_path() { printf '%s%s' "$SYSROOT" "$1"; }

# Decision record: key=value lines a test can assert on, so the suite checks
# the branch taken rather than the wording of a log line.
DECISIONS_FILE="${OMOCACHY_DECISIONS_FILE:-}"
[[ -z $DECISIONS_FILE ]] || : >"$DECISIONS_FILE"
decide() {
    [[ -z $DECISIONS_FILE ]] || printf '%s=%s\n' "$1" "$2" >>"$DECISIONS_FILE"
}

# ---------------------------------------------------------------------------
# The dry-run contract: every state-changing command flows through one of
# these helpers. In --dry-run mode they print the command (and, for file
# writes, the full content) instead of running it, so review can enforce "no
# sudo outside run_root/write_root_file/append_root_file" with a single grep
# and "no state changes in --dry-run" by inspection of this file.
# ---------------------------------------------------------------------------
run() {
    if $DRY_RUN; then
        echo "DRYRUN: $*"
    else
        "$@"
    fi
}

run_root() {
    if $DRY_RUN; then
        echo "DRYRUN: sudo $*"
    else
        sudo "$@"
    fi
}

# Write stdin as the contents of privileged file $1 via sudo tee. Dry-run
# prints the content indented so the plan shows exactly what would land.
write_root_file() {
    local dest="$1"
    if $DRY_RUN; then
        echo "DRYRUN: write $dest:"
        sed 's/^/    | /'
    else
        sudo tee "$dest" >/dev/null
    fi
}

append_root_file() {
    local dest="$1"
    if $DRY_RUN; then
        echo "DRYRUN: append to $dest:"
        sed 's/^/    | /'
    else
        sudo tee -a "$dest" >/dev/null
    fi
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--yes] [--skip-user-configs] [--autologin]
                        [--verify-only]

  --dry-run            Print every state-changing command (prefixed DRYRUN:)
                       and the content of every file it would write, instead
                       of executing. Read-only detection (bootloader, LUKS,
                       GPU, current pacman/mkinitcpio state) still runs.
  --yes                Skip the confirmation prompt.
  --skip-user-configs  Touch nothing under \$HOME: no /etc/skel replay
                       (omarchy-reinstall-configs), no omarchy-refresh-limine,
                       no omarchy-provision-user, no fish conf.d file, no uwsm
                       env.d file from the GPU scripts. For homes managed by a
                       dotfiles tool (yadm, chezmoi, stow).
  --autologin          Write /etc/sddm.conf.d/autologin.conf for \$USER
                       (Omarchy's ISO default). Off by default.
  --verify-only        Run the read-only assertion suite against the current
                       system and exit. Nothing is installed or changed. Use
                       it after 'omarchy update' to confirm the reconciliation
                       still holds.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes) ASSUME_YES=true ;;
        --skip-user-configs) SKIP_USER_CONFIGS=true ;;
        --autologin) AUTOLOGIN=true ;;
        --verify-only) VERIFY_ONLY=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Persistent log + failure diagnosis.
#
# The log, the ERR/INT traps and the pattern scanner below are the three
# things worth keeping from the earlier jeanmartins7/omarchy-on-cachyos
# project (bin/install-omarchy-v4-on-cachyos.sh:25-36 and :293 
# _diagnose_failure). Its rsync-over-/usr/share/omarchy model is not reused:
# that path is pacman-owned on 4.x.
# ---------------------------------------------------------------------------
if $DRY_RUN || $VERIFY_ONLY || $SKIP_USER_CONFIGS; then
    # These modes promise to leave $HOME alone (README) and to change nothing
    # (dry-run contract). Keep the transcript, but outside $HOME.
    LOG_FILE="${OMOCACHY_LOG:-/tmp/omocachy-install-$TIMESTAMP.log}"
else
    LOG_FILE="${OMOCACHY_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/omocachy/install-$TIMESTAMP.log}"
fi
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/omocachy-install-$TIMESTAMP.log"
    touch "$LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_STEP="startup"
step() {
    CURRENT_STEP="$1"
    echo ""
    echo "--- $1 ---"
}

# Scan the install log for the failure patterns that actually show up in a
# pacman/omarchy-apply-system abort, and print the last few.
diagnose_failure() {
    local patterns regex matches
    patterns=(
        "error:" "Error:" "ERROR" "FAILED" "fatal:"
        "command not found" "No such file or directory" "Permission denied"
        "could not" "unable to" "target not found" "unresolvable package"
        "failed to" "conflicting files" "exists in filesystem"
        "Traceback" "SyntaxError" "segfault"
    )
    [[ -s $LOG_FILE ]] || return 0
    regex="$(printf '%s\n' "${patterns[@]}" | paste -sd '|' -)"
    matches="$(grep -inE "$regex" "$LOG_FILE" 2>/dev/null | tail -20 || true)"
    [[ -n $matches ]] || return 0
    echo "" >&2
    echo "-- log lines matching known failure patterns (last 20) --" >&2
    printf '  %s\n' "$matches" >&2
}

on_err() {
    local rc="$1" line="$2"
    trap - ERR
    # A subshell (command substitution, process substitution, an explicit
    # `( ... )`) inherits this trap under `set -E`. Reporting "aborted" from
    # there is a lie — the parent carries on — and diagnose_failure would scan
    # a log that already contains its own previous output, nesting it. Only
    # the main shell reports. Observed on the GRUB CachyOS guest: a Port-less
    # sshd_config made a grep in a process substitution exit 1 and produced
    # ~280 lines of nested false "aborted" blocks.
    if [[ $BASHPID != "$$" ]]; then
        exit "$rc"
    fi
    echo "" >&2
    echo "Error: aborted at line $line (exit $rc) during step: $CURRENT_STEP" >&2
    diagnose_failure
    echo "" >&2
    echo "Full log: $LOG_FILE" >&2
    exit "$rc"
}

trap 'on_err "$?" "$LINENO"' ERR
trap 'echo "" >&2; echo "Interrupted (SIGINT) during step: $CURRENT_STEP. Log: $LOG_FILE" >&2; exit 130' INT
trap 'echo "" >&2; echo "Terminated (SIGTERM) during step: $CURRENT_STEP. Log: $LOG_FILE" >&2; exit 143' TERM

echo "=== install-omarchy-quattro.sh ==="
$DRY_RUN && echo "(dry-run mode: no privileged or state-changing commands will execute)"
$VERIFY_ONLY && echo "(verify-only mode: read-only assertion suite)"
echo "Log: $LOG_FILE"
echo ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

CURRENT_STEP="preflight"

if [[ -n $SYSROOT ]]; then
    if ! $DRY_RUN; then
        echo "Error: OMOCACHY_SYSROOT is a test seam and requires --dry-run." >&2
        exit 1
    fi
    if [[ ! -d $SYSROOT ]]; then
        echo "Error: OMOCACHY_SYSROOT=$SYSROOT is not a directory." >&2
        exit 1
    fi
    echo "(sysroot mode: host state is read from $SYSROOT; EFI-variable and systemd probes are skipped)"
    echo ""
fi

if [[ $EUID -eq 0 ]]; then
    echo "Error: do not run this script as root. It calls sudo itself where needed." >&2
    exit 1
fi

if ! command -v pacman &>/dev/null; then
    echo "Error: pacman not found. This script targets an Arch-based system (CachyOS)." >&2
    exit 1
fi

# Package probes. Under a sysroot they read the fixture's local database
# directory names instead of querying the live one. The -[0-9]* guard keeps
# `limine` from matching limine-mkinitcpio-hook-1.37.1-1.
pkg_installed() {
    local d
    if [[ -n $SYSROOT ]]; then
        for d in "$(host_path /var/lib/pacman/local)/$1"-[0-9]*/desc; do
            [[ -e $d ]] && return 0
        done
        return 1
    fi
    pacman -Qq "$1" &>/dev/null
}

pkg_version() {
    local d base
    if [[ -n $SYSROOT ]]; then
        for d in "$(host_path /var/lib/pacman/local)/$1"-[0-9]*/desc; do
            [[ -e $d ]] || continue
            base="$(basename "$(dirname "$d")")"
            echo "${base#"$1"-}"
            return 0
        done
        return 1
    fi
    pacman -Q "$1" 2>/dev/null | awk '{print $2}'
}

# systemd unit state. A fixture tree has no service manager, so under a
# sysroot every probe answers "not enabled" and says so once.
svc_enabled() {
    [[ -z $SYSROOT ]] || return 1
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# CachyOS detection. The load-bearing signal is a [cachyos*] repo stanza in
# pacman.conf: an installed CachyOS 260809 has NO /etc/cachyos-release at all
# (unowned by any package, `pacman -F` finds nothing shipping it — the file
# exists only on the live ISO), verified on a pristine guest. The release file
# is kept as a secondary hint for hosts that do have one. /etc/os-release is
# deliberately not consulted: omarchy-settings rewrites it to ID=omarchy.
IS_CACHYOS=false
if grep -qE '^\[cachyos' "$(host_path /etc/pacman.conf)" 2>/dev/null; then
    IS_CACHYOS=true
elif [[ -f $(host_path /etc/cachyos-release) ]]; then
    IS_CACHYOS=true
fi

if ! $IS_CACHYOS && ! $VERIFY_ONLY; then
    echo "Warning: this does not look like a CachyOS system (no /etc/cachyos-release and no [cachyos*] repo in /etc/pacman.conf)."
    echo "This script's reconciliation logic (pacman.conf/mirrorlist restore, boot hook handling) assumes CachyOS."
    if ! $ASSUME_YES; then
        read -r -p "Continue anyway? [y/N] " reply
        [[ $reply =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
    fi
fi

REAPPLY=false
if pkg_installed omarchy; then
    REAPPLY=true
    echo "omarchy $(pkg_version omarchy) is already installed: this run is a re-apply (packages upgraded, reconciliation re-asserted)."
fi

# ---------------------------------------------------------------------------
# Bootloader detection.
#
# By ESP contents and firmware state, never by "is the limine package
# installed": omarchy hard-depends on limine, so on any Omarchy host that
# probe answers "limine" no matter what actually boots the machine. Order:
#   1. bootctl's LoaderInfo EFI variable (what the firmware actually loaded)
#   2. the contents of the ESP
#   3. readable loader configs under /boot
#   4. packages -- last resort, warned about, and never trusted for limine
# ---------------------------------------------------------------------------
BOOTLOADER="unknown"
BOOTLOADER_SOURCE=""

if [[ -z $SYSROOT ]] && command -v bootctl &>/dev/null; then
    bootctl_product="$(bootctl status 2>/dev/null | grep -m1 'Product:' || true)"
    case "${bootctl_product,,}" in
        *limine*)       BOOTLOADER="limine";       BOOTLOADER_SOURCE="bootctl LoaderInfo: ${bootctl_product##*Product: }" ;;
        *systemd-boot*) BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="bootctl LoaderInfo: ${bootctl_product##*Product: }" ;;
        *grub*)         BOOTLOADER="grub";         BOOTLOADER_SOURCE="bootctl LoaderInfo: ${bootctl_product##*Product: }" ;;
    esac
fi

# ESP scan. Candidate mount points in the order Arch uses them. /boot is 0700
# on a Limine install, so an unreadable candidate is skipped, not fatal.
esp_candidates() {
    local esp
    if [[ -z $SYSROOT ]] && command -v bootctl &>/dev/null; then
        esp="$(bootctl --print-esp-path 2>/dev/null || true)"
        [[ -z $esp ]] || printf '%s\n' "$(host_path "$esp")"
    fi
    printf '%s\n' "$(host_path /boot)" "$(host_path /efi)" "$(host_path /boot/efi)"
}

esp_note() { # $1 = loader name, $2 = esp dir
    [[ " ${esp_found[*]-} " == *" $1 "* ]] || esp_found+=("$1")
    esp_where="$2"
}

# Does $1 (an ESP root) carry loader $2? nullglob only drops non-matching
# WILDCARD words, so the fixed filenames are tested separately.
esp_carries() {
    local esp="$1" kind="$2" hits=()
    shopt -s nullglob
    case "$kind" in
        grub)
            hits=("$esp"/EFI/*/grubx64.efi "$esp"/EFI/*/grubia32.efi)
            [[ -e $esp/grub/grub.cfg ]] && hits+=(x)
            ;;
        systemd-boot)
            hits=("$esp"/EFI/systemd/systemd-boot*.efi)
            [[ -e $esp/loader/loader.conf ]] && hits+=(x)
            ;;
        limine)
            hits=("$esp"/EFI/limine/*.efi "$esp"/EFI/BOOT/limine*.efi)
            [[ -e $esp/limine.conf ]] && hits+=(x)
            ;;
    esac
    shopt -u nullglob
    ((${#hits[@]} > 0))
}

if [[ $BOOTLOADER == "unknown" ]]; then
    esp_found=()
    esp_where=""
    while read -r esp_dir; do
        [[ -d $esp_dir && -r $esp_dir ]] || continue
        for esp_kind in grub systemd-boot limine; do
            esp_carries "$esp_dir" "$esp_kind" || continue
            esp_note "$esp_kind" "$esp_dir"
        done
    done < <(esp_candidates)

    if ((${#esp_found[@]} == 1)); then
        BOOTLOADER="${esp_found[0]}"
        BOOTLOADER_SOURCE="ESP contents under $esp_where"
    elif ((${#esp_found[@]} > 1)); then
        # A leftover Limine EFI binary next to a live GRUB/systemd-boot is the
        # realistic collision (Omarchy's 80-limine-efi-deploy hook drops one
        # in). Prefer the loader that is not limine and say so.
        for cand in grub systemd-boot limine; do
            [[ " ${esp_found[*]} " == *" $cand "* ]] || continue
            BOOTLOADER="$cand"
            BOOTLOADER_SOURCE="ESP contents under $esp_where (also found: ${esp_found[*]})"
            break
        done
        echo "Warning: more than one bootloader is present on the ESP (${esp_found[*]}); assuming $BOOTLOADER. Override by fixing the ESP before running this." >&2
    fi
fi

if [[ $BOOTLOADER == "unknown" ]]; then
    if [[ -r $(host_path /boot/limine.conf) ]]; then
        BOOTLOADER="limine"; BOOTLOADER_SOURCE="/boot/limine.conf present"
    elif [[ -r $(host_path /boot/grub/grub.cfg) ]]; then
        BOOTLOADER="grub"; BOOTLOADER_SOURCE="/boot/grub/grub.cfg present"
    elif [[ -r $(host_path /boot/loader/loader.conf) ]]; then
        BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="/boot/loader/loader.conf present"
    fi
fi

if [[ $BOOTLOADER == "unknown" ]]; then
    # Package probes, last and least. `limine` is deliberately NOT probed:
    # it is an omarchy dependency, so its presence proves nothing.
    if pkg_installed grub; then
        BOOTLOADER="grub"; BOOTLOADER_SOURCE="package probe (grub installed)"
        echo "Warning: bootloader detected only from the installed grub package; the ESP could not be read (is /boot mounted and readable?)." >&2
    elif pkg_installed systemd-boot || { [[ -z $SYSROOT ]] && command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; }; then
        BOOTLOADER="systemd-boot"; BOOTLOADER_SOURCE="bootctl is-installed"
    else
        echo "Warning: no bootloader could be identified from the ESP, /boot or the firmware. Boot-related reconciliation (limine defaults, limine pacman hooks, initramfs rebuild command) will take the conservative non-Limine path." >&2
    fi
fi

# LUKS detection: whether the *root* device sits behind LUKS, plus an unlock
# parameter on the kernel command line. A crypto_LUKS volume elsewhere (spare
# disk, USB stick plugged in during the run) or a crypttab entry for a
# non-root volume says nothing about how this machine boots, and refusing on
# those alone would block a merge that is already correct for the way the
# machine starts.
CMDLINE="$(cat "$(host_path /proc/cmdline)" 2>/dev/null || true)"
CMDLINE_CRYPT="$(cmdline_crypt_flavour "$CMDLINE")"

# lsblk -s walks the device and its parents, so this is true for
# LUKS -> LVM -> root chains and false for a LUKS data disk elsewhere.
# Under a sysroot there is no live root device to inspect: the fixture
# signals below (proc/cmdline, etc/crypttab) carry detection there.
root_luks=false
root_resolved=true
if [[ -z $SYSROOT ]]; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    # btrfs subvolumes are printed as DEV[/subvol]; lsblk wants the device.
    root_src="${root_src%%\[*}"
    if [[ -z $root_src ]]; then
        root_resolved=false
    elif ! root_fstypes="$(lsblk -sno FSTYPE "$root_src" 2>/dev/null)"; then
        # A root source lsblk cannot walk is an unresolved root, not evidence
        # that the root is unencrypted: say so instead of reading a silent
        # false. The cmdline signal still applies.
        root_resolved=false
    elif grep -q crypto_LUKS <<<"$root_fstypes"; then
        root_luks=true
    fi
fi

LUKS_DETECTED=false
if [[ $root_luks == true || $CMDLINE_CRYPT != none ]]; then
    LUKS_DETECTED=true
elif [[ -f $(host_path /etc/crypttab) ]] && grep -qvE '^\s*#|^\s*$' "$(host_path /etc/crypttab)" 2>/dev/null; then
    echo "Warning: /etc/crypttab lists encrypted volumes but the root device is not one and the kernel command line unlocks nothing; treating this machine as unencrypted at boot." >&2
fi
if [[ $root_resolved == false && -z $SYSROOT ]]; then
    echo "Warning: could not resolve the root device; LUKS detection falls back to the kernel command line only." >&2
fi

CURRENT_HOOKS="$(effective_hooks "$(host_path /etc/mkinitcpio.conf)" "$(host_path /etc/mkinitcpio.conf.d)")"
CAPTURED_FLAVOUR="$(hooks_flavour "$CURRENT_HOOKS")"

# Refuse rather than guess. A captured array that mixes the two initramfs
# flavours, or that disagrees with the unlock parameter the machine actually
# boots with, has no correct merge: every possible output either fails to
# unlock the root volume or tries to unlock it twice.
if hooks_reason="$(hooks_conflict "$CURRENT_HOOKS" "$CMDLINE_CRYPT" "$LUKS_DETECTED")"; then
    echo "Error: cannot reconcile the mkinitcpio HOOKS on this machine." >&2
    echo "  effective HOOKS: ($CURRENT_HOOKS)" >&2
    echo "  kernel cmdline unlock style: $CMDLINE_CRYPT" >&2
    echo "  reason: $hooks_reason" >&2
    echo "" >&2
    echo "Fix /etc/mkinitcpio.conf (and /etc/mkinitcpio.conf.d/*.conf) so the array matches how this machine boots, rebuild the initramfs, reboot, then re-run this script." >&2
    decide hooks_conflict "$hooks_reason"
    exit 1
fi

MERGED_HOOKS="$(merge_preview "$CURRENT_HOOKS" "$OMARCHY_REFERENCE_HOOKS")" || MERGED_HOOKS=""

# GPU vendor: read-only lspci probe via this repo's own detector. Under a
# sysroot the fixture host has no GPU and probe output must not leak in from
# the machine running the test; the value only feeds the printed summary.
if [[ -n $SYSROOT ]]; then
    GPU_TYPE="none"
else
    GPU_TYPE="$(bash "$SCRIPT_DIR/gpu-detect.sh")"
fi

REPO_ALREADY_PRESENT=false
grep -qE '^\[omarchy\]' "$(host_path /etc/pacman.conf)" 2>/dev/null && REPO_ALREADY_PRESENT=true

# Service state that omarchy-apply-system changes and this script re-asserts:
# install/config/snapper.sh disables snapper-timeline.timer,
# install/hardware/network.sh disables iwd.service.
SNAPPER_TIMELINE_WAS_ENABLED=false
svc_enabled snapper-timeline.timer && SNAPPER_TIMELINE_WAS_ENABLED=true
IWD_WAS_ENABLED=false
svc_enabled iwd.service && IWD_WAS_ENABLED=true
NM_BACKEND_IWD=false
if grep -rhsE '^\s*wifi\.backend\s*=\s*iwd\s*$' \
    "$(host_path /etc/NetworkManager/NetworkManager.conf)" \
    "$(host_path /etc/NetworkManager/conf.d/)" 2>/dev/null | grep -q .; then
    NM_BACKEND_IWD=true
fi

# shellcheck disable=SC1090  # path goes through host_path(); present on any Arch host
PRE_OS_RELEASE_ID="$(. "$(host_path /etc/os-release)" 2>/dev/null && echo "${ID:-}")"

# /etc/skel collision: CachyOS's own Hyprland profile ships
# /etc/skel/.config/hypr/config/*.lua, and Omarchy ships its own skel tree.
# omarchy-reinstall-configs replays whatever ends up there over $HOME.
SKEL_HYPR_FILES=false
if compgen -G "$(host_path /etc/skel)/.config/hypr/*" >/dev/null 2>&1; then
    SKEL_HYPR_FILES=true
fi

# Paths this script owns or reads later; defined here so --verify-only can
# run the assertion suite without executing any of the install steps.
ZZ_HOOKS_CONF=/etc/mkinitcpio.conf.d/zz-cachyos-keep-hooks.conf
LIMINE_DEFAULT=/etc/default/limine
SNAPPER_CONFIG=/etc/snapper/configs/root
SNAPPER_CONFD=/etc/conf.d/snapper
FAILLOCK_CONF=/etc/security/faillock.conf
OMARCHY_FAILLOCK_SRC=/usr/share/omarchy/etc-overrides/security-faillock.conf
# The guard hook ships in the SYSTEM hook directory, not /etc/pacman.d/hooks
# (`pacman -Ql omarchy`), which is why a same-named file in /etc/pacman.d/
# hooks (or a later HookDir) can override it and why pacman -Qkk stays clean.
UPDATE_GUARD_HOOK=/usr/share/libalpm/hooks/00-omarchy-update-guard.hook
OMOCACHY_HOOK_DIR=/etc/pacman.d/hooks-omocachy
OMARCHY_ISO_CLOSURE=(
    cups avahi docker power-profiles-daemon kernel-modules-hook
    ufw ufw-docker bluez bluez-utils plocate
)
APPLY_REQUIREMENTS=(
    "unit:cups.service=cups"
    "unit:avahi-daemon.service=avahi"
    "unit:linux-modules-cleanup.service=kernel-modules-hook"
    "unit:docker.socket=docker"
    "unit:power-profiles-daemon.service=power-profiles-daemon"
    "unit:sddm.service=sddm"
    "unit:NetworkManager.service=networkmanager"
    "unit:ufw.service=ufw"
    "unit:bluetooth.service=bluez"
    "cmd:ufw=ufw"
    "cmd:ufw-docker=ufw-docker"
    "cmd:updatedb=plocate"
)

unit_exists() {
    systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .
}

check_apply_requirements() {
    local req kind name pkg missing=()
    for req in "${APPLY_REQUIREMENTS[@]}"; do
        kind="${req%%:*}"; name="${req#*:}"; pkg="${name#*=}"; name="${name%%=*}"
        case "$kind" in
            unit) unit_exists "$name" || missing+=("$name (package: $pkg)") ;;
            cmd)  command -v "$name" &>/dev/null || missing+=("$name (package: $pkg)") ;;
        esac
    done
    if ((${#missing[@]})); then
        printf 'Missing apply-system prerequisite: %s\n' "${missing[@]}" >&2
        return 1
    fi
    return 0
}
# Every Port an sshd is configured to listen on: the main config plus its
# drop-ins (a drop-in is the normal shape). One awk, no pipeline and no grep:
# a stock sshd_config has only `#Port 22`, and a grep that matches nothing
# exits 1, which under `set -e` inside a process substitution is a failure
# this function has no business producing.
ssh_ports() {
    local f p ports=()
    shopt -s nullglob
    for f in "$(host_path /etc/ssh/sshd_config)" "$(host_path /etc/ssh/sshd_config.d)"/*.conf; do
        [[ -r $f ]] || continue
        while read -r p; do
            [[ -n $p ]] && ports+=("$p")
        done < <(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }' "$f")
    done
    shopt -u nullglob
    ((${#ports[@]})) || ports=(22)
    printf '%s\n' "${ports[@]}" | sort -u
}

SSHD_PRESENT=false
if svc_enabled sshd.service || svc_enabled sshd.socket; then
    SSHD_PRESENT=true
elif [[ -n $SYSROOT ]] && pkg_installed openssh && [[ -f $(host_path /etc/ssh/sshd_config) ]]; then
    # No service manager to ask under a sysroot: an installed openssh with a
    # config is the closest honest answer.
    SSHD_PRESENT=true
fi


PACMAN_HOOK_DIR=/etc/pacman.d/hooks
SNAPPER_BACKUP=""
SNAPPER_CONFD_BACKUP=""
OS_RELEASE_BACKUP=""
NSSWITCH_BACKUP=""
FAILLOCK_BACKUP=""
MIRRORLIST_BACKUP=""
LIMINE_CONF_BACKUP=""
PACMAN_CONF_BACKUP=""

# The initramfs rebuild command: /usr/local/bin/mkinitcpio
# (limine-mkinitcpio-hook) is an interactive wrapper that prompts after -P and
# would hang under --yes, so a non-Limine machine uses the absolute binary.
if [[ $BOOTLOADER == "limine" ]]; then
    INITRAMFS_REBUILD="limine-mkinitcpio"
else
    INITRAMFS_REBUILD="/usr/bin/mkinitcpio -P"
fi

decide is_cachyos "$IS_CACHYOS"
decide reapply "$REAPPLY"
decide bootloader "$BOOTLOADER"
decide bootloader_source "$BOOTLOADER_SOURCE"
decide luks "$LUKS_DETECTED"
decide cmdline_crypt "$CMDLINE_CRYPT"
decide captured_hooks "$CURRENT_HOOKS"
decide captured_flavour "$CAPTURED_FLAVOUR"
decide merged_hooks "$MERGED_HOOKS"
decide initramfs_rebuild "$INITRAMFS_REBUILD"
decide skel_hypr_files "$SKEL_HYPR_FILES"
decide boot_hook_policy "$([[ $BOOTLOADER == limine ]] && echo limine-native || echo hookdir-override)"
decide skip_user_configs "$SKIP_USER_CONFIGS"
decide skel_replay "$($SKIP_USER_CONFIGS && echo skipped || echo yes)"
decide refresh_limine "$(if $SKIP_USER_CONFIGS; then echo skipped-user-configs; elif [[ $BOOTLOADER == limine ]]; then echo yes-restore-cachyos-conf; else echo skipped-not-limine; fi)"
decide provision_user "$($SKIP_USER_CONFIGS && echo skipped || echo yes)"
decide autologin "$AUTOLOGIN"

echo "Plan summary:"
echo "  CachyOS system:            $IS_CACHYOS"
echo "  Re-apply (omarchy present): $REAPPLY"
echo "  Bootloader:                $BOOTLOADER${BOOTLOADER_SOURCE:+ ($BOOTLOADER_SOURCE)}"
echo "  LUKS detected:             $LUKS_DETECTED (cmdline unlock style: $CMDLINE_CRYPT)"
echo "  Current mkinitcpio HOOKS:  ($CURRENT_HOOKS)"
echo "  Initramfs flavour:         $CAPTURED_FLAVOUR"
echo "  Merged HOOKS (predicted):  ($MERGED_HOOKS)"
echo "  Initramfs rebuild command: $INITRAMFS_REBUILD"
echo "  /etc/os-release ID:        $PRE_OS_RELEASE_ID"
echo "  /etc/skel has hypr config: $SKEL_HYPR_FILES"
echo "  GPU vendor:                $GPU_TYPE"
echo "  [omarchy] repo present:    $REPO_ALREADY_PRESENT"
echo "  snapper-timeline.timer:    $($SNAPPER_TIMELINE_WAS_ENABLED && echo enabled || echo disabled)"
echo "  iwd.service enabled:       $IWD_WAS_ENABLED (NetworkManager wifi.backend=iwd: $NM_BACKEND_IWD)"
echo "  Target user:               $USER"
echo "  Skip user configs:         $SKIP_USER_CONFIGS"
echo "  SDDM autologin:            $AUTOLOGIN"
echo ""

# ---------------------------------------------------------------------------
# Assertion suite (also the whole of --verify-only)
# ---------------------------------------------------------------------------

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
check_faillock() {
    # Decision: Omarchy's faillock.conf is ACCEPTED, not restored -- it is
    # half of a pair with install/config/increase-lockout-limit.sh, which
    # edits /etc/pam.d/{system-auth,sddm-autologin} to match deny=10.
    # Restoring CachyOS's file alone would leave PAM and faillock disagreeing.
    [[ ! -f $OMARCHY_FAILLOCK_SRC ]] || cmp -s "$FAILLOCK_CONF" "$OMARCHY_FAILLOCK_SRC"
}
check_hooks() {
    [[ -f $ZZ_HOOKS_CONF ]] || return 1
    local now crypt
    now="$(effective_hooks)"
    # Bootable-shaped: the encryption hook is present and is the flavour the
    # kernel command line actually asks for.
    if $LUKS_DETECTED; then
        crypt="$(hooks_crypt_flavour "$now")"
        [[ $crypt != none ]] || return 1
        if [[ $CMDLINE_CRYPT != none ]]; then
            [[ $crypt == "$CMDLINE_CRYPT" ]] || return 1
        else
            [[ $crypt == "$CAPTURED_FLAVOUR" ]] || return 1
        fi
    fi
    has_word plymouth "$now" || return 1
    has_word btrfs-overlayfs "$now" || has_word sd-btrfs-overlayfs "$now"
}
check_limine_hook_pkg() {
    # Nothing this script does modifies a file owned by
    # limine-mkinitcpio-hook: the non-Limine override lives in its own
    # HookDir. -Qkk must therefore be clean on every bootloader.
    pkg_installed limine-mkinitcpio-hook || return 0
    [[ -z "$(pacman -Qkk limine-mkinitcpio-hook 2>&1 >/dev/null | grep '^warning: ' || true)" ]]
}
check_hookdir_override() {
    [[ $BOOTLOADER != "limine" ]] || return 0
    grep -qxF "HookDir = $PACMAN_HOOK_DIR/" /etc/pacman.conf || return 1
    grep -qxF "HookDir = $OMOCACHY_HOOK_DIR/" /etc/pacman.conf || return 1
    [[ -f $OMOCACHY_HOOK_DIR/90-mkinitcpio-install.hook ]] || return 1
    grep -q '/usr/share/libalpm/scripts/mkinitcpio install' "$OMOCACHY_HOOK_DIR/90-mkinitcpio-install.hook" || return 1
    # The PATH pin is what keeps /usr/local/bin/mkinitcpio (the
    # limine-mkinitcpio-hook shim) out of the alpm script's unqualified
    # `mkinitcpio` lookup. Without it the hook still rebuilds the initramfs
    # and then runs limine-mkinitcpio anyway.
    grep -q '^Exec = /usr/bin/env PATH=/usr/bin ' "$OMOCACHY_HOOK_DIR/90-mkinitcpio-install.hook"
}
# Can this check reach root without a prompt? Probed on its own, because the
# alternative -- inferring it from the exit status of the command being run --
# cannot tell "no passwordless sudo" from "the command found nothing", which
# is the SUCCESS case for most of these. `ls` with no matches exits 2, so the
# checks below used to announce "/boot is not readable" on a perfectly
# readable /boot and pass for the wrong reason (found on the GRUB guest).
can_sudo_quietly() {
    sudo -n true 2>/dev/null
}

check_no_limine_artifacts() {
    # End-state form of the check above: on a machine Limine does not boot,
    # no kernel transaction should have produced a Limine config or UKI.
    [[ $BOOTLOADER != "limine" ]] || return 0
    if ! can_sudo_quietly; then
        echo "      (needs passwordless sudo to inspect /boot; not treated as a failure)"
        return 0
    fi
    local found
    found="$(sudo -n sh -c 'ls -1 /boot/limine.conf /boot/limine.conf.old /boot/EFI/Linux/omarchy_*.efi 2>/dev/null' || true)"
    [[ -z $found ]] || { echo "      Limine artefacts on a $BOOTLOADER machine: $(tr '\n' ' ' <<<"$found")" >&2; return 1; }
}
check_limine_service() {
    [[ $BOOTLOADER == "limine" ]] || ! systemctl is-enabled --quiet limine-snapper-sync.service 2>/dev/null
}
check_limine_default() {
    [[ $BOOTLOADER == "limine" ]] || return 0
    grep -qE '^\s*ENABLE_UKI=' "$LIMINE_DEFAULT" 2>/dev/null || return 1
    grep -qE '^\s*BOOT_ORDER=' "$LIMINE_DEFAULT" 2>/dev/null || return 1
    ! $IS_CACHYOS || grep -qE '^\s*TARGET_OS_NAME=' "$LIMINE_DEFAULT" 2>/dev/null
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
    # --verify-only never takes a backup, so $SNAPPER_BACKUP is empty there and
    # the old form returned success whenever no backup had been taken, printing
    # PASS for a check that had compared nothing. Fall back to the newest backup
    # a previous full run left on disk.
    local backup="$SNAPPER_BACKUP" newest
    if [[ -z $backup ]]; then
        newest="$(ls -1t /etc/snapper/configs/root.omarchy-quattro-backup-* 2>/dev/null | head -n1 || true)"
        if [[ -z $newest ]]; then
            echo "      (no pre-install snapper backup on this machine to compare against; not verified)"
            return 0
        fi
        backup="$newest"
    fi
    cmp -s "$backup" "$SNAPPER_CONFIG"
}
check_update_guard() {
    # Not a failure -- an expectation. The omarchy package installs this
    # PreTransaction AbortOnFail hook and every later `pacman -Syu` hits it.
    [[ -f $UPDATE_GUARD_HOOK ]]
}
check_cli() {
    command -v omarchy &>/dev/null
}
check_iso_closure() {
    # The nine (plus avahi) packages apply-system needs but omarchy does not
    # depend on. A missing one here means the next `omarchy update` -- or the
    # next apply -- aborts the way the CachyOS guest did.
    local p missing=()
    for p in "${OMARCHY_ISO_CLOSURE[@]}"; do
        pkg_installed "$p" || missing+=("$p")
    done
    ((${#missing[@]} == 0)) || { echo "      missing: ${missing[*]}" >&2; return 1; }
}
check_apply_units() {
    check_apply_requirements 2>/dev/null
}
check_ufw_ssh() {
    # Only meaningful where an sshd is enabled and ufw exists.
    command -v ufw &>/dev/null || return 0
    $SSHD_PRESENT || return 0
    # `ufw status` is the wrong source: apply-system's firewall.sh sets
    # ENABLED=yes and enables the unit without starting it, so until the next
    # boot ufw reports "Status: inactive" and lists NO rules even though the
    # allow was accepted and is in /etc/ufw/user.rules. `ufw show added`
    # reports the configured rules in either state (GRUB CachyOS guest: this
    # was the suite's only FAIL, and it was wrong).
    local added port
    if ! can_sudo_quietly; then
        echo "      (needs passwordless sudo to read 'ufw show added'; not treated as a failure)"
        return 0
    fi
    added="$(sudo -n ufw show added 2>/dev/null || true)"
    for port in $(ssh_ports); do
        grep -qE "allow[[:space:]]+${port}(/tcp)?\b" <<<"$added" || return 1
    done
}
check_omarchy_path_env() {
    # Either dev-link owns it, or /etc/environment carries it for every shell.
    [[ -f /etc/omarchy.conf ]] || grep -qE '^\s*OMARCHY_PATH=' /etc/environment 2>/dev/null
}
check_limine_cmdline_args() {
    # On a LUKS Limine host, omarchy-settings' drop-in appends
    # `initramfs_async=0` with +=; its upstream comment says an encrypted boot
    # otherwise falls back to an unthemed text LUKS prompt. A plain
    # KERNEL_CMDLINE[default]= anywhere later (/etc/default/limine loads last)
    # silently replaces it, so check the GENERATED entries, not the inputs.
    [[ $BOOTLOADER == "limine" ]] || return 0
    $LUKS_DETECTED || return 0
    pkg_installed omarchy-settings || return 0
    local generated
    if ! can_sudo_quietly; then
        echo "      (needs passwordless sudo to read /boot/limine.conf; not treated as a failure)"
        return 0
    fi
    generated="$(sudo -n cat /boot/limine.conf 2>/dev/null || true)"
    if [[ -z $generated ]]; then
        echo "      (no readable /boot/limine.conf to inspect; not treated as a failure)"
        return 0
    fi
    if grep -q 'initramfs_async=0' <<<"$generated"; then
        return 0
    fi
    echo "      /boot/limine.conf has no initramfs_async=0: something assigned KERNEL_CMDLINE with '=' and dropped omarchy-settings' += additions. Expect an unthemed text LUKS prompt." >&2
    return 1
}

run_assertion_suite() {
    step "Assertion suite"
    assert "[omarchy] present in /etc/pacman.conf, and the CachyOS repos still present on a CachyOS host" check_repos
    assert "/etc/os-release says ID=cachyos on a CachyOS host (omarchy-settings scriptlet reverted)" check_os_release
    assert "/etc/security/faillock.conf is Omarchy's (accepted deliberately: PAM is edited to match)" check_faillock
    assert "$ZZ_HOOKS_CONF exists and the effective HOOKS are bootable-shaped (encryption hook matches the cmdline flavour, plymouth and an overlayfs hook present)" check_hooks
    assert "pacman -Qkk limine-mkinitcpio-hook is clean (no packaged file was edited)" check_limine_hook_pkg
    assert "non-limine machine overrides the limine pacman hooks from $OMOCACHY_HOOK_DIR and keeps stock initramfs rebuilds" check_hookdir_override
    assert "non-limine machine has no Limine config or UKI on /boot (the /usr/local/bin/mkinitcpio shim did not run limine-mkinitcpio)" check_no_limine_artifacts
    assert "non-limine machine has limine-snapper-sync.service disabled" check_limine_service
    assert "$LIMINE_DEFAULT carries the ENABLE_UKI/BOOT_ORDER/TARGET_OS_NAME overrides on a Limine host" check_limine_default
    assert "sddm enabled; NetworkManager enabled" check_services
    assert "/etc/sddm.conf absent (sddm.conf.d drop-ins take effect)" check_sddm_conf
    assert "/etc/snapper/configs/root matches the pre-install backup" check_snapper
    assert "the omarchy update guard hook is installed (direct 'pacman -Syu' will abort from here on)" check_update_guard
    assert "the v4 CLI entrypoint (omarchy) is present" check_cli
    assert "the ISO package closure apply-system needs is installed (${OMARCHY_ISO_CLOSURE[*]})" check_iso_closure
    assert "every unit and command the apply stages call exists" check_apply_units
    assert "ssh is allowed through ufw where an sshd is enabled (Omarchy's firewall.sh denies all incoming)" check_ufw_ssh
    assert "OMARCHY_PATH is exported outside \$HOME (/etc/environment), so 'omarchy update' works on a --skip-user-configs host" check_omarchy_path_env
    assert "the generated Limine entries keep omarchy-settings' initramfs_async=0 on a LUKS host (nothing replaced KERNEL_CMDLINE with '=')" check_limine_cmdline_args

    if $ASSERT_FAILED; then
        echo "" >&2
        echo "One or more post-install assertions failed. See FAIL lines above." >&2
        return 1
    fi
    return 0
}

if $VERIFY_ONLY; then
    run_assertion_suite || {
        echo ""
        echo "Verify-only run FAILED. Log: $LOG_FILE" >&2
        exit 1
    }
    echo ""
    echo "Verify-only run complete. Log: $LOG_FILE"
    exit 0
fi

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

step "Repo + keyring"

# Bootstraps trust for the very first transaction that fetches omarchy-keyring
# itself (its post_install runs pacman-key --populate omarchy from there on).
# A re-apply already has the key, and a keyserver hiccup must not abort it
# (seen on the CachyOS guest: "keyserver receive failed"); fall back through
# two public keyservers before giving up. The pacman keyring cannot be
# represented in a sysroot fixture, so the probe is skipped under the test
# seam and the dry run prints the fetch it would perform.
if [[ -z $SYSROOT ]] && pacman-key --list-keys "$OMARCHY_KEY_ID" &>/dev/null; then
    echo "Omarchy packaging key $OMARCHY_KEY_ID already in the pacman keyring."
elif $DRY_RUN; then
    run_root pacman-key --recv-keys "$OMARCHY_KEY_ID"
else
    key_fetched=false
    for ks in "" hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
        key_args=()
        [[ -n $ks ]] && key_args=("--keyserver" "$ks")
        if run_root pacman-key --recv-keys "$OMARCHY_KEY_ID" "${key_args[@]}"; then
            key_fetched=true
            break
        fi
        echo "Warning: could not fetch $OMARCHY_KEY_ID from ${ks:-the default keyserver}; trying the next." >&2
    done
    $key_fetched || { echo "Error: could not fetch the Omarchy packaging key from any keyserver." >&2; exit 1; }
fi
run_root pacman-key --lsign-key "$OMARCHY_KEY_ID"

if $REPO_ALREADY_PRESENT; then
    echo "[omarchy] repo already present in /etc/pacman.conf, skipping append."
else
    printf '\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$OMARCHY_REPO_SERVER" |
        append_root_file /etc/pacman.conf
fi

# ---------------------------------------------------------------------------
# Boot-hook policy for non-Limine machines.
#
# This runs BEFORE the pacman transaction, because the damage happens inside
# it: limine-mkinitcpio-hook arrives as an omarchy dependency on every
# machine, and its hooks fire in the same transaction that installs it --
# 80-limine-efi-deploy.hook runs `limine-install`, which deploys the Limine
# EFI binary onto the ESP of a GRUB or systemd-boot machine.
#
# The override is a THIRD HookDir, not an edit of any packaged file:
#   - /etc/pacman.d/hooks/90-mkinitcpio-install.hook is owned by
#     limine-mkinitcpio-hook, and because it lives in /etc/pacman.d/hooks it
#     already shadows mkinitcpio's own /usr/share/libalpm/hooks hook of the
#     same name. Writing over it (or no-op'ing it) either disables initramfs
#     regeneration entirely -- an unbootable machine after the next kernel
#     upgrade -- or gets reverted on the next upgrade, and pre-creating it
#     would make pacman abort the install with a file conflict.
#   - pacman.conf(5): HookDir may be given more than once, "with hooks in
#     later directories taking precedence over hooks in earlier directories".
#     Specifying it at all replaces the /etc/pacman.d/hooks default, so both
#     lines are written, in order.
# Result: no packaged file is touched (`pacman -Qkk limine-mkinitcpio-hook`
# stays clean), stock initramfs rebuilds keep happening, and the Limine EFI
# deployment/entry hooks are inert. Restore path: delete
# /etc/pacman.d/hooks-omocachy and the two HookDir lines from /etc/pacman.conf.
# ---------------------------------------------------------------------------

ensure_hookdir_lines() {
    local conf tmp
    conf="$(host_path /etc/pacman.conf)"
    if grep -qxF "HookDir = $OMOCACHY_HOOK_DIR/" "$conf" 2>/dev/null; then
        echo "HookDir override already registered in /etc/pacman.conf."
        return 0
    fi
    if grep -qE '^\s*HookDir\s*=' "$conf" 2>/dev/null; then
        # The file already sets HookDir, so pacman's /etc/pacman.d/hooks
        # default is already replaced by whatever it lists. Insert ours
        # directly after the LAST existing HookDir line: same section, and
        # later directories win.
        echo "Inserting \"HookDir = $OMOCACHY_HOOK_DIR/\" after the last existing HookDir line in /etc/pacman.conf."
        if $DRY_RUN; then
            echo "DRYRUN: rewrite /etc/pacman.conf with that one line added"
        else
            tmp="$(mktemp)"
            awk -v ours="HookDir = $OMOCACHY_HOOK_DIR/" '
                { line[NR] = $0; if ($0 ~ /^[[:space:]]*HookDir[[:space:]]*=/) last = NR }
                END { for (i = 1; i <= NR; i++) { print line[i]; if (i == last) print ours } }
            ' "$conf" >"$tmp"
            run_root cp -f "$tmp" /etc/pacman.conf
            rm -f "$tmp"
        fi
    else
        # No HookDir at all: pacman's default is the single directory
        # /etc/pacman.d/hooks, and naming any HookDir replaces that default,
        # so both lines are written -- in this order.
        run_root sed -i "/^\[options\]/a HookDir = $PACMAN_HOOK_DIR/\nHookDir = $OMOCACHY_HOOK_DIR/" /etc/pacman.conf
    fi
    if ! $DRY_RUN && ! grep -qxF "HookDir = $OMOCACHY_HOOK_DIR/" /etc/pacman.conf; then
        echo "Error: could not register $OMOCACHY_HOOK_DIR in /etc/pacman.conf (no [options] section?). Refusing to continue: the limine pacman hooks would run on a $BOOTLOADER machine." >&2
        exit 1
    fi
}

write_inert_hook() {
    local name="$1"
    write_root_file "$OMOCACHY_HOOK_DIR/$name" <<EOF
# Written by omocachy install-omarchy-quattro.sh: overrides the
# limine-mkinitcpio-hook hook of the same name on a machine whose bootloader
# is $BOOTLOADER, not Limine. This file shadows it by living in a HookDir
# that pacman reads later; the packaged hook itself is untouched.
# Delete this file (and the HookDir line in /etc/pacman.conf) to restore
# stock behaviour.
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
}

apply_boot_hook_policy() {
    if [[ $BOOTLOADER == "limine" ]]; then
        echo "limine is the active bootloader; leaving Omarchy's limine integration (limine-snapper-sync, limine-mkinitcpio-hook) active."
        return 0
    fi
    echo "Active bootloader is '$BOOTLOADER', not limine; shadowing the limine pacman hooks from $OMOCACHY_HOOK_DIR."
    run_root mkdir -p "$OMOCACHY_HOOK_DIR"
    ensure_hookdir_lines

    # Stock initramfs rebuilds: a copy of mkinitcpio's own hook, which the
    # limine variant in /etc/pacman.d/hooks would otherwise shadow. The two
    # differ only in the Exec and in one Target (vmlinuz vs pkgbase).
    #
    # The Exec is rewritten, and that rewrite is load-bearing.
    # /usr/share/libalpm/scripts/mkinitcpio calls `mkinitcpio "${args[@]}"`
    # UNQUALIFIED, and limine-mkinitcpio-hook ships a PATH shim at
    # /usr/local/bin/mkinitcpio which wins that lookup. The shim runs the real
    # binary and then, seeing -p in the args, prompts "run limine-mkinitcpio
    # now? [Y/n]" — with stdin at EOF inside a pacman hook the empty answer
    # takes the yes branch, so a GRUB machine gets /boot/limine.conf and a
    # Limine UKI in /boot/EFI/Linux written on every kernel transaction
    # (observed on the GRUB CachyOS guest: deleted both, reinstalled the
    # kernel, both came back). Pinning PATH to /usr/bin for the hook keeps the
    # shim out of the lookup without touching the packaged file.
    local stock=/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
    local override="$OMOCACHY_HOOK_DIR/90-mkinitcpio-install.hook"
    if [[ -f $(host_path "$stock") ]]; then
        run_root cp -f "$stock" "$override"
        run_root sed -i \
            's|^Exec = /usr/share/libalpm/scripts/mkinitcpio |Exec = /usr/bin/env PATH=/usr/bin /usr/share/libalpm/scripts/mkinitcpio |' \
            "$override"
        if ! $DRY_RUN && ! grep -q '^Exec = /usr/bin/env PATH=/usr/bin ' "$override"; then
            echo "Error: could not pin PATH in $override (upstream changed the Exec line?)." >&2
            echo "Without it /usr/local/bin/mkinitcpio (limine-mkinitcpio-hook's shim) runs limine-mkinitcpio on every kernel upgrade of this $BOOTLOADER machine." >&2
            exit 1
        fi
    else
        echo "Warning: $stock not found (mkinitcpio not installed?); this machine will have NO initramfs rebuild hook once limine-mkinitcpio-hook lands. Install mkinitcpio first." >&2
    fi

    local base
    for base in 60-limine-mkinitcpio-remove-pre.hook 80-limine-efi-deploy.hook 90-limine-mkinitcpio-remove-post.hook; do
        write_inert_hook "$base"
    done
}

step "Boot-hook policy"
apply_boot_hook_policy

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
#     cp -f .../etc-overrides/os-release /etc/os-release`, the same for
#     nsswitch.conf and /etc/security/faillock.conf, on every install AND
#     upgrade. The backups and the persistent restore hook below must exist
#     before that first scriptlet fires.
# The pacman.conf backup is taken here, after the [omarchy] stanza and the
# HookDir lines are in place, so restoring it later keeps both.
# ---------------------------------------------------------------------------

step "Pre-install reconciliation"

backup_etc_file() {
    local src="$1" var="$2"
    if [[ -f $(host_path "$src") ]]; then
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

backup_etc_file "$SNAPPER_CONFIG" SNAPPER_BACKUP
backup_etc_file "$SNAPPER_CONFD" SNAPPER_CONFD_BACKUP
backup_etc_file /etc/os-release OS_RELEASE_BACKUP
backup_etc_file /etc/nsswitch.conf NSSWITCH_BACKUP
# faillock: backed up but NOT restored. omarchy-settings' etc-overrides copy
# is paired with install/config/increase-lockout-limit.sh, which rewrites
# /etc/pam.d/system-auth and /etc/pam.d/sddm-autologin to the same deny=10
# policy; restoring CachyOS's file alone would leave PAM and faillock
# disagreeing about the lockout. Restore path if you disagree:
#   sudo cp -a /etc/security/faillock.conf.$BACKUP_SUFFIX /etc/security/faillock.conf
backup_etc_file "$FAILLOCK_CONF" FAILLOCK_BACKUP

# /boot is 0700 on Limine installs, so existence cannot be tested unprivileged;
# on a Limine machine $ESP_PATH/limine.conf must exist for limine-update to
# work at all, so a failed copy is worth a warning rather than an abort.
if [[ $BOOTLOADER == "limine" ]]; then
    LIMINE_CONF_BACKUP="/etc/limine.conf.$BACKUP_SUFFIX"
    run_root cp -a /boot/limine.conf "$LIMINE_CONF_BACKUP" ||
        { echo "Warning: could not back up /boot/limine.conf." >&2; LIMINE_CONF_BACKUP=""; }
fi

# Persist the CachyOS identity across omarchy-settings upgrades. The scriptlet
# re-fires on every upgrade, so a one-off restore is not enough: a
# PostTransaction hook copies the preserved files back after each one. The
# preserved copies are taken once, from a host that is not yet ID=omarchy.
# ID=omarchy is not cosmetic: CachyOS's own tooling (cachyos-* scripts,
# chwd profiles, its update helpers) keys off it and mis-detects the host.
PRESERVE_DIR=/etc/cachyos-preserved
PRESERVE_HOOK=/etc/pacman.d/hooks/zz-cachyos-preserve-etc.hook
if [[ -f $(host_path "$PRESERVE_DIR/os-release") ]]; then
    echo "Keeping existing $PRESERVE_DIR copies (os-release, nsswitch.conf)."
elif [[ $PRE_OS_RELEASE_ID == "omarchy" ]]; then
    echo "Warning: /etc/os-release already says ID=omarchy and no $PRESERVE_DIR copy exists; nothing pre-Omarchy left to preserve, skipping the preserve hook." >&2
else
    run_root mkdir -p "$PRESERVE_DIR"
    run_root cp -a /etc/os-release "$PRESERVE_DIR/os-release"
    run_root cp -a /etc/nsswitch.conf "$PRESERVE_DIR/nsswitch.conf"
fi
if [[ -f $(host_path "$PRESERVE_DIR/os-release") || $PRE_OS_RELEASE_ID != "omarchy" ]]; then
    run_root mkdir -p /etc/pacman.d/hooks
    write_root_file "$PRESERVE_HOOK" <<EOF
# Written by omocachy install-omarchy-quattro.sh.
# omarchy-settings' post_install/post_upgrade scriptlet (_etc_overrides_apply)
# does \`rm -f /etc/os-release; cp -f .../etc-overrides/os-release /etc/os-release\`
# and \`cp -f .../etc-overrides/nsswitch.conf /etc/nsswitch.conf\` on every
# install and upgrade. Put the CachyOS files back after each such transaction.
# faillock.conf is deliberately NOT listed: Omarchy's copy is paired with its
# PAM edits. Restore path: delete this hook and $PRESERVE_DIR.
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
# mkinitcpio sources it last and it sees the HOOKS array Omarchy set (plus any
# HOOKS+= a lexically earlier drop-in such as omarchy_resume.conf added).
# The transform, and the reasoning behind each mapping, live in
# bin/lib/hooks-merge.sh.
if [[ -n $CURRENT_HOOKS ]]; then
    run_root mkdir -p /etc/mkinitcpio.conf.d
    render_keep_hooks_conf "$CURRENT_HOOKS" | write_root_file "$ZZ_HOOKS_CONF"
    echo "Predicted merged HOOKS against omarchy-settings 4.0.2's array: ($MERGED_HOOKS)"
else
    echo "Warning: could not determine current mkinitcpio HOOKS; skipping $ZZ_HOOKS_CONF." >&2
fi

# Limine defaults. omarchy-settings ships /etc/limine-entry-tool.d/
# omarchy-defaults.conf (TARGET_OS_NAME="Omarchy", BOOT_ORDER="*, *fallback,
# Snapshots") and omarchy-uki.conf (ENABLE_UKI=yes). limine-entry-tool's
# load_config (/usr/lib/limine/limine-common-functions:99-129) loads
# /usr/share/limine-entry-tool.d, then /etc/limine-entry-tool.conf, then
# /etc/limine-entry-tool.d/*.conf, and /etc/default/limine LAST, so keys set
# there win. That is why the overrides go here instead of editing the
# packaged drop-ins, which the next omarchy-settings upgrade would restore.
# On CachyOS the "Omarchy" OS name mismatches the /+CachyOS entry and makes
# limine-snapper-sync abort, UKI mode changes the boot layout under a running
# CachyOS, and the ISO BOOT_ORDER drops the *lts entry (mroboff #74). Only
# keys the file does not already set are appended, so an existing choice is
# left alone. TARGET_OS_NAME is only known for CachyOS.
if [[ $BOOTLOADER == "limine" ]]; then
    limine_key_set() {
        [[ -r $(host_path "$LIMINE_DEFAULT") ]] && grep -qE "^\s*$1=" "$(host_path "$LIMINE_DEFAULT")"
    }
    limine_block=""
    if $IS_CACHYOS; then
        limine_key_set TARGET_OS_NAME || limine_block+='TARGET_OS_NAME="CachyOS"'$'\n'
    elif ! limine_key_set TARGET_OS_NAME; then
        echo "Note: not CachyOS, so TARGET_OS_NAME is not written to $LIMINE_DEFAULT; set it yourself if limine-snapper-sync cannot find your OS entry."
    fi
    limine_key_set ENABLE_UKI || limine_block+='ENABLE_UKI=no'$'\n'
    if ! limine_key_set BOOT_ORDER; then
        if pkg_installed linux-cachyos-lts || pkg_installed linux-lts; then
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
            printf '# Restore path: delete this block.\n'
            printf '#\n'
            printf '# If you ever add a KERNEL_CMDLINE line here, it MUST use += and not =.\n'
            printf '# This file loads last, and a plain assignment REPLACES what the\n'
            printf '# omarchy-settings drop-in appends with += -- including initramfs_async=0,\n'
            printf '# which is what keeps an encrypted boot on the themed Plymouth LUKS prompt\n'
            printf '# instead of dropping to an unthemed text one, and the splash arguments.\n'
            printf '#   KERNEL_CMDLINE[default]+=" your args here"\n'
            printf '%s# <<< omocachy <<<\n' "$limine_block"
        } | append_root_file "$LIMINE_DEFAULT"
    else
        echo "$LIMINE_DEFAULT already sets TARGET_OS_NAME, ENABLE_UKI and BOOT_ORDER; leaving it alone."
    fi
    decide limine_default_block "$(printf '%s' "$limine_block" | tr '\n' ';')"

    # /etc/default/limine loading last cuts both ways. omarchy-settings'
    # drop-in APPENDS its kernel arguments
    # (`KERNEL_CMDLINE[default]+=" quiet splash loglevel=0 ... initramfs_async=0"`),
    # so a plain `KERNEL_CMDLINE[default]=` in /etc/default/limine silently
    # replaces them: the regenerated entries lose Plymouth's splash arguments
    # and the initramfs_async=0 workaround whose own comment says an encrypted
    # boot otherwise falls back to an unthemed text LUKS prompt. Observed on
    # the CachyOS guest. Not auto-fixed: rewriting someone's kernel command
    # line is exactly the class of change that does not get a second try.
    if grep -qE '^\s*KERNEL_CMDLINE\[[^]]*\]\s*=' "$(host_path "$LIMINE_DEFAULT")" 2>/dev/null; then
        echo "Warning: $LIMINE_DEFAULT assigns KERNEL_CMDLINE with '=', and it loads after omarchy-settings' drop-in, which uses '+='." >&2
        echo "         Omarchy's own arguments (quiet splash loglevel=0 ... initramfs_async=0) will be dropped from regenerated entries." >&2
        echo "         Change that line to '+=' or add those arguments yourself; initramfs_async=0 is what keeps the LUKS prompt themed." >&2
        decide limine_cmdline_style "assign-overrides-omarchy"
    elif grep -qE '^\s*KERNEL_CMDLINE\[[^]]*\]\s*\+=' "$(host_path "$LIMINE_DEFAULT")" 2>/dev/null; then
        decide limine_cmdline_style "append"
    else
        decide limine_cmdline_style "unset"
    fi
else
    decide limine_default_block "not-limine"
fi

# SDDM: /etc/sddm.conf (if present) outranks every file in /etc/sddm.conf.d/,
# and Omarchy's SDDM theme/session config ships as package-owned
# sddm.conf.d/*.conf files. Remove any stale /etc/sddm.conf before those
# land so they actually take effect (PR #28 / plan 006 rationale).
if [[ -f $(host_path /etc/sddm.conf) ]]; then
    echo "Removing stale /etc/sddm.conf so package-shipped sddm.conf.d drop-ins win."
    run_root rm -f /etc/sddm.conf
fi

# ---------------------------------------------------------------------------
# Install packages
#
# Including the ISO package closure. omarchy-apply-system's stages enable and
# call things the Omarchy ISO has already installed but the `omarchy` package
# does not depend on. On a CachyOS host each one is a hard abort, verified on
# a real CachyOS 260809 guest (2026-09-07), in this order — one per re-run:
#   install/config/enable-services.sh   "Unit cups.service does not exist"        -> cups
#                                       (same list: docker.socket, power-profiles-daemon.service)
#   install/config/enable-services.sh   "Unit linux-modules-cleanup.service does not exist"
#                                                                                 -> kernel-modules-hook
#   install/config/firewall.sh          "ufw: command not found" (exit 127)       -> ufw
#   install/config/firewall.sh          empty `command -v ufw-docker`             -> ufw-docker
#   install/hardware/bluetooth.sh       "Unit bluetooth.service does not exist"   -> bluez, bluez-utils
#   install/post-install/localdb.sh     "updatedb: command not found" (exit 127)  -> plocate
# avahi-daemon.service is enabled by the same script; it happened to be present
# on the pristine guest, and is listed here so it cannot be the next surprise.
# ufw-docker lives in [omarchy], which is why this cannot run before the repo
# stanza is appended — it goes in the same transaction as the omarchy packages.
# ---------------------------------------------------------------------------

step "Installing omarchy packages"
# On a re-apply the omarchy package's 00-omarchy-update-guard.hook is already
# installed (PreTransaction, AbortOnFail); omarchy-update-pacman-guard:8 lets a
# direct -Syu through only with OMARCHY_ALLOW_DIRECT_PACMAN=1.
echo "Also installing the ISO package closure: ${OMARCHY_ISO_CLOSURE[*]}"
run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed --noconfirm \
    omarchy-settings omarchy omarchy-nvim "${OMARCHY_ISO_CLOSURE[@]}"
decide iso_closure "${OMARCHY_ISO_CLOSURE[*]}"

# ---------------------------------------------------------------------------
# Pre-apply gate
#
# Prove the units and commands the apply stages call exist, and say which
# package is missing if one does not, instead of letting omarchy-apply-system
# die halfway through with "Unit foo.service does not exist".
# ---------------------------------------------------------------------------


step "Pre-apply prerequisite gate"
if $DRY_RUN; then
    echo "DRYRUN: verify each unit/command omarchy-apply-system calls exists:"
    printf '    | %s\n' "${APPLY_REQUIREMENTS[@]}"
else
    if check_apply_requirements; then
        echo "All units and commands the apply stages call are present."
    else
        echo "Error: omarchy-apply-system would abort on the prerequisites listed above." >&2
        echo "Install the named packages and re-run; do not run apply-system without them." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# ssh survival
#
# install/config/firewall.sh does `ufw default deny incoming`, flips
# ENABLED=yes in /etc/ufw/ufw.conf and enables the unit — with NO ssh
# allowance anywhere. The rules load into the kernel as they are written, so
# an ssh session dies mid-apply, before any reboot (observed on the CachyOS
# guest; recovery needed the hypervisor console). Every ufw rule added before
# apply-system persists in /etc/ufw/user.rules, so the allowance is added
# here, ahead of it. Nothing is opened on a machine with no sshd.
# ---------------------------------------------------------------------------

step "Firewall (ssh survival)"
if $SSHD_PRESENT; then
    SSH_PORT_LIST="$(ssh_ports | tr '\n' ' ')"
    echo "!! An sshd is enabled on this machine and Omarchy's install/config/firewall.sh"
    echo "!! turns ufw on with 'default deny incoming' and no ssh rule. Allowing ssh now,"
    echo "!! before apply-system runs, so this run cannot lock you out: $SSH_PORT_LIST"
    for ssh_port in $SSH_PORT_LIST; do
        run_root ufw allow "$ssh_port/tcp"
    done
    decide ufw_ssh "allowed:$(echo "$SSH_PORT_LIST" | tr -s ' ' | sed 's/ $//' | tr ' ' ',')"
else
    echo "No sshd is enabled here, so nothing was opened. Note that Omarchy's"
    echo "install/config/firewall.sh will still enable ufw with 'default deny incoming':"
    echo "if you enable sshd later, run 'sudo ufw allow 22/tcp' BEFORE you rely on it."
    decide ufw_ssh "no-sshd"
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

step "Running omarchy-apply-system"
run_root omarchy-apply-system --install-user "$USER" --first-install

# ---------------------------------------------------------------------------
# Post-apply pacman reconciliation
#
# Ordered immediately after apply-system returns, and before GPU dispatch:
# install/post-install/pacman.sh (run inside apply-system) does
# `cp -f .../pacman-stable.conf /etc/pacman.conf` and the matching mirrorlist,
# wiping the CachyOS repos, the [omarchy] stanza and the HookDir lines in one
# go. amd-rocm.sh's own `sudo pacman -S rocm-core ...` call needs those repos
# back BEFORE it runs, so this cannot wait until the very end of the script.
# ---------------------------------------------------------------------------

step "Post-apply pacman.conf/mirrorlist reconciliation"
run_root cp -a "$PACMAN_CONF_BACKUP" /etc/pacman.conf
if [[ -n $MIRRORLIST_BACKUP ]]; then
    run_root cp -a "$MIRRORLIST_BACKUP" /etc/pacman.d/mirrorlist
fi
# Defense in depth: the backup already contains [omarchy] and (on a non-Limine
# machine) the HookDir lines, because it was taken after both were written.
# Re-check anyway, in case that invariant ever changes.
if $DRY_RUN; then
    echo "DRYRUN: ensure [omarchy] stanza and HookDir lines present in restored /etc/pacman.conf"
else
    if ! grep -qE '^\[omarchy\]' /etc/pacman.conf; then
        printf '\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$OMARCHY_REPO_SERVER" |
            append_root_file /etc/pacman.conf
    fi
    if [[ $BOOTLOADER != "limine" ]]; then
        ensure_hookdir_lines
    fi
fi
run_root pacman -Sy --noconfirm

# ---------------------------------------------------------------------------
# Post-apply /etc reconciliation
# ---------------------------------------------------------------------------

step "Post-apply /etc reconciliation"
# os-release/nsswitch.conf: the preserve hook above already put them back
# during the transaction when it applied; this covers the first run on a host
# where the hook was skipped, and is a no-op otherwise.
[[ -n $OS_RELEASE_BACKUP ]] && run_root cp -a "$OS_RELEASE_BACKUP" /etc/os-release
[[ -n $NSSWITCH_BACKUP ]] && run_root cp -a "$NSSWITCH_BACKUP" /etc/nsswitch.conf
# faillock.conf: Omarchy's version is accepted (see the backup comment above).
echo "Leaving Omarchy's $FAILLOCK_CONF in place (its PAM edits match it).${FAILLOCK_BACKUP:+ Backup: $FAILLOCK_BACKUP}"

# OMARCHY_PATH for every shell, not just the ones /etc/skel seeds.
#
# `omarchy update` calls omarchy-update-dev, whose line 7
# (`[[ $OMARCHY_PATH != "/usr/share/omarchy" ]] || exit 0`) runs under
# `set -euo pipefail`: with the variable unset it dies with
# "OMARCHY_PATH: unbound variable" before the update starts. The only thing
# that exports it is /usr/share/omarchy/default/bash/env-bootstrap, sourced
# by the package's own /etc/profile.d/omarchy.sh (LOGIN shells only) and by
# /etc/skel/.bashrc — which is exactly what --skip-user-configs does not
# replay. Observed on the CachyOS guest: `omarchy update` from a non-login
# shell, and `sudo omarchy update`, both die there.
#
# /etc/environment is read by pam_env at session setup, so it covers every
# shell (fish included), ssh sessions and the graphical session, without
# touching $HOME. It is only written when /etc/omarchy.conf is absent: with
# omarchy-dev-link active that file names a different checkout, and
# env-bootstrap (which runs later, in login shells) must stay authoritative.
# Restore path: delete the delimited block from /etc/environment.
if [[ -f $(host_path /etc/omarchy.conf) ]]; then
    echo "/etc/omarchy.conf exists (omarchy-dev-link); leaving OMARCHY_PATH to env-bootstrap."
    decide omarchy_path_env "dev-link-present"
elif grep -qE '^\s*OMARCHY_PATH=' "$(host_path /etc/environment)" 2>/dev/null; then
    echo "/etc/environment already sets OMARCHY_PATH; leaving it alone."
    decide omarchy_path_env "already-set"
else
    {
        printf '\n# >>> omocachy install-omarchy-quattro.sh >>>\n'
        printf '# Read by pam_env, so every shell and session type gets it -- not just the\n'
        printf '# login shells /etc/profile.d/omarchy.sh covers and the interactive shells\n'
        printf '# /etc/skel/.bashrc covers. Without it `omarchy update` dies in\n'
        printf '# omarchy-update-dev with "OMARCHY_PATH: unbound variable".\n'
        printf 'OMARCHY_PATH=/usr/share/omarchy\n'
        printf '# <<< omocachy <<<\n'
    } | append_root_file /etc/environment
    decide omarchy_path_env "written"
fi
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

# ---------------------------------------------------------------------------
# Login (SDDM)
#
# Upstream 4.0.2 ships only 10-theme.conf and 10-wayland.conf via
# omarchy-settings; install/login/sddm.sh only trims PAM keyring lines. The
# remembered-user and autologin state come from the Omarchy ISO, not from any
# package. The Omarchy SDDM theme has no username field, so a fresh CachyOS
# without a remembered user cannot log in at all (mroboff #74).
# ---------------------------------------------------------------------------

step "Login (SDDM)"
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
# re-synced via omarchy-reinstall-configs (`cp -af /etc/skel/. ~/`) and then
# omarchy-provision-user --first-install (== "omarchy finalize user", runtime
# tweaks /etc/skel can't do: xdg dirs, skill symlinks, install/user/*).
#
# omarchy-reinstall-configs also calls omarchy-refresh-limine, which does
# `sudo mv /boot/limine.conf /boot/limine.conf.bak` with no bootloader check:
# on a GRUB or systemd-boot machine that mv fails, and reinstall-configs runs
# under `set -euo pipefail`, so the whole seeding step aborts halfway. On such
# a machine refresh-limine is shadowed by a PATH stub for the duration of the
# call -- scoped to this run, nothing on disk changed.
# ---------------------------------------------------------------------------

seed_user_configs() {
    # Omarchy's own tools need OMARCHY_PATH even though this shell never
    # sourced Omarchy's profile: the steps below call omarchy-plymouth-set and
    # friends, which die with "OMARCHY_PATH: unbound variable" over ssh (a
    # fresh CachyOS user has no ~/.bashrc yet — that is what this step
    # installs). Source Omarchy's own bootstrap rather than hard-coding the
    # path, and leave an existing value alone.
    if [[ -z ${OMARCHY_PATH:-} ]]; then
        local env_bootstrap=/usr/share/omarchy/default/bash/env-bootstrap
        if [[ -r $env_bootstrap ]]; then
            set +u
            # shellcheck disable=SC1090
            source "$env_bootstrap"
            set -u
        else
            export OMARCHY_PATH=/usr/share/omarchy
        fi
    fi

    if [[ -d $(host_path /etc/skel) ]]; then
        local home_backup_dir="$HOME/.omarchy-quattro-backup-$TIMESTAMP" entry name
        if $SKEL_HYPR_FILES; then
            echo "Note: /etc/skel contains a .config/hypr tree (CachyOS's Hyprland profile ships one, and so does Omarchy). It is about to be copied over \$HOME."
        fi
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
        if [[ $BOOTLOADER == "limine" ]]; then
            run omarchy-reinstall-configs
            # refresh-limine replaced the CachyOS loader config with
            # Omarchy's branded one. Put the pre-install file back and
            # regenerate the entries.
            if [[ -n $LIMINE_CONF_BACKUP ]]; then
                run_root cp -a "$LIMINE_CONF_BACKUP" /boot/limine.conf
                run_root limine-update
            fi
        else
            echo "Shadowing omarchy-refresh-limine for this call: the bootloader is $BOOTLOADER, not Limine."
            local shim_dir
            if $DRY_RUN; then
                echo "DRYRUN: omarchy-reinstall-configs (with a no-op omarchy-refresh-limine first on PATH)"
            else
                shim_dir="$(mktemp -d)"
                printf '#!/bin/sh\necho "omocachy: skipping omarchy-refresh-limine (bootloader is %s)"\n' "$BOOTLOADER" >"$shim_dir/omarchy-refresh-limine"
                chmod +x "$shim_dir/omarchy-refresh-limine"
                PATH="$shim_dir:$PATH" omarchy-reinstall-configs
                rm -rf "$shim_dir"
            fi
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
if status is-interactive
    command -q mise; and mise activate fish | source
    command -q zoxide; and zoxide init fish | source
end
EOF
    fi
}

step "User-level config seeding"
if $SKIP_USER_CONFIGS; then
    echo "Skipped (--skip-user-configs):"
    echo "  - /etc/skel replay (omarchy-reinstall-configs)"
    echo "  - omarchy-refresh-limine"
    echo "  - omarchy-provision-user"
    echo "  - the fish conf.d file and the GPU scripts' uwsm env.d file"
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
step "GPU setup"
case "$GPU_TYPE" in
    nvidia) echo "Detected NVIDIA GPU -> dispatch target: bin/nvidia.sh (via gpu-setup.sh)" ;;
    amd)    echo "Detected AMD GPU -> dispatch target: bin/amd-rocm.sh (via gpu-setup.sh)" ;;
    none)   echo "No GPU detected -> gpu-setup.sh will no-op" ;;
esac
run env OMOCACHY_SKIP_USER_CONFIGS="$($SKIP_USER_CONFIGS && echo 1 || echo 0)" bash "$SCRIPT_DIR/gpu-setup.sh"

# ---------------------------------------------------------------------------
# Remaining post-apply reconciliation
# ---------------------------------------------------------------------------

step "Snapper reconciliation"
if [[ -n $SNAPPER_BACKUP ]]; then
    run_root cp -a "$SNAPPER_BACKUP" "$SNAPPER_CONFIG"
else
    echo "No pre-install snapper backup was taken; leaving Omarchy's $SNAPPER_CONFIG in place."
fi

step "Bootloader reconciliation"
# The hook policy itself was applied before the pacman transaction; re-assert
# it (idempotent) in case apply-system rewrote pacman.conf a second time, and
# stop limine-snapper-sync on machines Limine does not boot.
if [[ $BOOTLOADER != "limine" ]]; then
    run_root systemctl disable --now limine-snapper-sync.service
fi
apply_boot_hook_policy

step "Rebuilding initramfs"
# shellcheck disable=SC2086
run_root $INITRAMFS_REBUILD

run_assertion_suite || exit 1

echo ""
echo "Done."
echo ""
echo "Note: the omarchy package installs /usr/share/libalpm/hooks/00-omarchy-update-guard.hook,"
echo "a PreTransaction AbortOnFail hook. From now on every direct 'pacman -Syu' on this"
echo "machine aborts, including the ones paru/yay run for you. Update with 'omarchy update',"
echo "or set OMARCHY_ALLOW_DIRECT_PACMAN=1 in the environment of a direct pacman/paru/yay call."
echo ""
echo "After the first 'omarchy update', re-run this script with --verify-only: it re-checks"
echo "that the CachyOS repos, os-release, HOOKS and boot-hook policy all survived the update."
echo ""
echo "Three things a real CachyOS run turned up, worth knowing before you reboot:"
if $SSHD_PRESENT; then
    echo "  * ufw is now enabled with 'default deny incoming'. This script allowed your sshd"
    echo "    port(s) ($(ssh_ports | tr '\n' ' ')) beforehand, so remote access survives. Anything else you"
    echo "    expose (e.g. Samba, a dev server) needs its own 'sudo ufw allow ...'."
else
    echo "  * ufw is now enabled with 'default deny incoming' and NOTHING is allowed in."
    echo "    If you enable sshd later, run 'sudo ufw allow 22/tcp' before you depend on it."
fi
echo "  * Run 'omarchy update' as your user, not with sudo: root's environment has no"
echo "    OMARCHY_PATH either, and a root-created /tmp/omarchy-update.log then blocks your"
echo "    next attempt (delete it if that happens). OMARCHY_PATH is now set in"
echo "    /etc/environment, which takes effect at your next login -- for this session use"
echo "    'OMARCHY_PATH=/usr/share/omarchy omarchy update'."
echo "  * A migration ('Repair the pre-suspend lock monitor') reports that"
echo "    omarchy-sleep-lock.service is not loaded and says it will retry. That is expected"
echo "    on a layered install and is not a failure; nothing else in the update is affected."
echo ""
echo "Log: $LOG_FILE"
