#!/bin/bash
# omocachy test suite. Runs on any Arch-based host; changes nothing.
#
#   tests/run.sh              everything
#   tests/run.sh lint         bash -n + shellcheck
#   tests/run.sh hooks        the mkinitcpio HOOKS merge, against arrays
#   tests/run.sh matrix       the dry run against each tests/fixtures/* sysroot
#   tests/run.sh purity       the dry-run contract (no state-changing binary runs)
#
# What the matrix proves and what it does not: it proves the wrapper's
# DECISION LOGIC takes the intended branch on CachyOS-shaped input. It does
# not prove the resulting system boots. Nothing in this repo has ever been
# run on real CachyOS.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
INSTALLER="$REPO_DIR/bin/install-omarchy-quattro.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1" >&2; [[ $# -lt 2 ]] || printf '     %s\n' "$2" >&2; FAIL=$((FAIL + 1)); }
head_() { printf '\n== %s ==\n' "$1"; }

expect_eq() { # NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected: $2"; printf '     actual:   %s\n' "$3" >&2; fi
}
expect_contains() { # NAME NEEDLE HAYSTACK
    if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain: $2"; printf '     actual:   %.400s\n' "$3" >&2; fi
}

# ---------------------------------------------------------------------------
run_lint() {
    head_ "lint"
    local f
    for f in "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh; do
        if bash -n "$f" 2>"$WORK/err"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")" "$(cat "$WORK/err")"; fi
    done
    if command -v shellcheck &>/dev/null; then
        if shellcheck --severity=error "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh >"$WORK/sc" 2>&1; then
            ok "shellcheck --severity=error"
        else
            bad "shellcheck --severity=error" "$(cat "$WORK/sc")"
        fi
    else
        echo "skip shellcheck (not installed)"
    fi
}

# ---------------------------------------------------------------------------
# The HOOKS merge, driven directly. Each case feeds a captured array and
# Omarchy's shipped array to the rendered drop-in, exactly as mkinitcpio
# would source it.
OMARCHY_HOOKS="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"

run_hooks() {
    head_ "HOOKS merge"
    # shellcheck source=bin/lib/hooks-merge.sh
    source "$REPO_DIR/bin/lib/hooks-merge.sh"

    local cap merged

    # 1. CachyOS systemd/sd-encrypt array with a HOOKS+= drop-in (lvm2).
    cap="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck lvm2"
    merged="$(merge_preview "$cap" "$OMARCHY_HOOKS")"
    expect_eq "systemd/sd-encrypt: merged array" \
        "base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt lvm2 filesystems fsck sd-btrfs-overlayfs" \
        "$merged"
    expect_eq "systemd/sd-encrypt: no udev hook leaks in" "" "$(has_word udev "$merged" && echo leaked)"
    expect_eq "systemd/sd-encrypt: no udev encrypt hook leaks in" "" "$(has_word encrypt "$merged" && echo leaked)"

    # 2. udev/encrypt array with a HOOKS+= drop-in (usr) and lvm2/resume.
    cap="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystems fsck usr"
    merged="$(merge_preview "$cap" "$OMARCHY_HOOKS")"
    expect_eq "udev/encrypt: merged array" \
        "base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt lvm2 resume usr filesystems fsck btrfs-overlayfs" \
        "$merged"
    expect_eq "udev/encrypt: no systemd hook leaks in" "" "$(has_word systemd "$merged" && echo leaked)"

    # 3. Omarchy's own additions survive both flavours.
    expect_eq "plymouth kept (udev)" "yes" "$(has_word plymouth "$merged" && echo yes)"
    expect_eq "overlayfs kept (udev)" "yes" "$(has_word btrfs-overlayfs "$merged" && echo yes)"

    # 4. kms is never re-added when Omarchy drops it (NVIDIA-only host).
    merged="$(merge_preview "base udev kms block encrypt filesystems" "base udev block encrypt filesystems fsck")"
    expect_eq "kms not re-added" "" "$(has_word kms "$merged" && echo readded)"

    # 5. Refusal paths.
    expect_contains "refuse: both flavours" "mutually exclusive" \
        "$(hooks_conflict "base systemd udev block encrypt filesystems" none false)"
    expect_contains "refuse: both encryption hooks" "two unlock paths" \
        "$(hooks_conflict "base systemd block encrypt sd-encrypt filesystems" systemd true)"
    expect_contains "refuse: hooks/cmdline flavour mismatch" "already drifted apart" \
        "$(hooks_conflict "base udev block encrypt filesystems" systemd true)"
    expect_contains "refuse: LUKS with no encryption hook" "neither 'encrypt' nor 'sd-encrypt'" \
        "$(hooks_conflict "base systemd block filesystems" none true)"
    if hooks_conflict "base systemd block sd-encrypt filesystems" systemd true >/dev/null; then
        bad "no refusal for a consistent systemd array"
    else
        ok "no refusal for a consistent systemd array"
    fi

    # 6. HOOKS+= drop-ins are part of the captured value, and the last
    #    lexical conf.d file wins for a plain HOOKS= assignment.
    local d="$WORK/hooks-order"
    mkdir -p "$d/etc/mkinitcpio.conf.d"
    printf 'HOOKS=(base udev block filesystems)\n' >"$d/etc/mkinitcpio.conf"
    printf 'HOOKS=(base udev block encrypt filesystems fsck)\n' >"$d/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
    printf 'HOOKS+=(resume)\n' >"$d/etc/mkinitcpio.conf.d/omarchy_resume.conf"
    printf 'HOOKS+=(lvm2)\n' >"$d/etc/mkinitcpio.conf.d/zz-last.conf"
    expect_eq "effective HOOKS: later conf.d wins, HOOKS+= accumulates" \
        "base udev block encrypt filesystems fsck resume lvm2" \
        "$(effective_hooks "$d/etc/mkinitcpio.conf" "$d/etc/mkinitcpio.conf.d")"
}

# ---------------------------------------------------------------------------
# Fixture matrix. Each fixture directory is a sysroot; expected.decisions is
# the set of key=value decision records that must appear.
dry_run_fixture() { # FIXTURE OUT DEC [extra args...]
    local fixture="$1" out="$2" dec="$3"; shift 3
    : >"$dec"
    OMOCACHY_SYSROOT="$FIXTURES/$fixture" \
    OMOCACHY_DECISIONS_FILE="$dec" \
    OMOCACHY_LOG="$WORK/$fixture.log" \
        "$INSTALLER" --dry-run --yes "$@" >"$out" 2>&1
}

decision() { # DEC KEY
    sed -n "s/^$2=//p" "$1" | tail -1
}

run_matrix() {
    head_ "fixture matrix"
    local fx dec out key want got rc
    for fx in "$FIXTURES"/*/; do
        fx="$(basename "$fx")"
        [[ -f $FIXTURES/$fx/expected.decisions ]] || continue
        dec="$WORK/$fx.dec"; out="$WORK/$fx.out"
        dry_run_fixture "$fx" "$out" "$dec"
        rc=$?
        want="$(sed -n 's/^exit=//p' "$FIXTURES/$fx/expected.decisions" | tail -1)"
        [[ -n $want ]] || want=0
        expect_eq "$fx: exit status" "$want" "$rc"
        while IFS= read -r line; do
            [[ -n $line && $line != \#* && $line != exit=* ]] || continue
            key="${line%%=*}"; want="${line#*=}"
            got="$(decision "$dec" "$key")"
            expect_eq "$fx: $key" "$want" "$got"
        done <"$FIXTURES/$fx/expected.decisions"
        if [[ -f $FIXTURES/$fx/expected.stderr ]]; then
            while IFS= read -r needle; do
                [[ -n $needle && $needle != \#* ]] || continue
                expect_contains "$fx: output mentions '$needle'" "$needle" "$(cat "$out")"
            done <"$FIXTURES/$fx/expected.stderr"
        fi
    done

    # --skip-user-configs must flip exactly three decisions, and the flagless
    # default must leave them on.
    dec="$WORK/skip.dec"; out="$WORK/skip.out"
    dry_run_fixture cachyos-limine-luks "$out" "$dec" --skip-user-configs
    expect_eq "skip-user-configs: skel replay" "skipped" "$(decision "$dec" skel_replay)"
    expect_eq "skip-user-configs: limine refresh" "skipped-user-configs" "$(decision "$dec" refresh_limine)"
    expect_eq "skip-user-configs: provision-user" "skipped" "$(decision "$dec" provision_user)"
    expect_eq "skip-user-configs: no reinstall-configs in the plan" "" "$(grep -c 'DRYRUN.*omarchy-reinstall-configs' "$out" | grep -v '^0$')"
    expect_eq "skip-user-configs: no provision-user in the plan" "" "$(grep -c 'DRYRUN.*omarchy-provision-user' "$out" | grep -v '^0$')"

    dec="$WORK/noskip.dec"; out="$WORK/noskip.out"
    dry_run_fixture cachyos-limine-luks "$out" "$dec"
    expect_eq "default: skel replay" "yes" "$(decision "$dec" skel_replay)"
    expect_eq "default: limine refresh" "yes-restore-cachyos-conf" "$(decision "$dec" refresh_limine)"
    expect_eq "default: provision-user" "yes" "$(decision "$dec" provision_user)"
    expect_contains "default: reinstall-configs present in the plan" "omarchy-reinstall-configs" "$(cat "$out")"
    expect_contains "default: provision-user present in the plan" "omarchy-provision-user" "$(cat "$out")"

    # On a non-Limine machine the skel replay still runs, but refresh-limine
    # is shadowed for the duration of the call.
    dec="$WORK/grub-user.dec"; out="$WORK/grub-user.out"
    dry_run_fixture cachyos-grub-plain "$out" "$dec"
    expect_eq "grub host: limine refresh gated off" "skipped-not-limine" "$(decision "$dec" refresh_limine)"
    expect_contains "grub host: refresh-limine shadowed, replay still runs" \
        "no-op omarchy-refresh-limine" "$(cat "$out")"
}

# ---------------------------------------------------------------------------
# Dry-run purity: put failing stubs for every state-changing binary first on
# PATH and prove none of them is executed.
run_purity() {
    head_ "dry-run purity"
    local shim="$WORK/shim" log="$WORK/shim.log" b
    mkdir -p "$shim"
    : >"$log"
    for b in sudo pacman pacman-key cp mv rm systemctl mkinitcpio limine-mkinitcpio limine-update \
             omarchy-apply-system omarchy-reinstall-configs omarchy-provision-user omarchy-refresh-limine; do
        printf '#!/bin/sh\necho "VIOLATION: %s $*" >>"%s"\nexit 97\n' "$b" "$log" >"$shim/$b"
        chmod +x "$shim/$b"
    done
    local out="$WORK/purity.out" dec="$WORK/purity.dec"
    : >"$dec"
    PATH="$shim:$PATH" \
    OMOCACHY_SYSROOT="$FIXTURES/cachyos-limine-luks" \
    OMOCACHY_DECISIONS_FILE="$dec" \
    OMOCACHY_LOG="$WORK/purity.log" \
        "$INSTALLER" --dry-run --yes >"$out" 2>&1
    local rc=$?
    expect_eq "dry run completes with the stubs first on PATH" "0" "$rc"
    expect_eq "no state-changing binary was executed" "" "$(cat "$log")"
    expect_contains "the plan still prints the sudo commands" "DRYRUN: sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu" "$(cat "$out")"

    # Same for the non-Limine path, which has more moving parts.
    : >"$log"
    PATH="$shim:$PATH" \
    OMOCACHY_SYSROOT="$FIXTURES/cachyos-grub-plain" \
    OMOCACHY_DECISIONS_FILE="$WORK/purity2.dec" \
    OMOCACHY_LOG="$WORK/purity2.log" \
        "$INSTALLER" --dry-run --yes >"$WORK/purity2.out" 2>&1
    rc=$?
    expect_eq "grub dry run completes with the stubs first on PATH" "0" "$rc"
    expect_eq "grub dry run executed no state-changing binary" "" "$(cat "$log")"
}

case "${1:-all}" in
    lint)   run_lint ;;
    hooks)  run_hooks ;;
    matrix) run_matrix ;;
    purity) run_purity ;;
    all)    run_lint; run_hooks; run_matrix; run_purity ;;
    *)      echo "Usage: $0 [lint|hooks|matrix|purity|all]" >&2; exit 2 ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
