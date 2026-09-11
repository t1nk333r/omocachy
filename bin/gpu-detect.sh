#!/bin/bash

# Detect NVIDIA (vendor ID: 10de)
if lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "nvidia"
# Detect AMD (vendor ID: 1002)
elif lspci -nn -d 1002: | grep -qE "VGA|3D"; then
    echo "amd"
else
    echo "none"
fi