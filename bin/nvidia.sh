#!/bin/bash
set -euo pipefail

# --- NVIDIA configuration for Omarchy on CachyOS ---
# Philosophy: detect and use whatever NVIDIA driver CachyOS has installed.
# Only install a driver if none is present. Never downgrade or force-replace.
#
# The architecture probe (PCI device id -> generation, open-GSP capability) is
# adapted from jeanmartins7/omarchy-on-cachyos (itself a fork of
# mroboff/omarchy-on-cachyos); here it reports the
# generation and flags the one combination that silently breaks — an open
# kernel module on a pre-Turing card — instead of choosing packages, which
# CachyOS's chwd already does from its own device-id table.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
parse_dry_run_flag "$@"

# Exit early if no NVIDIA GPU is present
if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    info "No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_LINE="$(lspci -nn -d 10de: | grep -E "VGA|3D" | head -n1)"
GPU_NAME="${GPU_LINE#*: }"
GPU_ID="$(sed -n 's/.*\[10de:\([0-9a-fA-F]\{4\}\)\].*/\1/p' <<<"$GPU_LINE")"
info "NVIDIA GPU detected: $GPU_NAME"

# Generation from the PCI device id. NVIDIA's open kernel modules need GSP
# firmware, which exists from Turing (TU1xx, device ids 0x1e00+) onward;
# Pascal and Maxwell must use the proprietary modules.
SUPPORTS_OPEN_GSP=false
ARCH_NAME="unknown"
if [[ -n $GPU_ID ]]; then
    DEC_ID=$((16#$GPU_ID))
    if ((DEC_ID >= 0x2900)); then
        ARCH_NAME="Blackwell or newer"
        SUPPORTS_OPEN_GSP=true
    elif ((DEC_ID >= 0x2600)); then
        ARCH_NAME="Ada Lovelace"
        SUPPORTS_OPEN_GSP=true
    elif ((DEC_ID >= 0x2200)); then
        ARCH_NAME="Ampere"
        SUPPORTS_OPEN_GSP=true
    elif ((DEC_ID >= 0x1e00)); then
        ARCH_NAME="Turing"
        SUPPORTS_OPEN_GSP=true
    elif ((DEC_ID >= 0x1b00)); then
        ARCH_NAME="Pascal"
    elif ((DEC_ID >= 0x1300)); then
        ARCH_NAME="Maxwell"
    fi
    info "Architecture: $ARCH_NAME (open kernel modules supported: $SUPPORTS_OPEN_GSP)"
fi

# Determine if a working NVIDIA driver is already installed
# Covers all chwd NVIDIA profiles: nvidia-open-dkms (+ its fallback raw dkms
# package "nvidia-open-dkms"), and the versioned proprietary branches
# nvidia-580xx-{dkms,utils} / nvidia-470xx-{dkms,utils}. "nvidia-utils" (or
# its versioned equivalent) is always present regardless of whether the
# kernel modules come from a per-kernel precompiled package
# (linux-cachyos-nvidia-open) or a raw dkms package, so matching on the
# utils/dkms package name alone is sufficient.
NVIDIA_DRIVER=$(pacman -Qq | grep -E '^nvidia(-open)?(-[0-9]+xx)?-(dkms|utils)$' | head -n1 || true)

if [[ -n $NVIDIA_DRIVER ]]; then
    DRIVER_VERSION=$(pacman -Q "$NVIDIA_DRIVER" 2>/dev/null | awk '{print $2}')
    info "Active NVIDIA driver found: $NVIDIA_DRIVER $DRIVER_VERSION"
    info "Respecting existing CachyOS driver installation."
    if ! $SUPPORTS_OPEN_GSP && pacman -Qq | grep -qE '^nvidia-open|^linux-.*-nvidia-open$'; then
        # chwd has no plain "nvidia" profile (plan 007): the proprietary branch
        # for a pre-Turing card is the generation-versioned one.
        warn "an open kernel module package is installed but this GPU ($ARCH_NAME) has no GSP firmware support; it will not initialise. Switch to the proprietary branch (Pascal: 'sudo chwd -i nvidia-dkms-580xx', Maxwell: 'sudo chwd -i nvidia-dkms-470xx')."
    fi
else
    info "No NVIDIA driver detected — installing via chwd..."
    # chwd's -a/--autoconfigure takes at most one PCI classid and defaults to
    # "any" (all PCI+USB classes) when bare, which would also configure
    # unrelated hardware (e.g. fingerprint readers). Scope it to the same
    # PCI classes this script already gates on above (VGA / 3D controller),
    # so only GPU profiles are touched. chwd itself still picks the correct
    # NVIDIA profile variant (open-dkms/580xx/470xx/nouveau) via its own
    # device-id matching.
    for gpu_class_id in 0300 0302; do
        run_root chwd -a "$gpu_class_id"
    done
    info "Driver installed via CachyOS hardware detection."
fi

# Hardware video acceleration: libva-utils to verify it (vainfo), and the
# NVIDIA VA-API driver that LIBVA_DRIVER_NAME=nvidia below selects — without
# it that variable points at nothing and browsers fall back to software
# decode (adopted from jeanmartins7/omarchy-on-cachyos).
run_root pacman -S --needed --noconfirm libva-utils libva-nvidia-driver

# DRM kernel mode setting is required for Wayland. Recent drivers default to
# modeset=1, and CachyOS may already ship a drop-in; only write one when
# nothing in /etc/modprobe.d sets it, so an existing choice is never
# overridden (adopted from jeanmartins7/omarchy-on-cachyos).
if grep -rqs 'nvidia[-_]drm.*modeset' /etc/modprobe.d/ 2>/dev/null; then
    info "nvidia_drm modeset is already configured in /etc/modprobe.d; leaving it alone."
else
    write_root_file /etc/modprobe.d/nvidia-modeset.conf <<'EOF'
# Written by omacachy bin/nvidia.sh: DRM kernel mode setting for Wayland.
options nvidia_drm modeset=1 fbdev=1
EOF
    info "Wrote /etc/modprobe.d/nvidia-modeset.conf (rebuild the initramfs to apply)."
fi

# Session environment for the NVIDIA driver: the file it lands in, the
# skip-user-configs behaviour and the dry-run handling live in
# write_gpu_session_env (bin/lib/common.sh).
GPU_ENV_CONTENT='# Written by omacachy bin/nvidia.sh (NVIDIA)
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1'
write_gpu_session_env "NVIDIA" "$GPU_ENV_CONTENT"

info "NVIDIA configuration complete."
