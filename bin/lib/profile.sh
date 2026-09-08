# shellcheck shell=bash
# shellcheck disable=SC2034  # this is a library: its arrays are used by callers
# profile.sh — the profile-bundle format shared by omocachy-profile-export.sh,
# omocachy-profile-import.sh and omocachy-doctor.sh. Sourced, never executed.
#
# Bundle layout (schema 1):
#
#   <bundle>/
#     manifest.json        source facts, captured paths, plugin table, hashes
#     SUMMARY.md           the same, for humans
#     home/                payload, relative to $HOME
#     packages/            explicit-native.txt, explicit-foreign.txt,
#                          omarchy-repo.txt, mise-tools.txt
#     services/            user-enabled.txt, system-enabled.txt
#     system/              informational only: os-release, mkinitcpio HOOKS,
#                          package versions. Never applied by the importer.
#
# A bundle is user data, not a backup: it carries the desktop profile (the
# Quickshell layer, shell/tooling config, the package and mise tool lists),
# not $HOME.

[[ -n ${OMOCACHY_PROFILE_SH:-} ]] && return 0
OMOCACHY_PROFILE_SH=1

PROFILE_SCHEMA=1

# --- what never enters a bundle -------------------------------------------
# Regenerable build output and editor/VCS scratch. tar --exclude globs;
# unanchored, so "*/node_modules" matches at any depth.
PROFILE_JUNK_EXCLUDES=(
    '*/.git/index.lock'
    '*/node_modules'
    '*/__pycache__'
    '*/.venv'
    '*/.mypy_cache'
    '*/.pytest_cache'
    '*/.ruff_cache'
    '*/.direnv'
    '*/.cache'
    '*/target/debug'
    '*/target/release'
    '*.bak'
    '*.bak.*'
    '*.old'
    '*.orig'
    '*.rej'
    '*.log'
    '*.qcow2'
    '*.iso'
    '*.core'
)

# Credential stores, relative to $HOME. Refused even if a --paths file asks
# for them: a profile bundle travels between machines and gets copied around.
PROFILE_SECRET_DIRS=(
    .ssh
    .gnupg
    .password-store
    .aws
    .kube
    .docker
    .mozilla
    .local/share/keyrings
    .config/gh
    .config/op
    .config/sops
    .config/rclone
    .config/Bitwarden
    .config/keepassxc
)

# Secret-shaped file names, swept out of the staged payload after the copy
# (find -name globs). Every hit is listed in the manifest and SUMMARY, so a
# false positive is visible rather than silent.
PROFILE_SECRET_FILE_GLOBS=(
    '*.pem'
    '*.key'
    '*.p12'
    '*.pfx'
    '*.kdbx'
    '*.jks'
    'id_rsa*'
    'id_ed25519*'
    'id_ecdsa*'
    '.netrc'
    '.npmrc'
    '.pypirc'
    '.env'
    '.env.*'
    '*.env'
    '*token*'
    '*Token*'
    '*TOKEN*'
    '*secret*'
    '*Secret*'
    '*credential*'
    '*Credential*'
    '*password*'
    '*.gpg'
    '*.asc'
    'known_hosts'
    'authorized_keys'
)

# Text that suggests a captured config carries a credential inline. Used for
# a warning only — these files (shell.json above all: plugin service URLs and
# API keys live there) are part of the desktop profile and must travel.
PROFILE_SECRET_CONTENT_RE='(api[_-]?key|apikey|access[_-]?token|bearer |client[_-]?secret|password)['"'"'"]?\s*[:=]'

# --- packages the importer never installs ---------------------------------
# "ERE::reason". The bundle lists them anyway (the report names every skip),
# because the decision is the operator's — it is just not automatic.
PROFILE_PKG_DENY=(
    '^linux(-|$)|-headers$::kernel/headers — the target boots its own CachyOS kernel; changing that is boot-critical'
    '^(limine|grub|refind-efi|systemd-boot)::bootloader — installed and configured by the CachyOS install'
    '^(nvidia|lib32-nvidia|opencl-nvidia|nvidia-utils|mesa-vdpau)::GPU driver stack — chwd owns it on CachyOS (bin/gpu-setup.sh)'
    '^(omarchy|omarchy-.*|quickshell|quickshell-git)$::installed by bin/install-omarchy-quattro.sh as packages'
    '^(base|base-devel|pacman|systemd|glibc|linux-firmware.*|mkinitcpio|sddm)$::base system — already provided by CachyOS'
    '^cachyos-::CachyOS metapackages — provided by the target install'
    '^tldr$::conflicts with CachyOS'"'"'s tealdeer (pick one by hand)'
)

profile_pkg_denied() {
    local pkg="$1" entry re reason
    for entry in "${PROFILE_PKG_DENY[@]}"; do
        re="${entry%%::*}"
        reason="${entry##*::}"
        if [[ $pkg =~ $re ]]; then
            printf '%s\n' "$reason"
            return 0
        fi
    done
    return 1
}

# --- capture list ---------------------------------------------------------
# Data lines of a profile-paths.conf, with the hard-denied directories
# filtered out.
profile_read_paths() {
    local file="$1" line deny skip
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z $line ]] && continue
        skip=false
        for deny in "${PROFILE_SECRET_DIRS[@]}"; do
            [[ $line == "$deny" || $line == "$deny"/* ]] && skip=true
        done
        if $skip; then
            printf 'refusing to capture credential store: %s\n' "$line" >&2
            continue
        fi
        printf '%s\n' "$line"
    done <"$file"
}

# --- host-specific files --------------------------------------------------
# Captured (they document the source machine) but not restored on top of a
# working target by default: a monitor layout from another machine is at best
# wrong and can leave no usable display, and a GPU session env for the wrong
# vendor breaks hardware acceleration. The importer parks them as
# <name>.from-<source-host> unless --restore-host-specific is given.
PROFILE_HOST_SPECIFIC=(
    .config/hypr/monitors.lua
    .config/hypr/monitors.conf
    .config/uwsm/env.d/50-omocachy-gpu
)

# --- plugins --------------------------------------------------------------
# TSV rows: id, kind (git|local), remote, branch, commit, dirty. A "local"
# plugin exists only on this machine — nothing can re-clone it, so the bundle
# is its only copy, which is why the payload carries plugin contents instead
# of a list of remotes.
profile_plugin_rows() {
    local dir="$1" p id kind remote branch commit dirty
    [[ -d $dir ]] || return 0
    for p in "$dir"/*/; do
        [[ -d $p ]] || continue
        id="$(basename "$p")"
        if [[ -e $p.git ]]; then
            kind=git
            remote="$(git -C "$p" remote get-url origin 2>/dev/null || echo '-')"
            branch="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
            commit="$(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo '-')"
            if [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]]; then dirty=yes; else dirty=no; fi
        else
            kind=local remote=- branch=- commit=- dirty=-
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$remote" "$branch" "$commit" "$dirty"
    done
}

# Plugin ids shell.json references but that no package ships: every id in
# .plugins[], .bar.layout.* and .disabledPlugins whose namespace is not
# "omarchy." (those are built into the omarchy package).
profile_shelljson_plugin_ids() {
    local shell_json="$1"
    [[ -r $shell_json ]] || return 0
    jq -r '
        [ (.plugins // [])[]?.id,
          ((.bar.layout // {}) | to_entries[]?.value[]?.id),
          (.bar.centerAnchor // empty),
          (.disabledPlugins // [])[]? ]
        | map(select(type == "string"))
        | unique[]
    ' "$shell_json" 2>/dev/null | grep -v '^omarchy\.' || true
}

# --- bundle access --------------------------------------------------------
# Resolve a bundle argument (directory or .tar.zst/.tar.gz archive) to a
# directory. Archives are extracted under $2 (a caller-owned temp dir).
profile_resolve_bundle() {
    local arg="$1" workdir="${2:-}" inner
    if [[ -d $arg ]]; then
        [[ -f $arg/manifest.json ]] || {
            printf 'not a profile bundle (no manifest.json): %s\n' "$arg" >&2
            return 1
        }
        printf '%s\n' "$arg"
        return 0
    fi
    if [[ -f $arg ]]; then
        [[ -n $workdir ]] || {
            printf 'archive bundle needs a work directory\n' >&2
            return 1
        }
        mkdir -p "$workdir"
        tar -C "$workdir" -xf "$arg" || return 1
        inner="$(find "$workdir" -maxdepth 2 -name manifest.json -printf '%h\n' -quit)"
        [[ -n $inner ]] || {
            printf 'no manifest.json inside %s\n' "$arg" >&2
            return 1
        }
        printf '%s\n' "$inner"
        return 0
    fi
    printf 'no such bundle: %s\n' "$arg" >&2
    return 1
}

profile_manifest() {
    jq -r "$2 // empty" "$1/manifest.json" 2>/dev/null
}
