#!/bin/bash
set -euo pipefail

# omocachy-profile-import.sh — restore an omocachy profile bundle (see
# bin/omocachy-profile-export.sh) onto a CachyOS machine that already runs
# Omarchy 4, i.e. after bin/install-omarchy-quattro.sh.
#
# Safety model:
#   - every path the restore would overwrite is copied to
#     ~/.local/state/omocachy/backups/import-<ts>/ FIRST, and that directory
#     gets a generated rollback.sh which puts the machine back;
#   - the payload is merged, never deleted over: files the bundle does not
#     carry are left alone;
#   - host-specific files (monitor layout, GPU session env) are restored
#     beside their target as <name>.from-<host> instead of replacing working
#     ones, unless --restore-host-specific says otherwise;
#   - packages are filtered against a deny policy (kernels, bootloader, GPU
#     driver stack, base system) that is reported, not silent;
#   - nothing runs as root except the pacman transaction of the packages
#     stage.
#
# Design and evidence: plans/016-omarchy-profile-migration.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=bin/lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

DRY_RUN=false
ASSUME_YES=false
BUNDLE_ARG=""
RESTORE_HOST_SPECIFIC=false
ONLY=""
SKIP=""
ALL_STAGES=(configs packages mise services verify)

usage() {
    cat <<USAGE
Usage: $(basename "$0") --bundle PATH [options]

  --bundle PATH             Bundle directory or .tar.zst/.tar.gz archive.
  --only  a,b               Run only these stages.
  --skip  a,b               Run everything except these stages.
                            Stages: ${ALL_STAGES[*]}
  --restore-host-specific   Also overwrite host-specific files (Hyprland
                            monitor layout, GPU session env) instead of
                            dropping them beside the target as
                            <name>.from-<source-host>.
  --dry-run                 Print the plan; change nothing.
  --yes                     Skip the confirmation prompt.
USAGE
}

while (($#)); do
    case "$1" in
    --bundle)
        BUNDLE_ARG="${2:?--bundle needs a path}"
        shift 2
        ;;
    --only)
        ONLY="${2:?--only needs a stage list}"
        shift 2
        ;;
    --skip)
        SKIP="${2:?--skip needs a stage list}"
        shift 2
        ;;
    --restore-host-specific)
        RESTORE_HOST_SPECIFIC=true
        shift
        ;;
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --yes)
        ASSUME_YES=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

require_not_root
require_cmds tar jq pacman
[[ -n $BUNDLE_ARG ]] || {
    usage >&2
    exit 1
}

stage_enabled() {
    local s="$1"
    if [[ -n $ONLY ]]; then
        [[ ",$ONLY," == *",$s,"* ]]
    elif [[ -n $SKIP ]]; then
        [[ ",$SKIP," != *",$s,"* ]]
    else
        return 0
    fi
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STATE_DIR="$HOME/.local/state/omocachy"
BACKUP_DIR="$STATE_DIR/backups/import-$TIMESTAMP"
REPORT_DIR="$STATE_DIR/reports/import-$TIMESTAMP"
WORK="$(mktemp -d -t omocachy-import-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

BUNDLE="$(profile_resolve_bundle "$BUNDLE_ARG" "$WORK/bundle")" || die "cannot read bundle."

SCHEMA="$(profile_manifest "$BUNDLE" .schema)"
[[ $SCHEMA == "$PROFILE_SCHEMA" ]] || die "bundle schema $SCHEMA, this script speaks $PROFILE_SCHEMA."

SRC_HOST="$(profile_manifest "$BUNDLE" .source.host)"
SRC_USER="$(profile_manifest "$BUNDLE" .source.user)"
SRC_HOME="$(profile_manifest "$BUNDLE" .source.home)"
SRC_OMARCHY="$(profile_manifest "$BUNDLE" .source.omarchy)"
SRC_GPU="$(profile_manifest "$BUNDLE" .source.gpu)"
SRC_CREATED="$(profile_manifest "$BUNDLE" .created)"
mapfile -t CAPTURED < <(profile_manifest "$BUNDLE" '.payload.captured[]')

TGT_OMARCHY="$(pacman -Q omarchy 2>/dev/null | awk '{print $2}' || true)"
TGT_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
TGT_GPU="$(bash "$SCRIPT_DIR/gpu-detect.sh" 2>/dev/null || echo unknown)"

echo "=== omocachy-profile-import.sh ==="
$DRY_RUN && echo "(dry-run: nothing will be changed)"
echo ""
echo "Bundle:   $BUNDLE"
echo "  created $SRC_CREATED on $SRC_HOST ($SRC_USER, home $SRC_HOME)"
echo "  omarchy ${SRC_OMARCHY:-absent}, GPU $SRC_GPU, ${#CAPTURED[@]} captured paths"
echo "Target:   $(uname -n) ($TGT_ID), omarchy ${TGT_OMARCHY:-absent}, GPU $TGT_GPU"
echo "Backups:  $BACKUP_DIR (with rollback.sh)"
echo "Stages:   $(for s in "${ALL_STAGES[@]}"; do stage_enabled "$s" && printf '%s ' "$s"; done)"
echo ""

[[ -n $TGT_OMARCHY ]] || warn "the omarchy package is not installed here — run bin/install-omarchy-quattro.sh first, or the Quickshell config will have no shell to run in."
[[ $SRC_USER == "$USER" ]] || warn "bundle was captured for user '$SRC_USER'; restoring into '$USER' ($HOME). Absolute paths inside configs that point at $SRC_HOME will need fixing by hand."

confirm "Restore into $HOME?" || die "aborted."

if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
    # From here on every line also lands in the report directory, so a
    # migration that fails halfway leaves a transcript next to its lists.
    start_logging "$REPORT_DIR/import.log"
fi

STAGE_RESULT=()
record_stage() { STAGE_RESULT+=("$1: $2"); }

# ---------------------------------------------------------------------------
# configs — merge the payload into $HOME, after backing up what it shadows
# ---------------------------------------------------------------------------

stage_configs() {
    local rel rc backed=0 fresh=0
    echo "--- configs ---"
    [[ -d $BUNDLE/home ]] || {
        warn "bundle has no home/ payload."
        record_stage configs SKIPPED
        return 0
    }

    : >"$WORK/restored.tsv"
    for rel in "${CAPTURED[@]}"; do
        [[ -e "$BUNDLE/home/$rel" ]] || continue
        if [[ -e "$HOME/$rel" ]]; then
            if $DRY_RUN; then
                echo "DRYRUN: back up $HOME/$rel -> $BACKUP_DIR/$rel"
            else
                mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
                cp -a "$HOME/$rel" "$BACKUP_DIR/$rel"
            fi
            printf '%s\texisted\n' "$rel" >>"$WORK/restored.tsv"
            backed=$((backed + 1))
        else
            printf '%s\tnew\n' "$rel" >>"$WORK/restored.tsv"
            fresh=$((fresh + 1))
        fi

        if $DRY_RUN; then
            echo "DRYRUN: merge bundle home/$rel into $HOME/$rel"
        else
            rc=0
            tar -C "$BUNDLE/home" -cf - -- "$rel" | tar -C "$HOME" -xf - || rc=$?
            ((rc == 0)) || die "restoring $rel failed (tar exit $rc); rollback: $BACKUP_DIR/rollback.sh"
            printf '    ok  %s\n' "$rel"
        fi
    done

    # Host-specific files: a monitor layout or a GPU session env from another
    # machine is at best wrong and at worst leaves no usable display, so they
    # land beside the target file instead of on top of it.
    local hs target
    for hs in "${PROFILE_HOST_SPECIFIC[@]}"; do
        [[ -e "$BUNDLE/home/$hs" ]] || continue
        $RESTORE_HOST_SPECIFIC && continue
        target="$HOME/$hs.from-$SRC_HOST"
        if $DRY_RUN; then
            echo "DRYRUN: keep target's $hs; park the bundle's copy at $target"
        else
            if [[ -e "$BACKUP_DIR/$hs" ]]; then
                mv -f "$HOME/$hs" "$target"
                cp -a "$BACKUP_DIR/$hs" "$HOME/$hs"
            else
                mv -f "$HOME/$hs" "$target"
            fi
            echo "    host-specific: kept this machine's $hs; bundle copy parked at ${target/#$HOME/~}"
        fi
    done

    if ! $DRY_RUN; then
        cp -a "$WORK/restored.tsv" "$REPORT_DIR/restored.tsv"
        write_rollback
        echo "    backed up $backed existing paths, added $fresh new ones"
        echo "    rollback: $BACKUP_DIR/rollback.sh"
    fi
    record_stage configs OK
}

# A generated undo for exactly the paths this run touched: restore the ones
# that existed, remove the ones it introduced. Nothing else is in scope.
write_rollback() {
    local rel state
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "# Undo of omocachy-profile-import.sh run $TIMESTAMP."
        echo '# Restores the paths that existed before the import and removes the'
        echo '# ones it introduced. Pass --dry-run to see the plan.'
        echo 'DRY=false'
        echo '[[ ${1:-} == --dry-run ]] && DRY=true'
        echo "BACKUP=\"$BACKUP_DIR\""
        echo "HOME_DIR=\"$HOME\""
        echo 'restore() {'
        echo '    if $DRY; then echo "would restore $HOME_DIR/$1"; return; fi'
        echo '    # Stage the copy beside the target and swap it in, so a live'
        echo '    # desktop watching e.g. ~/.config/hypr never observes the'
        echo '    # directory missing for the duration of a copy.'
        echo '    local stage="$HOME_DIR/$1.omocachy-rollback.$$"'
        echo '    rm -rf "$stage"'
        echo '    mkdir -p "$(dirname "$HOME_DIR/$1")"'
        echo '    cp -a "$BACKUP/$1" "$stage"'
        echo '    rm -rf "$HOME_DIR/$1"'
        echo '    mv "$stage" "$HOME_DIR/$1"'
        echo '}'
        echo 'drop() {'
        echo '    if $DRY; then echo "would remove $HOME_DIR/$1"; return; fi'
        echo '    rm -rf "$HOME_DIR/$1"'
        echo '}'
        while IFS=$'\t' read -r rel state; do
            [[ -z $rel ]] && continue
            if [[ $state == existed ]]; then
                printf 'restore %q\n' "$rel"
            else
                printf 'drop %q\n' "$rel"
            fi
        done <"$WORK/restored.tsv"
        echo 'echo "rollback complete"'
    } >"$BACKUP_DIR/rollback.sh"
    chmod 755 "$BACKUP_DIR/rollback.sh"
}

# ---------------------------------------------------------------------------
# packages — reinstall the source machine's explicit packages, minus policy
# ---------------------------------------------------------------------------

network_up() {
    have getent || return 0
    timeout 5 getent ahostsv4 pkgs.omarchy.org &>/dev/null ||
        timeout 5 getent ahostsv4 archlinux.org &>/dev/null
}

stage_packages() {
    echo "--- packages ---"
    local native=() foreign=() installed wanted pkg reason
    [[ -f $BUNDLE/packages/explicit-native.txt ]] || {
        warn "bundle carries no package lists."
        record_stage packages SKIPPED
        return 0
    }

    installed="$WORK/installed.txt"
    pacman -Qq 2>/dev/null | sort >"$installed"

    : >"$WORK/skipped-policy.txt"
    : >"$WORK/todo-native.txt"
    : >"$WORK/todo-foreign.txt"

    while IFS= read -r pkg; do
        [[ -z $pkg ]] && continue
        grep -qxF "$pkg" "$installed" && continue
        if reason="$(profile_pkg_denied "$pkg")"; then
            printf '%s\t%s\n' "$pkg" "$reason" >>"$WORK/skipped-policy.txt"
            continue
        fi
        if pacman -Si "$pkg" &>/dev/null; then
            printf '%s\n' "$pkg" >>"$WORK/todo-native.txt"
        else
            printf '%s\n' "$pkg" >>"$WORK/todo-foreign.txt"
        fi
    done < <(cat "$BUNDLE/packages/explicit-native.txt" "$BUNDLE/packages/explicit-foreign.txt" 2>/dev/null | sort -u)

    mapfile -t native <"$WORK/todo-native.txt"
    mapfile -t foreign <"$WORK/todo-foreign.txt"
    wanted=$((${#native[@]} + ${#foreign[@]}))
    echo "    $(wc -l <"$WORK/skipped-policy.txt" | tr -d ' ') skipped by policy, ${#native[@]} from configured repos, ${#foreign[@]} not in any configured repo (AUR/foreign)"
    while IFS=$'\t' read -r pkg reason; do
        [[ -z $pkg ]] && continue
        printf '    policy: %-28s %s\n' "$pkg" "$reason"
    done <"$WORK/skipped-policy.txt"

    if ! $DRY_RUN; then
        cp -a "$WORK/skipped-policy.txt" "$REPORT_DIR/packages-skipped-by-policy.tsv"
        cp -a "$WORK/todo-native.txt" "$REPORT_DIR/packages-from-repos.txt"
        cp -a "$WORK/todo-foreign.txt" "$REPORT_DIR/packages-foreign.txt"
    fi

    ((wanted)) || {
        echo "    nothing to install"
        record_stage packages OK
        return 0
    }

    if ! $DRY_RUN && ! network_up; then
        warn "no network: skipping the install. Lists are in $REPORT_DIR; re-run with --only packages when online."
        record_stage packages "SKIPPED (offline)"
        return 0
    fi

    local failed=()
    if ((${#native[@]})); then
        # OMARCHY_ALLOW_DIRECT_PACMAN: the omarchy package installs a
        # PreTransaction hook that aborts any direct pacman -Syu.
        if ! run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm -- "${native[@]}"; then
            warn "the batch transaction failed; retrying package by package so one bad name does not block the rest."
            for pkg in "${native[@]}"; do
                run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm -- "$pkg" || failed+=("$pkg")
            done
        fi
    fi

    if ((${#foreign[@]})); then
        local helper="" h
        for h in paru yay; do have "$h" && {
            helper="$h"
            break
        }; done
        if [[ -z $helper ]]; then
            warn "${#foreign[@]} packages are not in any configured repo and no AUR helper (paru/yay) is installed. List: $REPORT_DIR/packages-foreign.txt"
        else
            for pkg in "${foreign[@]}"; do
                run env OMARCHY_ALLOW_DIRECT_PACMAN=1 "$helper" -S --needed --noconfirm -- "$pkg" || failed+=("$pkg")
            done
        fi
    fi

    if ((${#failed[@]})); then
        printf '%s\n' "${failed[@]}" >"$REPORT_DIR/packages-failed.txt"
        warn "${#failed[@]} packages did not install; see $REPORT_DIR/packages-failed.txt"
        record_stage packages "PARTIAL (${#failed[@]} failed)"
    else
        record_stage packages OK
    fi
}

# ---------------------------------------------------------------------------
# mise — the tool versions the restored ~/.config/mise/config.toml asks for
# ---------------------------------------------------------------------------

stage_mise() {
    echo "--- mise ---"
    if ! have mise; then
        warn "mise is not installed (comes with Omarchy's provisioning / mise-bin); skipping."
        record_stage mise SKIPPED
        return 0
    fi
    if [[ ! -f $HOME/.config/mise/config.toml ]]; then
        echo "    no ~/.config/mise/config.toml; nothing to install"
        record_stage mise SKIPPED
        return 0
    fi
    if ! $DRY_RUN && ! network_up; then
        warn "no network: skipping 'mise install'. Run it yourself when online."
        record_stage mise "SKIPPED (offline)"
        return 0
    fi
    if run mise install --yes; then
        record_stage mise OK
    else
        warn "'mise install' reported failures; see the output above."
        record_stage mise PARTIAL
    fi
}

# ---------------------------------------------------------------------------
# services — re-enable the user units that were enabled on the source
# ---------------------------------------------------------------------------

stage_services() {
    echo "--- services ---"
    local list="$BUNDLE/services/user-enabled.txt" unit missing=() enabled=0
    [[ -f $list ]] || {
        record_stage services SKIPPED
        return 0
    }
    while IFS= read -r unit; do
        [[ -z $unit ]] && continue
        if ! systemctl --user cat "$unit" &>/dev/null; then
            missing+=("$unit")
            continue
        fi
        systemctl --user is-enabled --quiet "$unit" 2>/dev/null && continue
        run systemctl --user enable "$unit" || warn "could not enable $unit"
        enabled=$((enabled + 1))
    done <"$list"
    echo "    enabled $enabled unit(s); ${#missing[@]} unit(s) not present on this machine"
    if ((${#missing[@]})); then
        printf '%s\n' "${missing[@]}" | sed 's/^/    missing: /'
        $DRY_RUN || printf '%s\n' "${missing[@]}" >"$REPORT_DIR/services-missing.txt"
    fi
    record_stage services OK
}

# ---------------------------------------------------------------------------
# verify — hand over to the doctor
# ---------------------------------------------------------------------------

stage_verify() {
    echo "--- verify ---"
    if $DRY_RUN; then
        echo "DRYRUN: bash $SCRIPT_DIR/omocachy-doctor.sh --bundle $BUNDLE"
        record_stage verify SKIPPED
        return 0
    fi
    if bash "$SCRIPT_DIR/omocachy-doctor.sh" --bundle "$BUNDLE"; then
        record_stage verify OK
    else
        record_stage verify FAILED
    fi
}

for stage in "${ALL_STAGES[@]}"; do
    if stage_enabled "$stage"; then
        echo ""
        "stage_$stage"
    else
        record_stage "$stage" "not selected"
    fi
done

# GPU session env from another vendor is actively wrong; the parked copy is
# harmless, but say so, because the fix is one command.
if [[ $SRC_GPU != "$TGT_GPU" ]]; then
    echo ""
    warn "source GPU vendor was '$SRC_GPU', this machine is '$TGT_GPU'. Run bin/gpu-setup.sh to write the right session environment."
fi

echo ""
echo "--- Result ---"
printf '  %s\n' "${STAGE_RESULT[@]}"
if ! $DRY_RUN; then
    echo ""
    echo "Reports:  $REPORT_DIR"
    echo "Rollback: $BACKUP_DIR/rollback.sh   (--dry-run supported)"
    echo ""
    echo "Log out and back in (or run 'omarchy-restart-shell') to pick up the restored Quickshell layer."
fi

for r in "${STAGE_RESULT[@]}"; do
    [[ $r == *FAILED* ]] && exit 1
done
exit 0
