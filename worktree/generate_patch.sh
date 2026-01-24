#!/usr/bin/env bash
#!/usr/bin/env bash
LINUX_VERSION="${LINUX_VERSION:-6.18.3}"
TAR_FILE_NAME="linux-${LINUX_VERSION}.tar.xz"
TAR_FILE_PATH="../ap6611s-build/${TAR_FILE_NAME}"

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
WORK_DIR="clean-linux-${LINUX_VERSION}"
TARGET_DIR="${DIR}/${WORK_DIR}"
PATCH_FILE_NAME="${PATCH_FILE_NAME:-ap6611s-brcmfmac.patch}"
# 修改：patch文件生成在worktree目录（上级目录），而非子目录内
PATCH_FILE_PATH="${DIR}/${PATCH_FILE_NAME}"

if [ -d "${TARGET_DIR}" ] && [ -f "${TARGET_DIR}/Makefile" ]; then
    cd "${TARGET_DIR}" || exit 1
else
    if [ ! -f "${TAR_FILE_PATH}" ]; then
        echo "错误：未检测到压缩包${TAR_FILE_PATH}，脚本无法继续执行！"
        exit 1
    fi

    mkdir -p "${TARGET_DIR}"

    tar -xJf "${TAR_FILE_PATH}" -C "${TARGET_DIR}"

    TOP_LEVEL_DIR="${TARGET_DIR}/linux-${LINUX_VERSION}"
    if [ -d "${TOP_LEVEL_DIR}" ]; then
        mv "${TOP_LEVEL_DIR}"/* "${TARGET_DIR}/"
        rm -rf "${TOP_LEVEL_DIR}"
    fi

    cd "${TARGET_DIR}" || exit 1
fi

if [ ! -d ".git" ]; then
    git init
    git add .
    git commit -m "initial" > /dev/null
    git tag -a v1.0-initial -m "初始提交，基础版本" > /dev/null
fi

if ! git rev-parse --verify --quiet v1.0-initial > /dev/null; then
    echo "错误：未检测到v1.0-initial标签，无法生成patch文件！"
    exit 1
fi

# 生成patch文件到worktree目录
git diff v1.0-initial HEAD > "${PATCH_FILE_PATH}"

if [ ! -f "${PATCH_FILE_PATH}" ]; then
    echo "错误：patch文件生成失败！"
    exit 1
fi

cd - > /dev/null
