#!/bin/bash
set -euo pipefail

# --- AMD configuration for Omarchy on CachyOS ---
# Installs the AMDGPU driver profile via chwd plus the ROCm runtime and the
# VA-API utilities. VA-API only: Mesa removed VDPAU upstream (Sept 2025), so
# mesa-vdpau/VDPAU_DRIVER must never come back here (plan 008).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
parse_dry_run_flag "$@"

# 1. Get AMD GPU ID. The pipeline exits non-zero on a host with no AMD GPU
# (grep finds nothing), which under pipefail aborted this script before its own
# "no GPU" guard could print; `|| true` hands the empty result to the guard.
GPU_ID=$(lspci -nn -d 1002: | grep -E "VGA|3D" | head -n1 | sed -n 's/.*\[1002:\([0-9a-fA-F]\{4\}\)\].*/\1/p' || true)

if [[ -z $GPU_ID ]]; then
    info "No AMD GPU found. Skipping."
    exit 0
fi

info "Found AMD GPU ID: $GPU_ID"

# 2. Leftover NVIDIA packages are inert on an AMD-only machine; forced
# removal risks breaking hybrid AMD+NVIDIA systems, and chwd's amd profile
# needs no removals (see plan 007).

# 3. Install AMD driver profile via chwd
info "Installing AMD AMDGPU driver profile..."
run_root chwd -i amd

# 4. Install ROCm runtime + VA-API utils
info "Installing ROCm and VA-API packages..."
run_root pacman -S --needed --noconfirm rocm-core rocm-hip-runtime rocm-smi-lib libva-utils

# 5. Session environment for ROCm: the file it lands in, the
# skip-user-configs behaviour and the dry-run handling live in
# write_gpu_session_env (bin/lib/common.sh).
GPU_ENV_CONTENT='# Written by omocachy bin/amd-rocm.sh (AMD ROCm)
export LIBVA_DRIVER_NAME=radeonsi
export ROCM_HOME=/opt/rocm
export PATH=$ROCM_HOME/bin:$PATH'
write_gpu_session_env "AMD ROCm" "$GPU_ENV_CONTENT"
