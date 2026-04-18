#!/bin/bash
# =============================================================================
# ImgFlash v3 - Initramfs-only ISO Builder
# =============================================================================
# Produces a hybrid BIOS+UEFI ISO with full Secure Boot support.
#
# Architecture: initramfs-only (no rootfs, no overlayfs, no OpenRC).
#   UEFI: shim (Microsoft-signed) -> GRUB (Debian-signed) -> vmlinuz (Debian-signed)
#   BIOS: syslinux -> vmlinuz
#   Runtime: initramfs /init -> exec installer -> dd image -> reboot
#
# Usage: build.sh -u <image_url> [-n <iso_name>]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/build.env"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://ftp.debian.org/debian}"
SYSLINUX_DIR="/usr/share/syslinux"
ISOHDPFX_PATH="${SYSLINUX_DIR}/isohdpfx.bin"
RETRY_MAX="${RETRY_MAX:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# ---------------------------------------------------------------------------
# Build directories
# ---------------------------------------------------------------------------
BUILD_DIR="${SCRIPT_DIR}/build"
DL_DIR="${BUILD_DIR}/dl"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"
KERN_DIR="${BUILD_DIR}/kernel"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
IMAGE_URL=""
ISO_NAME=""

while getopts "u:n:" opt; do
    case $opt in
        u) IMAGE_URL="$OPTARG" ;;
        n) ISO_NAME="$OPTARG" ;;
        *) echo "Usage: $0 -u <image_url> [-n <iso_name>]"; exit 1 ;;
    esac
done

[[ -z "${IMAGE_URL}" ]] && { echo "ERROR: -u <image_url> is required"; exit 1; }
ISO_NAME="${ISO_NAME:-imgflash}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

retry() {
    local max="${1}" delay="${2}"
    shift 2
    for i in $(seq 1 "$max"); do
        if "$@"; then return 0; fi
        [[ $i -eq $max ]] && { echo "ERROR: Failed after $max attempts: $*" >&2; return 1; }
        echo "  Retry $i/$max in ${delay}s..."
        sleep "$delay"
    done
}

find_latest_deb() {
    local url="$1" pattern="$2"
    curl -sL "$url" | tr '"' '\n' | grep -E "$pattern" | sort -V | tail -1
}

# ---------------------------------------------------------------------------
# Initialize build environment
# ---------------------------------------------------------------------------

echo "=========================================="
echo "  ImgFlash v3 - ISO Builder"
echo "=========================================="
echo "  Image: ${IMAGE_URL}"
echo "  Name:  ${ISO_NAME}"
echo ""

rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${DL_DIR}" "${INITRAMFS_DIR}" "${ISO_DIR}" "${KERN_DIR}" "${OUTPUT_DIR}"

# =============================================================================
# Phase 1: Download and extract external components
# =============================================================================

echo "==== Phase 1: Downloading components ===="

# --- 1a. Debian signed kernel + modules ---
echo "  Extracting Debian signed kernel + modules..."
KVER=$("${SCRIPT_DIR}/tools/extract-debian-kernel.sh" -o "${KERN_DIR}" -m "${REQUIRED_MODULES}")
echo "  Kernel version: ${KVER}"

# --- 1b. Debian shim + signed GRUB ---
echo "  Downloading Debian shim..."
SHIM_POOL="${DEBIAN_MIRROR}/pool/main/s/shim-signed/"
SHIM_DEB=$(find_latest_deb "$SHIM_POOL" '^shim-signed_.*_amd64\.deb$')
if [[ -z "$SHIM_DEB" ]]; then
    echo "ERROR: Cannot find shim-signed package" >&2; exit 1
fi
echo "    ${SHIM_DEB}"
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${DL_DIR}/shim.deb" "${SHIM_POOL}${SHIM_DEB}"

echo "  Downloading Debian signed GRUB..."
GRUB_POOL="${DEBIAN_MIRROR}/pool/main/g/grub2/"
GRUB_DEB=$(find_latest_deb "$GRUB_POOL" '^grub-efi-amd64-signed_.*_amd64\.deb$')
if [[ -z "$GRUB_DEB" ]]; then
    echo "ERROR: Cannot find grub-efi-amd64-signed package" >&2; exit 1
fi
echo "    ${GRUB_DEB}"
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${DL_DIR}/grub.deb" "${GRUB_POOL}${GRUB_DEB}"

# --- 1c. BusyBox static binary ---
echo "  Downloading BusyBox..."
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${DL_DIR}/busybox" "${BUSYBOX_URL}"
chmod +x "${DL_DIR}/busybox"

# =============================================================================
# Phase 2: Compile static GNU dd
# =============================================================================

echo "==== Phase 2: Compiling static GNU dd ===="

if ! command -v gcc &>/dev/null; then
    echo "ERROR: gcc is required for compiling static dd" >&2; exit 1
fi

CU_URL="https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VERSION}.tar.xz"
CU_DIR="${BUILD_DIR}/coreutils-${COREUTILS_VERSION}"

echo "  Downloading coreutils ${COREUTILS_VERSION}..."
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL "$CU_URL" | tar -xJ -C "${BUILD_DIR}"

echo "  Configuring..."
cd "${CU_DIR}"
./configure LDFLAGS="-static" --disable-nls --quiet 2>/dev/null

echo "  Compiling dd..."
make -j"$(nproc)" dd --quiet V=0 2>/dev/null

cp src/dd "${DL_DIR}/gnu-dd"
cd "${SCRIPT_DIR}"

chmod +x "${DL_DIR}/gnu-dd"
echo "  Static dd ready: $(ls -lh "${DL_DIR}/gnu-dd" | awk '{print $5}')"

# =============================================================================
# Phase 3: Assemble initramfs
# =============================================================================

echo "==== Phase 3: Assembling initramfs ===="

# --- 3a. Directory structure ---
rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,tmp}
mkdir -p "${INITRAMFS_DIR}"/{usr/bin,usr/sbin,lib}
mkdir -p "${INITRAMFS_DIR}"/{media/cdrom,image,var/log,root}
mkdir -p "${INITRAMFS_DIR}"/{dev/pts,dev/shm}

# --- 3b. Install BusyBox ---
cp "${DL_DIR}/busybox" "${INITRAMFS_DIR}/bin/busybox"
chmod +x "${INITRAMFS_DIR}/bin/busybox"

# Note: we do NOT pre-create symlinks. The /init script runs
# /bin/busybox --install -s at boot time, which creates all symlinks.

# --- 3c. Install static GNU dd (as gnu-dd, init.sh copies it over /bin/dd) ---
cp "${DL_DIR}/gnu-dd" "${INITRAMFS_DIR}/bin/gnu-dd"
chmod +x "${INITRAMFS_DIR}/bin/gnu-dd"

# --- 3d. Install /init and /usr/bin/installer ---
cp "${SCRIPT_DIR}/scripts/init.sh" "${INITRAMFS_DIR}/init"
chmod +x "${INITRAMFS_DIR}/init"

# Embed SCAN_TIMEOUT from build.env into /init
sed -i "s/TRIES -lt 10/TRIES -lt ${SCAN_TIMEOUT:-10}/" "${INITRAMFS_DIR}/init"
sed -i "s/after 10 seconds/after ${SCAN_TIMEOUT:-10} seconds/" "${INITRAMFS_DIR}/init"

cp "${SCRIPT_DIR}/scripts/installer.sh" "${INITRAMFS_DIR}/usr/bin/installer"
chmod +x "${INITRAMFS_DIR}/usr/bin/installer"

# --- 3e. Install kernel modules (from extract-debian-kernel output) ---
echo "  Installing kernel modules..."
cp -a "${KERN_DIR}/lib" "${INITRAMFS_DIR}/"

MOD_COUNT=$(find "${INITRAMFS_DIR}/lib/modules" -name '*.ko*' | wc -l)
MOD_SIZE=$(du -sh "${INITRAMFS_DIR}/lib/modules" | awk '{print $1}')
echo "  Modules: ${MOD_COUNT} files, ${MOD_SIZE}"

# --- 3f. Create cpio archive ---
echo "  Creating initramfs archive..."
cd "${INITRAMFS_DIR}"
find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initrd.img"
cd "${SCRIPT_DIR}"

INITRD_SIZE=$(ls -lh "${BUILD_DIR}/initrd.img" | awk '{print $5}')
echo "  Initramfs size: ${INITRD_SIZE}"

# =============================================================================
# Phase 4: Create image.squashfs
# =============================================================================

echo "==== Phase 4: Creating image.squashfs ===="

IMAGE_DIR="${BUILD_DIR}/image"
mkdir -p "${IMAGE_DIR}"

# --- Download and decompress input image ---
if [[ "${IMAGE_URL}" =~ ^https?:// ]]; then
    echo "  Downloading image from ${IMAGE_URL}..."
    RAW_IMAGE="${DL_DIR}/input-image"
    retry 3 10 curl -fSL -o "${RAW_IMAGE}" "${IMAGE_URL}"
else
    RAW_IMAGE="${IMAGE_URL}"
    if [[ ! -f "${RAW_IMAGE}" ]]; then
        echo "ERROR: Image file not found: ${RAW_IMAGE}" >&2; exit 1
    fi
fi

# Decompress if needed
echo "  Preparing image..."
case "${RAW_IMAGE}" in
    *.gz|*.gzip)  zcat  "${RAW_IMAGE}" > "${IMAGE_DIR}/image.img" ;;
    *.xz)         xzcat "${RAW_IMAGE}" > "${IMAGE_DIR}/image.img" ;;
    *.zst|*.zstd) zstdcat "${RAW_IMAGE}" > "${IMAGE_DIR}/image.img" ;;
    *.bz2)        bzcat "${RAW_IMAGE}" > "${IMAGE_DIR}/image.img" ;;
    *.zip)
        unzip -o "${RAW_IMAGE}" -d "${IMAGE_DIR}/"
        # Find the .img file inside
        IMG_IN_ZIP=$(find "${IMAGE_DIR}" -name '*.img' -type f | head -1)
        if [[ -n "$IMG_IN_ZIP" && "$IMG_IN_ZIP" != "${IMAGE_DIR}/image.img" ]]; then
            mv "$IMG_IN_ZIP" "${IMAGE_DIR}/image.img"
        fi
        ;;
    *.7z)
        7z x -o"${IMAGE_DIR}" "${RAW_IMAGE}" -y
        IMG_IN_7Z=$(find "${IMAGE_DIR}" -name '*.img' -type f | head -1)
        if [[ -n "$IMG_IN_7Z" && "$IMG_IN_7Z" != "${IMAGE_DIR}/image.img" ]]; then
            mv "$IMG_IN_7Z" "${IMAGE_DIR}/image.img"
        fi
        ;;
    *)            cp "${RAW_IMAGE}" "${IMAGE_DIR}/image.img" ;;
esac

if [[ ! -f "${IMAGE_DIR}/image.img" ]]; then
    echo "ERROR: Failed to prepare image.img" >&2; exit 1
fi

IMG_SIZE=$(ls -lh "${IMAGE_DIR}/image.img" | awk '{print $5}')
echo "  Raw image size: ${IMG_SIZE}"

# --- Create squashfs ---
echo "  Creating squashfs..."
mksquashfs "${IMAGE_DIR}" "${BUILD_DIR}/image.squashfs" \
    -comp "${SQUASHFS_COMP}" -no-progress -no-xattrs

SQFS_SIZE=$(ls -lh "${BUILD_DIR}/image.squashfs" | awk '{print $5}')
echo "  Squashfs size: ${SQFS_SIZE}"

# =============================================================================
# Phase 5: Assemble ISO file system structure
# =============================================================================

echo "==== Phase 5: Assembling ISO structure ===="

# --- 5a. Kernel and initramfs ---
mkdir -p "${ISO_DIR}/boot"
cp "${KERN_DIR}/vmlinuz" "${ISO_DIR}/boot/vmlinuz"
cp "${BUILD_DIR}/initrd.img" "${ISO_DIR}/boot/initrd.img"

# --- 5b. Image squashfs ---
cp "${BUILD_DIR}/image.squashfs" "${ISO_DIR}/image.squashfs"

# --- 5c. Syslinux (BIOS boot) ---
if [[ ! -d "${SYSLINUX_DIR}" ]]; then
    echo "ERROR: syslinux not found at ${SYSLINUX_DIR}. Install syslinux package." >&2
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

# --- 5d. EFI boot (Secure Boot chain: shim -> GRUB -> kernel) ---
mkdir -p "${ISO_DIR}/EFI/BOOT"

# Extract shim
dpkg-deb -x "${DL_DIR}/shim.deb" "${BUILD_DIR}/shim-extract"
cp "${BUILD_DIR}/shim-extract/usr/lib/shim/shimx64.efi.signed" \
   "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"

# Extract signed GRUB
dpkg-deb -x "${DL_DIR}/grub.deb" "${BUILD_DIR}/grub-extract"
cp "${BUILD_DIR}/grub-extract/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
   "${ISO_DIR}/EFI/BOOT/grubx64.efi"

# GRUB configuration
cat > "${ISO_DIR}/EFI/BOOT/grub.cfg" << 'EOF'
set timeout=3
set default=0

menuentry "ImgFlash" {
    linux /boot/vmlinuz quiet
    initrd /boot/initrd.img
}
EOF

# --- 5e. Create FAT EFI boot image ---
mkdir -p "${ISO_DIR}/boot/grub"

dd if=/dev/zero of="${ISO_DIR}/boot/grub/efi.img" bs=1M count=4 2>/dev/null
mkfs.vfat -F 12 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || \
    mkfs.vfat -F 16 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || \
    mkfs.vfat -F 32 "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null

mmd -i "${ISO_DIR}/boot/grub/efi.img" ::EFI ::EFI/BOOT
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" "::EFI/BOOT/BOOTX64.EFI"
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/grubx64.efi" "::EFI/BOOT/grubx64.efi"
mcopy -i "${ISO_DIR}/boot/grub/efi.img" "${ISO_DIR}/EFI/BOOT/grub.cfg"    "::EFI/BOOT/grub.cfg"

echo "  ISO structure assembled."

# =============================================================================
# Phase 6: Generate final ISO
# =============================================================================

echo "==== Phase 6: Generating ISO ===="

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

ISO_SIZE=$(ls -lh "${FINAL_ISO}" | awk '{print $5}')

echo ""
echo "=========================================="
echo "  Build complete!"
echo "  Output: ${FINAL_ISO}"
echo "  Size:   ${ISO_SIZE}"
echo "=========================================="
