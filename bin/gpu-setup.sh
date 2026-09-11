#!/bin/bash
set -euo pipefail

# Vendor dispatch for GPU setup. --dry-run is forwarded to the vendor script,
# which parses it itself; anything else is refused here, so a typo cannot fall
# through to the privileged path.
#
# Test seam (defaults to "off", so normal operation is unchanged):
#   OMOCACHY_GPU_TYPE=<nvidia|amd|none>  skip the lspci probe and dispatch on
#                                        this value (see tests/run.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
    case "$arg" in
    --dry-run) ;; # forwarded to the vendor script below
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

GPU_TYPE="${OMOCACHY_GPU_TYPE:-$(bash "$SCRIPT_DIR/gpu-detect.sh")}"

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
