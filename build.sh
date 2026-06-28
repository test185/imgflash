#!/bin/bash
# ===========
# ImgFlash
# ===========

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/build.env"
[[ -f "${ENV_FILE}" ]] || { echo "错误：缺少配置文件 ${ENV_FILE}" >&2; exit 1; }
source "${ENV_FILE}"

die() { echo "错误：$*" >&2; exit 1; }

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
    *) die "不支持的架构 '${ARCH}'（支持 amd64 / arm64）" ;;
esac

SIGNED_PKGS="${KERNEL_PKG},${GRUB_PKG}"
[[ "${ENABLE_SECURE_BOOT:-0}" == "1" ]] && SIGNED_PKGS="${KERNEL_PKG},${SHIM_PKG},${GRUB_PKG}"

BASE_MODULES="${MOD_FILESYSTEM} ${MOD_NLS} ${MOD_ATA} ${MOD_USB} ${MOD_CDROM} ${MOD_INPUT} ${MOD_EMMC} ${MOD_EMMC_CARDREADER} ${MOD_EMMC_USB:-}"
OPT_NVME=$([[ "${INCLUDE_NVME}" != "0" ]] && echo "${MOD_NVME}" || echo "")
OPT_VIRT=$([[ "${INCLUDE_VIRT}" != "0" ]] && echo "${MOD_VIRT}" || echo "")
REQUIRED_MODULES="${BASE_MODULES} ${OPT_NVME} ${OPT_VIRT}"

ISOLINUX_BIN=$(find /usr -name isolinux.bin 2>/dev/null | head -1)
LDLINUX_C32=$(find /usr -name ldlinux.c32 2>/dev/null | head -1)
ISOHDPFX_PATH=$(find /usr -name isohdpfx.bin 2>/dev/null | head -1)

# --- 构建目录 ---
BUILD_DIR="${SCRIPT_DIR}/build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# --- 退出清理 ---
BUILD_SUCCESS=0
cleanup() {
    [[ "${BUILD_SUCCESS}" -eq 0 && -d "${BUILD_DIR}" ]] && { echo "清理构建目录..."; rm -rf "${BUILD_DIR}"; }
    :
}
trap cleanup EXIT

# --- 辅助函数 ---
verify_sha256() {
    local actual=$(sha256sum "$1" | cut -d' ' -f1)
    [[ "$actual" == "$2" ]] && { echo "  SHA256 校验通过"; return 0; }
    echo "  SHA256 校验失败！" >&2
    echo "  预期: $2" >&2
    echo "  实际: $actual" >&2
    return 1
}

retry() {
    local max="$1" delay="$2"
    shift 2
    for i in $(seq 1 "$max"); do
        "$@" && return 0
        [[ $i -eq $max ]] && die "重试 $max 次后仍失败：$*"
        echo "  第 $i/$max 次重试，${delay} 秒后..."
        sleep "$delay"
    done
}

download_image() {
    local url="$1" checksum="$2"
    echo "  正在下载：${url}"
    retry 3 5 curl -Lo "${BUILD_DIR}/downloaded_file" "$url"

    if [[ -n "$checksum" ]]; then
        echo "  正在验证 SHA256..."
        verify_sha256 "${BUILD_DIR}/downloaded_file" "$checksum" || {
            echo "  校验失败，尝试重新下载..."
            rm -f "${BUILD_DIR}/downloaded_file"
            retry 2 3 curl -Lo "${BUILD_DIR}/downloaded_file" "$url"
            verify_sha256 "${BUILD_DIR}/downloaded_file" "$checksum" || die "SHA256 校验再次失败，终止构建"
        }
    fi

    local file_type=$(file --mime-type -b "${BUILD_DIR}/downloaded_file")
    echo "  文件类型：${file_type}"

    local extracted_name=""

    case "${url}" in
        *.tar.gz|*.tar.xz|*.tar.bz2|*.tar.zst|*.tgz)
            tar -xf "${BUILD_DIR}/downloaded_file" -C "${BUILD_DIR}/"
            extracted_name=$(ls "${BUILD_DIR}"/*.img 2>/dev/null | head -1 | xargs basename)
            ;;
    esac

    if [[ -z "${extracted_name}" ]]; then
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
    fi

    rm -f "${BUILD_DIR}/downloaded_file"
    [[ -n "${extracted_name}" && -f "${BUILD_DIR}/${extracted_name}" ]] || die "未找到解压后的镜像文件！"

    mv "${BUILD_DIR}/${extracted_name}" "${BUILD_DIR}/temp.img"
    ISO_NAME=${ISO_NAME:-$(basename "${extracted_name}" .img)}
}

# --- CLI 参数解析 ---
IMAGE_PATH=""
IMAGE_URL=""
ISO_NAME=""
SHA256_CHECKSUM=""

show_help() {
    cat <<EOF
ImgFlash - 纯 initramfs ISO 构建器

用法: $0 [选项]

选项:
  -i, --image    指定本地 .img 文件路径
  -u, --url      从 URL 下载镜像文件
  -n, --name     输出 ISO 名称（默认从镜像文件名推导）
  -c, --checksum SHA256 校验值（可选）
  -h, --help     显示此帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--image) IMAGE_PATH="$2"; shift 2 ;;
        -n|--name)  ISO_NAME="$2"; shift 2 ;;
        -u|--url)   IMAGE_URL="$2"; shift 2 ;;
        -c|--checksum) SHA256_CHECKSUM="$2"; shift 2 ;;
        -h|--help)  show_help; exit 0 ;;
        *) echo "未知选项: $1"; show_help; exit 1 ;;
    esac
done

[[ -n "${IMAGE_URL}" || -n "${IMAGE_PATH}" ]] || die "必须提供镜像路径 (-i) 或下载 URL (-u)"

# --- 依赖检查 ---
echo "==== 依赖检查 ===="
REQUIRED_CMDS="mmdebstrap curl tar xz zstd modprobe depmod mksquashfs xorriso mcopy mmd mkfs.vfat cpio file sha256sum"
for cmd in ${REQUIRED_CMDS}; do
    command -v "$cmd" &>/dev/null || die "缺少必要命令 '$cmd'，请先安装"
done
echo "  依赖检查通过"

# --- 确定输入镜像 ---
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

[[ -n "${IMAGE_URL}" ]] && download_image "${IMAGE_URL}" "${SHA256_CHECKSUM}"

if [[ -n "${IMAGE_PATH}" ]]; then
    [[ -f "${IMAGE_PATH}" ]] || die "找不到镜像文件：${IMAGE_PATH}"
    [[ -n "${SHA256_CHECKSUM}" ]] && { echo "  正在验证本地镜像 SHA256..."; verify_sha256 "${IMAGE_PATH}" "${SHA256_CHECKSUM}" || exit 1; }
    cp "${IMAGE_PATH}" "${BUILD_DIR}/temp.img"
    ISO_NAME=${ISO_NAME:-$(basename "${IMAGE_PATH}" .img)}
fi

# =============================================================================
# Phase 1: mmdebstrap 创建最小 Debian 环境
# =============================================================================
rm -rf "${ROOTFS_DIR}"

echo ""; echo "=========================================="
echo "  ImgFlash - ISO 构建器"
echo "=========================================="
echo "  Debian 套件 : ${DEBIAN_SUITE}"
echo "  目标架构    : ${ARCH}"
echo "  Secure Boot : $([ "${ENABLE_SECURE_BOOT:-0}" == "1" ] && echo "启用" || echo "禁用")"
echo "  Debian 镜像 : ${DEBIAN_MIRROR}"
echo "  输出名称    : ${ISO_NAME}"
echo "=========================================="; echo ""

echo "[Phase 1] mmdebstrap ${DEBIAN_SUITE} (${ARCH}) ..."
mmdebstrap --variant=essential \
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

GRUB_SRC=$(find "${ROOTFS_DIR}" -name "${GRUB_FIND}" 2>/dev/null | head -1)
[[ -n "${GRUB_SRC}" ]] || die "rootfs 中未找到 GRUB"

if [[ "${ENABLE_SECURE_BOOT:-0}" == "1" ]]; then
    SHIM_SRC=$(find "${ROOTFS_DIR}" -name "${SHIM_FIND}" 2>/dev/null | head -1)
    [[ -n "${SHIM_SRC}" ]] || die "rootfs 中未找到 shim"
fi

command -v busybox &>/dev/null || die "未找到 busybox，请安装 busybox-static 包"
echo "  BusyBox $(busybox --help 2>&1 | head -1 | awk '{print $NF}')"

rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/* \
       "${ROOTFS_DIR}/var/cache/apt"/*
echo "  Phase 2 完成。"

# =============================================================================
# Phase 3: 组装 initramfs
# =============================================================================
echo ""; echo "[Phase 3] 组装 initramfs ..."

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,tmp}
mkdir -p "${INITRAMFS_DIR}"/{usr/bin,usr/sbin,lib}
mkdir -p "${INITRAMFS_DIR}"/{media/cdrom,image,var/log,root}
mkdir -p "${INITRAMFS_DIR}"/{dev/pts,dev/shm}

if [[ "${USE_TUI}" == "1" ]]; then
    ARCH_DIR="${ARCH^^}"
    cp "${SCRIPT_DIR}/binaries/${ARCH_DIR}/busybox_MODPROBE"  "${INITRAMFS_DIR}/sbin/modprobe"
    cp "${SCRIPT_DIR}/binaries/${ARCH_DIR}/busybox_MOUNT"     "${INITRAMFS_DIR}/bin/mount"
    chmod +x "${INITRAMFS_DIR}/sbin/modprobe" "${INITRAMFS_DIR}/bin/mount"
else
    cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    ln -s busybox "${INITRAMFS_DIR}/bin/sh"
fi

if [[ "${USE_TUI}" == "1" ]]; then
    [[ -f "/build/binaries/disktui-lite" ]] || die "找不到 /build/binaries/disktui-lite，请先构建 disktui-lite"
    cp /build/binaries/disktui-lite "${INITRAMFS_DIR}/usr/bin/disktui-lite"
    chmod +x "${INITRAMFS_DIR}/usr/bin/disktui-lite"
    ln -s /usr/bin/disktui-lite "${INITRAMFS_DIR}/init"
else
    cp "${SCRIPT_DIR}/scripts/init.sh" "${INITRAMFS_DIR}/init"
    chmod +x "${INITRAMFS_DIR}/init"
    sed -i "s/TRIES -lt 10/TRIES -lt ${SCAN_TIMEOUT}/" "${INITRAMFS_DIR}/init"
    sed -i "s/after 10 seconds/after ${SCAN_TIMEOUT} seconds/" "${INITRAMFS_DIR}/init"
    cp "${SCRIPT_DIR}/scripts/installer.sh" "${INITRAMFS_DIR}/usr/bin/installer"
    chmod +x "${INITRAMFS_DIR}/usr/bin/installer"
fi

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

cp "${VMLINUZ}"  "${BUILD_DIR}/vmlinuz"
cp "${GRUB_SRC}" "${BUILD_DIR}/grub.efi"
VMLINUZ="${BUILD_DIR}/vmlinuz"
GRUB_SRC="${BUILD_DIR}/grub.efi"

if [[ "${ENABLE_SECURE_BOOT:-0}" == "1" ]]; then
    cp "${SHIM_SRC}" "${BUILD_DIR}/shim.efi"
    SHIM_SRC="${BUILD_DIR}/shim.efi"
fi

rm -rf "${ROOTFS_DIR}"
depmod -b "${INITRAMFS_DIR}" "${KVER}"

MOD_COUNT=$(find "${INITRAMFS_DIR}/lib/modules" -name '*.ko' | wc -l)
MOD_SIZE=$(du -sh "${INITRAMFS_DIR}/lib/modules" | awk '{print $1}')
echo "  模块：${MOD_COUNT} 个文件，${MOD_SIZE}"

echo "  创建 initramfs 归档 ..."
cd "${INITRAMFS_DIR}"
find . -print0 | sort -z | cpio --null -o -H newc --owner root:root 2>/dev/null | zstd -${ZSTD_LEVEL} > "${BUILD_DIR}/initrd.img"
cd "${SCRIPT_DIR}"

INITRD_SIZE=$(ls -lh "${BUILD_DIR}/initrd.img" | awk '{print $5}')
echo "  Initramfs 大小：${INITRD_SIZE}"

rm -rf "${INITRAMFS_DIR}"
echo "  Phase 3 完成。"

# =============================================================================
# Phase 4: 打包镜像容器
# =============================================================================
echo ""; echo "[Phase 4] 打包镜像容器 ..."

mv "${BUILD_DIR}/temp.img" "${BUILD_DIR}/image.img"
fallocate --dig-holes "${BUILD_DIR}/image.img" 2>/dev/null || true
echo "  原始镜像大小：$(ls -lh "${BUILD_DIR}/image.img" | awk '{print $5}')"

echo "  创建 squashfs（zstd）..."
mksquashfs "${BUILD_DIR}/image.img" "${BUILD_DIR}/image.squashfs" \
    -b 1M -comp zstd -Xcompression-level ${ZSTD_LEVEL} \
    -no-fragments -no-duplicates -no-progress -no-xattrs

echo "  Squashfs 大小：$(ls -lh "${BUILD_DIR}/image.squashfs" | awk '{print $5}')"
rm -f "${BUILD_DIR}/image.img"
echo "  Phase 4 完成。"

# =============================================================================
# Phase 5: 组装 ISO 文件系统结构
# =============================================================================
echo ""; echo "[Phase 5] 组装 ISO 结构 ..."

mkdir -p "${ISO_DIR}/boot"
mv "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
mv "${BUILD_DIR}/initrd.img" "${ISO_DIR}/boot/initrd.img"
mv "${BUILD_DIR}/image.squashfs" "${ISO_DIR}/image.squashfs"

if [[ "${HAS_BIOS}" -eq 1 ]]; then
    [[ -n "${ISOLINUX_BIN}" && -n "${LDLINUX_C32}" && -n "${ISOHDPFX_PATH}" ]] || \
        die "未找到 syslinux 引导文件。请安装 syslinux-common 和 isolinux 包。"

    mkdir -p "${ISO_DIR}/boot/syslinux"
    cp "${ISOLINUX_BIN}"  "${ISO_DIR}/boot/syslinux/isolinux.bin"
    cp "${LDLINUX_C32}"   "${ISO_DIR}/boot/syslinux/ldlinux.c32"

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

mkdir -p "${ISO_DIR}/EFI/BOOT"
src="${GRUB_SRC}"
[[ "${ENABLE_SECURE_BOOT:-0}" == "1" ]] && src="${SHIM_SRC}"

cp "$src" "${ISO_DIR}/EFI/BOOT/${EFI_SHIM_NAME}"
[[ "${ENABLE_SECURE_BOOT:-0}" == "1" ]] && cp "${GRUB_SRC}" "${ISO_DIR}/EFI/BOOT/${EFI_GRUB_NAME}"

TIMEOUT_STYLE=$([[ "${BOOT_TIMEOUT}" -eq 0 ]] && echo "hidden" || echo "menu")

cat > "${ISO_DIR}/EFI/BOOT/grub.cfg" << EOF
search --no-floppy --label --set=root ${VOLUME_LABEL}
set timeout=${BOOT_TIMEOUT}
set timeout_style=${TIMEOUT_STYLE}
set default=0

menuentry "ImgFlash" {
    linux /boot/vmlinuz ${KERNEL_PARAMS}
    initrd /boot/initrd.img
}
EOF

mkdir -p "${ISO_DIR}/boot/grub"
EFI_IMG="${ISO_DIR}/boot/grub/efi.img"
FINAL_KB=$(( $(du -skL "${ISO_DIR}/EFI/BOOT" | awk '{print $1}') + 512 ))
echo "  EFI 镜像: ${FINAL_KB} KB"

dd if=/dev/zero of="${EFI_IMG}" bs=1k count="${FINAL_KB}" 2>/dev/null
mkfs.vfat "${EFI_IMG}" >/dev/null

mmd -i "${EFI_IMG}" ::EFI
mcopy -s -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT" ::EFI

echo "  Phase 5 完成。"

# =============================================================================
# Phase 6: 生成最终 ISO
# =============================================================================
echo ""; echo "[Phase 6] 生成 ISO ..."

FINAL_ISO="${OUTPUT_DIR}/${ISO_NAME}.iso"

if [[ "${HAS_BIOS}" -eq 1 ]]; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -o "${FINAL_ISO}" \
        -full-iso9660-filenames \
        -volid "${VOLUME_LABEL}" \
        -isohybrid-mbr "${ISOHDPFX_PATH}" \
        -eltorito-boot boot/syslinux/isolinux.bin \
            -no-emul-boot \
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
        -e boot/grub/efi.img \
        -no-emul-boot \
        "${ISO_DIR}"
fi

rm -rf "${ISO_DIR}"
[ "$(uname)" = "Linux" ] && chown "$(id -u):$(id -g)" "${FINAL_ISO}" 2>/dev/null || true

BUILD_SUCCESS=1

echo ""; echo "=================="
echo "  构建完成！"
echo "=================="
echo "  产物：${FINAL_ISO} ($(du -h "${FINAL_ISO}" | awk '{print $1}'))"
