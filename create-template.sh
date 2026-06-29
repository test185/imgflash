#!/bin/bash
# ===========
# ImgFlash - 创建构建模板
# ===========

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/build.env"
[[ -f "${ENV_FILE}" ]] || { echo "错误：缺少配置文件 ${ENV_FILE}" >&2; exit 1; }
source "${ENV_FILE}"

die() { echo "错误：$*" >&2; exit 1; }

# --- CLI 参数 ---
SECURE_BOOT="${ENABLE_SECURE_BOOT:-0}"
OUTPUT_NAME=""
SKIP_BOOTSTRAP=0

show_help() {
    cat <<EOF
ImgFlash - 创建构建模板

用法: $0 [选项]

选项:
  --arch          目标架构（amd64/arm64，默认 amd64）
  --secure-boot   启用 Secure Boot（默认禁用）
  --skip-bootstrap  跳过 Phase 1-2，复用已有 boot cache
  -o, --output    输出模板名称（不含 .iso 后缀）
  -h, --help      显示此帮助

环境变量:
  ARCH            目标架构（amd64/arm64）
  ENABLE_SECURE_BOOT  启用 Secure Boot（0/1）

输出:
  模板 ISO 将保存到 templates/ 目录
  默认名称格式: {arch}-template.iso 或 {arch}-secureboot-template.iso

示例:
  $0 --arch amd64 --secure-boot -o amd64-secureboot
  $0 --arch arm64
EOF
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --arch) ARCH="$2"; shift 2 ;;
        --secure-boot) SECURE_BOOT="1"; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
        -o|--output) OUTPUT_NAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "未知选项: $1"; show_help; exit 1 ;;
    esac
done

# --- 确定输出名称 ---
if [[ -z "${OUTPUT_NAME}" ]]; then
    OUTPUT_NAME="${ARCH}-template"
    [[ "${SECURE_BOOT}" == "1" ]] && OUTPUT_NAME="${ARCH}-secureboot-template"
fi

TEMPLATES_DIR="${SCRIPT_DIR}/templates"
mkdir -p "${TEMPLATES_DIR}"
FINAL_ISO="${TEMPLATES_DIR}/${OUTPUT_NAME}.iso"

# --- 架构映射 ---
case "${ARCH}" in
    amd64)
        KERNEL_PKG="linux-image-amd64"
        SHIM_PKG="shim-signed"
        GRUB_PKG="grub-efi-amd64-signed"
        SHIM_NAME="shimx64.efi.signed"
        GRUB_NAME="grubx64.efi.signed"
        EFI_BOOT="BOOTX64.EFI"
        ;;
    arm64)
        KERNEL_PKG="linux-image-arm64"
        SHIM_PKG="shim-arm64-signed"
        GRUB_PKG="grub-efi-arm64-signed"
        SHIM_NAME="shimaa64.efi.signed"
        GRUB_NAME="grubaa64.efi.signed"
        EFI_BOOT="BOOTAA64.EFI"
        ;;
    *) die "不支持的架构 '${ARCH}'" ;;
esac

# --- 构建目录 ---
BUILD_DIR="${SCRIPT_DIR}/build/${ARCH}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"

# --- 退出清理 ---
BUILD_SUCCESS=0
cleanup() {
    [[ "${BUILD_SUCCESS}" -eq 0 && -d "${BUILD_DIR}" ]] && { echo "清理构建目录..."; rm -rf "${BUILD_DIR}"; }
    :
}
trap cleanup EXIT

echo ""; echo "=========================================="
echo "  ImgFlash - 创建模板"
echo "=========================================="
echo "  架构      : ${ARCH}"
echo "  Secure Boot: $([ "${SECURE_BOOT}" == "1" ] && echo "启用" || echo "禁用")"
echo "  输出      : ${OUTPUT_NAME}.iso"
echo "=========================================="; echo ""

# =============================================================================
# Phase 1-2: 创建 rootfs 并提取组件
# =============================================================================

if [[ "${SKIP_BOOTSTRAP}" == "1" ]]; then
    echo "[跳过] Phase 1-2：复用 ${BUILD_DIR}"
    [[ -d "${ROOTFS_DIR}" ]] || die "rootfs 不存在，无法跳过 bootstrap"

    VMLINUZ=$(ls "${ROOTFS_DIR}"/boot/vmlinuz-* 2>/dev/null | head -1)
    [[ -n "${VMLINUZ}" ]] || die "复用 rootfs 中未找到 vmlinuz"
    KVER=$(basename "${VMLINUZ}" | sed 's/^vmlinuz-//')
    echo "  内核版本：${KVER}"

    GRUB_SRC=$(find "${ROOTFS_DIR}" -name "${GRUB_NAME}" -print -quit 2>/dev/null)
    if [[ -z "${GRUB_SRC}" ]]; then
        echo "  未找到 ${GRUB_NAME}，尝试其他路径..."
        GRUB_SRC=$(find "${ROOTFS_DIR}" -name "grub*.efi*" -print -quit 2>/dev/null)
    fi
    [[ -n "${GRUB_SRC}" ]] || die "复用 rootfs 中未找到 GRUB EFI 文件"

    SHIM_SRC=$(find "${ROOTFS_DIR}" -name "${SHIM_NAME}" -print -quit 2>/dev/null)
    if [[ -z "${SHIM_SRC}" ]]; then
        SHIM_SRC=$(find "${ROOTFS_DIR}" -name "shim*.efi*" -print -quit 2>/dev/null)
    fi
    [[ "${SECURE_BOOT}" == "1" && -z "${SHIM_SRC}" ]] && die "复用 rootfs 中未找到 shim"
else
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    SIGNED_PKGS="${KERNEL_PKG},${GRUB_PKG}"
    [[ "${SECURE_BOOT}" == "1" ]] && SIGNED_PKGS="${KERNEL_PKG},${SHIM_PKG},${GRUB_PKG}"

    echo "[Phase 1] mmdebstrap ${DEBIAN_SUITE} (${ARCH}) ..."
    mmdebstrap --variant=essential \
        --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
        --include="${SIGNED_PKGS}" \
        "${DEBIAN_SUITE}" "${ROOTFS_DIR}" "${DEBIAN_MIRROR}"
    echo "  Phase 1 完成。"

    # =============================================================================
    # Phase 2: 提取组件
    # =============================================================================
    echo ""; echo "[Phase 2] 提取组件 ..."

    VMLINUZ=$(ls "${ROOTFS_DIR}"/boot/vmlinuz-* 2>/dev/null | head -1)
    [[ -n "${VMLINUZ}" ]] || die "rootfs 中未找到 vmlinuz"
    KVER=$(basename "${VMLINUZ}" | sed 's/^vmlinuz-//')
    echo "  内核版本：${KVER}"

    GRUB_SRC=$(find "${ROOTFS_DIR}" -name "${GRUB_NAME}" -print -quit 2>/dev/null)
    if [[ -z "${GRUB_SRC}" ]]; then
        echo "  未找到 ${GRUB_NAME}，尝试其他路径..."
        GRUB_SRC=$(find "${ROOTFS_DIR}" -name "grub*.efi*" -print -quit 2>/dev/null)
    fi
    [[ -n "${GRUB_SRC}" ]] || die "rootfs 中未找到 GRUB EFI 文件"

    SHIM_SRC=$(find "${ROOTFS_DIR}" -name "${SHIM_NAME}" -print -quit 2>/dev/null)
    if [[ -z "${SHIM_SRC}" ]]; then
        SHIM_SRC=$(find "${ROOTFS_DIR}" -name "shim*.efi*" -print -quit 2>/dev/null)
    fi
    [[ "${SECURE_BOOT}" == "1" && -z "${SHIM_SRC}" ]] && die "rootfs 中未找到 shim"

    rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/* \
           "${ROOTFS_DIR}/var/cache/apt"/*

    echo "  Phase 2 完成。"
fi

# =============================================================================
# Phase 3: 组装 initramfs
# =============================================================================
echo ""; echo "[Phase 3] 组装 initramfs ..."

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,tmp}
mkdir -p "${INITRAMFS_DIR}"/{usr/bin,usr/sbin,lib}
mkdir -p "${INITRAMFS_DIR}"/{media/cdrom,image,var/log,root}

# BusyBox（带 modprobe 支持）
ARCH_DIR="${ARCH^^}"
cp "${SCRIPT_DIR}/binaries/${ARCH_DIR}/busybox_MODPROBE"  "${INITRAMFS_DIR}/sbin/modprobe"
cp "${SCRIPT_DIR}/binaries/${ARCH_DIR}/busybox_MOUNT"     "${INITRAMFS_DIR}/bin/mount"
chmod +x "${INITRAMFS_DIR}/sbin/modprobe" "${INITRAMFS_DIR}/bin/mount"

# disktui-lite
[[ -f "${SCRIPT_DIR}/binaries/disktui-lite" ]] || die "找不到 disktui-lite，请先构建"
cp "${SCRIPT_DIR}/binaries/disktui-lite" "${INITRAMFS_DIR}/usr/bin/disktui-lite"
chmod +x "${INITRAMFS_DIR}/usr/bin/disktui-lite"
ln -s /usr/bin/disktui-lite "${INITRAMFS_DIR}/init"

# 模块列表
BASE_MODULES="${MOD_FILESYSTEM} ${MOD_NLS} ${MOD_ATA} ${MOD_USB} ${MOD_CDROM} ${MOD_INPUT} ${MOD_EMMC} ${MOD_EMMC_CARDREADER} ${MOD_EMMC_USB:-}"
OPT_NVME=$([[ "${INCLUDE_NVME}" != "0" ]] && echo "${MOD_NVME}" || echo "")
OPT_VIRT=$([[ "${INCLUDE_VIRT}" != "0" ]] && echo "${MOD_VIRT}" || echo "")
REQUIRED_MODULES="${BASE_MODULES} ${OPT_NVME} ${OPT_VIRT}"

echo "${REQUIRED_MODULES}" | tr ' ' '\n' > "${INITRAMFS_DIR}/etc/modules"

echo "  精简内核模块 ..."
MOD_SRC="${ROOTFS_DIR}/lib/modules/${KVER}"
[[ -d "${MOD_SRC}" ]] || die "找不到内核模块目录 ${MOD_SRC}"

depmod -b "${ROOTFS_DIR}" "${KVER}"

echo "  正在解析模块依赖链 ..."
NEEDED_FILES=""
for mod in ${REQUIRED_MODULES}; do
    deps=$(modprobe -d "${ROOTFS_DIR}" -S "${KVER}" --show-depends "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}')
    NEEDED_FILES="${NEEDED_FILES} ${deps}"
done
NEEDED_FILES=$(echo "$NEEDED_FILES" | tr ' ' '\n' | sort -u | grep .)

[[ -n "$NEEDED_FILES" ]] || die "modprobe 未能解析任何模块依赖，构建环境异常"

MOD_DEST="${INITRAMFS_DIR}/lib/modules/${KVER}"
echo "  包含 $(echo "$NEEDED_FILES" | wc -l) 个模块（含依赖）"

for mod_file in $NEEDED_FILES; do
    rel_path=$(echo "$mod_file" | sed "s|${MOD_SRC}/||")
    dest_dir="${MOD_DEST}/$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    xz -dc "$mod_file" > "${dest_dir}/$(basename "${rel_path%.xz}")"
done

for f in modules.builtin modules.builtin.modinfo; do
    [ -f "${MOD_SRC}/$f" ] && cp "${MOD_SRC}/$f" "${MOD_DEST}/"
done

[[ "${SKIP_BOOTSTRAP}" == "1" ]] && rm -rf "${ROOTFS_DIR}"
depmod -b "${INITRAMFS_DIR}" "${KVER}"

MOD_COUNT=$(find "${INITRAMFS_DIR}/lib/modules" -name '*.ko' | wc -l)
MOD_SIZE=$(du -sh "${INITRAMFS_DIR}/lib/modules" | awk '{print $1}')
echo "  模块：${MOD_COUNT} 个文件，${MOD_SIZE}"

echo "  创建 initramfs 归档 ..."
cd "${INITRAMFS_DIR}"
find . -print0 | sort -z | cpio --null -o -H newc --owner root:root 2>/dev/null | zstd -T0 -${ZSTD_LEVEL} > "${BUILD_DIR}/initrd.img"
cd "${SCRIPT_DIR}"

INITRD_SIZE=$(ls -lh "${BUILD_DIR}/initrd.img" | awk '{print $5}')
echo "  Initramfs 大小：${INITRD_SIZE}"

rm -rf "${INITRAMFS_DIR}"
echo "  Phase 3 完成。"

# =============================================================================
# Phase 4: 组装 ISO 结构
# =============================================================================
echo ""; echo "[Phase 4] 组装模板 ISO ..."

mkdir -p "${ISO_DIR}/boot"
cp "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
cp "${BUILD_DIR}/initrd.img" "${ISO_DIR}/boot/initrd.img"

# EFI 引导
mkdir -p "${ISO_DIR}/EFI/BOOT" "${ISO_DIR}/EFI/debian"

if [[ "${SECURE_BOOT}" == "1" ]]; then
    cp "${SHIM_SRC}" "${ISO_DIR}/EFI/BOOT/${EFI_BOOT}"
    cp "${GRUB_SRC}" "${ISO_DIR}/EFI/BOOT/${GRUB_NAME%%.*}.efi"
else
    cp "${GRUB_SRC}" "${ISO_DIR}/EFI/BOOT/${EFI_BOOT}"
fi

# GRUB 配置（不含用户镜像）
TIMEOUT_STYLE=$([[ "${BOOT_TIMEOUT}" -eq 0 ]] && echo "hidden" || echo "menu")

cat > "${ISO_DIR}/EFI/debian/grub.cfg" << EOF
search --no-floppy --label --set=root ${VOLUME_LABEL}
set timeout=${BOOT_TIMEOUT}
set timeout_style=${TIMEOUT_STYLE}
set default=0

menuentry "ImgFlash" {
    linux /boot/vmlinuz ${KERNEL_PARAMS}
    initrd /boot/initrd.img
}
EOF

# 创建 efi.img（El Torito 标准）
mkdir -p "${ISO_DIR}/boot/grub"
EFI_IMG="${ISO_DIR}/boot/grub/efi.img"
EFI_SIZE_KB=$(( $(du -skL "${GRUB_SRC}" 2>/dev/null | awk '{print $1}') + 580 ))
[[ "${SECURE_BOOT}" == "1" ]] && EFI_SIZE_KB=$(( EFI_SIZE_KB + $(du -skL "${SHIM_SRC}" 2>/dev/null | awk '{print $1}') ))

echo "  EFI 镜像: ${EFI_SIZE_KB} KB"

dd if=/dev/zero of="${EFI_IMG}" bs=1k count="${EFI_SIZE_KB}" 2>/dev/null
mkfs.vfat "${EFI_IMG}" >/dev/null
mmd -i "${EFI_IMG}" ::EFI ::EFI/BOOT ::EFI/debian

if [[ "${SECURE_BOOT}" == "1" ]]; then
    mcopy -i "${EFI_IMG}" "${SHIM_SRC}" ::EFI/BOOT/${EFI_BOOT}
    mcopy -i "${EFI_IMG}" "${GRUB_SRC}" ::EFI/BOOT/${GRUB_NAME%%.*}.efi
else
    mcopy -i "${EFI_IMG}" "${GRUB_SRC}" ::EFI/BOOT/${EFI_BOOT}
fi

mcopy -i "${EFI_IMG}" - ::EFI/debian/grub.cfg << STUB_EOF
search --no-floppy --label --set=root ${VOLUME_LABEL}
configfile /EFI/debian/grub.cfg
STUB_EOF

echo "  生成模板 ISO ..."
xorriso -as mkisofs \
    -iso-level 3 \
    -o "${FINAL_ISO}" \
    -full-iso9660-filenames \
    -volid "${VOLUME_LABEL}" \
    -e boot/grub/efi.img \
    -no-emul-boot \
    "${ISO_DIR}"

rm -rf "${ISO_DIR}"
BUILD_SUCCESS=1

echo ""; echo "=================="
echo "  模板创建完成！"
echo "=================="
echo "  产物：${FINAL_ISO} ($(du -h "${FINAL_ISO}" | awk '{print $1}'))"