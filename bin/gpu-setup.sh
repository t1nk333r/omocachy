#!/bin/bash
set -euo pipefail

# Vendor dispatch for GPU setup. Arguments (e.g. --dry-run) are forwarded to
# the vendor script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GPU_TYPE=$(bash "$SCRIPT_DIR/gpu-detect.sh")

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
esac
