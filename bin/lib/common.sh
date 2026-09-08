# shellcheck shell=bash
# common.sh — helpers shared by omocachy's scripts. Sourced, never executed.
#
# The dry-run contract: every state-changing command in this project flows
# through one of the helpers below. In dry-run mode they print the command
# (and, for file writes, the full content) instead of running it, so review
# can enforce "no sudo outside run_root/write_root_file/append_root_file"
# with a single grep and "no state changes in --dry-run" by inspection.

[[ -n ${OMOCACHY_COMMON_SH:-} ]] && return 0
OMOCACHY_COMMON_SH=1

# Scripts set this from their own --dry-run flag before calling the helpers.
DRY_RUN=${DRY_RUN:-false}

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

# Write stdin as unprivileged file $1 (parent directories created).
write_user_file() {
    local dest="$1"
    if $DRY_RUN; then
        echo "DRYRUN: write $dest:"
        sed 's/^/    | /'
    else
        mkdir -p "$(dirname "$dest")"
        cat >"$dest"
    fi
}

have() { command -v "$1" &>/dev/null; }

info() { printf '[*] %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_not_root() {
    [[ $EUID -eq 0 ]] || return 0
    die "do not run this script as root: it works on \$HOME and calls sudo itself where needed."
}

require_cmds() {
    local missing=() c
    for c in "$@"; do
        have "$c" || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# confirm PROMPT — true unless the user declines. Auto-true when ASSUME_YES
# or DRY_RUN is set, so a plan can always be printed unattended.
confirm() {
    local reply
    { ${ASSUME_YES:-false} || $DRY_RUN; } && return 0
    read -r -p "$1 [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]]
}

# Mirror all output into a log file as well as the terminal. Called by the
# long-running scripts so a failed migration leaves a readable transcript
# (adopted from mroboff/omarchy-on-cachyos' installer, which tees every run).
start_logging() {
    local log="$1"
    mkdir -p "$(dirname "$log")"
    exec > >(tee -a "$log") 2>&1
    info "log: $log"
}
