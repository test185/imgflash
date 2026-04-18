#!/bin/bash
# =============================================================================
# ImgFlash - Debian Kernel + Module Extractor
# =============================================================================
# Downloads a Debian signed kernel and matching modules, extracts only the
# required modules (with dependency resolution), and prepares a slim module
# tree suitable for initramfs inclusion.
#
# Usage:
#   extract-debian-kernel.sh -o <output_dir> [-m "mod1 mod2 ..."]
#
# Output:
#   <output_dir>/vmlinuz              - Signed kernel binary
#   <output_dir>/lib/modules/<kver>/  - Slim module tree with depmod metadata
#   stdout                            - Kernel version string (e.g. 6.1.0-13-amd64)
#
# All progress output goes to stderr; only KVER goes to stdout.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR=""
REQUIRED="${REQUIRED_MODULES:-squashfs isofs loop ahci nvme usb-storage sr_mod sd_mod cdrom virtio_blk virtio_pci}"

while getopts "o:m:" opt; do
    case $opt in
        o) OUTPUT_DIR="$OPTARG" ;;
        m) REQUIRED="$OPTARG" ;;
        *) echo "Usage: $0 -o <output_dir> [-m \"mod1 mod2 ...\"]" >&2; exit 1 ;;
    esac
done

[[ -z "${OUTPUT_DIR}" ]] && { echo "ERROR: -o <output_dir> is required" >&2; exit 1; }

DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://ftp.debian.org/debian}"
RETRY_MAX="${RETRY_MAX:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

retry() {
    local max="${1}" delay="${2}"
    shift 2
    for i in $(seq 1 "$max"); do
        if "$@"; then return 0; fi
        [[ $i -eq $max ]] && { echo "ERROR: Failed after $max attempts: $*" >&2; return 1; }
        echo "  Retry $i/$max in ${delay}s..." >&2
        sleep "$delay"
    done
}

find_latest_deb() {
    local url="$1" pattern="$2"
    curl -sL "$url" | tr '"' '\n' | grep -E "$pattern" | sort -V | tail -1
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# 1. Find and download Debian signed kernel
# ---------------------------------------------------------------------------

echo "  Finding Debian signed kernel..." >&2
KERN_POOL="${DEBIAN_MIRROR}/pool/main/l/linux-signed-amd64/"
KERN_DEB=$(find_latest_deb "$KERN_POOL" '^linux-image-[0-9].*_amd64\.deb$')
if [[ -z "$KERN_DEB" ]]; then
    echo "ERROR: Cannot find Debian signed kernel in ${KERN_POOL}" >&2
    exit 1
fi
echo "  Downloading ${KERN_DEB}..." >&2
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${WORK_DIR}/kernel.deb" "${KERN_POOL}${KERN_DEB}"

# Extract kernel version from filename
# e.g. linux-image-6.1.0-13-amd64_6.1.0-13+deb12u2_amd64.deb -> 6.1.0-13-amd64
KVER=$(echo "$KERN_DEB" | sed -E 's/linux-image-([0-9][0-9.]*-[0-9]+-amd64).*/\1/')
echo "  Kernel version: ${KVER}" >&2

# Extract vmlinuz
dpkg-deb -x "${WORK_DIR}/kernel.deb" "${WORK_DIR}/kernel-extract"
cp "${WORK_DIR}/kernel-extract/boot/vmlinuz-"* "${OUTPUT_DIR}/vmlinuz"

# ---------------------------------------------------------------------------
# 2. Find and download matching kernel modules
# ---------------------------------------------------------------------------

echo "  Finding Debian kernel modules..." >&2
MODS_POOL="${DEBIAN_MIRROR}/pool/main/l/linux/"
MODS_DEB=$(find_latest_deb "$MODS_POOL" "linux-modules-${KVER}_.*_amd64\\.deb\$")
if [[ -z "$MODS_DEB" ]]; then
    echo "ERROR: Cannot find linux-modules-${KVER} in ${MODS_POOL}" >&2
    exit 1
fi
echo "  Downloading ${MODS_DEB}..." >&2
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${WORK_DIR}/modules.deb" "${MODS_POOL}${MODS_DEB}"

# Extract all modules to a temp tree
dpkg-deb -x "${WORK_DIR}/modules.deb" "${WORK_DIR}/modules-all"

# Decompress .ko.zst / .ko.xz to .ko (ensures BusyBox modprobe compatibility)
echo "  Decompressing kernel modules..." >&2
for f in $(find "${WORK_DIR}/modules-all" -name '*.ko.zst'); do
    zstd -d -f "$f" -o "${f%.zst}" && rm "$f"
done
for f in $(find "${WORK_DIR}/modules-all" -name '*.ko.xz'); do
    xz -d -f "$f"
done

# Run depmod on the full module tree
depmod -b "${WORK_DIR}/modules-all" "${KVER}"

# ---------------------------------------------------------------------------
# 3. Resolve required modules with dependencies
# ---------------------------------------------------------------------------

echo "  Resolving module dependencies..." >&2
NEEDED_FILES=""

for mod in $REQUIRED; do
    # -S sets kernel version so modprobe looks under the right directory
    deps=$(modprobe -d "${WORK_DIR}/modules-all" -S "${KVER}" --show-depends "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}')
    NEEDED_FILES="${NEEDED_FILES} ${deps}"
done

# Deduplicate
NEEDED_FILES=$(echo "$NEEDED_FILES" | tr ' ' '\n' | sort -u | grep -v '^$')

if [[ -z "$NEEDED_FILES" ]]; then
    echo "WARNING: No modules resolved. Including all modules as fallback." >&2
    MOD_DEST="${OUTPUT_DIR}/lib/modules/${KVER}"
    mkdir -p "${MOD_DEST}"
    cp -a "${WORK_DIR}/modules-all/lib/modules/${KVER}/"* "${MOD_DEST}/"
else
    echo "  Including $(echo "$NEEDED_FILES" | wc -l) modules (with dependencies)" >&2

    # Copy only needed .ko files
    for mod_file in $NEEDED_FILES; do
        rel_path=$(echo "$mod_file" | sed "s|${WORK_DIR}/modules-all/lib/modules/${KVER}/||")
        dest_dir="${OUTPUT_DIR}/lib/modules/${KVER}/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp "$mod_file" "$dest_dir/"
    done

    # Copy module metadata files (small, needed by modprobe)
    for f in modules.builtin modules.builtin.modinfo modules.order; do
        src="${WORK_DIR}/modules-all/lib/modules/${KVER}/$f"
        [ -f "$src" ] && cp "$src" "${OUTPUT_DIR}/lib/modules/${KVER}/"
    done

    # Run depmod on the slim module tree
    depmod -b "${OUTPUT_DIR}" "${KVER}"
fi

# Output kernel version for build.sh to consume (stdout only)
echo "${KVER}"