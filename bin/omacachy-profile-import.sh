#!/bin/bash
set -euo pipefail

# omacachy-profile-import.sh — restore an omacachy profile bundle (see
# bin/omacachy-profile-export.sh) onto a CachyOS machine that already runs
# Omarchy 4, i.e. after bin/install-omarchy-quattro.sh.
#
# Safety model:
#   - every path the restore would overwrite is copied to
#     ~/.local/state/omacachy/backups/import-<ts>/ FIRST, and that directory
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
# Design and evidence: plans/018-omarchy-profile-migration.md.

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
STATE_DIR="$HOME/.local/state/omacachy"
BACKUP_DIR="$STATE_DIR/backups/import-$TIMESTAMP"
REPORT_DIR="$STATE_DIR/reports/import-$TIMESTAMP"
WORK="$(mktemp -d -t omacachy-import-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

BUNDLE="$(profile_resolve_bundle "$BUNDLE_ARG" "$WORK/bundle")" || die "cannot read bundle."

SCHEMA="$(profile_manifest "$BUNDLE" .schema)"
[[ $SCHEMA == "$PROFILE_SCHEMA" ]] || die "bundle schema $SCHEMA, this script speaks $PROFILE_SCHEMA."

SRC_HOST="$(profile_manifest "$BUNDLE" .source.host)"
# The host name becomes part of a filename (.from-<host>), so a manifest that
# carries a host with a slash in it must not steer the parked copy elsewhere.
SRC_HOST_SAFE="${SRC_HOST//[^A-Za-z0-9._-]/_}"
SRC_USER="$(profile_manifest "$BUNDLE" .source.user)"
SRC_HOME="$(profile_manifest "$BUNDLE" .source.home)"
SRC_OMARCHY="$(profile_manifest "$BUNDLE" .source.omarchy)"
SRC_GPU="$(profile_manifest "$BUNDLE" .source.gpu)"
SRC_CREATED="$(profile_manifest "$BUNDLE" .created)"
mapfile -t CAPTURED < <(profile_manifest "$BUNDLE" '.payload.captured[]')

# The manifest is user data like the rest of the bundle. A ".." entry clears
# both existence gates in stage_configs ("$BUNDLE/home/$rel" exists, and the
# escape target exists) and then drives mkdir -p/cp -a outside $HOME and an
# rm -rf in the generated rollback. Refuse the bundle before anything under
# $HOME is touched — no backup dir, no prompt.
bad=()
for rel in "${CAPTURED[@]}"; do
    profile_rel_path_ok "$rel" || bad+=("$rel")
done
if ((${#bad[@]})); then
    printf 'Refusing bundle: %d unsafe path(s) in payload.captured:\n' "${#bad[@]}" >&2
    printf '  %q\n' "${bad[@]}" >&2
    exit 1
fi

TGT_OMARCHY="$(pacman -Q omarchy 2>/dev/null | awk '{print $2}' || true)"
TGT_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
TGT_GPU="$(bash "$SCRIPT_DIR/gpu-detect.sh" 2>/dev/null || echo unknown)"

echo "=== omacachy-profile-import.sh ==="
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

    for rel in "${CAPTURED[@]}"; do
        [[ -e "$BUNDLE/home/$rel" ]] || continue
        # A dangling symlink is not [[ -e ]], but it is still something the
        # bundle shadows: classify it as pre-existing so the backup holds the
        # link and the undo puts it back, instead of an rm -rf with nothing to
        # restore.
        if [[ -e "$HOME/$rel" || -L "$HOME/$rel" ]]; then
            if $DRY_RUN; then
                echo "DRYRUN: back up $HOME/$rel -> $BACKUP_DIR/$rel"
            else
                mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
                cp -a "$HOME/$rel" "$BACKUP_DIR/$rel"
                printf '%s\texisted\n' "$rel" >>"$BACKUP_DIR/restored.tsv"
            fi
            backed=$((backed + 1))
        else
            if ! $DRY_RUN; then
                printf '%s\tnew\n' "$rel" >>"$BACKUP_DIR/restored.tsv"
            fi
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
        target="$HOME/$hs.from-$SRC_HOST_SAFE"
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
        cp -a "$BACKUP_DIR/restored.tsv" "$REPORT_DIR/restored.tsv"
        echo "    backed up $backed existing paths, added $fresh new ones"
        echo "    rollback: $BACKUP_DIR/rollback.sh"
        # tar replaces files by unlink+create; a live Hyprland watching
        # ~/.config/hypr can reload inside that window and keep showing
        # "cannot open hyprland.lua" until the next reload (seen on the
        # CachyOS guest, plan 018). Reload once the merge is complete.
        #
        # The probe below has to survive a machine with no session, which is
        # the normal case for an import: over ssh HYPRLAND_INSTANCE_SIGNATURE
        # is unset, and with no desktop there is no $XDG_RUNTIME_DIR/hypr for
        # it to find. There find exits 1 on a missing directory, and under
        # set -e + pipefail that aborted the whole run at the end of the
        # configs stage — before packages, mise, services and verify (plan
        # 044). An absent instance is not an error: it only means there is
        # nothing to reload.
        if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
            newest_hypr=""
            if [[ -d ${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr ]]; then
                newest_hypr="$(find "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2 || true)"
            fi
            if [[ -n $newest_hypr ]]; then
                export HYPRLAND_INSTANCE_SIGNATURE="$newest_hypr"
            fi
        fi
        if have hyprctl && hyprctl -j version &>/dev/null; then
            hyprctl reload >/dev/null 2>&1 && echo "    reloaded the running Hyprland"
        fi
    fi
    record_stage configs OK
}

# A generated undo for exactly the paths this run touched: restore the ones
# that existed, remove the ones it introduced. Nothing else is in scope. It
# replays $BACKUP_DIR/restored.tsv at run time rather than carrying a copy of
# the list, so it stays honest if the merge dies halfway — which is also why
# it is generated before the first path is merged, not after the last.
write_rollback() {
    # Defence in depth inside the generated script: the list it replays comes
    # from a manifest this run already validated, but restored.tsv is a plain
    # file sitting next to the backup, and a hand-edited or truncated one must
    # not turn the undo into an rm -rf outside $HOME.
    local guard='    case "$1" in *..*|/*) echo "rollback: refusing unsafe path $1" >&2; return 1 ;; esac'
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "# Undo of omacachy-profile-import.sh run $TIMESTAMP."
        echo '# Restores the paths that existed before the import and removes the'
        echo '# ones it introduced. Pass --dry-run to see the plan.'
        echo 'DRY=false'
        echo '[[ ${1:-} == --dry-run ]] && DRY=true'
        echo "BACKUP=\"$BACKUP_DIR\""
        echo "HOME_DIR=\"$HOME\""
        echo 'restore() {'
        echo "$guard"
        echo '    if $DRY; then echo "would restore $HOME_DIR/$1"; return; fi'
        echo '    # Stage the copy beside the target and swap it in, so a live'
        echo '    # desktop watching e.g. ~/.config/hypr never observes the'
        echo '    # directory missing for the duration of a copy.'
        echo '    local stage="$HOME_DIR/$1.omacachy-rollback.$$"'
        echo '    rm -rf "$stage"'
        echo '    mkdir -p "$(dirname "$HOME_DIR/$1")"'
        echo '    cp -a "$BACKUP/$1" "$stage"'
        echo '    rm -rf "$HOME_DIR/$1"'
        echo '    mv "$stage" "$HOME_DIR/$1"'
        echo '}'
        echo 'drop() {'
        echo "$guard"
        echo '    if $DRY; then echo "would remove $HOME_DIR/$1"; return; fi'
        echo '    rm -rf "$HOME_DIR/$1"'
        echo '}'
        cat <<'ROLLBACK'
while IFS=$'\t' read -r rel state; do
    [[ -n $rel ]] || continue
    if [[ $state == existed ]]; then restore "$rel"; else drop "$rel"; fi
done <"$BACKUP/restored.tsv"
ROLLBACK
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

# The repositories this machine configures. pacman-conf reads [options] and
# every Include=, which a grep of /etc/pacman.conf alone would miss; the
# fallback is for a host without pacman-conf.
target_repos() {
    local out=""
    have pacman-conf && out="$(pacman-conf --repo-list 2>/dev/null || true)"
    if [[ -z $out ]]; then
        out="$(sed -n 's/^\[\([^]]*\)\]$/\1/p' /etc/pacman.conf 2>/dev/null | grep -vx options || true)"
    fi
    [[ -n $out ]] && printf '%s\n' "$out"
}

# The repository the bundle recorded for a package (packages/repos.tsv), if it
# carries the table at all. pacman -Qqen cannot tell an official repo from a
# third-party *sync* repo, so a chaotic-aur package looks native to the
# exporter; the importer uses the recorded repo to explain a helper failure
# that is really "this machine does not configure the repo the source machine
# had" (plan 044: chaotic-keyring, chaotic-mirrorlist) instead of counting it
# as a broken package. Bundles written before this field carry no repos.tsv,
# and then this answers nothing.
bundle_repo_of() { # PKG
    local tsv="$BUNDLE/packages/repos.tsv"
    [[ -f $tsv ]] || return 1
    awk -F'\t' -v p="$1" '$1 == p { print $2; found = 1 } END { exit !found }' "$tsv"
}

# The installed package a wanted package conflicts with, if any. The importer
# never removes packages, so a conflict with something the target already has
# makes pacman answer "no" to its removal prompt under --noconfirm, and the
# whole transaction fails to prepare (plan 044: pipewire-jack vs jack2,
# mise-bin vs mise). The target's package wins and the wanted one is skipped
# with its reason. A conflict naming an installed package outright is reported
# (jack2, not the virtual jack it provides); `pacman -Qi` resolves a virtual
# name the way pacman's own conflict check does, as the fallback.
installed_conflict() { # SI_OUTPUT INSTALLED_FILE
    local conf c winner=""
    conf="$(sed -n 's/^Conflicts With *: *//p' <<<"$1")"
    for c in $conf; do
        c="${c%%[<=>]*}"
        [[ -z $c || $c == None ]] && continue
        if grep -qxF "$c" "$2"; then
            winner="$c"
        elif [[ -z $winner ]] && pacman -Qi -- "$c" &>/dev/null; then
            winner="$c"
        fi
    done
    [[ -n $winner ]] || return 1
    printf '%s\n' "$winner"
}

# One transaction against the configured repos, its output captured to $1 so a
# failure can be classified. OMARCHY_ALLOW_DIRECT_PACMAN: the omarchy package
# installs a PreTransaction hook that aborts a direct pacman -Syu. pipefail is
# set, so the pipeline reports pacman's status, not tee's.
install_native() { # LOG ARGS...
    local log="$1"
    shift
    if $DRY_RUN; then
        run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm "$@"
    else
        run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm "$@" 2>&1 | tee "$log"
    fi
}

stage_packages() {
    echo "--- packages ---"
    local native=() foreign=() installed wanted pkg reason si=""
    [[ -f $BUNDLE/packages/explicit-native.txt ]] || {
        warn "bundle carries no package lists."
        record_stage packages SKIPPED
        return 0
    }

    installed="$WORK/installed.txt"
    pacman -Qq 2>/dev/null | sort >"$installed"
    local TGT_REPOS=()
    mapfile -t TGT_REPOS < <(target_repos)

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
        # One pacman -Si per package answers both questions: is there a repo
        # for this name here, and does it conflict with something installed?
        si="$(pacman -Si "$pkg" 2>/dev/null || true)"
        if [[ -n $si ]] && reason="$(installed_conflict "$si" "$installed")"; then
            printf '%s\t%s\n' "$pkg" "conflicts with $reason, which is installed here; the importer never removes packages, so replace it by hand to switch" >>"$WORK/skipped-policy.txt"
            continue
        fi
        if [[ -n $si ]]; then
            printf '%s\n' "$pkg" >>"$WORK/todo-native.txt"
        else
            # No configured repo has this name. The bundle's recorded source
            # repo is not consulted here: a chaotic-aur package can still be
            # obtainable from the AUR (helium-browser-bin is), and only the
            # helper can say. The table is used below, when a helper failure
            # needs explaining.
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
        local blog="$WORK/pacman-native.log" conflicts=() native_ok=false

        # 1. The batch transaction, one go for all of them.
        if install_native "$blog" -- "${native[@]}"; then
            native_ok=true
        else
            # 2. A stale database is the commonest way this dies: the name is
            #    in the DB while the file behind it has been rolled off the
            #    mirror, so a dependency 404s (plan 044: mangohud through an
            #    old python-matplotlib entry) and nothing is installed.
            #    Refresh once and retry the same transaction, before demoting
            #    it to one transaction per package.
            echo "    the batch transaction failed; refreshing the package databases and retrying once."
            run_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Sy 2>&1 ||
                warn "the database refresh failed; retrying the transaction anyway."
            if install_native "$blog" -- "${native[@]}"; then
                native_ok=true
            fi
        fi

        # 3. Files an earlier partial setup left behind. pacman refuses to
        #    install over a path no package owns and names it; overwrite
        #    exactly those paths and nothing else. (The wrapper's plan-043
        #    sweep does the same for yaru-icon-theme vs /usr/share/icons/Yaru.)
        if ! $native_ok; then
            mapfile -t conflicts < <(sed -n 's/^[A-Za-z0-9@._+-]*: \(.*\) exists in filesystem$/\1/p' "$blog" | sort -u)
            if ((${#conflicts[@]})); then
                echo "    retrying with --overwrite for ${#conflicts[@]} file(s) no package owns:"
                printf '        %s\n' "${conflicts[@]}"
                if install_native "$blog" --overwrite "$(printf '%s,' "${conflicts[@]}" | sed 's/,$//')" -- "${native[@]}"; then
                    native_ok=true
                fi
            fi
        fi

        # 4. One bad name must not block the rest. Last resort: a batch that
        #    got this far without installing is rare.
        if ! $native_ok; then
            warn "the batch transaction still failed; retrying package by package so one bad name does not block the rest."
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

    # A helper failure for a package the bundle recorded as coming from a repo
    # this machine does not configure — and that no configured repo has — is
    # the bundle naming a machine-specific repo (chaotic-aur), not a broken
    # package: nothing here configures chaotic mirrors, and an AUR package
    # called chaotic-keyring does not exist. Report those as a policy skip that
    # names the repo and keep them out of the failure list. A package the
    # helper *can* obtain from the AUR is never pre-skipped for its recorded
    # repo — helium-browser-bin and sway-audio-idle-inhibit-git are recorded as
    # chaotic-aur on the source machine and install from the AUR here.
    if ((${#failed[@]})); then
        local still=() repo=""
        for pkg in "${failed[@]}"; do
            repo="$(bundle_repo_of "$pkg" || true)"
            if [[ -n $repo && $repo != aur && $repo != unknown ]] &&
                ! printf '%s\n' "${TGT_REPOS[@]}" | grep -qxF "$repo"; then
                printf '    policy: %-28s %s\n' "$pkg" "source repo '$repo' is not configured here and no AUR package provides it"
                if ! $DRY_RUN; then
                    printf '%s\t%s\n' "$pkg" "bundle says it came from the '$repo' repo, which this machine does not configure, and the AUR helper could not provide it" >>"$REPORT_DIR/packages-skipped-by-policy.tsv"
                fi
                continue
            fi
            still+=("$pkg")
        done
        failed=("${still[@]}")
    fi

    if ((${#failed[@]})); then
        printf '%s\n' "${failed[@]}" >"$REPORT_DIR/packages-failed.txt"
        warn "${#failed[@]} of ${wanted} package(s) did not install:"
        printf '    failed: %s\n' "${failed[@]}"
        echo "    the reason for each is in the output above; list: $REPORT_DIR/packages-failed.txt"
        # A partial package stage is a failure, not a detail: the old
        # "PARTIAL" wording matched neither the FAILED check below nor the
        # doctor's, so a run with six packages missing exited 0 (plan 044).
        # Policy skips never reach this list — they are printed with their
        # reason and counted in packages-skipped-by-policy.tsv.
        record_stage packages "FAILED (${#failed[@]} of ${wanted} did not install)"
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
        echo "DRYRUN: bash $SCRIPT_DIR/omacachy-doctor.sh --bundle $BUNDLE"
        record_stage verify SKIPPED
        return 0
    fi
    if bash "$SCRIPT_DIR/omacachy-doctor.sh" --bundle "$BUNDLE"; then
        record_stage verify OK
    else
        record_stage verify FAILED
    fi
}

# Everything a half-finished run needs to be undone or explained exists before
# the first stage runs. In particular the undo is written here, before a single
# path is merged: the "restoring $rel failed … rollback: …" message must not
# point at a file the operator does not have, and the list the undo replays
# must not be the temp dir's copy. The functions above are definitions only,
# so nothing between the prompt and this point needs the directories.
if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
    # The undo reads $BACKUP_DIR/restored.tsv at run time, so the list has to
    # exist from the moment the undo does — a run that never reaches the
    # configs stage (--only packages, or a bundle without a home/ payload)
    # still gets an empty one to replay.
    : >"$BACKUP_DIR/restored.tsv"
    write_rollback
    # From here on every line also lands in the report directory, so a
    # migration that fails halfway leaves a transcript next to its lists.
    start_logging "$REPORT_DIR/import.log"
fi

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
