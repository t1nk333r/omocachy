# shellcheck shell=bash
# common.sh — helpers shared by omacachy's scripts. Sourced, never executed.
#
# The dry-run contract: every state-changing command in this project flows
# through one of the helpers below. In dry-run mode they print the command
# (and, for file writes, the full content) instead of running it, so review
# can enforce "no sudo outside run_root/write_root_file/append_root_file"
# with a single grep and "no state changes in --dry-run" by inspection.

[[ -n ${OMACACHY_COMMON_SH:-} ]] && return 0
OMACACHY_COMMON_SH=1

# Scripts set this from their own --dry-run flag before calling the helpers.
DRY_RUN=${DRY_RUN:-false}

# parse_dry_run_flag "$@" — the standard flag set for the small GPU scripts:
# --dry-run anywhere sets DRY_RUN=true, -h/--help prints usage, and anything
# else is refused with usage on stderr. Parsing every argument (not just $1)
# is what keeps a misplaced flag from silently taking the privileged path.
# Callers that only forward the flag (gpu-setup.sh) ignore the variable.
parse_dry_run_flag() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h | --help)
            echo "Usage: $(basename "$0") [--dry-run]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $(basename "$0") [--dry-run]" >&2
            exit 1
            ;;
        esac
    done
}

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

# The session-environment file both GPU scripts write. ~/.config/uwsm/env is
# the user's own file (often dotfile-managed) and is never appended to; uwsm
# also sources env.d/* (uwsm(1) CONFIGURATION: "uwsm/env, uwsm/env.d/*"),
# which gives the scripts a file they own outright and can rewrite on re-runs.
OMACACHY_GPU_ENV_FILE="$HOME/.config/uwsm/env.d/50-omacachy-gpu"

# write_gpu_session_env LABEL CONTENT — write the vendor's session
# environment, or print it under OMACACHY_SKIP_USER_CONFIGS=1, where $HOME is
# off limits. LABEL names the vendor in the confirmation line ("NVIDIA").
write_gpu_session_env() {
    local label="$1" content="$2"
    if [[ ${OMACACHY_SKIP_USER_CONFIGS:-0} == 1 ]]; then
        info "--skip-user-configs: not writing $OMACACHY_GPU_ENV_FILE. Recommended session environment (add to your own uwsm env or env.d file):"
        printf '%s\n' "$content"
    else
        printf '%s\n' "$content" | write_user_file "$OMACACHY_GPU_ENV_FILE"
        # Pre-rename machines have 50-omocachy-gpu; uwsm sources every env.d
        # file, so a stale copy would keep exporting the same variables.
        local legacy_env="$HOME/.config/uwsm/env.d/50-omocachy-gpu"
        if [[ -e $legacy_env ]]; then
            if $DRY_RUN; then
                echo "DRYRUN: rm -f $legacy_env"
            else
                rm -f "$legacy_env"
                info "removed the pre-rename $legacy_env"
            fi
        fi
        info "$label session environment written to $OMACACHY_GPU_ENV_FILE"
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
# (adopted from jeanmartins7/omarchy-on-cachyos, whose installer tees every run).
start_logging() {
    local log="$1"
    mkdir -p "$(dirname "$log")"
    exec > >(tee -a "$log") 2>&1
    info "log: $log"
}
