#!/bin/bash
# =============================================================================
# ImgFlash - 纯 initramfs ISO 构建器
# =============================================================================
# 生成同时支持 BIOS + UEFI（含 Secure Boot）的混合启动 ISO。
#
# 架构：纯 initramfs-only（无 rootfs、无 overlayfs、无 OpenRC）。
#   UEFI: shim（Microsoft 签名）→ GRUB（Debian 签名）→ vmlinuz（Debian 签名）
#   BIOS: syslinux → vmlinuz
# 运行时：initramfs /init → exec installer → dd 写盘 → 重启
#
# 构建流程：
#   Phase 1: mmdebstrap 创建最小 Debian 环境
#   Phase 2: 提取组件（内核 / shim / GRUB / BusyBox）
#   Phase 3: 组装 initramfs
#   Phase 4: 打包镜像容器
#   Phase 5: 组装 ISO 文件系统结构
#   Phase 6: xorriso 生成最终 ISO
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 加载构建配置
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/build.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "错误：缺少配置文件 ${ENV_FILE}" >&2; exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

# --- 架构映射 ---
case "${ARCH}" in
    amd64)
        KERNEL_PKG="linux-image-amd64"
        SHIM_PKG="shim-signed"
        GRUB_PKG="grub-efi-amd64-signed"
        SHIM_FIND="shimx64.efi.signed"
        GRUB_FIND="grubx64.efi.signed"
        EFI_SHIM_NAME="BOOTX64.EFI"
        EFI_GRUB_NAME="grubx64.efi"
        HAS_BIOS=1
        ;;
    arm64)
        KERNEL_PKG="linux-image-arm64"
        SHIM_PKG="shim-arm64-signed"
        GRUB_PKG="grub-efi-arm64-signed"
        SHIM_FIND="shimaa64.efi.signed"
        GRUB_FIND="grubaa64.efi.signed"
        EFI_SHIM_NAME="BOOTAA64.EFI"
        EFI_GRUB_NAME="grubaa64.efi"
        HAS_BIOS=0
        ;;
    *)
        echo "错误：不支持的架构 '${ARCH}'（支持 amd64 / arm64）" >&2; exit 1
        ;;
esac

SIGNED_PKGS="${KERNEL_PKG},${SHIM_PKG},${GRUB_PKG}"

# --- 基础模块（所有场景必需） ---
BASE_MODULES="${MOD_FILESYSTEM} ${MOD_NLS} ${MOD_ATA} ${MOD_USB} ${MOD_CDROM} ${MOD_INPUT}"

# --- 可选模块 ---
OPT_NVME=""
[[ "${INCLUDE_NVME}" != "0" ]] && OPT_NVME="${MOD_NVME}"

OPT_VIRT=""
[[ "${INCLUDE_VIRT}" != "0" ]] && OPT_VIRT="${MOD_VIRT}"

# --- 最终模块列表 ---
REQUIRED_MODULES="${BASE_MODULES} ${OPT_NVME} ${OPT_VIRT}"

ISOLINUX_BIN=$(find /usr -name isolinux.bin 2>/dev/null | head -1)
LDLINUX_C32=$(find /usr -name ldlinux.c32 2>/dev/null | head -1)
ISOHDPFX_PATH=$(find /usr -name isohdpfx.bin 2>/dev/null | head -1)

# ---------------------------------------------------------------------------
# 构建目录
# ---------------------------------------------------------------------------
BUILD_DIR="${SCRIPT_DIR}/build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ---------------------------------------------------------------------------
# 退出清理
# ---------------------------------------------------------------------------
BUILD_SUCCESS=0

cleanup() {
    # 构建失败时清理半成品
    if [[ "${BUILD_SUCCESS}" -eq 0 && -d "${BUILD_DIR}" ]]; then
        echo "清理构建目录..."
        rm -rf "${BUILD_DIR}"
    fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

retry() {
    local max="${1}" delay="${2}"
    shift 2
    for i in $(seq 1 "$max"); do
        if "$@"; then return 0; fi
        [[ $i -eq $max ]] && { echo "错误：重试 $max 次后仍失败：$*" >&2; return 1; }
        echo "  第 $i/$max 次重试，${delay} 秒后..."
        sleep "$delay"
    done
}

download_image() {
    local url="$1"

    echo "  正在下载：${url}"
    retry 3 5 curl -k -L -o "${BUILD_DIR}/downloaded_file" "$url"

    local file_type
    file_type=$(file --mime-type -b "${BUILD_DIR}/downloaded_file")
    echo "  文件类型：${file_type}"

    local extracted_name=""

    case "${file_type}" in
        application/gzip)
            extracted_name=$(basename "$url" | sed 's/\.gz$//')
            gunzip -c "${BUILD_DIR}/downloaded_file" > "${BUILD_DIR}/${extracted_name}"
            ;;
        application/x-xz)
            extracted_name=$(basename "$url" | sed 's/\.xz$//')
            xz -dc "${BUILD_DIR}/downloaded_file" > "${BUILD_DIR}/${extracted_name}"
            ;;
        application/x-bzip2)
            extracted_name=$(basename "$url" | sed 's/\.bz2$//')
            bzip2 -dc "${BUILD_DIR}/downloaded_file" > "${BUILD_DIR}/${extracted_name}"
            ;;
        application/zip)
            unzip -j -o "${BUILD_DIR}/downloaded_file" -d "${BUILD_DIR}/"
            extracted_name=$(ls "${BUILD_DIR}"/*.img 2>/dev/null | head -n1 | xargs basename)
            ;;
        application/x-7z-compressed)
            7z x "${BUILD_DIR}/downloaded_file" -o"${BUILD_DIR}/"
            extracted_name=$(ls "${BUILD_DIR}"/*.img 2>/dev/null | head -n1 | xargs basename)
            ;;
        *)
            extracted_name=$(basename "$url")
            mv "${BUILD_DIR}/downloaded_file" "${BUILD_DIR}/${extracted_name}"
            ;;
    esac

    rm -f "${BUILD_DIR}/downloaded_file"

    if [[ -z "${extracted_name}" || ! -f "${BUILD_DIR}/${extracted_name}" ]]; then
        echo "错误：未找到解压后的镜像文件！" >&2; exit 1
    fi

    mv "${BUILD_DIR}/${extracted_name}" "${BUILD_DIR}/temp.img"

    if [[ -z "${ISO_NAME}" ]]; then
        ISO_NAME=$(basename "${extracted_name}" .img)
    fi
}

# ---------------------------------------------------------------------------
# CLI 参数解析
# ---------------------------------------------------------------------------
IMAGE_PATH=""
IMAGE_URL=""
ISO_NAME=""

show_help() {
    echo "ImgFlash - 纯 initramfs ISO 构建器"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -i, --image   指定本地 .img 文件路径"
    echo "  -u, --url     从 URL 下载镜像文件"
    echo "  -n, --name    输出 ISO 名称（默认从镜像文件名推导）"
    echo "  -h, --help    显示此帮助"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--image)
            IMAGE_PATH="$2"; shift 2 ;;
        -n|--name)
            ISO_NAME="$2"; shift 2 ;;
        -u|--url)
            IMAGE_URL="$2"; shift 2 ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            echo "未知选项: $1"; show_help; exit 1 ;;
    esac
done

if [[ -z "${IMAGE_URL}" && -z "${IMAGE_PATH}" ]]; then
    echo "错误：必须提供镜像路径 (-i) 或下载 URL (-u)"
    show_help
    exit 1
fi

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------

echo "==== 依赖检查 ===="
REQUIRED_CMDS="mmdebstrap curl tar xz zstd modprobe depmod mksquashfs xorriso mcopy mmd mkfs.vfat cpio file"
for cmd in ${REQUIRED_CMDS}; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误：缺少必要命令 '$cmd'，请先安装" >&2; exit 1
    fi
done
echo "  依赖检查通过"

# ---------------------------------------------------------------------------
# 确定输入镜像
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

if [[ -n "${IMAGE_URL}" ]]; then
    download_image "${IMAGE_URL}"
fi

if [[ -n "${IMAGE_PATH}" ]]; then
    if [[ ! -f "${IMAGE_PATH}" ]]; then
        echo "错误：找不到镜像文件：${IMAGE_PATH}" >&2; exit 1
    fi
    cp "${IMAGE_PATH}" "${BUILD_DIR}/temp.img"
    if [[ -z "${ISO_NAME}" ]]; then
        ISO_NAME=$(basename "${IMAGE_PATH}" .img)
    fi
fi

# ---------------------------------------------------------------------------
# 初始化构建环境
# ---------------------------------------------------------------------------

echo ""
echo "=========================================="
echo "  ImgFlash - ISO 构建器"
echo "=========================================="
echo "  Debian 套件 : ${DEBIAN_SUITE}"
echo "  目标架构    : ${ARCH}"
echo "  Debian 镜像 : ${DEBIAN_MIRROR}"
echo "  输出名称    : ${ISO_NAME}"
echo "=========================================="
echo ""

# =============================================================================
# Phase 1: mmdebstrap 创建最小 Debian 环境
# =============================================================================

rm -rf "${ROOTFS_DIR}"

echo "[Phase 1] mmdebstrap ${DEBIAN_SUITE} (${ARCH}) ..."
mmdebstrap --variant=essential \
    --include="${SIGNED_PKGS}" \
    "${DEBIAN_SUITE}" "${ROOTFS_DIR}" "${DEBIAN_MIRROR}"

echo "  Phase 1 完成。"

# =============================================================================
# Phase 2: 提取组件
# =============================================================================

echo ""
echo "[Phase 2] 提取组件 ..."

# --- 签名内核 ---
VMLINUZ=$(ls "${ROOTFS_DIR}"/boot/vmlinuz-* 2>/dev/null | head -1)
if [[ -z "${VMLINUZ}" ]]; then
    echo "错误：rootfs 中未找到 vmlinuz" >&2; exit 1
fi
KVER=$(basename "${VMLINUZ}" | sed 's/^vmlinuz-//')
echo "  内核版本：${KVER}"

# --- shim + 签名 GRUB ---
SHIM_SRC=$(find "${ROOTFS_DIR}" -name "${SHIM_FIND}" 2>/dev/null | head -1)
GRUB_SRC=$(find "${ROOTFS_DIR}" -name "${GRUB_FIND}" 2>/dev/null | head -1)
if [[ -z "${SHIM_SRC}" || -z "${GRUB_SRC}" ]]; then
    echo "错误：rootfs 中未找到 shim 或 GRUB" >&2; exit 1
fi

# --- BusyBox（来自 busybox-static 包，静态链接） ---
if ! command -v busybox &>/dev/null; then
    echo "错误：未找到 busybox，请安装 busybox-static 包" >&2; exit 1
fi
echo "  BusyBox $(busybox --help 2>&1 | head -1 | awk '{print $NF}')"

# 清理 rootfs 的 apt 缓存
rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/* \
       "${ROOTFS_DIR}/var/cache/apt"/*

echo "  Phase 2 完成。"

# =============================================================================
# Phase 3: 组装 initramfs
# =============================================================================

echo ""
echo "[Phase 3] 组装 initramfs ..."

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,tmp}
mkdir -p "${INITRAMFS_DIR}"/{usr/bin,usr/sbin,lib}
mkdir -p "${INITRAMFS_DIR}"/{media/cdrom,image,var/log,root}
mkdir -p "${INITRAMFS_DIR}"/{dev/pts,dev/shm}

# BusyBox
cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox"
chmod +x "${INITRAMFS_DIR}/bin/busybox"

# 创建 /bin/sh 符号链接（内核执行 /init 时需要解释器）
ln -s busybox "${INITRAMFS_DIR}/bin/sh"

# /init 和 /usr/bin/installer
cp "${SCRIPT_DIR}/scripts/init.sh" "${INITRAMFS_DIR}/init"
chmod +x "${INITRAMFS_DIR}/init"

echo "${REQUIRED_MODULES}" | tr ' ' '\n' > "${INITRAMFS_DIR}/etc/modules"

sed -i "s/TRIES -lt 10/TRIES -lt ${SCAN_TIMEOUT}/" "${INITRAMFS_DIR}/init"
sed -i "s/after 10 seconds/after ${SCAN_TIMEOUT} seconds/" "${INITRAMFS_DIR}/init"

cp "${SCRIPT_DIR}/scripts/installer.sh" "${INITRAMFS_DIR}/usr/bin/installer"
chmod +x "${INITRAMFS_DIR}/usr/bin/installer"

# 精简内核模块
echo "  精简内核模块 ..."

MOD_SRC="${ROOTFS_DIR}/lib/modules/${KVER}"
if [[ ! -d "${MOD_SRC}" ]]; then
    echo "错误：找不到内核模块目录 ${MOD_SRC}" >&2; exit 1
fi

depmod -b "${ROOTFS_DIR}" "${KVER}"

# 用 modprobe 解析所需模块及依赖
echo "  正在解析模块依赖链 ..."
NEEDED_FILES=""
for mod in ${REQUIRED_MODULES}; do
    deps=$(modprobe -d "${ROOTFS_DIR}" -S "${KVER}" --show-depends "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}')
    NEEDED_FILES="${NEEDED_FILES} ${deps}"
done
NEEDED_FILES=$(echo "$NEEDED_FILES" | tr ' ' '\n' | sort -u | grep .)

if [[ -z "$NEEDED_FILES" ]]; then
    echo "错误：modprobe 未能解析任何模块依赖，构建环境异常" >&2; exit 1
fi

MOD_DEST="${INITRAMFS_DIR}/lib/modules/${KVER}"
echo "  包含 $(echo "$NEEDED_FILES" | wc -l) 个模块（含依赖）"

for mod_file in $NEEDED_FILES; do
    rel_path=$(echo "$mod_file" | sed "s|${MOD_SRC}/||")
    dest_dir="${MOD_DEST}/$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    xz -dc "$mod_file" > "${dest_dir}/$(basename "${rel_path%.xz}")"
done

# 拷贝模块元数据
for f in modules.builtin modules.builtin.modinfo modules.order; do
    [ -f "${MOD_SRC}/$f" ] && cp "${MOD_SRC}/$f" "${MOD_DEST}/"
done

# 模块已全部复制到 initramfs，提取后续阶段需要的文件，然后释放 rootfs
cp "${VMLINUZ}"   "${BUILD_DIR}/vmlinuz"
cp "${SHIM_SRC}"  "${BUILD_DIR}/shim.efi"
cp "${GRUB_SRC}"  "${BUILD_DIR}/grub.efi"
VMLINUZ="${BUILD_DIR}/vmlinuz"
SHIM_SRC="${BUILD_DIR}/shim.efi"
GRUB_SRC="${BUILD_DIR}/grub.efi"

rm -rf "${ROOTFS_DIR}"

depmod -b "${INITRAMFS_DIR}" "${KVER}"

MOD_COUNT=$(find "${INITRAMFS_DIR}/lib/modules" -name '*.ko' | wc -l)
MOD_SIZE=$(du -sh "${INITRAMFS_DIR}/lib/modules" | awk '{print $1}')
echo "  模块：${MOD_COUNT} 个文件，${MOD_SIZE}"

# 打包 cpio 归档
echo "  创建 initramfs 归档 ..."
cd "${INITRAMFS_DIR}"
find . -print0 | cpio --null -o -H newc --owner root:root 2>/dev/null | zstd -${ZSTD_LEVEL} > "${BUILD_DIR}/initrd.img"
cd "${SCRIPT_DIR}"

INITRD_SIZE=$(ls -lh "${BUILD_DIR}/initrd.img" | awk '{print $5}')
echo "  Initramfs 大小：${INITRD_SIZE}"

# initramfs 打包完成，释放空间
rm -rf "${INITRAMFS_DIR}"

echo "  Phase 3 完成。"

# =============================================================================
# Phase 4: 打包镜像容器
# =============================================================================

echo ""
echo "[Phase 4] 打包镜像容器 ..."

mv "${BUILD_DIR}/temp.img" "${BUILD_DIR}/image.img"

IMG_SIZE=$(ls -lh "${BUILD_DIR}/image.img" | awk '{print $5}')
echo "  原始镜像大小：${IMG_SIZE}"

echo "  创建 squashfs（zstd）..."
mksquashfs "${BUILD_DIR}/image.img" "${BUILD_DIR}/image.squashfs" \
    -comp zstd -Xcompression-level ${ZSTD_LEVEL} -no-progress -no-xattrs

SQFS_SIZE=$(ls -lh "${BUILD_DIR}/image.squashfs" | awk '{print $5}')
echo "  Squashfs 大小：${SQFS_SIZE}"

# 镜像源文件不再需要，释放空间
rm -f "${BUILD_DIR}/image.img"

echo "  Phase 4 完成。"

# =============================================================================
# Phase 5: 组装 ISO 文件系统结构
# =============================================================================

echo ""
echo "[Phase 5] 组装 ISO 结构 ..."

mkdir -p "${ISO_DIR}/boot"
mv "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
mv "${BUILD_DIR}/initrd.img" "${ISO_DIR}/boot/initrd.img"
mv "${BUILD_DIR}/image.squashfs" "${ISO_DIR}/image.squashfs"

# Syslinux（BIOS 启动，仅 amd64）
if [[ "${HAS_BIOS}" -eq 1 ]]; then
    if [[ -z "${ISOLINUX_BIN}" || -z "${LDLINUX_C32}" || -z "${ISOHDPFX_PATH}" ]]; then
        echo "错误：未找到 syslinux 引导文件。请安装 syslinux-common 和 isolinux 包。" >&2
        exit 1
    fi

    mkdir -p "${ISO_DIR}/boot/syslinux"
    cp "${ISOLINUX_BIN}"  "${ISO_DIR}/boot/syslinux/isolinux.bin"
    cp "${LDLINUX_C32}"   "${ISO_DIR}/boot/syslinux/ldlinux.c32"
    cp "${ISOHDPFX_PATH}" "${ISO_DIR}/boot/syslinux/isohdpfx.bin"

    SYSLINUX_TIMEOUT=$(( BOOT_TIMEOUT * 10 ))

    cat > "${ISO_DIR}/boot/syslinux/syslinux.cfg" << EOF
DEFAULT imgflash
PROMPT 0
TIMEOUT ${SYSLINUX_TIMEOUT}

LABEL imgflash
  KERNEL /boot/vmlinuz
  INITRD /boot/initrd.img
  APPEND ${KERNEL_PARAMS}
EOF
fi

# EFI 启动（Secure Boot 链：shim → GRUB → 内核）

# 1. 先把文件集结到 ISO 根目录
mkdir -p "${ISO_DIR}/EFI/BOOT"
cp "${SHIM_SRC}" "${ISO_DIR}/EFI/BOOT/${EFI_SHIM_NAME}"
cp "${GRUB_SRC}" "${ISO_DIR}/EFI/BOOT/${EFI_GRUB_NAME}"

# 2. 完整菜单配置
cat > "${ISO_DIR}/EFI/BOOT/grub.cfg" << EOF
search --no-floppy --label --set=root ${VOLUME_LABEL}
set timeout=${BOOT_TIMEOUT}
set default=0

menuentry "ImgFlash" {
    linux /boot/vmlinuz ${KERNEL_PARAMS}
    initrd /boot/initrd.img
}
EOF

# 3. 制作 efi.img
mkdir -p "${ISO_DIR}/boot/grub"
EFI_IMG="${ISO_DIR}/boot/grub/efi.img"
SOURCE_KB=$(du -skL "${ISO_DIR}/EFI/BOOT" | awk '{print $1}')
FINAL_KB=$(( SOURCE_KB + 512 ))
echo "  EFI 镜像: ${FINAL_KB} KB"
dd if=/dev/zero of="${EFI_IMG}" bs=1k count="${FINAL_KB}" 2>/dev/null
mkfs.vfat "${EFI_IMG}" >/dev/null

mmd -i "${EFI_IMG}" ::EFI ::EFI/BOOT

mcopy -i "${EFI_IMG}" \
    "${ISO_DIR}/EFI/BOOT/${EFI_SHIM_NAME}" \
    "${ISO_DIR}/EFI/BOOT/${EFI_GRUB_NAME}" \
    "${ISO_DIR}/EFI/BOOT/grub.cfg" \
    ::EFI/BOOT/

echo "  Phase 5 完成。"

# =============================================================================
# Phase 6: 生成最终 ISO
# =============================================================================

echo ""
echo "[Phase 6] 生成 ISO ..."

FINAL_ISO="${OUTPUT_DIR}/${ISO_NAME}.iso"

if [[ "${HAS_BIOS}" -eq 1 ]]; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -o "${FINAL_ISO}" \
        -full-iso9660-filenames \
        -volid "${VOLUME_LABEL}" \
        -isohybrid-mbr "${ISO_DIR}/boot/syslinux/isohdpfx.bin" \
        -eltorito-boot boot/syslinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/syslinux/boot.cat \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
        -isohybrid-gpt-basdat \
        -append_partition 2 0xef "${ISO_DIR}/boot/grub/efi.img" \
        "${ISO_DIR}"
else
    xorriso -as mkisofs \
        -iso-level 3 \
        -o "${FINAL_ISO}" \
        -full-iso9660-filenames \
        -volid "${VOLUME_LABEL}" \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
        -append_partition 2 0xef "${ISO_DIR}/boot/grub/efi.img" \
        "${ISO_DIR}"
fi

# ISO 已生成，释放 ISO 目录空间
rm -rf "${ISO_DIR}"

# CI 用 sudo 构建时产物归 root，修正属主
[ "$(uname)" = "Linux" ] && chown "$(id -u):$(id -g)" "${FINAL_ISO}" 2>/dev/null || true

BUILD_SUCCESS=1

echo ""
echo "=================="
echo "  构建完成！"
echo "=================="
ISO_SIZE=$(du -h "${FINAL_ISO}" | awk '{print $1}')
echo "  产物：${FINAL_ISO} (${ISO_SIZE})"