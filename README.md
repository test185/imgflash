<div align="center">

# ImgFlash

**将任意 `.img` 镜像打包为可引导 ISO，启动后一键写入磁盘**

<p align="center">
  <img src="https://img.shields.io/badge/language-bash-yellow?style=flat-square&logo=gnubash" alt="Bash">
  <img src="https://img.shields.io/badge/dockerfile-ready-blue?style=flat-square&logo=docker" alt="Dockerfile">
</p>

<p align="center">
  <a href="https://github.com/GuangYu-yu/imgflash">
    <img src="https://img.shields.io/github/stars/GuangYu-yu/imgflash?style=flat-square&label=Star&color=00ADD8&logo=github" alt="GitHub Stars">
  </a>
  <a href="https://github.com/GuangYu-yu/imgflash/forks">
    <img src="https://img.shields.io/github/forks/GuangYu-yu/imgflash?style=flat-square&label=Fork&color=00ADD8&logo=github" alt="GitHub Forks">
  </a>
</p>

<p align="center">
  <a href="https://deepwiki.com/GuangYu-yu/imgflash">
    <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki">
  </a>
  <a href="https://zread.ai/GuangYu-yu/imgflash">
    <img src="https://img.shields.io/badge/Ask_Zread-_.svg?style=flat&color=00b0aa&labelColor=000000&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB3aWR0aD0iMTYiIGhlaWdodD0iMTYiIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTQuOTYxNTYgMS42MDAxSDIuMjQxNTZDMS44ODgxIDEuNjAwMSAxLjYwMTU2IDEuODg2NjQgMS42MDE1NiAyLjI0MDFWNC45NjAxQzEuNjAxNTYgNS4zMTM1NiAxLjg4ODEgNS42MDAxIDIuMjQxNTYgNS42MDAxSDQuOTYxNTZDNS4zMTUwMiA1LjYwMDEgNS42MDE1NiA1LjMxMzU2IDUuNjAxNTYgNC45NjAxVjIuMjQwMUM1LjYwMTU2IDEuODg2NjQgNS4zMTUwMiAxLjYwMDEgNC45NjE1NiAxLjYwMDFaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00Ljk2MTU2IDEwLjM5OTlIMi4yNDE1NkMxLjg4ODEgMTAuMzk5OSAxLjYwMTU2IDEwLjY4NjQgMS42MDE1NiAxMS4wMzk5VjEzLjc1OTlDMS42MDE1NiAxNC4xMTM0IDEuODg4MSAxNC4zOTk5IDIuMjQxNTYgMTQuMzk5OUg0Ljk2MTU2QzUuMzE1MDIgMTQuMzk5OSA1LjYwMTU2IDE0LjExMzQgNS42MDE1NiAxMy43NTk5VjExLjAzOTlDNS42MDE1NiAxMC42ODY0IDUuMzE1MDIgMTAuMzk5OSA0Ljk2MTU2IDEwLjM5OTlaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik0xMy43NTg0IDEuNjAwMUgxMS4wMzg0QzEwLjY4NSAxLjYwMDEgMTAuMzk4NCAxLjg4NjY0IDEwLjM5ODQgMi4yNDAxVjQuOTYwMUMxMC4zOTg0IDUuMzEzNTYgMTAuNjg1IDUuNjAwMSAxMS4wMzg0IDUuNjAwMUgxMy43NTg0QzE0LjExMTkgNS42MDAxIDE0LjM5ODQgNS4zMTM1NiAxNC4zOTg0IDQuOTYwMVYyLjI0MDFDMTQuMzk4NCAxLjg4NjY0IDE0LjExMTkgMS42MDAxIDEzLjc1ODQgMS42MDAxWiIgZmlsbD0iI2ZmZiIvPgo8cGF0aCBkPSJNNCAxMkwxMiA0TDQgMTJaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00IDEyTDEyIDQiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgo8L3N2Zz4K&logoColor=ffffff" alt="zread">
  </a>
</p>

</div>

## 架构

纯 initramfs-only，无 rootfs、无 overlayfs、无 init 切换：

- **amd64**：UEFI + BIOS 双启动
  - UEFI 链（Secure Boot）：shim（Microsoft 签名）→ GRUB（Debian 签名）→ vmlinuz（Debian 签名）
  - UEFI 链（非 Secure Boot）：GRUB → vmlinuz
  - BIOS 链：syslinux → vmlinuz
- **arm64**：UEFI 单启动
  - UEFI 链：同 amd64，按 Secure Boot 配置决定
- **运行时**：initramfs `/init` → 加载模块/挂载介质 → exec `installer` → dd 写盘 → 重启

## 构建流程

| 阶段 | 说明 |
|------|------|
| Phase 1 | mmdebstrap 创建最小 Debian 环境（含引导组件） |
| Phase 2 | 提取内核 / shim（可选） / GRUB / BusyBox |
| Phase 3 | 组装 initramfs（BusyBox + 内核模块 + 安装脚本） |
| Phase 4 | 将镜像打包为 squashfs 容器（zstd 压缩） |
| Phase 5 | 组装 ISO 文件系统结构（UEFI 引导 + 可选 BIOS 引导） |
| Phase 6 | xorriso 生成最终 ISO |

## 使用方式

### Docker 构建（推荐）

```bash
docker build -t imgflash .

# 从本地镜像构建
docker run --rm --privileged \
  -v "$(pwd)/output:/build/output" \
  imgflash -i /path/to/image.img

# 从 URL 下载镜像并构建
docker run --rm --privileged \
  -v "$(pwd)/output:/build/output" \
  imgflash -u https://example.com/image.img.gz

# 使用自定义配置构建
docker run --rm --privileged \
  -v "$(pwd)/output:/build/output" \
  -v "$(pwd)/my.env:/build/build.env" \
  imgflash -i /path/to/image.img
```

### 命令行参数

```
用法: build.sh [选项]

选项:
  -i, --image   指定本地 .img 文件路径
  -u, --url     从 URL 下载镜像文件（支持 raw / gz / xz / bz2 / zip / 7z）
  -n, --name    输出 ISO 名称（默认从镜像文件名推导）
  -h, --help    显示帮助
```

### 构建配置

所有构建参数通过 `build.env` 配置，修改后重新构建即可生效。

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `ARCH` | 目标架构（amd64 / arm64） | `amd64` |
| `DEBIAN_MIRROR` | Debian 镜像源 | `https://ftp.debian.org/debian` |
| `DEBIAN_SUITE` | Debian 套件版本 | `trixie` |
| `VOLUME_LABEL` | ISO 卷标 | `IMGFLASH` |
| `MOD_*` | 各组内核模块定义 | 见 build.env |
| `INCLUDE_NVME` | NVMe 模块开关 | `1` |
| `INCLUDE_VIRT` | 虚拟化模块开关 | `1` |
| `ENABLE_SECURE_BOOT` | Secure Boot 支持 | `0` |
| `BOOT_TIMEOUT` | 启动菜单超时（秒） | `3` |
| `KERNEL_PARAMS` | 内核启动参数 | `quiet` |
| `SCAN_TIMEOUT` | 启动时扫描介质的超时秒数 | `10` |
| `ZSTD_LEVEL` | zstd 压缩级别 | `19` |

## GitHub Actions CI

通过 `workflow_dispatch` 手动触发构建：

1. 进入仓库 Actions 页面
2. 选择 "构建 ImgFlash 安装器 ISO" 工作流
3. 选择目标架构（amd64 / arm64）
4. 填入镜像下载地址和可选的 ISO 名称
5. 按需启用 Secure Boot
6. 构建完成后从 Artifacts 下载 ISO

## 安装器运行时

ISO 启动后进入交互式安装器：

1. 自动枚举可写磁盘（显示大小和型号）
2. 用户选择目标磁盘
3. 二次确认（需输入大写 `YES`）
4. dd 写入并显示实时进度
5. 写入完成后自动弹出介质并重启

选择 `0` 可进入 Shell 进行手动操作。