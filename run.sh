#!/usr/bin/env bash
set -euo pipefail

# Remove previous extracted kernel source for a clean build
sudo rm -rf ap6611s-build/linux-6.18.3/

# Run the installer under sudo with explicit environment variables
sudo WORKDIR="$(pwd)/ap6611s-build" \
DTB_ONLY=true \
PATCH_SCRIPT="$(pwd)/scripts/generate_patch.sh" \
PATCH_FILE="$(pwd)/patches/ap6611s-brcmfmac.patch" \
SUDO_USER="$(whoami)" \
bash ./scripts/install_ap6611s.sh
