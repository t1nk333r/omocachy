#!/bin/bash
set -euo pipefail

# Per-item preinstall removal for Omarchy 4 ("Quattro") — an a-la-carte
# alternative to Omarchy's all-or-nothing omarchy-remove-preinstalls.
# Derived from basecamp/omarchy's bin/omarchy-remove-preinstalls and the
# enumeration logic of omarchy-webapp-remove-all / omarchy-tui-remove-all,
# © David Heinemeier Hansson, MIT license. Removal is delegated to Omarchy's
# own tools (omarchy-pkg-drop, omarchy-webapp-remove, omarchy-tui-remove),
# so behavior tracks upstream.

# Test-only overrides (not documented in --help, mock dirs/scripts only):
#   DQ_APP_DIR       — override the .desktop directory scanned for web apps/TUIs
#   DQ_BIN_DIR        — override the directory scanned/targeted for agent CLI stubs
#   DQ_OMARCHY_SCRIPT — override the omarchy-remove-preinstalls copy to parse
#   DQ_BINDINGS_FILE  — override the Hyprland bindings file used for cleanup
# When any of these are set and the mode is --list or --dry-run, the Omarchy-4
# guard below is relaxed so the enumeration/parsing logic can be exercised on a
# non-Quattro development machine without a real Omarchy 4 install.

# Fallback snapshots, used only if parsing the installed omarchy-remove-preinstalls
# yields nothing (e.g. upstream reshuffles its script format).
PKG_FALLBACK=(aether cliamp libreoffice-fresh xournalpp pinta obsidian obs-studio kdenlive moonlight-qt lazydocker omacut omacalc omawrite)
STUB_FALLBACK=(codex claude gemini copilot gh opencode playwright playwright-cli pi omp grok crush ghui hunk)

MODE="interactive"
DRY_RUN=0

print_help() {
    cat <<'EOF'
Usage: debloat-quattro.sh [--list|--dry-run|--help]

Per-item preinstall removal for Omarchy 4 (Quattro), an a-la-carte
alternative to Omarchy's built-in omarchy-remove-preinstalls.

  --list      Print enumerated removal candidates per category and exit.
              Read-only; no selection UI, no changes.
  --dry-run   Run the selection UI, but print each removal action with a
              DRYRUN: prefix instead of performing it.
  --help      Show this help and exit.

With no flags, runs interactively: enumerate candidates, let you pick
per-item via gum, confirm, then remove your selections.

Restoring: re-run Omarchy's own omarchy-install-preinstalls to bring
everything back.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --list) MODE="list" ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) print_help; exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            print_help >&2
            exit 1
            ;;
    esac
done

# --- Guard -------------------------------------------------------------

test_override_active=0
if [[ -n "${DQ_APP_DIR:-}" || -n "${DQ_BIN_DIR:-}" || -n "${DQ_OMARCHY_SCRIPT:-}" || -n "${DQ_BINDINGS_FILE:-}" ]]; then
    test_override_active=1
fi

guard_ok=1
if [[ ! -d /usr/share/omarchy ]] || ! command -v omarchy-pkg-drop >/dev/null 2>&1 || ! command -v gum >/dev/null 2>&1; then
    guard_ok=0
fi

if [[ "$guard_ok" -eq 0 ]]; then
    if [[ ( "$MODE" == "list" || "$DRY_RUN" -eq 1 ) && "$test_override_active" -eq 1 ]]; then
        : # test-only relaxation, see comment block above
    else
        echo "Omarchy 4 not detected — this tool is for Quattro installs."
        exit 1
    fi
fi

# --- Enumeration ---------------------------------------------------------

APP_DIR="${DQ_APP_DIR:-$HOME/.local/share/applications}"
BIN_DIR="${DQ_BIN_DIR:-$HOME/.local/bin}"
OMARCHY_SCRIPT="${DQ_OMARCHY_SCRIPT:-/usr/share/omarchy/bin/omarchy-remove-preinstalls}"
BINDINGS_FILE="${DQ_BINDINGS_FILE:-}"
if [[ -z "$BINDINGS_FILE" ]]; then
    for candidate in "$HOME/.config/hypr/bindings.lua" "$HOME/.config/hypr/bindings.conf"; do
        if [[ -f "$candidate" ]]; then
            BINDINGS_FILE="$candidate"
            break
        fi
    done
fi

# Parse the `omarchy-pkg-drop pkg1 pkg2 ...` argument block (possibly
# backslash-continued across lines) out of the installed
# omarchy-remove-preinstalls script.
parse_pkg_list() {
    local script="$1"
    [[ -f "$script" ]] || return 0
    awk '
        /^[[:space:]]*omarchy-pkg-drop([[:space:]]|\\|$)/ { capture=1 }
        capture {
            line = $0
            sub(/^[[:space:]]*omarchy-pkg-drop/, "", line)
            cont = (line ~ /\\[[:space:]]*$/)
            gsub(/\\[[:space:]]*$/, "", line)
            n = split(line, words)
            for (i = 1; i <= n; i++) if (words[i] != "") print words[i]
            if (!cont) capture = 0
        }
    ' "$script" 2>/dev/null || true
}

# Parse the `rm -f ~/.local/bin/name1 ~/.local/bin/name2 ...` stub-removal
# block (possibly backslash-continued) out of the installed
# omarchy-remove-preinstalls script.
parse_stub_list() {
    local script="$1"
    [[ -f "$script" ]] || return 0
    awk '
        /^[[:space:]]*rm -f ~\/\.local\/bin\// { capture=1 }
        capture {
            line = $0
            cont = (line ~ /\\[[:space:]]*$/)
            gsub(/\\[[:space:]]*$/, "", line)
            n = split(line, words)
            for (i = 1; i <= n; i++) {
                w = words[i]
                if (w ~ /^~\/\.local\/bin\//) {
                    sub(/^~\/\.local\/bin\//, "", w)
                    print w
                }
            }
            if (!cont) capture = 0
        }
    ' "$script" 2>/dev/null || true
}

# True when this name is one the picker may remove. Upstream removes most of
# the parsed names unconditionally; cursor-agent, muse and hermes only when the
# file is the wrapper Omarchy's own installer wrote, because a launcher the
# user put at the same path must survive (Cursor's own installer links
# cursor-agent, Muse may be a personal wrapper, Hermes Desktop ships its own
# command). The mise wrappers carry the marker line upstream greps for; hermes
# is answered by the installer itself via `--owns`, which takes no argument and
# reports on its own path only.
stub_owned_by_omarchy() { # NAME
    local name="$1"
    local file="$BIN_DIR/$name"
    case "$name" in
    cursor-agent)
        [[ -f $file && ! -L $file ]] && grep -Eq '^mise use -g .*"cursor-agent"' "$file"
        ;;
    muse)
        [[ -f $file && ! -L $file ]] && grep -Eq '^mise use -g .*"http:muse\[' "$file"
        ;;
    hermes)
        # --owns speaks about ~/.local/bin/hermes and nothing else, so under the
        # DQ_BIN_DIR test override it would be answering about a different file:
        # fail closed rather than authorize a removal it never judged.
        [[ "$file" == "$HOME/.local/bin/hermes" ]] || return 1
        command -v omarchy-install-hermes-cli >/dev/null 2>&1 && omarchy-install-hermes-cli --owns
        ;;
    *)
        return 0
        ;;
    esac
}

pkg_warning=""
mapfile -t parsed_pkgs < <(parse_pkg_list "$OMARCHY_SCRIPT")
if [[ "${#parsed_pkgs[@]}" -eq 0 ]]; then
    parsed_pkgs=("${PKG_FALLBACK[@]}")
    pkg_warning="Warning: could not parse the package list from $OMARCHY_SCRIPT; using the built-in snapshot (may be stale)."
fi

stub_warning=""
mapfile -t parsed_stubs < <(parse_stub_list "$OMARCHY_SCRIPT")
if [[ "${#parsed_stubs[@]}" -eq 0 ]]; then
    parsed_stubs=("${STUB_FALLBACK[@]}")
    stub_warning="Warning: could not parse the agent CLI stub list from $OMARCHY_SCRIPT; using the built-in snapshot (may be stale)."
fi

# Packages: filter the parsed/fallback list to what's actually installed.
pkg_candidates=()
if command -v pacman >/dev/null 2>&1; then
    declare -A installed_exact=()
    while IFS= read -r name; do
        installed_exact[$name]=1
    done < <(pacman -Qq 2>/dev/null || true)
    for pkg in "${parsed_pkgs[@]}"; do
        if [[ -n "${installed_exact[$pkg]:-}" ]]; then
            pkg_candidates+=("$pkg")
        fi
    done
fi

# Web apps / TUIs: same enumeration grep patterns as upstream's
# omarchy-webapp-remove-all / omarchy-tui-remove-all.
webapp_candidates=()
tui_candidates=()
if [[ -d "$APP_DIR" ]]; then
    while IFS= read -r -d '' file; do
        if grep -q "Exec=omarchy-launch-webapp\|Exec=omarchy-webapp-handler" "$file" 2>/dev/null; then
            webapp_candidates+=("$(basename "${file%.desktop}")")
        elif grep -q "Exec=xdg-terminal-exec --app-id=TUI\." "$file" 2>/dev/null; then
            tui_candidates+=("$(basename "${file%.desktop}")")
        fi
    done < <(find "$APP_DIR" -maxdepth 1 -name '*.desktop' -print0 2>/dev/null)
fi

# Agent CLI stubs: which of the parsed/fallback stub names exist in BIN_DIR and
# are Omarchy's own to remove.
stub_present=()
for stub in "${parsed_stubs[@]}"; do
    if [[ -e "$BIN_DIR/$stub" ]] && stub_owned_by_omarchy "$stub"; then
        stub_present+=("$stub")
    fi
done

# Return bindings that launch the selected app/TUI, or a selected web app's
# URL. Restrict matching to recognized launcher forms so unrelated bindings
# are never removed just because they happen to mention the same word.
find_matching_bindings() {
    local category="$1"
    local name="$2"
    local line compact url desktop_file
    local -a urls=()

    [[ -n "$BINDINGS_FILE" && -f "$BINDINGS_FILE" ]] || return 0

    if [[ "$category" == "webapp" ]]; then
        desktop_file="$APP_DIR/$name.desktop"
        [[ -f "$desktop_file" ]] || return 0
        mapfile -t urls < <(grep -Eo 'https?://[^[:space:]"]+' "$desktop_file" 2>/dev/null | sort -u)
        [[ "${#urls[@]}" -gt 0 ]] || return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|--) ]] && continue
        compact="$(tr -d '[:space:]' <<< "$line")"

        case "$category" in
            webapp)
                for url in "${urls[@]}"; do
                    if [[ "$compact" == *"webapp="* && "$line" == *"$url"* ]] \
                        || [[ "$line" == *"omarchy-launch-webapp"* && "$line" == *"$url"* ]]; then
                        printf '%s\n' "$line"
                        break
                    fi
                done
                ;;
            package)
                if [[ "$compact" == *"launch=\"$name\""* ]] \
                    || [[ "$line" == *"omarchy-launch-or-focus-tui $name"* ]] \
                    || [[ "$line" == *"uwsm-app -- $name"* ]]; then
                    printf '%s\n' "$line"
                fi
                ;;
            tui)
                if [[ "$compact" == *"tui=\"$name\""* ]] \
                    || [[ "$line" == *"omarchy-launch-tui $name"* ]] \
                    || [[ "$line" == *"omarchy-launch-or-focus-tui $name"* ]]; then
                    printf '%s\n' "$line"
                fi
                ;;
        esac
    done < "$BINDINGS_FILE"
}

remove_matching_bindings() {
    local bindings=("$@")
    local binding backup_file tmp_file line remove_line

    [[ "${#bindings[@]}" -gt 0 ]] || return 0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: back up $BINDINGS_FILE and remove ${#bindings[@]} matching Hyprland binding(s)"
        for binding in "${bindings[@]}"; do
            echo "DRYRUN: remove binding: $binding"
        done
        return 0
    fi

    backup_file="$(mktemp "${BINDINGS_FILE}.backup.XXXXXX")"
    cp -p "$BINDINGS_FILE" "$backup_file"
    tmp_file="$(mktemp "${BINDINGS_FILE}.tmp.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        remove_line=0
        for binding in "${bindings[@]}"; do
            if [[ "$line" == "$binding" ]]; then
                remove_line=1
                break
            fi
        done
        [[ "$remove_line" -eq 1 ]] || printf '%s\n' "$line" >> "$tmp_file"
    done < "$BINDINGS_FILE"

    chmod --reference="$BINDINGS_FILE" "$tmp_file"
    mv "$tmp_file" "$BINDINGS_FILE"
    echo "Removed ${#bindings[@]} matching Hyprland binding(s); backup: $backup_file"
}

# --- --list mode -----------------------------------------------------------

if [[ "$MODE" == "list" ]]; then
    echo "Packages:"
    if [[ "${#pkg_candidates[@]}" -eq 0 ]]; then
        echo "  (none)"
    else
        for p in "${pkg_candidates[@]}"; do echo "  $p"; done
    fi
    [[ -n "$pkg_warning" ]] && echo "  $pkg_warning"

    echo "Web apps:"
    if [[ "${#webapp_candidates[@]}" -eq 0 ]]; then
        echo "  (none)"
    else
        for w in "${webapp_candidates[@]}"; do echo "  $w"; done
    fi

    echo "TUIs:"
    if [[ "${#tui_candidates[@]}" -eq 0 ]]; then
        echo "  (none)"
    else
        for t in "${tui_candidates[@]}"; do echo "  $t"; done
    fi

    echo "Agent CLI stubs:"
    if [[ "${#stub_present[@]}" -eq 0 ]]; then
        echo "  (none)"
    else
        for s in "${stub_present[@]}"; do echo "  $s"; done
    fi
    [[ -n "$stub_warning" ]] && echo "  $stub_warning"

    exit 0
fi

# --- Selection UI ------------------------------------------------------

any_candidates=0
[[ "${#pkg_candidates[@]}" -gt 0 || "${#webapp_candidates[@]}" -gt 0 || "${#tui_candidates[@]}" -gt 0 || "${#stub_present[@]}" -gt 0 ]] && any_candidates=1

if [[ "$any_candidates" -eq 0 ]]; then
    echo "Nothing removable found."
    exit 0
fi

selected_pkgs=()
if [[ "${#pkg_candidates[@]}" -gt 0 ]]; then
    mapfile -t selected_pkgs < <(gum choose --no-limit --header "Packages" "${pkg_candidates[@]}")
else
    echo "No packages found — skipping."
fi

selected_webapps=()
if [[ "${#webapp_candidates[@]}" -gt 0 ]]; then
    mapfile -t selected_webapps < <(gum choose --no-limit --header "Web apps" "${webapp_candidates[@]}")
else
    echo "No web apps found — skipping."
fi

selected_tuis=()
if [[ "${#tui_candidates[@]}" -gt 0 ]]; then
    mapfile -t selected_tuis < <(gum choose --no-limit --header "TUIs" "${tui_candidates[@]}")
else
    echo "No TUIs found — skipping."
fi

selected_stubs=()
if [[ "${#stub_present[@]}" -gt 0 ]]; then
    mapfile -t selected_stubs < <(gum choose --no-limit --header "Agent CLI stubs" "${stub_present[@]}")
else
    echo "No agent CLI stubs found — skipping."
fi

selected_bindings=()
for name in "${selected_pkgs[@]}"; do
    mapfile -t matching_bindings < <(find_matching_bindings package "$name" | sort -u)
    selected_bindings+=("${matching_bindings[@]}")
done
for name in "${selected_webapps[@]}"; do
    mapfile -t matching_bindings < <(find_matching_bindings webapp "$name" | sort -u)
    selected_bindings+=("${matching_bindings[@]}")
done
for name in "${selected_tuis[@]}"; do
    mapfile -t matching_bindings < <(find_matching_bindings tui "$name" | sort -u)
    selected_bindings+=("${matching_bindings[@]}")
done
if [[ "${#selected_bindings[@]}" -gt 1 ]]; then
    mapfile -t selected_bindings < <(printf '%s\n' "${selected_bindings[@]}" | sort -u)
fi

remove_bindings=0
if [[ "${#selected_bindings[@]}" -gt 0 ]]; then
    echo "Found ${#selected_bindings[@]} matching Hyprland binding(s) in $BINDINGS_FILE."
    echo "A backup will be made; bindings are changed only after every selected removal succeeds."
    if gum confirm "Also remove these matching bindings?"; then
        remove_bindings=1
    fi
fi

total_selected=$(( ${#selected_pkgs[@]} + ${#selected_webapps[@]} + ${#selected_tuis[@]} + ${#selected_stubs[@]} ))

if [[ "$total_selected" -eq 0 ]]; then
    echo "Nothing selected."
    exit 0
fi

# --- Summary + confirm ---------------------------------------------------

echo ""
echo "Selected for removal:"
if [[ "${#selected_pkgs[@]}" -gt 0 ]]; then
    echo "  Packages: ${selected_pkgs[*]}"
fi
if [[ "${#selected_webapps[@]}" -gt 0 ]]; then
    echo "  Web apps: ${selected_webapps[*]}"
fi
if [[ "${#selected_tuis[@]}" -gt 0 ]]; then
    echo "  TUIs: ${selected_tuis[*]}"
fi
if [[ "${#selected_stubs[@]}" -gt 0 ]]; then
    echo "  Agent CLI stubs: ${selected_stubs[*]}"
fi
if [[ "$remove_bindings" -eq 1 ]]; then
    echo "  Hyprland bindings: ${#selected_bindings[@]} matching binding(s)"
fi
echo ""

if ! gum confirm "Remove the $total_selected selected items?"; then
    echo "Cancelled."
    exit 0
fi

# --- Execution -----------------------------------------------------------

if [[ "${#selected_pkgs[@]}" -gt 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: omarchy-pkg-drop ${selected_pkgs[*]}"
    else
        omarchy-pkg-drop "${selected_pkgs[@]}"
    fi
fi

for name in "${selected_webapps[@]}"; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: omarchy-webapp-remove $name"
    else
        omarchy-webapp-remove "$name"
    fi
done

for name in "${selected_tuis[@]}"; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: omarchy-tui-remove $name"
    else
        omarchy-tui-remove "$name"
    fi
done

if [[ "${#selected_stubs[@]}" -gt 0 ]]; then
    for stub in "${selected_stubs[@]}"; do
        # Re-checked here so a path that stopped being Omarchy's own between the
        # picker and this point is never deleted.
        if ! stub_owned_by_omarchy "$stub"; then
            echo "Skipping $stub: not the wrapper Omarchy installed."
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "DRYRUN: rm -f $BIN_DIR/$stub"
        else
            rm -f "$BIN_DIR/$stub"
        fi
    done
fi

# The binding file is deliberately changed only after all selected removal
# commands have completed successfully. Its backup makes this optional cleanup
# fully reversible if a match turns out not to be wanted.
if [[ "$remove_bindings" -eq 1 ]]; then
    remove_matching_bindings "${selected_bindings[@]}"
fi

# --- Marker semantics ------------------------------------------------------

full_selection=1
[[ "${#pkg_candidates[@]}" -gt 0 && "${#selected_pkgs[@]}" -ne "${#pkg_candidates[@]}" ]] && full_selection=0
[[ "${#webapp_candidates[@]}" -gt 0 && "${#selected_webapps[@]}" -ne "${#webapp_candidates[@]}" ]] && full_selection=0
[[ "${#tui_candidates[@]}" -gt 0 && "${#selected_tuis[@]}" -ne "${#tui_candidates[@]}" ]] && full_selection=0
[[ "${#stub_present[@]}" -gt 0 && "${#selected_stubs[@]}" -ne "${#stub_present[@]}" ]] && full_selection=0

if [[ "$full_selection" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: mkdir -p ~/.local/state/omarchy && touch ~/.local/state/omarchy/preinstalls-removed"
    else
        mkdir -p "$HOME/.local/state/omarchy"
        touch "$HOME/.local/state/omarchy/preinstalls-removed"
    fi
else
    echo "Partial removal: Omarchy's preinstalls-removed flag was left unset, so Hyprland keybindings/menu entries for removed apps may linger until you remove the rest (or re-run omarchy-install-preinstalls to restore)."
fi

if command -v hyprctl >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRYRUN: hyprctl reload"
    else
        hyprctl reload || true
    fi
fi

echo ""
echo "Restore everything at any time with: omarchy-install-preinstalls"
