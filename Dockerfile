# syntax=docker/dockerfile:1

ARG VERSION_ARG="latest"
FROM scratch AS build-amd64

COPY --from=qemux/qemu:7.29 / /

ARG TARGETARCH
ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        python3-minimal \
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

# Binary-patch QEMU to remove VM identity strings visible to guest applications.
# All replacements are the same byte length to preserve binary integrity.
RUN <<'PYEOF'
#!/usr/bin/env python3
import os, sys

path = '/usr/bin/qemu-system-x86_64'
if not os.path.exists(path):
    print(f'WARNING: {path} not found, skipping QEMU identity patch', file=sys.stderr)
    sys.exit(0)

patches = [
    # ACPI OEM ID field (6 bytes): eliminates "BOCHS " in firmware tables
    (b'BOCHS ',        b'INTEL '),
    # ACPI OEM Table ID field (8 bytes): eliminates "BXPC" in firmware tables
    (b'BXPC    ',      b'PC8086  '),
    # ACPI _HID for fw_cfg device: eliminates ACPI\QEMU0002 registry key
    (b'QEMU0002',      b'ASUS0002'),
    # IDE/AHCI disk model string: eliminates "QEMU HARDDISK" from SMART/WMI
    (b'QEMU HARDDISK', b'ASUS HARDDISK'),
    # Optical drive model strings
    (b'QEMU DVD-ROM',  b'ASUS DVD-ROM'),
    (b'QEMU CD-ROM',   b'ASUS CD-ROM'),
]

data = open(path, 'rb').read()
total = 0
for old, new in patches:
    assert len(old) == len(new), f'Length mismatch: {old!r} vs {new!r}'
    count = data.count(old)
    data = data.replace(old, new)
    total += count
    print(f'  [{count:2d}x] {old!r} -> {new!r}', file=sys.stderr)

open(path, 'wb').write(data)
print(f'QEMU binary patched ({total} replacements total)', file=sys.stderr)
PYEOF

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

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
