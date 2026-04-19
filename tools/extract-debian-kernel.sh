#!/bin/bash
# =============================================================================
# ImgFlash - Debian 签名内核及模块提取工具
# =============================================================================

set -euo pipefail

OUTPUT_DIR=""
REQUIRED="${REQUIRED_MODULES:-squashfs isofs loop ahci nvme usb-storage sr_mod sd_mod cdrom virtio_blk virtio_pci}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"

while getopts "o:m:" opt; do
    case $opt in
        o) OUTPUT_DIR="$OPTARG" ;;
        m) REQUIRED="$OPTARG" ;;
        *) echo "用法: $0 -o <输出目录> [-m \"模块1 模块2 ...\"]" >&2; exit 1 ;;
    esac
done

[[ -z "${OUTPUT_DIR}" ]] && { echo "错误：必须指定 -o <输出目录>" >&2; exit 1; }

DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://ftp.debian.org/debian}"
RETRY_MAX="${RETRY_MAX:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

retry() {
    local max="${1}" delay="${2}"
    shift 2
    for i in $(seq 1 "$max"); do
        if "$@"; then return 0; fi
        [[ $i -eq $max ]] && { echo "错误：重试 $max 次后仍失败：$*" >&2; return 1; }
        echo "  第 $i/$max 次重试，${delay} 秒后..." >&2
        sleep "$delay"
    done
}

# 从 Packages 索引中提取指定包的指定字段（如有重复取最新版本）
pkg_field() {
    local pkg="$1" field="$2"
    awk -v pkg="$pkg" -v field="$field" '
        /^Package: / { cur_pkg = $2; in_target = (cur_pkg == pkg) }
        in_target && /^Version: / { cur_ver = $2 }
        in_target && index($0, field ": ") == 1 { cur_val = substr($0, length(field) + 3) }
        in_target && /^$/ {
            if (cur_ver > best_ver || best_ver == "") {
                best_ver = cur_ver; best_val = cur_val
            }
            in_target = 0
        }
        END { if (best_val != "") print best_val }
    ' "${WORK_DIR}/Packages"
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"

# =============================================================================
# 1. 下载软件包索引
# =============================================================================

echo "  下载 Debian ${DEBIAN_SUITE} 软件包索引..." >&2
> "${WORK_DIR}/Packages"

for dist in "${DEBIAN_SUITE}-updates" "${DEBIAN_SUITE}-security" "${DEBIAN_SUITE}"; do
    URL="${DEBIAN_MIRROR}/dists/${dist}/main/binary-amd64/Packages.gz"
    curl -sL "${URL}" 2>/dev/null | gunzip 2>/dev/null >> "${WORK_DIR}/Packages" || true
done

if [[ ! -s "${WORK_DIR}/Packages" ]]; then
    echo "错误：软件包索引为空" >&2; exit 1
fi

# =============================================================================
# 2. 解析内核版本
# =============================================================================

# 从元包的 Depends 字段获取实际签名内核包名
KERN_DEP=$(pkg_field "linux-image-amd64" "Depends")
KERN_PKG=$(echo "${KERN_DEP}" | grep -oP 'linux-image-\d+\.\d+\.\d+-\d+-amd64' | head -1 || true)

if [[ -z "${KERN_PKG}" ]]; then
    echo "错误：无法从 linux-image-amd64 依赖中解析签名内核包名" >&2; exit 1
fi

KVER="${KERN_PKG#linux-image-}"
echo "  内核版本：${KVER}" >&2

# =============================================================================
# 3. 下载签名内核
# =============================================================================

KERN_PATH=$(pkg_field "${KERN_PKG}" "Filename")
if [[ -z "${KERN_PATH}" ]]; then
    echo "错误：找不到签名内核包 ${KERN_PKG}" >&2; exit 1
fi
echo "  下载签名内核..." >&2
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${WORK_DIR}/kernel.deb" "${DEBIAN_MIRROR}/${KERN_PATH}"

dpkg-deb -x "${WORK_DIR}/kernel.deb" "${WORK_DIR}/kernel-extract"
cp "${WORK_DIR}/kernel-extract/boot/vmlinuz-"* "${OUTPUT_DIR}/vmlinuz"

# =============================================================================
# 4. 下载内核模块
# =============================================================================

MODS_PATH=$(pkg_field "linux-modules-${KVER}" "Filename")
if [[ -z "${MODS_PATH}" ]]; then
    echo "错误：找不到模块包 linux-modules-${KVER}" >&2; exit 1
fi
echo "  下载内核模块..." >&2
retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${WORK_DIR}/modules.deb" "${DEBIAN_MIRROR}/${MODS_PATH}"

# linux-modules-extra（如果存在）
EXTRA_PATH=$(pkg_field "linux-modules-extra-${KVER}" "Filename")
if [[ -n "${EXTRA_PATH}" ]]; then
    echo "  下载额外模块..." >&2
    retry "${RETRY_MAX}" "${RETRY_DELAY}" curl -fSL -o "${WORK_DIR}/modules-extra.deb" "${DEBIAN_MIRROR}/${EXTRA_PATH}"
fi

# 提取模块
dpkg-deb -x "${WORK_DIR}/modules.deb" "${WORK_DIR}/modules-all"
if [[ -f "${WORK_DIR}/modules-extra.deb" ]]; then
    dpkg-deb -x "${WORK_DIR}/modules-extra.deb" "${WORK_DIR}/modules-all"
fi

# 解压 .ko.zst 为 .ko（BusyBox modprobe 不支持压缩模块）
echo "  解压内核模块..." >&2
for f in $(find "${WORK_DIR}/modules-all" -name '*.ko.zst'); do
    zstd -d -f "$f" -o "${f%.zst}" && rm "$f"
done

depmod -b "${WORK_DIR}/modules-all" "${KVER}"

# =============================================================================
# 5. 精简模块树
# =============================================================================

echo "  解析模块依赖..." >&2
NEEDED_FILES=""
for mod in $REQUIRED; do
    deps=$(modprobe -d "${WORK_DIR}/modules-all" -S "${KVER}" --show-depends "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}')
    NEEDED_FILES="${NEEDED_FILES} ${deps}"
done

NEEDED_FILES=$(echo "$NEEDED_FILES" | tr ' ' '\n' | sort -u | grep -v '^$')

if [[ -z "$NEEDED_FILES" ]]; then
    echo "警告：未解析到任何模块，回退为包含全部模块" >&2
    MOD_DEST="${OUTPUT_DIR}/lib/modules/${KVER}"
    mkdir -p "${MOD_DEST}"
    cp -a "${WORK_DIR}/modules-all/lib/modules/${KVER}/"* "${MOD_DEST}/"
else
    echo "  包含 $(echo "$NEEDED_FILES" | wc -l) 个模块（含依赖）" >&2
    for mod_file in $NEEDED_FILES; do
        rel_path=$(echo "$mod_file" | sed "s|${WORK_DIR}/modules-all/lib/modules/${KVER}/||")
        dest_dir="${OUTPUT_DIR}/lib/modules/${KVER}/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp "$mod_file" "$dest_dir/"
    done

    for f in modules.builtin modules.builtin.modinfo modules.order; do
        src="${WORK_DIR}/modules-all/lib/modules/${KVER}/$f"
        [ -f "$src" ] && cp "$src" "${OUTPUT_DIR}/lib/modules/${KVER}/"
    done

    depmod -b "${OUTPUT_DIR}" "${KVER}"
fi

# stdout 输出内核版本供 build.sh 使用
echo "${KVER}"