#!/bin/bash
# omacachy — mkinitcpio HOOKS reconciliation.
#
# Sourced by bin/install-omarchy-quattro.sh and by tests/run.sh. Defining the
# merge here (instead of inline in the installer) is what makes it testable
# against fixtures without touching the host: tests/run.sh sources this file,
# feeds it CachyOS-shaped and Omarchy-shaped arrays, and asserts the merged
# result. No side effects at source time.
#
# The merge itself is *rendered*, not computed: render_keep_hooks_conf emits a
# mkinitcpio drop-in that transforms whatever array Omarchy's own drop-in set,
# at rebuild time. That is deliberate — Omarchy's array is not known before its
# packages are installed, and it changes between releases. merge_preview runs
# the very same rendered text against a given array, so what the tests exercise
# is the artifact that lands on disk, not a second implementation of it.

has_word() { [[ " $2 " == *" $1 "* ]]; }

# The effective HOOKS the way mkinitcpio resolves them: the base file first,
# then every conf.d/*.conf in lexical order. A later `HOOKS=` replaces the
# array wholesale; a later `HOOKS+=` (omarchy_resume.conf) appends to it.
# Runs in a subshell with -e/-u relaxed: package drop-ins are not written
# against a caller's strict mode.
effective_hooks() {
    local conf="${1:-/etc/mkinitcpio.conf}" confd="${2:-/etc/mkinitcpio.conf.d}"
    (
        set +eu
        HOOKS=()
        # shellcheck disable=SC1090
        [[ -f $conf ]] && source "$conf" 2>/dev/null
        shopt -s nullglob
        for f in "$confd"/*.conf; do
            # shellcheck disable=SC1090
            source "$f" 2>/dev/null
        done
        echo "${HOOKS[*]}"
    )
}

# systemd | udev — which initramfs flavour an array is written in.
hooks_flavour() {
    local h
    for h in systemd sd-encrypt sd-vconsole sd-shutdown; do
        has_word "$h" "$1" && { echo systemd; return; }
    done
    echo udev
}

# systemd | udev | none — which flavour of encryption hook an array carries.
hooks_crypt_flavour() {
    has_word sd-encrypt "$1" && { echo systemd; return; }
    has_word encrypt "$1" && { echo udev; return; }
    echo none
}

# systemd | udev | none — which flavour the kernel command line asks for.
# rd.luks.uuid=/rd.luks.name= are read by the systemd initramfs only;
# cryptdevice= is read by the udev `encrypt` hook only.
cmdline_crypt_flavour() {
    case " $1 " in
        *" rd.luks."*) echo systemd ;;
        *" cryptdevice="*) echo udev ;;
        *) echo none ;;
    esac
}

# hooks_conflict CAPTURED_HOOKS CMDLINE_CRYPT_FLAVOUR LUKS(true|false)
# Prints the reason and returns 0 when the captured array cannot be reconciled
# with the machine it was captured from. Returns 1 (no conflict) otherwise.
# The caller must stop on 0: every one of these produces an initramfs that
# either cannot unlock the root volume or double-unlocks it.
hooks_conflict() {
    local hooks="$1" cmdline_crypt="$2" luks="$3" crypt
    if has_word systemd "$hooks" && has_word udev "$hooks"; then
        echo "the captured HOOKS contain both 'systemd' and 'udev' — the two initramfs flavours are mutually exclusive, so there is no single flavour to express Omarchy's additions in"
        return 0
    fi
    if has_word encrypt "$hooks" && has_word sd-encrypt "$hooks"; then
        echo "the captured HOOKS contain both 'encrypt' and 'sd-encrypt' — two unlock paths for the same volume"
        return 0
    fi
    crypt="$(hooks_crypt_flavour "$hooks")"
    if [[ $luks == true && $crypt == none ]]; then
        echo "LUKS was detected but the captured HOOKS contain neither 'encrypt' nor 'sd-encrypt', so preserving them would not protect boot"
        return 0
    fi
    if [[ $crypt != none && $cmdline_crypt != none && $crypt != "$cmdline_crypt" ]]; then
        echo "the captured HOOKS use the $crypt encryption hook but the kernel command line asks for the $cmdline_crypt one ($([[ $cmdline_crypt == systemd ]] && echo 'rd.luks.*' || echo 'cryptdevice=')) — the running initramfs and /etc have already drifted apart, and any merge would guess which one is right"
        return 0
    fi
    return 1
}

# render_keep_hooks_conf CAPTURED_HOOKS — the mkinitcpio drop-in text.
render_keep_hooks_conf() {
    local captured="$1"
    cat <<EOF
# Written by omacachy install-omarchy-quattro.sh -- re-run the installer
# instead of editing; it re-captures the array below.
#
# Sourced by mkinitcpio after omarchy_hooks.conf (conf.d files load in
# lexical order and a later HOOKS= assignment replaces the array wholesale).
# omarchy-settings' file sets a udev/encrypt/keymap array tuned for the
# Omarchy ISO. On CachyOS that array breaks the next initramfs rebuild:
#   - A CachyOS LUKS install boots with rd.luks.uuid= on the kernel cmdline,
#     which only the systemd initramfs (sd-encrypt) unlocks; the udev
#     \`encrypt\` hook expects cryptdevice= and leaves the root volume locked.
#   - The systemd flavour needs the single sd-vconsole instead of
#     keymap+consolefont, and the snapshot-boot overlay hook has a systemd
#     variant (sd-btrfs-overlayfs, from limine-mkinitcpio-hook).
# Re-asserting the pre-install array wholesale would throw away plymouth (a
# hard dependency of omarchy-settings; its default/limine cmdline passes
# \`splash\`), so this file transforms the array Omarchy set instead.
#
# Effective HOOKS captured before the omarchy packages were installed
# (/etc/mkinitcpio.conf plus every conf.d drop-in, so HOOKS+= additions such
# as omarchy_resume.conf are part of it):
_cachyos_captured=($captured)

_cachyos_systemd=0
for _cachyos_h in systemd sd-encrypt sd-vconsole; do
  [[ " \${_cachyos_captured[*]} " == *" \$_cachyos_h "* ]] && _cachyos_systemd=1
done

# (a) Flavour-map Omarchy's array to the captured initramfs style. usr and
# resume are udev-only hooks (systemd's initramfs mounts /usr and resumes
# from hibernation itself); keep them only if the pre-install image had them.
_cachyos_result=()
for _cachyos_h in "\${HOOKS[@]}"; do
  if (( _cachyos_systemd )); then
    case \$_cachyos_h in
      udev) _cachyos_h=systemd ;;
      encrypt) _cachyos_h=sd-encrypt ;;
      keymap | consolefont) _cachyos_h=sd-vconsole ;;
      btrfs-overlayfs) _cachyos_h=sd-btrfs-overlayfs ;;
      usr | resume) [[ " \${_cachyos_captured[*]} " == *" \$_cachyos_h "* ]] || continue ;;
    esac
  fi
  [[ " \${_cachyos_result[*]} " == *" \$_cachyos_h "* ]] || _cachyos_result+=("\$_cachyos_h")
done

# (b) Re-add captured hooks Omarchy's array lacks (lvm2, mdadm_udev, resume,
# usr, ...): block-level ones go right before filesystems, the rest at the
# end. Two hooks are never re-added: kms, which omarchy_hooks.conf drops on
# purpose on NVIDIA-only machines, and the encryption hook of the flavour
# that was NOT captured -- the installer refuses to run when the captured
# array carries both, so at most one can appear here.
_cachyos_block="lvm2 mdadm_udev mdadm dmraid encrypt sd-encrypt sd-encrypt-opensc resume usr btrfs sd-verity"
for _cachyos_h in "\${_cachyos_captured[@]}"; do
  [[ \$_cachyos_h == kms ]] && continue
  if (( _cachyos_systemd )); then
    [[ \$_cachyos_h == encrypt || \$_cachyos_h == udev ]] && continue
    [[ \$_cachyos_h == keymap || \$_cachyos_h == consolefont ]] && continue
  else
    [[ \$_cachyos_h == sd-encrypt || \$_cachyos_h == systemd ]] && continue
    [[ \$_cachyos_h == sd-vconsole ]] && continue
  fi
  [[ " \${_cachyos_result[*]} " == *" \$_cachyos_h "* ]] && continue
  if [[ " \$_cachyos_block " == *" \$_cachyos_h "* && " \${_cachyos_result[*]} " == *" filesystems "* ]]; then
    _cachyos_tmp=()
    for _cachyos_r in "\${_cachyos_result[@]}"; do
      [[ \$_cachyos_r == filesystems ]] && _cachyos_tmp+=("\$_cachyos_h")
      _cachyos_tmp+=("\$_cachyos_r")
    done
    _cachyos_result=("\${_cachyos_tmp[@]}")
  else
    _cachyos_result+=("\$_cachyos_h")
  fi
done

HOOKS=("\${_cachyos_result[@]}")
unset _cachyos_captured _cachyos_systemd _cachyos_result _cachyos_tmp _cachyos_h _cachyos_r _cachyos_block
EOF
}

# merge_preview CAPTURED_HOOKS OMARCHY_HOOKS — the merged array, computed by
# running the rendered drop-in exactly the way mkinitcpio would: with HOOKS
# already set to Omarchy's array. Prints the result; returns non-zero (and
# prints nothing) if the drop-in itself fails to evaluate.
merge_preview() {
    local rendered
    rendered="$(render_keep_hooks_conf "$1")" || return 1
    (
        set +eu
        # shellcheck disable=SC2206
        HOOKS=($2)
        eval "$rendered" || exit 1
        echo "${HOOKS[*]}"
    )
}
