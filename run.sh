sudo rm -rf ap6611s-build/linux-6.18.3/
sudo WORKDIR="$(pwd)/ap6611s-build" \
PATCH_SCRIPT="$(pwd)/scripts/generate_patch.sh" \
PATCH_FILE="$(pwd)/patches/ap6611s-brcmfmac.patch" \
SUDO_USER="$(whoami)" \
bash ./scripts/install_ap6611s.sh
