#!/bin/bash
# omocachy test suite. Runs on any Arch-based host; changes nothing.
#
#   tests/run.sh              everything
#   tests/run.sh lint         bash -n + shellcheck
#   tests/run.sh hooks        the mkinitcpio HOOKS merge, against arrays
#   tests/run.sh units        the pure bin/lib/profile.sh helpers
#   tests/run.sh picker       the debloat picker's enumeration (--list)
#   tests/run.sh gpu          GPU vendor dispatch, lspci stubbed
#   tests/run.sh guard        the bundle trust boundary (manifest, digest, members)
#   tests/run.sh rollback     the generated undo (written before the merge)
#   tests/run.sh matrix       the dry run against each tests/fixtures/* sysroot
#   tests/run.sh purity       the dry-run contract (no state-changing binary runs)
#
# What the matrix proves and what it does not: it proves the wrapper's
# DECISION LOGIC takes the intended branch on CachyOS-shaped input. It does
# not prove the resulting system boots: real-CachyOS evidence lives in
# plans/016, plans/017 and handoff.md; this matrix proves decision logic only.

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
    # The documented local gate is warning severity with -x (handoff.md);
    # CI keeps the stricter --severity=error floor.
    SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
    if [[ -n ${OMOCACHY_SKIP_SHELLCHECK:-} ]]; then
        # Explicit, visible opt-out for machines without shellcheck.
        echo "skip shellcheck (OMOCACHY_SKIP_SHELLCHECK set)"
    elif command -v "$SHELLCHECK_BIN" &>/dev/null; then
        if "$SHELLCHECK_BIN" --severity=warning -x "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/lib/*.sh "$TESTS_DIR"/run.sh >"$WORK/sc" 2>&1; then
            ok "shellcheck --severity=warning -x"
        else
            bad "shellcheck --severity=warning -x" "$(cat "$WORK/sc")"
        fi
    else
        bad "lint: shellcheck not installed — install it, set SHELLCHECK_BIN, or set OMOCACHY_SKIP_SHELLCHECK=1 to skip deliberately"
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
# A host without Omarchy installed has no omarchy-* commands, so the wrapper
# takes its "not found on PATH" branch and the seeding decisions are never
# exercised. That is what made this pass for the wrong reason on the
# maintainers' Omarchy box and fail on a pristine CachyOS guest. Put inert
# stubs first on PATH: --dry-run only looks them up, it never executes them
# (and they exit 97 loudly if that ever stops being true).
omarchy_stubs() {
    local dir="$WORK/omarchy-stubs" b
    if [[ ! -d $dir ]]; then
        mkdir -p "$dir"
        for b in omarchy-reinstall-configs omarchy-provision-user omarchy-refresh-limine; do
            printf '#!/bin/sh\necho "test stub: %s must not execute under --dry-run" >&2\nexit 97\n' "$b" >"$dir/$b"
            chmod +x "$dir/$b"
        done
    fi
    printf '%s' "$dir"
}

dry_run_fixture() { # FIXTURE OUT DEC [extra args...]
    local fixture="$1" out="$2" dec="$3"; shift 3
    : >"$dec"
    PATH="$(omarchy_stubs):$PATH" \
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
    for b in sudo pacman pacman-key cp mv rm systemctl mkinitcpio limine-mkinitcpio limine-update ufw ufw-docker updatedb \
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

# ---------------------------------------------------------------------------
# Pure helpers from bin/lib/profile.sh, sourced directly. They carry the
# bundle format's hard rules (credential stores are refused, denied packages
# are named with a reason, only non-omarchy plugin ids need a clone in the
# bundle), and they need no sysroot to assert on.
run_units() {
    head_ "unit helpers"
    local d="$WORK/units" out got
    mkdir -p "$d"

    # 1. Credential stores never enter the capture list.
    printf '%s\n' '.ssh' '.config/hypr' >"$d/paths.conf"
    out="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_read_paths "$d/paths.conf" ) 2>"$d/paths.err" )"
    expect_eq "profile_read_paths: credential store dropped from the list" ".config/hypr" "$out"
    expect_contains "profile_read_paths: the refusal is reported" \
        "refusing to capture credential store: .ssh" "$(cat "$d/paths.err")"

    # 2. The GPU driver stack is never installed by the importer. nvidia-utils
    # rather than a mesa package: the deny list has always covered the former,
    # so the case holds before and after plan 024 tightens the mesa rules.
    got="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_pkg_denied nvidia-utils >/dev/null ) && echo denied || echo allowed )"
    expect_eq "profile_pkg_denied: nvidia-utils denied" "denied" "$got"

    # 3. An ordinary desktop package is not denied.
    got="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_pkg_denied firefox >/dev/null ) && echo denied || echo allowed )"
    expect_eq "profile_pkg_denied: firefox allowed" "allowed" "$got"

    # 4. The bootloader and GPU families (plan 024). The bundle can name any
    # package, so the deny list is a safety floor against a bundle reversing
    # the target's chwd-selected driver stack or dropping bootloader files on
    # a Limine machine: mesa-git, refind and syslinux all used to pass. The
    # allow list is the other half -- the `-.*` families must not be so coarse
    # that they catch ordinary desktop packages.
    local name
    for name in mesa-git lib32-mesa vulkan-radeon lib32-vulkan-radeon \
        xf86-video-amdgpu opencl-mesa lib32-opencl-nvidia intel-media-driver \
        refind syslinux limine-mkinitcpio-hook grub-btrfs nvidia-580xx-utils \
        rocm-hip-runtime cuda; do
        got="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_pkg_denied "$name" >/dev/null ) && echo denied || echo allowed )"
        expect_eq "profile_pkg_denied: $name denied" "denied" "$got"
    done
    for name in firefox neovim ripgrep git jq zoxide mise fd bat; do
        got="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_pkg_denied "$name" >/dev/null ) && echo denied || echo allowed )"
        expect_eq "profile_pkg_denied: $name allowed" "allowed" "$got"
    done

    # 5. omarchy.* plugin ids ship with the omarchy package; only the others
    # have to be re-cloned on the target.
    printf '%s\n' '{"plugins":[{"id":"foo.bar"},{"id":"omarchy.builtin"}]}' >"$d/shell.json"
    out="$( source "$REPO_DIR/bin/lib/profile.sh"; profile_shelljson_plugin_ids "$d/shell.json" )"
    expect_eq "profile_shelljson_plugin_ids: builtins filtered out" "foo.bar" "$out"

    # 6. The snapper assertion must never return success without comparing
    # something. In --verify-only no backup is taken, so the pre-fix body
    # short-circuited to success and printed PASS having compared nothing. The
    # wrapper runs top-level code, so the helper cannot be sourced and the
    # assertion suite cannot run under a fixture sysroot; pin the source shape
    # instead -- the on-disk fallback and the explicit note are present, and the
    # old `[[ -z $SNAPPER_BACKUP ]] ||` short-circuit is gone.
    out="$(sed -n '/^check_snapper()/,/^}/p' "$REPO_DIR/bin/install-omarchy-quattro.sh")"
    if [[ $out == *'omarchy-quattro-backup-*'* && $out == *'cmp -s'* \
        && $out == *'not verified'* && $out != *'[[ -z $SNAPPER_BACKUP ]] ||'* ]]; then
        ok "check_snapper: compares an on-disk backup or reports it cannot verify"
    else
        bad "check_snapper: compares an on-disk backup or reports it cannot verify" "$out"
    fi

    # 7. The inline-credential content sweep (plan 026). SUMMARY.md's "files
    # with inline credentials" count is the operator's only signal about a
    # bundle, so the pattern has to see the shapes real configs use -- apiKey
    # in shell.json above all. The old alternation was lowercase-only and the
    # consumer case-sensitive, so `apiKey`, `API_KEY` and every `*_TOKEN`
    # spelling reported 0. The sweep is warn-only and lists the matching
    # paths, so a broader pattern is visible rather than silent.
    local shape
    for shape in 'apiKey = "x"' 'API_KEY: y' 'GITHUB_TOKEN=z' \
        'AWS_SECRET_ACCESS_KEY=w' 'access_token: t' 'password: p'; do
        got="$( (source "$REPO_DIR/bin/lib/profile.sh"
            printf '%s\n' "$shape" | grep -qiE "$PROFILE_SECRET_CONTENT_RE") && echo matched || echo missed)"
        expect_eq "PROFILE_SECRET_CONTENT_RE matches: $shape" "matched" "$got"
    done
    for shape in 'keyboard = us' 'monitor = DP-1'; do
        got="$( (source "$REPO_DIR/bin/lib/profile.sh"
            printf '%s\n' "$shape" | grep -qiE "$PROFILE_SECRET_CONTENT_RE") && echo matched || echo clean)"
        expect_eq "PROFILE_SECRET_CONTENT_RE ignores: $shape" "clean" "$got"
    done
}

# ---------------------------------------------------------------------------
# Debloat picker enumeration, driven through the script's documented test-only
# overrides (bin/debloat-quattro.sh:15-19). Synthetic upstream script, .desktop
# pair and agent-CLI stub; --list only prints, so nothing here touches the host.
picker_section() { # OUT HEADER
    awk -v h="$2:" '$0 == h { on = 1; next } on && /^[^ ]/ { exit } on { print }' "$1"
}

run_picker() {
    head_ "debloat picker"
    local d="$WORK/picker" g="$WORK/picker-guards" out gout rc
    mkdir -p "$d/apps" "$d/bin"
    printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://example.invalid\n' >"$d/apps/Example.desktop"
    printf '[Desktop Entry]\nExec=xdg-terminal-exec --app-id=TUI.devtools\n' >"$d/apps/Devtools.desktop"
    printf '#!/bin/sh\n' >"$d/bin/codex"
    : >"$d/bindings.conf"
    printf '%s\n' 'omarchy-pkg-drop bash neovim' 'rm -f ~/.local/bin/codex' >"$d/upstream.sh"

    out="$d/list.out"
    DQ_APP_DIR="$d/apps" DQ_BIN_DIR="$d/bin" \
    DQ_OMARCHY_SCRIPT="$d/upstream.sh" DQ_BINDINGS_FILE="$d/bindings.conf" \
        bash "$REPO_DIR/bin/debloat-quattro.sh" --list >"$out" 2>&1
    rc=$?
    expect_eq "picker: --list runs off a Quattro host" "0" "$rc"
    # bash is on every Arch host; the package filter asks pacman for the real
    # installed set, so no other name is guaranteed to appear.
    expect_contains "picker: installed package enumerated" "  bash" "$(picker_section "$out" "Packages")"
    expect_eq "picker: webapp enumerated" "  Example" "$(picker_section "$out" "Web apps")"
    expect_eq "picker: TUI enumerated" "  Devtools" "$(picker_section "$out" "TUIs")"
    expect_eq "picker: agent CLI stub enumerated" "  codex" "$(picker_section "$out" "Agent CLI stubs")"

    # Ownership guards: upstream removes cursor-agent, muse and hermes only
    # when the file at that path is the wrapper Omarchy's own installer wrote,
    # because Cursor's installer, a personal Muse wrapper or Hermes Desktop's
    # command can live there. A user's launcher must not be offered for rm -f.
    mkdir -p "$g/bin"
    printf '%s\n' 'rm -f ~/.local/bin/codex \' '  ~/.local/bin/cursor-agent' \
        'rm -f ~/.local/bin/muse' 'rm -f ~/.local/bin/hermes' >"$g/upstream.sh"
    printf '#!/bin/sh\n' >"$g/bin/codex"
    ln -s /bin/true "$g/bin/cursor-agent"      # Cursor's own link, not the wrapper
    printf 'a personal muse wrapper\n' >"$g/bin/muse"
    printf 'hermes desktop command\n' >"$g/bin/hermes"

    gout="$g/list.out"
    DQ_APP_DIR="$d/apps" DQ_BIN_DIR="$g/bin" \
    DQ_OMARCHY_SCRIPT="$g/upstream.sh" DQ_BINDINGS_FILE="$d/bindings.conf" \
        bash "$REPO_DIR/bin/debloat-quattro.sh" --list >"$gout" 2>&1
    expect_eq "picker guard: symlinked cursor-agent not offered" "" \
        "$(picker_section "$gout" "Agent CLI stubs" | grep -x '  cursor-agent')"
    expect_eq "picker guard: marker-less muse not offered" "" \
        "$(picker_section "$gout" "Agent CLI stubs" | grep -x '  muse')"
    # hermes is decided by omarchy-install-hermes-cli --owns, which answers
    # about ~/.local/bin/hermes and nothing else: a file the picker found
    # anywhere else is never authorized, so this holds on any host.
    expect_eq "picker guard: hermes outside Omarchy's own path not offered" "" \
        "$(picker_section "$gout" "Agent CLI stubs" | grep -x '  hermes')"
    expect_eq "picker guard: unconditional stub still offered" "  codex" \
        "$(picker_section "$gout" "Agent CLI stubs")"

    # The same path holding the mise wrapper Omarchy wrote is still offered,
    # and the removal loop re-checks it before rm -f.
    rm "$g/bin/cursor-agent"
    printf '#!/bin/bash\nmise use -g --quiet "cursor-agent" || exit 1\n' >"$g/bin/cursor-agent"
    DQ_APP_DIR="$d/apps" DQ_BIN_DIR="$g/bin" \
    DQ_OMARCHY_SCRIPT="$g/upstream.sh" DQ_BINDINGS_FILE="$d/bindings.conf" \
        bash "$REPO_DIR/bin/debloat-quattro.sh" --list >"$gout" 2>&1
    expect_eq "picker guard: the cursor-agent wrapper Omarchy wrote is offered" "  cursor-agent" \
        "$(picker_section "$gout" "Agent CLI stubs" | grep -x '  cursor-agent')"
}

# ---------------------------------------------------------------------------
# GPU vendor dispatch, with lspci stubbed so the answer is ours, not the
# host's.
run_gpu() {
    head_ "GPU dispatch"
    local d="$WORK/gpu" out rc s
    mkdir -p "$d/empty" "$d/nvidia"
    printf '#!/bin/sh\nexit 0\n' >"$d/empty/lspci"
    printf '#!/bin/sh\necho "0000:01:00.0 VGA compatible controller: NVIDIA Corporation"\n' >"$d/nvidia/lspci"
    chmod +x "$d/empty/lspci" "$d/nvidia/lspci"

    out="$d/none.out"
    PATH="$d/empty:$PATH" bash "$REPO_DIR/bin/gpu-setup.sh" --dry-run >"$out" 2>&1
    rc=$?
    expect_eq "gpu-setup: a GPU-less host exits 0" "0" "$rc"
    expect_contains "gpu-setup: the none branch is taken" "No GPU detected" "$(cat "$out")"

    # A host with no AMD GPU must print its documented skip, not abort: the
    # GPU_ID pipeline in amd-rocm.sh used to fail under pipefail before that
    # guard could run (plan 033).
    out="$d/noamd.out"
    PATH="$d/empty:$PATH" bash "$REPO_DIR/bin/amd-rocm.sh" --dry-run >"$out" 2>&1
    rc=$?
    expect_eq "amd-rocm: a host with no AMD GPU exits 0" "0" "$rc"
    expect_contains "amd-rocm: the skip is printed" "No AMD GPU found. Skipping." "$(cat "$out")"

    # Every entry point refuses an unknown flag rather than ignoring it and
    # taking the privileged path.
    for s in gpu-setup nvidia amd-rocm; do
        out="$d/flag-$s.out"
        bash "$REPO_DIR/bin/$s.sh" --bogus >"$out" 2>&1
        rc=$?
        expect_eq "$s.sh: --bogus exits 1" "1" "$rc"
        expect_contains "$s.sh: --bogus prints usage" "Usage: $s.sh [--dry-run]" "$(cat "$out")"
    done

    # chwd is CachyOS-only: the driver-profile step must skip with a warning
    # where it is absent, and still run where it exists. An exclusive PATH pins
    # both branches on any host; only the detection pipeline is stubbed.
    local shim="$d/chwdless" chwdshim="$d/withchwd" b
    mkdir -p "$shim" "$chwdshim"
    printf '#!/bin/sh\necho "0000:03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [1002:744c]"\n' >"$shim/lspci"
    chmod +x "$shim/lspci"
    for b in bash dirname grep head sed; do ln -sf "$(command -v "$b")" "$shim/$b"; done
    printf '#!/bin/sh\nexit 0\n' >"$chwdshim/chwd"; chmod +x "$chwdshim/chwd"

    out="$d/chwdless.out"
    PATH="$shim" bash "$REPO_DIR/bin/amd-rocm.sh" --dry-run >"$out" 2>&1
    rc=$?
    expect_eq "amd-rocm: a chwd-less host completes its dry run" "0" "$rc"
    expect_contains "amd-rocm: chwd step skipped with a warning" \
        "chwd (CachyOS's hardware detection) is not installed" "$(cat "$out")"
    expect_eq "amd-rocm: no chwd command planned on a chwd-less host" "" \
        "$(sed -n '/DRYRUN: sudo chwd/p' "$out")"

    out="$d/chwd.out"
    PATH="$chwdshim:$shim" bash "$REPO_DIR/bin/amd-rocm.sh" --dry-run >"$out" 2>&1
    rc=$?
    expect_eq "amd-rocm: a host with chwd completes its dry run" "0" "$rc"
    expect_contains "amd-rocm: chwd profile step planned where chwd exists" \
        "DRYRUN: sudo chwd -i amd" "$(cat "$out")"

    # The detector seam dispatches to the named vendor's script without
    # consulting lspci at all; that vendor then no-ops on this GPU-less host.
    for s in nvidia amd-rocm; do
        out="$d/seam-$s.out"
        PATH="$d/empty:$PATH" OMOCACHY_GPU_TYPE="${s%-rocm}" \
            bash "$REPO_DIR/bin/gpu-setup.sh" --dry-run >"$out" 2>&1
        expect_contains "detector seam: ${s%-rocm} dispatches to $s.sh" "running $s.sh" "$(cat "$out")"
    done

    out="$d/seam-bogus.out"
    OMOCACHY_GPU_TYPE=bogus bash "$REPO_DIR/bin/gpu-setup.sh" >"$out" 2>&1
    rc=$?
    expect_eq "unknown detector value: exit 1" "1" "$rc"
    expect_contains "unknown detector value: the dispatcher says so" \
        "which this dispatcher does not know" "$(cat "$out")"

    # The sysroot seam: a fixture run must not consult the host probe at all,
    # so stub lspci to claim an NVIDIA card and require the printed summary to
    # still say none.
    out="$d/sysroot.out"
    PATH="$d/nvidia:$PATH" dry_run_fixture cachyos-limine-luks "$out" "$d/sysroot.dec"
    expect_eq "sysroot run ignores the host GPU probe" "none" \
        "$(sed -n 's/^.*GPU vendor: *//p' "$out" | tail -1)"
}

# ---------------------------------------------------------------------------
# The bundle trust boundary. A manifest is a file that arrives on a USB stick
# or as a mail attachment, so the paths it supplies and the archive it arrives
# in are checked before anything under $HOME is touched: every refusal below
# happens before the backup directory, the prompt or any mkdir/cp under $HOME.
run_guard() {
    head_ "bundle guard"
    local d="$WORK/guard" out rc row
    mkdir -p "$d/evil"

    # 1. ".." in payload.captured clears both existence gates in stage_configs
    # ("$BUNDLE/home/$rel" exists, and the escape target exists) and then
    # drives mkdir -p/cp -a outside $HOME, plus an rm -rf in the generated
    # rollback. The import must refuse it instead of prompting.
    printf '{"schema":1,"payload":{"captured":[".."]}}\n' >"$d/evil/manifest.json"
    out="$d/evil.out"
    bash "$REPO_DIR/bin/omocachy-profile-import.sh" \
        --dry-run --yes --bundle "$d/evil" --only configs >"$out" 2>&1
    rc=$?
    expect_eq "manifest: a .. entry makes the import exit 1" "1" "$rc"
    expect_contains "manifest: the refusal names payload.captured" \
        "unsafe path(s) in payload.captured" "$(cat "$out")"
    expect_contains "manifest: the offending entry is printed" "  .." "$(cat "$out")"

    # 2. The validator behind it: the escape matters after a safe-looking first
    # component too, which is why every component is walked, not just the first.
    rp() { ( source "$REPO_DIR/bin/lib/profile.sh"; profile_rel_path_ok "$1" ) && echo ok || echo no; }
    expect_eq "validator: a relative path is accepted" "ok" "$(rp '.config/hypr')"
    expect_eq "validator: '..' is refused" "no" "$(rp '..')"
    expect_eq "validator: an interior '..' is refused" "no" "$(rp 'a/../b')"
    expect_eq "validator: an absolute path is refused" "no" "$(rp '/etc/passwd')"

    # 3. Archives. A bundle exported with --archive carries its own digest, and
    # its member names are as much user input as the manifest is.
    resolve() { ( source "$REPO_DIR/bin/lib/profile.sh"; profile_resolve_bundle "$1" "$2" ) 2>&1; }
    mkdir -p "$d/src/bundle/home/.config"
    printf '{"schema":1,"payload":{"captured":[".config/guard"]}}\n' >"$d/src/bundle/manifest.json"
    printf 'theme\n' >"$d/src/bundle/home/.config/guard"
    tar -C "$d/src" -cf "$d/good.tar" bundle
    (cd "$d" && sha256sum good.tar >good.tar.sha256)

    out="$(resolve "$d/good.tar" "$d/w-good")"
    rc=$?
    expect_eq "archive: a good bundle resolves" "0" "$rc"
    expect_eq "archive: the resolved directory is the bundle root" "$d/w-good/bundle" "$out"

    # A bundle re-copied badly, or tampered with in transit.
    cp "$d/good.tar" "$d/mismatch.tar"
    printf '%064d  mismatch.tar\n' 0 >"$d/mismatch.tar.sha256"
    out="$(resolve "$d/mismatch.tar" "$d/w-mismatch")"
    rc=$?
    expect_eq "archive: a digest mismatch refuses the bundle" "1" "$rc"
    expect_contains "archive: the mismatch names the archive" \
        "digest mismatch for $d/mismatch.tar" "$out"

    # Bundles also travel by means that leave no digest beside them; that is a
    # note, not a refusal.
    cp "$d/good.tar" "$d/nodigest.tar"
    out="$(resolve "$d/nodigest.tar" "$d/w-nodigest")"
    rc=$?
    expect_eq "archive: an absent .sha256 does not refuse the bundle" "0" "$rc"
    expect_contains "archive: the absent digest is noted" \
        "no .sha256 next to $d/nodigest.tar" "$out"

    mkdir -p "$d/esc"
    printf 'x\n' >"$d/esc/f"
    tar -C "$d/esc" -cf "$d/evil.tar" --transform='s|^|../|' f 2>/dev/null
    out="$(resolve "$d/evil.tar" "$d/w-evil")"
    rc=$?
    expect_eq "archive: a ../ member refuses the bundle" "1" "$rc"
    expect_contains "archive: the ../ member is named" "unsafe archive member: ../f" "$out"

    mkdir -p "$d/mid/a"
    printf 'x\n' >"$d/mid/a/f"
    tar -C "$d/mid" -cf "$d/mid.tar" --transform='s|^a/f$|a/../f|' a/f 2>/dev/null
    out="$(resolve "$d/mid.tar" "$d/w-mid")"
    rc=$?
    expect_eq "archive: an interior .. member refuses the bundle" "1" "$rc"
    expect_contains "archive: the interior .. member is named" "unsafe archive member: a/../f" "$out"
    expect_eq "archive: a refused archive was not extracted" "" "$(find "$d/w-mid" -mindepth 1 2>/dev/null)"

    # 4. Remotes recorded in the manifest. A URL-form remote can embed a token
    # (https://user:tok@host/…), which must not be carried into the bundle.
    mkdir -p "$d/plugins/thing"
    git -C "$d/plugins/thing" init -q
    git -C "$d/plugins/thing" remote add origin 'https://user:token@example.invalid/thing.git'
    row="$( ( source "$REPO_DIR/bin/lib/profile.sh"; profile_plugin_rows "$d/plugins" ) |
        awk -F'\t' '$1 == "thing" { print $3 }')"
    expect_eq "plugin rows: the recorded remote keeps no userinfo" \
        "https://example.invalid/thing.git" "$row"

    # 5. The reader's side of the same boundary. The doctor grades this machine
    # against the bundle's lists, so a manifest it cannot read must not be
    # graded at all: jq streams nothing out of an empty one and every check
    # fell through to PASS, the plugin check included.
    mkdir -p "$d/doctor/bundle"
    printf '{}\n' >"$d/doctor/bundle/manifest.json"
    out="$d/doctor/out"
    bash "$REPO_DIR/bin/omocachy-doctor.sh" --bundle "$d/doctor/bundle" >"$out" 2>&1
    rc=$?
    expect_eq "doctor: an unreadable manifest exits 1" "1" "$rc"
    expect_contains "doctor: the unreadable manifest is named" \
        "bundle manifest is missing, unreadable or not schema 1: $d/doctor/bundle/manifest.json" "$(cat "$out")"
    expect_eq "doctor: the unreadable manifest is not graded" "no" \
        "$(grep -qF 'every plugin in the bundle is present' "$out" && echo yes || echo no)"
}

# ---------------------------------------------------------------------------
# The generated undo. It is written before the first path is merged, so a
# merge that dies halfway still leaves the operator the file the failure
# message points at, and it reads the touched paths from beside itself at run
# time, so the list survives the run that produced it. A dangling symlink
# under $HOME counts as pre-existing: [[ -e ]] is false for one, which used to
# classify it "new" — the undo then deleted it having never taken a backup.
run_rollback() {
    head_ "rollback integrity"
    local d="$WORK/rollback/bundle" h dir out rc

    mkdir -p "$d/home/.config/hypr" "$WORK/rollback/xdg"
    printf 'from the bundle\n' >"$d/home/.config/hypr/hyprland.lua"
    printf '{"schema":1,"source":{"host":"test","user":"me","home":"/home/me"},"payload":{"captured":[".config/hypr/hyprland.lua"]}}\n' >"$d/manifest.json"

    # HYPRLAND_INSTANCE_SIGNATURE points at nothing on purpose: with it unset
    # stage_configs adopts the newest live instance and reloads it, which from
    # a test would mean reloading the operator's desktop.
    _rollback_import() { # HOME
        env HOME="$1" XDG_RUNTIME_DIR="$WORK/rollback/xdg" HYPRLAND_INSTANCE_SIGNATURE=none \
            bash "$REPO_DIR/bin/omocachy-profile-import.sh" \
            --bundle "$d" --only configs --yes 2>&1
    }

    # 1. Happy path, over a dangling symlink.
    h="$WORK/rollback/home"
    mkdir -p "$h/.config/hypr"
    ln -s /nonexistent-omocachy-target "$h/.config/hypr/hyprland.lua"

    out="$(_rollback_import "$h")"
    rc=$?
    expect_eq "rollback: the configs merge succeeds" "0" "$rc"
    dir="$(echo "$h"/.local/state/omocachy/backups/import-*)"
    expect_eq "rollback: the undo is executable after the merge" "yes" \
        "$([[ -x $dir/rollback.sh ]] && echo yes)"
    expect_eq "rollback: the touched-path list sits beside it" "yes" \
        "$([[ -f $dir/restored.tsv ]] && echo yes)"
    expect_contains "rollback: a dangling symlink counts as pre-existing" \
        $'.config/hypr/hyprland.lua\texisted' "$(cat "$dir/restored.tsv" 2>/dev/null)"
    expect_eq "rollback: the backup holds the link, not a copy of its target" "yes" \
        "$([[ -L $dir/.config/hypr/hyprland.lua ]] && echo yes)"
    expect_eq "rollback: the bundle's file is what the merge left in place" "from the bundle" \
        "$(cat "$h/.config/hypr/hyprland.lua")"
    expect_contains "rollback: --dry-run replays the list the merge appended to" \
        "would restore $h/.config/hypr/hyprland.lua" "$("$dir/rollback.sh" --dry-run)"

    # 2. The merge dies mid-run. The undo the message points at must already
    # exist, and what was already touched must not die with the temp dir.
    h="$WORK/rollback/failed-home"
    mkdir -p "$h/.config/hypr" "$h/.local"
    ln -s /nonexistent-omocachy-target "$h/.config/hypr/hyprland.lua"
    chmod 500 "$h/.config/hypr"    # the backup reads it; the merge into it cannot

    out="$(_rollback_import "$h")"
    rc=$?
    chmod 700 "$h/.config/hypr"
    dir="$(echo "$h"/.local/state/omocachy/backups/import-*)"
    expect_eq "rollback: an unwritable target fails the merge" "1" "$rc"
    expect_contains "rollback: the failure message names the undo" \
        "rollback: $dir/rollback.sh" "$out"
    expect_eq "rollback: the undo exists although the merge died" "yes" \
        "$([[ -x $dir/rollback.sh ]] && echo yes)"
    expect_contains "rollback: the path already touched is still listed" \
        $'.config/hypr/hyprland.lua\texisted' "$(cat "$dir/restored.tsv" 2>/dev/null)"
    expect_contains "rollback: --dry-run still plans that restore" \
        "would restore $h/.config/hypr/hyprland.lua" "$("$dir/rollback.sh" --dry-run)"

    # 3. The list is a plain file beside the backup now that the undo reads it
    # at run time, so a hand-edited ".." must not become an rm -rf outside
    # $HOME. The canary sits in the parent directory the entry would reach.
    h="$WORK/rollback/tamper/home"
    mkdir -p "$h/.config/hypr"
    ln -s /nonexistent-omocachy-target "$h/.config/hypr/hyprland.lua"
    printf 'canary\n' >"$WORK/rollback/tamper/canary"

    _rollback_import "$h" >"$WORK/rollback/tamper/import.out" 2>&1
    dir="$(echo "$h"/.local/state/omocachy/backups/import-*)"
    printf '..\texisted\n' >>"$dir/restored.tsv"
    out="$("$dir/rollback.sh" 2>&1)"
    rc=$?
    expect_eq "rollback: a hand-edited '..' entry is refused" "1" "$rc"
    expect_contains "rollback: the refusal names the entry" "refusing unsafe path .." "$out"
    expect_eq "rollback: nothing outside the backup was removed" "canary" \
        "$(cat "$WORK/rollback/tamper/canary" 2>/dev/null)"
}

case "${1:-all}" in
    lint)     run_lint ;;
    hooks)    run_hooks ;;
    units)    run_units ;;
    picker)   run_picker ;;
    gpu)      run_gpu ;;
    guard)    run_guard ;;
    rollback) run_rollback ;;
    matrix)   run_matrix ;;
    purity)   run_purity ;;
    all)      run_lint; run_hooks; run_units; run_picker; run_gpu; run_guard; run_rollback; run_matrix; run_purity ;;
    *)        echo "Usage: $0 [lint|hooks|units|picker|gpu|guard|rollback|matrix|purity|all]" >&2; exit 2 ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
