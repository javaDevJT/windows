# syntax=docker/dockerfile:1

ARG VERSION_ARG="latest"

# ── Stage 0: Build QEMU 8.2.2 with zhaodice anti-detection patches ────────────
# Compiling from source is the only reliable way to change PCI vendor IDs
# (0x1AF4 → 0x8086), ACPI OEM strings, and all device identity strings.
FROM debian:trixie-slim AS qemu-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    wget \
    git \
    patch \
    python3 \
    python3-venv \
    ninja-build \
    pkg-config \
    libglib2.0-dev \
    libpixman-1-dev \
    zlib1g-dev \
    libfdt-dev \
    flex \
    bison \
    libaio-dev \
    libepoxy-dev \
    libdrm-dev \
    libgbm-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download QEMU 8.2.2 source (8.2.0 patch is compatible with 8.2.x series)
RUN wget -q https://download.qemu.org/qemu-8.2.2.tar.xz && \
    tar xf qemu-8.2.2.tar.xz && \
    rm qemu-8.2.2.tar.xz && \
    wget -q -O anti-detection.patch \
        https://raw.githubusercontent.com/zhaodice/qemu-anti-detection/main/qemu-8.2.0.patch

# Switch into the source tree so subsequent RUN steps don't need cd (DL3003)
WORKDIR /build/qemu-8.2.2

# git init is required for git apply to work on a non-repo directory
RUN git init -q && \
    git apply /build/anti-detection.patch

# Build only the x86_64 target to minimize compile time (~10-20 min on CI)
RUN ./configure \
        --prefix=/usr \
        --target-list=x86_64-softmmu \
        --disable-docs \
        --disable-guest-agent \
        --disable-sdl \
        --disable-gtk \
        --disable-curses \
        --disable-pa \
        --disable-xen \
        --enable-kvm && \
    make -j"$(nproc)" && \
    make install && \
    strip /usr/bin/qemu-system-x86_64

# ── Stage 1: Main amd64 image ─────────────────────────────────────────────────
FROM scratch AS build-amd64

COPY --from=qemux/qemu:7.29 / /

# Replace the distro QEMU binary with our anti-detection patched build.
# Key changes applied by the patch:
#   - PCI vendor IDs: 0x1AF4 (Red Hat/VirtIO) + 0x1B36 (Red Hat) → 0x8086 (Intel)
#   - ACPI OEM ID: "BOCHS " → "INTEL ", OEM Table ID: "BXPC" → "PC8086"
#   - ACPI fw_cfg _HID: "QEMU0002" → "ASUS0002" (removes ACPI\QEMU0002 registry key)
#   - All device model strings: "QEMU *" → "ASUS *" (disk, CD, USB, HID, etc.)
#   - SMBIOS: VM-present bit cleared, manufacturer/product spoofed
#   - EDID monitor: "RHT"/"QEMU Monitor" → "DEL"/"DEL Monitor"
#   - KVM CPUID leaf: "KVMKVMKVM" → "GenuineIntel" (in addition to hv_vendor_id= arg)
COPY --from=qemu-builder /usr/bin/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
COPY --from=qemu-builder /usr/share/qemu/ /usr/share/qemu/

ARG TARGETARCH
ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        samba \
        wimtools \
        dos2unix \
        cabextract \
        libxml2-utils \
        libarchive-tools && \
    wget "https://github.com/gershnik/wsdd-native/releases/download/v1.22/wsddn_1.22_${TARGETARCH}.deb" -O /tmp/wsddn.deb -q && \
    dpkg -i /tmp/wsddn.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./assets /run/assets

ADD --chmod=664 https://github.com/qemus/virtiso-whql/releases/download/v1.9.49-0/virtio-win-1.9.49.tar.xz /var/drivers.txz

FROM dockurr/windows-arm:${VERSION_ARG} AS build-arm64
FROM build-${TARGETARCH}

ARG VERSION_ARG="0.00"
RUN echo "$VERSION_ARG" > /run/version

VOLUME /storage
EXPOSE 3389 8006

ENV VERSION="11"
ENV RAM_SIZE="4G"
ENV CPU_CORES="2"
ENV DISK_SIZE="64G"

# Use Intel e1000e NIC instead of virtio-net-pci to avoid any VID 0x1AF4 leakage
# even before the PCI ID spoofing takes effect at the driver enumeration stage.
ENV ADAPTER="e1000e"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
