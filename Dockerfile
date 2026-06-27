FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    mmdebstrap debian-archive-keyring \
    curl file \
    xorriso squashfs-tools mtools dosfstools grub-pc-bin \
    xz-utils bzip2 p7zip-full unzip zstd cpio kmod \
    busybox-static \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY . .

ENTRYPOINT ["bash", "build.sh"]