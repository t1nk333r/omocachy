#!/bin/bash
set -euo pipefail

# Vendor dispatch for GPU setup. --dry-run is forwarded to the vendor script,
# which parses it itself; anything else is refused here, so a typo cannot fall
# through to the privileged path.
#
# Test seam (defaults to "off", so normal operation is unchanged):
#   OMACACHY_GPU_TYPE=<nvidia|amd|none>  skip the lspci probe and dispatch on
#                                        this value (see tests/run.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --dry-run only; the vendor script re-parses the flag itself.
parse_dry_run_flag "$@"

GPU_TYPE="${OMACACHY_GPU_TYPE:-$(bash "$SCRIPT_DIR/gpu-detect.sh")}"

case "$GPU_TYPE" in
nvidia)
    echo "[*] NVIDIA GPU detected, running nvidia.sh..."
    bash "$SCRIPT_DIR/nvidia.sh" "$@"
    ;;
amd)
    echo "[*] AMD GPU detected, running amd-rocm.sh..."
    bash "$SCRIPT_DIR/amd-rocm.sh" "$@"
    ;;
none)
    echo "[*] No GPU detected, skipping GPU setup."
    exit 0
    ;;
*)
    echo "[!] gpu-detect.sh returned '$GPU_TYPE', which this dispatcher does not know." >&2
    exit 1
    ;;
esac
