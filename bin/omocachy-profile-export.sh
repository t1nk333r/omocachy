#!/bin/bash
set -euo pipefail

# omocachy-profile-export.sh — capture this machine's Omarchy desktop profile
# into a portable bundle: the Quickshell layer (~/.config/omarchy: shell.json,
# plugins, themes, extensions, hooks), Hyprland and shell/tooling config, the
# explicit package list, mise tools and the enabled user units.
#
# Read-only with respect to the running system: it only writes inside the
# output directory. Run it on the machine you are leaving, then
# bin/omocachy-profile-import.sh on the CachyOS machine you are moving to
# (after bin/install-omarchy-quattro.sh has put Omarchy 4 there).
#
# Design and evidence: plans/018-omarchy-profile-migration.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=bin/lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

DRY_RUN=false
ASSUME_YES=false
SLIM=false
ARCHIVE=false
OUT_ROOT="$PWD"
PATHS_FILE="$REPO_DIR/share/profile-paths.conf"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--out DIR] [--paths FILE] [--slim] [--archive] [--dry-run] [--yes]

  --out DIR      Where to create the bundle directory (default: cwd).
  --paths FILE   Capture list, relative to \$HOME
                 (default: share/profile-paths.conf).
  --slim         Skip theme backgrounds (~/.config/omarchy/themes/*/backgrounds
                 and ~/.local/share/omarchy/themes/*/backgrounds). Wallpapers
                 dominate the size of a full bundle.
  --archive      Also write <bundle>.tar.zst (or .tar.gz) plus a .sha256, for
                 transport. Off by default so the bundle is not stored twice.
  --dry-run      Print the capture plan; write nothing.
  --yes          Skip the confirmation prompt.
USAGE
}

while (($#)); do
    case "$1" in
    --out)
        OUT_ROOT="${2:?--out needs a directory}"
        shift 2
        ;;
    --paths)
        PATHS_FILE="${2:?--paths needs a file}"
        shift 2
        ;;
    --slim)
        SLIM=true
        shift
        ;;
    --archive)
        ARCHIVE=true
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
require_cmds tar jq find du
[[ -r $PATHS_FILE ]] || die "capture list not readable: $PATHS_FILE"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_ID="omocachy-profile-$(uname -n)-$TIMESTAMP"
BUNDLE="$OUT_ROOT/$BUNDLE_ID"
WORK="$(mktemp -d -t omocachy-export-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

OMARCHY_CONFIG="$HOME/.config/omarchy"
PLUGIN_DIR="$OMARCHY_CONFIG/plugins"

echo "=== omocachy-profile-export.sh ==="
$DRY_RUN && echo "(dry-run: nothing will be written)"
echo ""

# ---------------------------------------------------------------------------
# What is here to capture
# ---------------------------------------------------------------------------

mapfile -t CAPTURE_PATHS < <(profile_read_paths "$PATHS_FILE")
PRESENT=()
for rel in "${CAPTURE_PATHS[@]}"; do
    [[ -e "$HOME/$rel" ]] && PRESENT+=("$rel")
done
((${#PRESENT[@]})) || die "none of the paths in $PATHS_FILE exist under $HOME."

pkg_version() { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }

OMARCHY_VERSION="$(pkg_version omarchy)"
SETTINGS_VERSION="$(pkg_version omarchy-settings)"
QUICKSHELL_PKG="$(pacman -Qq 2>/dev/null | grep -m1 -E '^quickshell(-git)?$' || true)"
QUICKSHELL_VERSION="${QUICKSHELL_PKG:+$(pkg_version "$QUICKSHELL_PKG")}"
SOURCE_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
GPU_TYPE="$(bash "$SCRIPT_DIR/gpu-detect.sh" 2>/dev/null || echo unknown)"

[[ -n $OMARCHY_VERSION ]] || warn "the omarchy package is not installed here; capturing config anyway."

echo "Source:        $SOURCE_ID, kernel $(uname -r), GPU $GPU_TYPE"
echo "Omarchy:       ${OMARCHY_VERSION:-absent} (omarchy-settings ${SETTINGS_VERSION:-absent}, ${QUICKSHELL_PKG:-no quickshell} ${QUICKSHELL_VERSION:-})"
echo "Capture list:  $PATHS_FILE (${#PRESENT[@]} of ${#CAPTURE_PATHS[@]} paths present)"
echo "Bundle:        $BUNDLE"
echo "Slim:          $SLIM"
echo ""

confirm "Create the bundle?" || die "aborted."

# ---------------------------------------------------------------------------
# Exclude set: regenerable junk, per-repo git-ignored files, --slim wallpapers
#
# Excluding each git repository's ignored files is what keeps a bundle
# reasonable: build output inside plugin checkouts (a Rust daemon's
# target/ dir, for one) is both large and reproducible from the checkout.
# ---------------------------------------------------------------------------

EXCLUDE_FILE="$WORK/excludes"
: >"$EXCLUDE_FILE"
: >"$WORK/secret-exemptions.txt"
printf '%s\n' "${PROFILE_JUNK_EXCLUDES[@]}" >>"$EXCLUDE_FILE"

if $SLIM; then
    # Wallpapers, wherever a theme keeps them. Measured on this project's dev
    # machine: an anchored 'themes/*/backgrounds' pattern is matched against
    # each member name and so misses the files below the directory, while the
    # unanchored form drops the directories and their contents (520 MiB of
    # themes -> 348 MiB).
    printf '%s\n' '*backgrounds' >>"$EXCLUDE_FILE"
fi

IGNORED_COUNT=0
while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"
    rel_repo="${repo#"$HOME"/}"
    while IFS= read -r ignored; do
        [[ -z $ignored ]] && continue
        printf '%s\n' "$rel_repo/${ignored%/}" >>"$EXCLUDE_FILE"
        IGNORED_COUNT=$((IGNORED_COUNT + 1))
    done < <(git -C "$repo" status --porcelain --ignored=matching 2>/dev/null |
        sed -n 's/^!! //p' | tr -d '"')
done < <(for rel in "${PRESENT[@]}"; do
    [[ -d "$HOME/$rel" ]] && find "$HOME/$rel" -maxdepth 3 -name .git -print 2>/dev/null
done)

echo "Excludes:      ${#PROFILE_JUNK_EXCLUDES[@]} junk globs + $IGNORED_COUNT git-ignored paths$($SLIM && echo " + theme backgrounds")"

# ---------------------------------------------------------------------------
# Stage the payload
# ---------------------------------------------------------------------------

if $DRY_RUN; then
    echo ""
    echo "DRYRUN: would capture into $BUNDLE/home:"
    for rel in "${PRESENT[@]}"; do
        printf '    %8s  %s\n' "$(du -sh --exclude=.git "$HOME/$rel" 2>/dev/null | cut -f1)" "$rel"
    done
else
    mkdir -p "$BUNDLE/home" "$BUNDLE/packages" "$BUNDLE/services" "$BUNDLE/system"
    chmod 700 "$BUNDLE"
    echo ""
    echo "--- Staging payload ---"
    for rel in "${PRESENT[@]}"; do
        rc=0
        tar -C "$HOME" -cf - --exclude-from="$EXCLUDE_FILE" \
            --warning=no-file-changed --warning=no-file-ignored -- "$rel" |
            tar -C "$BUNDLE/home" -xf - || rc=$?
        # tar exits 1 for "file changed/vanished while reading" (a live
        # desktop writes its own config); 2 is a real failure.
        ((rc <= 1)) || die "tar failed on $rel (exit $rc)"
        ((rc == 0)) || warn "$rel changed while being read; captured what was there."
        printf '    ok  %s\n' "$rel"
    done
fi

# ---------------------------------------------------------------------------
# Secret sweep: names that look like credentials leave the payload.
#
# Two exemptions keep the sweep from eating the workflow it is meant to
# carry: an executable file is a script (~/.local/bin/gotify-token-fetch is
# a tool, not a token) and a source/media extension is code or an asset (a
# plugin's docs/add-token.png). Everything actually removed is listed in the
# manifest and SUMMARY, so a false positive stays visible.
# ---------------------------------------------------------------------------

# Extensions that are code or assets, never a credential store.
PROFILE_SECRET_EXEMPT_EXT='qml|js|mjs|ts|jsx|tsx|py|rs|go|c|h|cpp|sh|bash|fish|zsh|lua|md|html|css|scss|png|jpg|jpeg|gif|svg|webp|ico|mp3|wav|ogg|mp4|webm|ttf|otf|woff2?'

SECRETS_REMOVED="$WORK/secrets-removed.txt"
: >"$SECRETS_REMOVED"
if ! $DRY_RUN; then
    find_args=()
    for glob in "${PROFILE_SECRET_FILE_GLOBS[@]}"; do
        ((${#find_args[@]})) && find_args+=(-o)
        find_args+=(-name "$glob")
    done
    while IFS= read -r hit; do
        rel_hit="${hit#"$BUNDLE/home/"}"
        if [[ -x $hit ]]; then
            printf '%s\tkept: executable, treated as a script\n' "$rel_hit" >>"$WORK/secret-exemptions.txt"
            continue
        fi
        if [[ ${hit,,} =~ \.($PROFILE_SECRET_EXEMPT_EXT)$ ]]; then
            printf '%s\tkept: source/asset extension\n' "$rel_hit" >>"$WORK/secret-exemptions.txt"
            continue
        fi
        printf '%s\n' "$rel_hit" >>"$SECRETS_REMOVED"
        rm -f "$hit"
    done < <(find "$BUNDLE/home" -type f \( "${find_args[@]}" \) -print 2>/dev/null)
    for d in "${PROFILE_SECRET_DIRS[@]}"; do
        if [[ -e "$BUNDLE/home/$d" ]]; then
            printf '%s (credential store)\n' "$d" >>"$SECRETS_REMOVED"
            rm -rf "${BUNDLE:?}/home/${d:?}"
        fi
    done
fi
SECRET_HITS=$(wc -l <"$SECRETS_REMOVED" | tr -d ' ')

# Files that keep credentials inline are part of the desktop profile
# (shell.json carries plugin service URLs and API keys) and must travel;
# flag them so the bundle is treated as sensitive.
INLINE_SECRETS="$WORK/inline-secrets.txt"
: >"$INLINE_SECRETS"
if ! $DRY_RUN; then
    grep -rlIE "$PROFILE_SECRET_CONTENT_RE" "$BUNDLE/home" 2>/dev/null |
        sed "s|^$BUNDLE/home/||" | sort >"$INLINE_SECRETS" || true
fi
INLINE_HITS=$(wc -l <"$INLINE_SECRETS" | tr -d ' ')

# ---------------------------------------------------------------------------
# Metadata: plugins, packages, mise, services, system facts
# ---------------------------------------------------------------------------

PLUGIN_TSV="$WORK/plugins.tsv"
profile_plugin_rows "$PLUGIN_DIR" >"$PLUGIN_TSV" || true
PLUGIN_COUNT=$(wc -l <"$PLUGIN_TSV" | tr -d ' ')
PLUGIN_LOCAL=$(awk -F'\t' '$2=="local"' "$PLUGIN_TSV" | wc -l | tr -d ' ')

# shell.json's plugin references that no package provides; each must exist as
# a directory on the target or the shell drops that part of its graph.
SHELL_IDS="$WORK/shell-plugin-ids.txt"
profile_shelljson_plugin_ids "$OMARCHY_CONFIG/shell.json" >"$SHELL_IDS" || true

NATIVE="$WORK/explicit-native.txt"
FOREIGN="$WORK/explicit-foreign.txt"
pacman -Qqen 2>/dev/null | sort >"$NATIVE" || : >"$NATIVE"
pacman -Qqem 2>/dev/null | sort >"$FOREIGN" || : >"$FOREIGN"
# Explicit packages that came from the [omarchy] repo: the importer gets them
# from the same repo, which install-omarchy-quattro.sh has already added.
OMARCHY_REPO="$WORK/omarchy-repo.txt"
if pacman -Sl omarchy &>/dev/null; then
    pacman -Sl omarchy 2>/dev/null | awk '{print $2}' | sort |
        comm -12 - <(cat "$NATIVE" "$FOREIGN" | sort -u) >"$OMARCHY_REPO"
else
    : >"$OMARCHY_REPO"
fi

MISE_TOOLS="$WORK/mise-tools.txt"
if have mise; then
    mise ls --current 2>/dev/null >"$MISE_TOOLS" || : >"$MISE_TOOLS"
else
    : >"$MISE_TOOLS"
fi

USER_UNITS="$WORK/user-enabled.txt"
SYSTEM_UNITS="$WORK/system-enabled.txt"
systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null |
    awk '{print $1}' | sort >"$USER_UNITS" || : >"$USER_UNITS"
systemctl list-unit-files --state=enabled --no-legend 2>/dev/null |
    awk '{print $1}' | sort >"$SYSTEM_UNITS" || : >"$SYSTEM_UNITS"

# Recorded in manifest.json as source.yadm_remote: a URL-form remote can embed
# a token, so scrub the userinfo the same way profile_plugin_rows does.
YADM_REMOTE="$(yadm remote get-url origin 2>/dev/null | sed 's|^\([a-z+][a-z+]*://\)[^/@]*@|\1|' || true)"

if ! $DRY_RUN; then
    cp -a "$NATIVE" "$FOREIGN" "$OMARCHY_REPO" "$MISE_TOOLS" "$BUNDLE/packages/"
    cp -a "$USER_UNITS" "$SYSTEM_UNITS" "$BUNDLE/services/"
    cp -a "$PLUGIN_TSV" "$SHELL_IDS" "$BUNDLE/system/"
    cp -a "$SECRETS_REMOVED" "$INLINE_SECRETS" "$WORK/secret-exemptions.txt" "$BUNDLE/system/"
    cp -a /etc/os-release "$BUNDLE/system/os-release" 2>/dev/null || true
    pacman -Q 2>/dev/null >"$BUNDLE/system/pacman-Q.txt" || true
    PAYLOAD_SIZE="$(du -sh "$BUNDLE/home" | cut -f1)"
    PAYLOAD_BYTES="$(du -sb "$BUNDLE/home" | cut -f1)"
else
    PAYLOAD_SIZE="(dry-run)"
    PAYLOAD_BYTES=0
fi

# ---------------------------------------------------------------------------
# manifest.json + SUMMARY.md
# ---------------------------------------------------------------------------

write_manifest() {
    jq -n \
        --argjson schema "$PROFILE_SCHEMA" \
        --arg created "$(date -Is)" \
        --arg host "$(uname -n)" \
        --arg user "$USER" \
        --arg home "$HOME" \
        --arg source_id "$SOURCE_ID" \
        --arg kernel "$(uname -r)" \
        --arg gpu "$GPU_TYPE" \
        --arg omarchy "${OMARCHY_VERSION:-}" \
        --arg settings "${SETTINGS_VERSION:-}" \
        --arg quickshell_pkg "${QUICKSHELL_PKG:-}" \
        --arg quickshell "${QUICKSHELL_VERSION:-}" \
        --arg yadm "${YADM_REMOTE:-}" \
        --argjson slim "$($SLIM && echo true || echo false)" \
        --argjson payload_bytes "${PAYLOAD_BYTES:-0}" \
        --arg captured "$(printf '%s\n' "${PRESENT[@]}")" \
        --rawfile plugins "$PLUGIN_TSV" \
        --rawfile shell_ids "$SHELL_IDS" \
        --rawfile secrets "$SECRETS_REMOVED" \
        --rawfile inline "$INLINE_SECRETS" \
        --rawfile native "$NATIVE" \
        --rawfile foreign "$FOREIGN" \
        --rawfile omarchy_repo "$OMARCHY_REPO" \
        --rawfile user_units "$USER_UNITS" \
        '
        def lines: split("\n") | map(select(length > 0));
        {
          schema: $schema,
          created: $created,
          source: {
            host: $host, user: $user, home: $home, os_release_id: $source_id,
            kernel: $kernel, gpu: $gpu,
            omarchy: $omarchy, omarchy_settings: $settings,
            quickshell_package: $quickshell_pkg, quickshell: $quickshell,
            yadm_remote: $yadm
          },
          options: { slim: $slim },
          payload: { bytes: $payload_bytes, captured: ($captured | lines) },
          plugins: ($plugins | lines | map(split("\t") | {
            id: .[0], kind: .[1], remote: .[2], branch: .[3],
            commit: .[4], dirty: .[5]
          })),
          shell_json_plugin_ids: ($shell_ids | lines),
          packages: {
            explicit_native: ($native | lines),
            explicit_foreign: ($foreign | lines),
            from_omarchy_repo: ($omarchy_repo | lines)
          },
          services: { user_enabled: ($user_units | lines) },
          secrets: {
            removed: ($secrets | lines),
            inline_credentials: ($inline | lines)
          }
        }
        '
}

if $DRY_RUN; then
    echo ""
    echo "DRYRUN: would write $BUNDLE/manifest.json, SUMMARY.md, packages/, services/, system/"
else
    write_manifest >"$BUNDLE/manifest.json"

    {
        echo "# $BUNDLE_ID"
        echo ""
        echo "Omarchy desktop profile captured by omocachy-profile-export.sh."
        echo ""
        echo "| Fact | Value |"
        echo "|---|---|"
        echo "| Created | $(date -Is) |"
        echo "| Source host | $(uname -n) ($SOURCE_ID, kernel $(uname -r)) |"
        echo "| User / home | $USER / $HOME |"
        echo "| Omarchy | ${OMARCHY_VERSION:-absent} / settings ${SETTINGS_VERSION:-absent} |"
        echo "| Quickshell | ${QUICKSHELL_PKG:-absent} ${QUICKSHELL_VERSION:-} |"
        echo "| GPU vendor | $GPU_TYPE |"
        echo "| Payload | $PAYLOAD_SIZE across ${#PRESENT[@]} paths |"
        echo "| Plugins | $PLUGIN_COUNT ($PLUGIN_LOCAL local-only — this bundle is their only copy) |"
        echo "| Explicit packages | $(wc -l <"$NATIVE" | tr -d ' ') native, $(wc -l <"$FOREIGN" | tr -d ' ') foreign/AUR |"
        echo "| Enabled user units | $(wc -l <"$USER_UNITS" | tr -d ' ') |"
        echo "| Slim | $SLIM |"
        echo ""
        echo "## Restore"
        echo ""
        echo '```bash'
        echo "# on the CachyOS machine, after bin/install-omarchy-quattro.sh:"
        echo "bin/omocachy-profile-import.sh --bundle <this-bundle> --dry-run"
        echo "bin/omocachy-profile-import.sh --bundle <this-bundle>"
        echo '```'
        echo ""
        echo "## Handle as sensitive"
        echo ""
        echo "$SECRET_HITS credential-shaped paths were removed from the payload"
        echo "(see \`system/secrets-removed.txt\`); $INLINE_HITS captured files still"
        echo "carry inline credentials — Quickshell plugin settings live in"
        echo "\`shell.json\`, API keys included (see \`system/inline-secrets.txt\`)."
        echo "Keep the bundle on trusted media."
        echo ""
        echo "## Captured paths"
        echo ""
        printf -- '- %s\n' "${PRESENT[@]}"
    } >"$BUNDLE/SUMMARY.md"
fi

# ---------------------------------------------------------------------------
# Optional archive for transport
# ---------------------------------------------------------------------------

if $ARCHIVE && ! $DRY_RUN; then
    echo ""
    echo "--- Archiving ---"
    if have zstd; then
        ARCHIVE_PATH="$BUNDLE.tar.zst"
        tar -C "$OUT_ROOT" -cf - "$BUNDLE_ID" | zstd -q -T0 -3 -o "$ARCHIVE_PATH" -f
    else
        ARCHIVE_PATH="$BUNDLE.tar.gz"
        tar -C "$OUT_ROOT" -czf "$ARCHIVE_PATH" "$BUNDLE_ID"
    fi
    chmod 600 "$ARCHIVE_PATH"
    (cd "$(dirname "$ARCHIVE_PATH")" && sha256sum "$(basename "$ARCHIVE_PATH")" >"$ARCHIVE_PATH.sha256")
    echo "    $ARCHIVE_PATH ($(du -sh "$ARCHIVE_PATH" | cut -f1))"
elif $ARCHIVE; then
    echo "DRYRUN: would write $BUNDLE.tar.zst + .sha256"
fi

echo ""
if $DRY_RUN; then
    echo "Dry run complete; nothing was written."
    exit 0
fi

echo "Bundle: $BUNDLE ($PAYLOAD_SIZE payload)"
echo "  plugins: $PLUGIN_COUNT ($PLUGIN_LOCAL local-only), secrets removed: $SECRET_HITS, files with inline credentials: $INLINE_HITS"
echo ""
echo "Next: on the CachyOS target, install Omarchy 4 with bin/install-omarchy-quattro.sh,"
echo "then restore this bundle with bin/omocachy-profile-import.sh --bundle $BUNDLE_ID"
