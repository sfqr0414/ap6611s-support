#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT_DIR="${SCRIPT_DIR}"

sudo rm -rf "${ROOT_DIR}/ap6611s-build/linux-6.18.3/"

sudo WORKDIR="${ROOT_DIR}/ap6611s-build" \
DTB_ONLY=true \
PATCH_SCRIPT="${ROOT_DIR}/scripts/generate_patch.sh" \
PATCH_FILE="${ROOT_DIR}/patches/ap6611s-brcmfmac.patch" \
SUDO_USER="$(whoami)" \
bash "${ROOT_DIR}/scripts/install_ap6611s.sh"
