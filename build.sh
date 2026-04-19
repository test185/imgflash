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
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 默认配置（可通过环境变量覆盖）
# ---------------------------------------------------------------------------
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://ftp.debian.org/debian}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
VOLUME_LABEL="${VOLUME_LABEL:-IMGFLASH}"
REQUIRED_MODULES="${REQUIRED_MODULES:-squashfs isofs loop ahci nvme usb-storage sr_mod sd_mod cdrom virtio_blk virtio_pci}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-10}"

SYSLINUX_DIR="/usr/share/syslinux"
ISOHDPFX_PATH="${SYSLINUX_DIR}/isohdpfx.bin"

# ---------------------------------------------------------------------------
# 构建目录
# ---------------------------------------------------------------------------
BUILD_DIR="${SCRIPT_DIR}/build"
DEBOOTSTRAP_DIR="${BUILD_DIR}/debootstrap"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"
OUTPUT_DIR="${SCRIPT_DIR}/output"

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
# 辅助函数
# ---------------------------------------------------------------------------

download_image() {
    local url="$1"

    echo "  正在下载：${url}"
    curl -k -L -o "${BUILD_DIR}/downloaded_file" "$url"

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
echo "  Debian 镜像 : ${DEBIAN_MIRROR}"
echo "  输出名称    : ${ISO_NAME}"
echo "=========================================="
echo ""

# =============================================================================
# 第1步：debootstrap 最小 Debian 环境
# =============================================================================

echo "==== 第1步：debootstrap ${DEBIAN_SUITE} ===="

if ! command -v debootstrap &>/dev/null; then
    echo "错误：需要 debootstrap，请安装后重试" >&2; exit 1
fi

rm -rf "${DEBOOTSTRAP_DIR}"
debootstrap --variant=minbase \
    --include=linux-image-amd64,shim-signed,grub-efi-amd64-signed \
    "${DEBIAN_SUITE}" "${DEBOOTSTRAP_DIR}" "${DEBIAN_MIRROR}"

echo "  debootstrap 完成"

# =============================================================================
# 第2步：从 debootstrap 环境提取所需文件
# =============================================================================

echo "==== 第2步：提取组件 ===="

# --- 2a. 签名内核 ---
VMLINUZ=$(ls "${DEBOOTSTRAP_DIR}"/boot/vmlinuz-* 2>/dev/null | head -1)
if [[ -z "${VMLINUZ}" ]]; then
    echo "错误：debootstrap 环境中未找到 vmlinuz" >&2; exit 1
fi
KVER=$(basename "${VMLINUZ}" | sed 's/^vmlinuz-//')
echo "  内核版本：${KVER}"
echo "  vmlinuz：${VMLINUZ}"

# --- 2b. shim + 签名 GRUB ---
SHIM_SRC=$(find "${DEBOOTSTRAP_DIR}" -name 'shimx64.efi.signed' 2>/dev/null | head -1)
GRUB_SRC=$(find "${DEBOOTSTRAP_DIR}" -name 'grubx64.efi.signed' 2>/dev/null | head -1)
if [[ -z "${SHIM_SRC}" || -z "${GRUB_SRC}" ]]; then
    echo "错误：debootstrap 环境中未找到 shim 或 GRUB" >&2; exit 1
fi
echo "  shim：${SHIM_SRC}"
echo "  GRUB：${GRUB_SRC}"

# --- 2c. BusyBox ---
echo "  检测最新 BusyBox 版本..."
BUSYBOX_VERSION=$(curl -sL "https://busybox.net/downloads/binaries/" \
    | grep -oP '\d+\.\d+\.\d+(?=-x86_64-linux-musl)' \
    | sort -V | tail -1 || true)
if [[ -z "${BUSYBOX_VERSION}" ]]; then
    echo "错误：无法检测 BusyBox 版本" >&2; exit 1
fi
echo "    BusyBox ${BUSYBOX_VERSION}"
BUSYBOX_URL="https://busybox.net/downloads/binaries/${BUSYBOX_VERSION}-x86_64-linux-musl/busybox"
curl -fSL -o "${BUILD_DIR}/busybox" "${BUSYBOX_URL}"
chmod +x "${BUILD_DIR}/busybox"

# --- 2d. 编译静态 GNU dd ---
echo "  编译静态 GNU dd..."
if ! command -v gcc &>/dev/null; then
    echo "错误：编译静态 dd 需要 gcc" >&2; exit 1
fi

COREUTILS_VERSION=$(curl -sL "https://ftp.gnu.org/gnu/coreutils/" \
    | grep -oP 'href="coreutils-\K[\d.]+' \
    | sort -V | tail -1 || true)
if [[ -z "${COREUTILS_VERSION}" ]]; then
    echo "错误：无法检测 coreutils 版本" >&2; exit 1
fi
echo "    coreutils ${COREUTILS_VERSION}"

CU_URL="https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VERSION}.tar.xz"
CU_DIR="${BUILD_DIR}/coreutils-${COREUTILS_VERSION}"

curl -fSL "$CU_URL" | tar -xJ -C "${BUILD_DIR}"
cd "${CU_DIR}"
./configure LDFLAGS="-static" --disable-nls --quiet 2>/dev/null
make -j"$(nproc)" dd --quiet V=0 2>/dev/null
cp src/dd "${BUILD_DIR}/gnu-dd"
cd "${SCRIPT_DIR}"
chmod +x "${BUILD_DIR}/gnu-dd"
echo "  静态 dd 就绪：$(ls -lh "${BUILD_DIR}/gnu-dd" | awk '{print $5}')"

# =============================================================================
# 第3步：组装 initramfs
# =============================================================================

echo "==== 第3步：组装 initramfs ===="

# --- 3a. 目录结构 ---
rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,tmp}
mkdir -p "${INITRAMFS_DIR}"/{usr/bin,usr/sbin,lib}
mkdir -p "${INITRAMFS_DIR}"/{media/cdrom,image,var/log,root}
mkdir -p "${INITRAMFS_DIR}"/{dev/pts,dev/shm}

# --- 3b. 安装 BusyBox ---
cp "${BUILD_DIR}/busybox" "${INITRAMFS_DIR}/bin/busybox"
chmod +x "${INITRAMFS_DIR}/bin/busybox"

# --- 3c. 安装静态 GNU dd（存为 gnu-dd，init.sh 启动时覆盖 /bin/dd）---
cp "${BUILD_DIR}/gnu-dd" "${INITRAMFS_DIR}/bin/gnu-dd"
chmod +x "${INITRAMFS_DIR}/bin/gnu-dd"

# --- 3d. 安装 /init 和 /usr/bin/installer ---
cp "${SCRIPT_DIR}/scripts/init.sh" "${INITRAMFS_DIR}/init"
chmod +x "${INITRAMFS_DIR}/init"

sed -i "s/TRIES -lt 10/TRIES -lt ${SCAN_TIMEOUT}/" "${INITRAMFS_DIR}/init"
sed -i "s/after 10 seconds/after ${SCAN_TIMEOUT} seconds/" "${INITRAMFS_DIR}/init"

cp "${SCRIPT_DIR}/scripts/installer.sh" "${INITRAMFS_DIR}/usr/bin/installer"
chmod +x "${INITRAMFS_DIR}/usr/bin/installer"

# --- 3e. 安装内核模块（精简）---
echo "  精简内核模块..."

MOD_SRC="${DEBOOTSTRAP_DIR}/lib/modules/${KVER}"
if [[ ! -d "${MOD_SRC}" ]]; then
    echo "错误：找不到内核模块目录 ${MOD_SRC}" >&2; exit 1
fi

# 解压 .ko.zst 为 .ko（BusyBox modprobe 不支持压缩模块）
for f in $(find "${MOD_SRC}" -name '*.ko.zst'); do
    zstd -d -f "$f" -o "${f%.zst}" && rm "$f"
done

# 用 modprobe 解析所需模块及依赖
NEEDED_FILES=""
for mod in ${REQUIRED_MODULES}; do
    deps=$(modprobe -d "${DEBOOTSTRAP_DIR}" -S "${KVER}" --show-depends "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}')
    NEEDED_FILES="${NEEDED_FILES} ${deps}"
done
NEEDED_FILES=$(echo "$NEEDED_FILES" | tr ' ' '\n' | sort -u | grep -v '^$')

MOD_DEST="${INITRAMFS_DIR}/lib/modules/${KVER}"

if [[ -z "$NEEDED_FILES" ]]; then
    echo "错误：modprobe 未能解析任何模块依赖，构建环境异常" >&2; exit 1
else
    echo "  包含 $(echo "$NEEDED_FILES" | wc -l) 个模块（含依赖）"
    for mod_file in $NEEDED_FILES; do
        rel_path=$(echo "$mod_file" | sed "s|${MOD_SRC}/||")
        dest_dir="${MOD_DEST}/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp "$mod_file" "$dest_dir/"
    done

    for f in modules.builtin modules.builtin.modinfo modules.order; do
        [ -f "${MOD_SRC}/$f" ] && cp "${MOD_SRC}/$f" "${MOD_DEST}/"
    done
fi

depmod -b "${INITRAMFS_DIR}" "${KVER}"

MOD_COUNT=$(find "${INITRAMFS_DIR}/lib/modules" -name '*.ko*' | wc -l)
MOD_SIZE=$(du -sh "${INITRAMFS_DIR}/lib/modules" | awk '{print $1}')
echo "  模块：${MOD_COUNT} 个文件，${MOD_SIZE}"

# --- 3f. 打包 cpio 归档 ---
echo "  创建 initramfs 归档..."
cd "${INITRAMFS_DIR}"
find . -print0 | cpio --null -o -H newc --owner root:root 2>/dev/null | gzip -9 > "${BUILD_DIR}/initrd.img"
cd "${SCRIPT_DIR}"

INITRD_SIZE=$(ls -lh "${BUILD_DIR}/initrd.img" | awk '{print $5}')
echo "  Initramfs 大小：${INITRD_SIZE}"

# =============================================================================
# 第4步：打包镜像容器
# =============================================================================

echo "==== 第4步：打包镜像容器 ===="

IMAGE_DIR="${BUILD_DIR}/image"
mkdir -p "${IMAGE_DIR}"

cp "${BUILD_DIR}/temp.img" "${IMAGE_DIR}/image.img"
rm -f "${BUILD_DIR}/temp.img"

IMG_SIZE=$(ls -lh "${IMAGE_DIR}/image.img" | awk '{print $5}')
echo "  原始镜像大小：${IMG_SIZE}"

echo "  创建 squashfs..."
mksquashfs "${IMAGE_DIR}" "${BUILD_DIR}/image.squashfs" \
    -comp xz -no-progress -no-xattrs

SQFS_SIZE=$(ls -lh "${BUILD_DIR}/image.squashfs" | awk '{print $5}')
echo "  Squashfs 大小：${SQFS_SIZE}"

# =============================================================================
# 第5步：组装 ISO 文件系统结构
# =============================================================================

echo "==== 第5步：组装 ISO 结构 ===="

# --- 5a. 内核和 initramfs ---
mkdir -p "${ISO_DIR}/boot"
cp "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
cp "${BUILD_DIR}/initrd.img" "${ISO_DIR}/boot/initrd.img"

# --- 5b. 镜像 squashfs ---
cp "${BUILD_DIR}/image.squashfs" "${ISO_DIR}/image.squashfs"

# --- 5c. Syslinux（BIOS 启动）---
if [[ ! -d "${SYSLINUX_DIR}" ]]; then
    echo "错误：未找到 syslinux（${SYSLINUX_DIR}）。请安装 syslinux 包。" >&2
    exit 1
fi

mkdir -p "${ISO_DIR}/boot/syslinux"
cp "${SYSLINUX_DIR}/isolinux.bin" "${ISO_DIR}/boot/syslinux/"
cp "${SYSLINUX_DIR}/ldlinux.c32"  "${ISO_DIR}/boot/syslinux/"
cp "${ISOHDPFX_PATH}"             "${ISO_DIR}/boot/syslinux/isohdpfx.bin"

cat > "${ISO_DIR}/boot/syslinux/syslinux.cfg" << 'EOF'
DEFAULT imgflash
PROMPT 0
TIMEOUT 30

LABEL imgflash
  KERNEL /boot/vmlinuz
  INITRD /boot/initrd.img
  APPEND quiet
EOF

# --- 5d. EFI 启动（Secure Boot 链：shim → GRUB → 内核）---
mkdir -p "${ISO_DIR}/EFI/BOOT"

cp "${SHIM_SRC}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
cp "${GRUB_SRC}" "${ISO_DIR}/EFI/BOOT/grubx64.efi"

cat > "${ISO_DIR}/EFI/BOOT/grub.cfg" << 'EOF'
search --no-floppy --label --set=root IMGFLASH
set timeout=3
set default=0

menuentry "ImgFlash" {
    linux /boot/vmlinuz quiet
    initrd /boot/initrd.img
}
EOF

# --- 5e. 创建 FAT EFI 启动镜像 ---
mkdir -p "${ISO_DIR}/boot/grub"

dd if=/dev/zero of="${ISO_DIR}/boot/grub/efi.img" bs=1M count=16 2>/dev/null
mkfs.vfat -F 12 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || \
    mkfs.vfat -F 16 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || \
    mkfs.vfat -F 32 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null

mmd -i "${ISO_DIR}/boot/grub/efi.img" ::EFI ::EFI/BOOT
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" "::EFI/BOOT/BOOTX64.EFI"
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/grubx64.efi" "::EFI/BOOT/grubx64.efi"
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/grub.cfg"    "::EFI/BOOT/grub.cfg"

echo "  ISO 结构组装完成。"

# =============================================================================
# 第6步：生成最终 ISO
# =============================================================================

echo "==== 第6步：生成 ISO ===="

FINAL_ISO="${OUTPUT_DIR}/${ISO_NAME}.iso"

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

# CI 用 sudo 构建时产物归 root，修正属主
[ "$(uname)" = "Linux" ] && chown "$(id -u):$(id -g)" "${FINAL_ISO}" 2>/dev/null || true

echo ""
echo "=================="
echo "  构建完成！"
echo "=================="
ISO_SIZE=$(du -h "${FINAL_ISO}" | awk '{print $1}')
echo "  产物：${FINAL_ISO} (${ISO_SIZE})"