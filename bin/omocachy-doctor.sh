#!/bin/bash
set -uo pipefail

# omocachy-doctor.sh — check that an Omarchy-4-on-CachyOS machine is in the
# shape this project puts it in, and that a migrated profile is actually
# complete. Read-only: it inspects, it never fixes.
#
# FAIL = the desktop is broken or a migrated profile is incomplete (exit 1).
# WARN = worth knowing, not fatal. SKIP = not applicable here (no session,
# no bundle to compare against).
#
# The plugin check is the load-bearing one: shell.json references Quickshell
# plugins by id, and an id with no directory in ~/.config/omarchy/plugins
# makes the shell drop that part of its graph (a missing lock plugin takes
# the lock IPC target with it), with no error a user would notice.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=bin/lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

BUNDLE_ARG=""
WORK=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--bundle PATH]

  --bundle PATH   Also compare this machine against a profile bundle
                  (directory or archive): plugin set, package list,
                  enabled user units.
USAGE
}

while (($#)); do
    case "$1" in
    --bundle)
        BUNDLE_ARG="${2:?--bundle needs a path}"
        shift 2
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

FAILED=0
WARNED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*" >&2
    FAILED=$((FAILED + 1))
}
soft() {
    printf 'WARN  %s\n' "$*"
    WARNED=$((WARNED + 1))
}
skip() { printf 'SKIP  %s\n' "$*"; }

BUNDLE=""
if [[ -n $BUNDLE_ARG ]]; then
    WORK="$(mktemp -d -t omocachy-doctor-XXXXXX)"
    trap 'rm -rf "$WORK"' EXIT
    BUNDLE="$(profile_resolve_bundle "$BUNDLE_ARG" "$WORK/bundle")" || exit 1
fi

OMARCHY_CONFIG="$HOME/.config/omarchy"
PLUGIN_DIR="$OMARCHY_CONFIG/plugins"
SHELL_JSON="$OMARCHY_CONFIG/shell.json"

echo "=== omocachy-doctor.sh ==="
echo "host: $(uname -n)  user: $USER"
echo ""

# --- system layer ----------------------------------------------------------
echo "--- system ---"

IS_CACHYOS=false
{ [[ -f /etc/cachyos-release ]] || grep -qE '^\[cachyos' /etc/pacman.conf 2>/dev/null; } && IS_CACHYOS=true
OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"

if $IS_CACHYOS; then
    if [[ $OS_ID == cachyos ]]; then
        pass "/etc/os-release still ID=cachyos (omarchy-settings' rewrite reverted)"
    else
        fail "/etc/os-release says ID=$OS_ID on a CachyOS host; omarchy-settings clobbered it and the preserve hook did not put it back"
    fi
    grep -qE '^\[cachyos' /etc/pacman.conf && pass "CachyOS repos present in /etc/pacman.conf" ||
        fail "no [cachyos*] repo in /etc/pacman.conf"
else
    skip "not a CachyOS host (os-release ID=$OS_ID) — CachyOS-specific checks"
fi

grep -qE '^\[omarchy\]' /etc/pacman.conf 2>/dev/null && pass "[omarchy] repo present" ||
    fail "[omarchy] repo missing from /etc/pacman.conf"

for pkg in omarchy omarchy-settings; do
    v="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
    [[ -n $v ]] && pass "$pkg $v installed" || fail "$pkg is not installed"
done

QS="$(pacman -Qq 2>/dev/null | grep -m1 -E '^quickshell(-git)?$' || true)"
if [[ -n $QS ]]; then
    pass "$QS $( pacman -Q "$QS" 2>/dev/null | awk '{print $2}') installed (the shell runtime)"
elif command -v quickshell &>/dev/null; then
    soft "quickshell binary present but no quickshell package owns it"
else
    fail "no quickshell provider installed — the Omarchy 4 shell cannot start"
fi

[[ -f /etc/sddm.conf ]] && fail "/etc/sddm.conf exists; it outranks every /etc/sddm.conf.d drop-in, so Omarchy's login theme/session config is inert" ||
    pass "/etc/sddm.conf absent (sddm.conf.d drop-ins take effect)"

systemctl is-enabled --quiet sddm.service 2>/dev/null && pass "sddm.service enabled" || fail "sddm.service is not enabled"

if $IS_CACHYOS; then
    if [[ -f /etc/mkinitcpio.conf.d/zz-cachyos-keep-hooks.conf ]]; then
        pass "mkinitcpio HOOKS drop-in present (zz-cachyos-keep-hooks.conf)"
    else
        soft "/etc/mkinitcpio.conf.d/zz-cachyos-keep-hooks.conf is missing; the next initramfs rebuild will use Omarchy's HOOKS. Re-run bin/install-omarchy-quattro.sh"
    fi
fi

# --- the Quickshell layer --------------------------------------------------
echo ""
echo "--- desktop profile ---"

if [[ -f $SHELL_JSON ]]; then
    if jq -e . "$SHELL_JSON" >/dev/null 2>&1; then
        pass "shell.json is valid JSON ($(jq -r '.plugins | length' "$SHELL_JSON") plugins listed, version $(jq -r '.version // "?"' "$SHELL_JSON"))"
    else
        fail "shell.json is not valid JSON — the shell will fall back to defaults"
    fi
else
    fail "$SHELL_JSON is missing — this machine has no migrated shell config"
fi

MISSING_IDS=()
if [[ -f $SHELL_JSON ]]; then
    while IFS= read -r id; do
        [[ -z $id ]] && continue
        [[ -d "$PLUGIN_DIR/$id" ]] || MISSING_IDS+=("$id")
    done < <(profile_shelljson_plugin_ids "$SHELL_JSON")
    if ((${#MISSING_IDS[@]})); then
        fail "${#MISSING_IDS[@]} plugin id(s) referenced by shell.json have no directory in ~/.config/omarchy/plugins:"
        printf '        %s\n' "${MISSING_IDS[@]}" >&2
    else
        pass "every plugin id in shell.json resolves to a directory in ~/.config/omarchy/plugins"
    fi
fi

if [[ -d $PLUGIN_DIR ]]; then
    # Dot-prefixed directories are Omarchy's own disabled/backup plugin
    # copies (.<id>.bak.<stamp>), not plugins.
    total=$(find "$PLUGIN_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | wc -l | tr -d ' ')
    local_only=$(profile_plugin_rows "$PLUGIN_DIR" | awk -F'\t' '$2=="local"' | wc -l | tr -d ' ')
    pass "$total plugin directories present ($local_only not backed by a git remote)"
else
    fail "$HOME/.config/omarchy/plugins does not exist"
fi

# Hyprland: only meaningful against a live instance. A dead session leaves
# both HYPRLAND_INSTANCE_SIGNATURE and its socket file behind (inherited by
# long-running shells and agents), so the test is whether hyprctl actually
# answers, not whether the socket exists. Over ssh there is no signature at
# all, so the newest instance directory is adopted first — that is the case
# that matters when checking a freshly migrated machine remotely.
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    newest_hypr="$(find "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)"
    [[ -n $newest_hypr ]] && export HYPRLAND_INSTANCE_SIGNATURE="$newest_hypr"
fi
if command -v hyprctl &>/dev/null && hyprctl -j version &>/dev/null; then
    errs="$(hyprctl configerrors 2>/dev/null)"
    if [[ -z $errs || $errs == *"no errors"* ]]; then
        pass "hyprctl configerrors: clean"
    else
        fail "hyprctl reports config errors:"
        printf '        %s\n' "$errs" >&2
    fi
    # omarchy-shell refuses to run without OMARCHY_PATH, which the desktop
    # session exports but an ssh login does not; /usr/share/omarchy is where
    # the omarchy package puts it.
    if OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" omarchy-shell shell ping &>/dev/null; then
        pass "omarchy-shell IPC answers (the Quickshell layer is running)"
    else
        soft "omarchy-shell IPC does not answer; the shell may not be running yet (log out and back in after an import)"
    fi
else
    skip "no live Hyprland instance in this context — hyprctl/omarchy-shell checks"
fi

# --- tooling ---------------------------------------------------------------
echo ""
echo "--- tooling ---"

if command -v mise &>/dev/null; then
    if [[ -f $HOME/.config/mise/config.toml ]]; then
        missing_tools="$(mise ls --current --missing --json 2>/dev/null | jq -r 'if type == "object" then (keys | length) else length end' 2>/dev/null)"
        if [[ -z $missing_tools ]]; then
            soft "could not read 'mise ls --missing'"
        elif [[ $missing_tools == 0 ]]; then
            pass "every mise tool in ~/.config/mise/config.toml is installed"
        else
            soft "$missing_tools mise tool(s) from config.toml are not installed yet — run 'mise install'"
        fi
    else
        skip "no ~/.config/mise/config.toml — mise tool check"
    fi
else
    soft "mise is not installed"
fi

if [[ $SHELL == */fish ]] || command -v fish &>/dev/null; then
    if [[ -f $HOME/.config/fish/conf.d/omocachy.fish ]]; then
        pass "fish integration present (~/.config/fish/conf.d/omocachy.fish: mise + zoxide)"
    else
        soft "no ~/.config/fish/conf.d/omocachy.fish; mise/zoxide are not activated for fish (bin/install-omarchy-quattro.sh writes it)"
    fi
fi

GPU="$(bash "$SCRIPT_DIR/gpu-detect.sh" 2>/dev/null || echo unknown)"
GPU_ENV="$HOME/.config/uwsm/env.d/50-omocachy-gpu"
if [[ $GPU == none || $GPU == unknown ]]; then
    skip "no discrete GPU detected — session env check"
elif [[ ! -f $GPU_ENV ]]; then
    soft "no $GPU_ENV; run bin/gpu-setup.sh to write the $GPU session environment"
elif grep -qi "$GPU" "$GPU_ENV" || { [[ $GPU == amd ]] && grep -q radeonsi "$GPU_ENV"; }; then
    pass "GPU session env matches the detected vendor ($GPU)"
else
    fail "$GPU_ENV was written for another vendor than the detected $GPU; re-run bin/gpu-setup.sh"
fi

# --- against a bundle ------------------------------------------------------
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
        fail "${#missing_plugins[@]} plugin(s) from the bundle are not on this machine:"
        printf '        %s\n' "${missing_plugins[@]}" >&2
    else
        pass "every plugin in the bundle is present on this machine"
    fi

    # Local-only plugins exist nowhere else: if one of those is missing the
    # bundle is the only copy, so call it out separately.
    lost=0
    while IFS= read -r id; do
        [[ -z $id ]] && continue
        [[ -d "$PLUGIN_DIR/$id" ]] || lost=$((lost + 1))
    done < <(profile_manifest "$BUNDLE" '.plugins[] | select(.kind == "local") | .id')
    ((lost == 0)) && pass "all local-only (unpublished) plugins restored" ||
        fail "$lost local-only plugin(s) missing — nothing but this bundle has them"

    installed="$WORK/installed.txt"
    pacman -Qq 2>/dev/null | sort >"$installed"
    absent=0
    denied=0
    while IFS= read -r pkg; do
        [[ -z $pkg ]] && continue
        grep -qxF "$pkg" "$installed" && continue
        if profile_pkg_denied "$pkg" >/dev/null; then denied=$((denied + 1)); else absent=$((absent + 1)); fi
    done < <(profile_manifest "$BUNDLE" '.packages.explicit_native[], .packages.explicit_foreign[]')
    if ((absent == 0)); then
        pass "every non-policy-denied explicit package from the bundle is installed ($denied denied by policy)"
    else
        soft "$absent explicit package(s) from the bundle are not installed here ($denied more denied by policy) — 'omocachy-profile-import.sh --only packages'"
    fi

    missing_units=0
    while IFS= read -r unit; do
        [[ -z $unit ]] && continue
        systemctl --user is-enabled --quiet "$unit" 2>/dev/null || missing_units=$((missing_units + 1))
    done < <(profile_manifest "$BUNDLE" '.services.user_enabled[]')
    ((missing_units == 0)) && pass "every user unit enabled on the source is enabled here" ||
        soft "$missing_units user unit(s) enabled on the source are not enabled here (their packages may be missing)"
fi

echo ""
echo "--- result ---"
echo "$FAILED failed, $WARNED warnings"
((FAILED == 0)) || exit 1
exit 0
