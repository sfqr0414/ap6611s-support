#!/usr/bin/env bash
set -euo pipefail

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}
warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}
error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root to install modules and trigger depmod."
    exit 1
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORKDIR=${WORKDIR:-"${SCRIPT_DIR}/../ap6611s-build"}
PATCH_SCRIPT=${PATCH_SCRIPT:-"${SCRIPT_DIR}/generate_patch.sh"}
PATCH_FILE=${PATCH_FILE:-"${SCRIPT_DIR}/../patches/ap6611s-brcmfmac.patch"}
DTB_TARGETS=${DTB_TARGETS:-"rk3588-orangepi-5-max.dtb rk3588-orangepi-5-plus.dtb rk3588-orangepi-5-ultra.dtb"}
DTB_DEST_DIR=${DTB_DEST_DIR:-/boot/dtb/rockchip}
KERNEL_SHORT=${KERNEL_SHORT:-6.18.3}
TARBALL_URL=${TARBALL_URL:-https://mirrors.aliyun.com/linux-kernel/v6.x/linux-${KERNEL_SHORT}.tar.xz}
TARBALL=${WORKDIR}/linux-${KERNEL_SHORT}.tar.xz
SRC_DIR=${WORKDIR}/linux-${KERNEL_SHORT}
MOD_SRC=drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko
MOD_DST=/lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko

# 提取系统内核定制后缀 
CURRENT_KERNEL_FULL=$(uname -r)
info "Current running kernel full version: ${CURRENT_KERNEL_FULL}"

if [[ "${CURRENT_KERNEL_FULL}" == "${KERNEL_SHORT}"* ]]; then
    EXTRAVERSION_AUTOMATIC="${CURRENT_KERNEL_FULL#${KERNEL_SHORT}}"
else
    error "Current kernel full version (${CURRENT_KERNEL_FULL}) does not match local kernel short version (${KERNEL_SHORT})"
    exit 1
fi

if [[ -z "${EXTRAVERSION_AUTOMATIC}" ]]; then
    warn "No custom suffix found for current kernel, using empty extraversion"
else
    info "Automatically extracted kernel custom suffix: ${EXTRAVERSION_AUTOMATIC}"
fi

# 拆分 KERNEL_SHORT 为 VERSION/PATCHLEVEL/SUBLEVEL（避免未绑定变量）
KERNEL_VERSION=${KERNEL_SHORT%%.*}
KERNEL_REMAIN=${KERNEL_SHORT#*.}
KERNEL_PATCHLEVEL=${KERNEL_REMAIN%%.*}
KERNEL_SUBLEVEL=${KERNEL_REMAIN#*.}

# 完整内核版本（拼接主版本+后缀）
FULL_KERNEL_VERSION="${KERNEL_SHORT}${EXTRAVERSION_AUTOMATIC}"
info "Full kernel version to generate: ${FULL_KERNEL_VERSION}"

# 手动生成版本文件（独立函数，可多次调用，防止被覆盖）
function force_generate_version_files() {
    # 彻底清理版本缓存文件
    local version_cache_files=(
        "${SRC_DIR}/.version"
        "${SRC_DIR}/include/config/kernel.release"
        "${SRC_DIR}/include/generated/utsrelease.h"
    )
    for cache_file in "${version_cache_files[@]}"; do
        if [[ -f "${cache_file}" ]]; then
            rm -f "${cache_file}"
            info "Deleted version cache file: ${cache_file}"
        fi
    done

    # 手动生成版本文件（不依赖内核编译，100%生效）
    # 1. 创建必要目录
    mkdir -p "${SRC_DIR}/include/generated"
    mkdir -p "${SRC_DIR}/include/config"

    # 2. 手动生成 utsrelease.h（核心：直接写入完整版本）
    local utsrelease_path="${SRC_DIR}/include/generated/utsrelease.h"
    echo "#define UTS_RELEASE \"${FULL_KERNEL_VERSION}\"" > "${utsrelease_path}"
    # 设置为只读，防止后续命令覆盖
    chmod 444 "${utsrelease_path}"
    if [[ -f "${utsrelease_path}" ]]; then
        info "✅ Successfully manually generated utsrelease.h: $(cat "${utsrelease_path}")"
    else
        error "Failed to manually generate utsrelease.h"
        exit 1
    fi

    # 3. 手动生成 kernel.release（内核编译时会读取该文件）
    local kernel_release_path="${SRC_DIR}/include/config/kernel.release"
    echo "${FULL_KERNEL_VERSION}" > "${kernel_release_path}"
    # 设置为只读，防止后续命令覆盖
    chmod 444 "${kernel_release_path}"
    if [[ -f "${kernel_release_path}" ]]; then
        info "✅ Successfully manually generated kernel.release: $(cat "${kernel_release_path}")"
    else
        error "Failed to manually generate kernel.release"
        exit 1
    fi

    # 4. 手动修改 Makefile（确保后续命令解析不出错）
    local makefile_path="${SRC_DIR}/Makefile"
    sed -i \
        -e "s/^VERSION = .*/VERSION = ${KERNEL_VERSION}/" \
        -e "s/^PATCHLEVEL = .*/PATCHLEVEL = ${KERNEL_PATCHLEVEL}/" \
        -e "s/^SUBLEVEL = .*/SUBLEVEL = ${KERNEL_SUBLEVEL}/" \
        -e "s/^EXTRAVERSION = .*/EXTRAVERSION = ${EXTRAVERSION_AUTOMATIC}/" \
        "${makefile_path}"
    info "✅ Successfully updated kernel Makefile: EXTRAVERSION=${EXTRAVERSION_AUTOMATIC}"
}

mkdir -p "$WORKDIR"

DTBS_LIST_PATH=""
DTBS_LIST_BACKUP=""

cleanup() {
    exit_code=${1:-$?}
    if [[ -n "$DTBS_LIST_BACKUP" && -f "$DTBS_LIST_BACKUP" ]]; then
        mv -f "$DTBS_LIST_BACKUP" "$DTBS_LIST_PATH" || true
        warn "Restored original dtbs-list from $DTBS_LIST_BACKUP"
    elif [[ -n "$DTBS_LIST_PATH" && -f "$DTBS_LIST_PATH" ]]; then
        rm -f "$DTBS_LIST_PATH" || true
        warn "Removed temporary dtbs-list $DTBS_LIST_PATH"
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        echo "❌ Script exited abnormally"
    fi
    exit "$exit_code"
}

trap 'cleanup $?' EXIT INT TERM QUIT

info "Ensuring build dependencies are installed"
if ! apt-get update >/dev/null 2>&1; then
    warn "apt-get update failed; continuing with existing package lists"
fi
apt-get install -y --no-install-recommends bc build-essential libncurses-dev bison flex libssl-dev libelf-dev ccache wget make patch device-tree-compiler binutils >/dev/null

if [[ ! -f "$PATCH_FILE" || ! -s "$PATCH_FILE" ]]; then
    if [[ -x "$PATCH_SCRIPT" ]]; then
        info "Generating patch file"
        "$PATCH_SCRIPT"
    else
        error "Missing patch script $PATCH_SCRIPT or patch file $PATCH_FILE"
        exit 1
    fi
fi

if [[ ! -f "$TARBALL" ]]; then
    info "Downloading kernel ${KERNEL_SHORT}"
    wget -nv -O "$TARBALL" "$TARBALL_URL"
fi

if [[ ! -d "$SRC_DIR" ]]; then
    info "Extracting kernel source to $SRC_DIR"
    tar -xf "$TARBALL" -C "$WORKDIR"
    INVOKER_USER=${SUDO_USER:-$(whoami)}
    if id "$INVOKER_USER" >/dev/null 2>&1; then
        info "Setting ownership of $SRC_DIR to $INVOKER_USER"
        chown -R "$INVOKER_USER":"$INVOKER_USER" "$SRC_DIR" || \
            warn "chown failed; you may need to fix permissions manually"
    else
        warn "Invoker user $INVOKER_USER not found; skipping chown"
    fi
fi

cd "$SRC_DIR"

# 第一步：先执行内核配置和模块环境准备（此时版本文件会被自动生成，无后缀）
info "Preparing kernel configuration and module build environment"
if [[ -f "/boot/config-$(uname -r)" ]]; then
    info "Copying running kernel config"
    cp "/boot/config-$(uname -r)" .config
else
    warn "/boot/config-$(uname -r) not found; using default config"
    make defconfig >/dev/null 2>&1
fi

# 执行 olddefconfig 更新配置
if make olddefconfig >/dev/null 2>&1; then
    info "make olddefconfig succeeded"
else
    warn "make olddefconfig failed; continuing with existing config"
fi

# 执行 modules_prepare 准备模块编译环境
if make modules_prepare >/dev/null 2>&1; then
    info "make modules_prepare succeeded"
else
    warn "make modules_prepare failed; module builds may still work against host build tree"
fi

# 第二步：强制生成版本文件（关键！在配置之后，防止被覆盖，且设置只读）
info "Forcing generation of version files (with suffix, read-only protection)"
force_generate_version_files

# 第三步：复制 Module.symvers（避免版本不匹配）
HOST_SYMVERS="/lib/modules/$(uname -r)/build/Module.symvers"
if [[ -f "$HOST_SYMVERS" ]]; then
    info "Copying host Module.symvers"
    cp "$HOST_SYMVERS" "$SRC_DIR/Module.symvers"
else
    warn "Host Module.symvers not found; modpost may fail"
fi

# 第四步：应用补丁（自动处理重复，无交互）
if patch --forward -f -p1 --quiet --dry-run < "$PATCH_FILE"; then
    patch --forward -f -p1 --quiet < "$PATCH_FILE"
    info "Patch applied cleanly"
elif ! patch --forward -f -p1 --quiet --dry-run < "$PATCH_FILE" 2>/dev/null; then
    warn "Patch was already applied, continuing"
else
    warn "Patch application failed (may be partially applied), continuing with caution"
fi

# 第五步：编译模块（核心！强制指定 KERNELRELEASE 环境变量，兜底注入版本）
info "Building brcmfmac module (force KERNELRELEASE=${FULL_KERNEL_VERSION})"
if [[ -d "$SRC_DIR" && -f "$SRC_DIR/.config" ]]; then
    # 强制传递 KERNELRELEASE 环境变量，让 modpost 生成正确的 vermagic
    KERNELRELEASE="${FULL_KERNEL_VERSION}" make -C "$SRC_DIR" M="$SRC_DIR/drivers/net/wireless/broadcom/brcm80211/brcmfmac" modules -j"$(nproc)"
elif [[ -d "/lib/modules/$(uname -r)/build" ]]; then
    warn "Local kernel source invalid; falling back to system build tree"
    KERNELRELEASE="${FULL_KERNEL_VERSION}" make -C "/lib/modules/$(uname -r)/build" M="$SRC_DIR/drivers/net/wireless/broadcom/brcm80211/brcmfmac" modules -j"$(nproc)"
else
    error "No valid kernel build tree found"
    exit 1
fi

# 第六步：验证模块 vermagic（严谨匹配，允许微小空格差异）
info "Verifying module version magic (check custom suffix)"
MODULE_VERMAGIC=$(modinfo "$SRC_DIR/$MOD_SRC" 2>/dev/null | grep -oP 'vermagic: \K.*' || true)
MODULE_VERMAGIC_TRIMMED=$(echo "${MODULE_VERMAGIC}" | xargs)

# 双重验证：既匹配后缀，也匹配完整版本
if [[ -z "${MODULE_VERMAGIC_TRIMMED}" ]]; then
    warn "Failed to extract module vermagic, proceed with caution"
elif [[ "${MODULE_VERMAGIC_TRIMMED}" == *"${EXTRAVERSION_AUTOMATIC}"* && "${MODULE_VERMAGIC_TRIMMED}" == *"${KERNEL_SHORT}"* ]]; then
    info "✅ Module vermagic is valid: ${MODULE_VERMAGIC_TRIMMED}"
else
    error "❌ Module vermagic missing suffix! Expected: *${EXTRAVERSION_AUTOMATIC}*, Got: ${MODULE_VERMAGIC_TRIMMED}"
    # 额外输出版本文件内容，方便排查
    info "=== Debug Info: Current version files ==="
    cat "${SRC_DIR}/include/generated/utsrelease.h" 2>/dev/null || warn "utsrelease.h not found"
    cat "${SRC_DIR}/include/config/kernel.release" 2>/dev/null || warn "kernel.release not found"
    exit 1
fi

# 后续步骤：编译 DTB、安装模块（与之前一致）
if [[ ! -f "$SRC_DIR/$MOD_SRC" ]]; then
    error "Module build failed: $MOD_SRC not found"
    exit 1
fi

info "Building device trees (only requested targets: $DTB_TARGETS)"
DTBS_LIST_PATH="${SRC_DIR}/arch/arm64/boot/dts/dtbs-list"
if [[ -f "$DTBS_LIST_PATH" ]]; then
    DTBS_LIST_BACKUP="${DTBS_LIST_PATH}.ap6611s.bak"
    cp -a "$DTBS_LIST_PATH" "$DTBS_LIST_BACKUP"
fi
printf '%s\n' $DTB_TARGETS > "$DTBS_LIST_PATH"

if make -C "$SRC_DIR" ARCH=arm64 dtbs -j"$(nproc)" >/tmp/ap6611s-dtbs.log 2>&1; then
    info "Requested DTBs built successfully (log: /tmp/ap6611s-dtbs.log)"
else
    warn "DTB build failed; see /tmp/ap6611s-dtbs.log for details"
    [[ -n "$DTBS_LIST_BACKUP" ]] && mv -f "$DTBS_LIST_BACKUP" "$DTBS_LIST_PATH" || rm -f "$DTBS_LIST_PATH"
    error "Aborting due to DTB build failure"
    exit 1
fi

info "Installing device trees"
mkdir -p "$DTB_DEST_DIR"
for dtb in $DTB_TARGETS; do
    dtb_name=$(basename "$dtb")
    DTB_SRC="$SRC_DIR/arch/arm64/boot/dts/rockchip/$dtb_name"
    if [[ ! -f "$DTB_SRC" ]]; then
        warn "$dtb_name not found at $DTB_SRC"
        continue
    fi
    DTB_DEST="$DTB_DEST_DIR/$dtb_name"
    [[ -f "$DTB_DEST" && ! -f "$DTB_DEST.ap6611s.bak" ]] && cp "$DTB_DEST" "$DTB_DEST.ap6611s.bak"
    install -m 0644 "$DTB_SRC" "$DTB_DEST"
    info "Replaced $dtb at $DTB_DEST"
done

info "Installing new module"
[[ -f "$MOD_DST" && ! -f "$MOD_DST.ap6611s.bak" ]] && cp "$MOD_DST" "$MOD_DST.ap6611s.bak"
install -m 0644 "$SRC_DIR/$MOD_SRC" "$MOD_DST"
depmod -a >/dev/null

if modprobe -r brcmfmac; then
    info "Old module unloaded"
else
    warn "brcmfmac was not loaded before install"
fi

if modprobe brcmfmac; then
    info "✅ brcmfmac module loaded successfully! Check dmesg for details."
else
    error "❌ Failed to load brcmfmac module! Check dmesg for errors."
    dmesg | grep -i brcmfmac | tail -5
    exit 1
fi

info "✅ All tasks completed successfully!"
