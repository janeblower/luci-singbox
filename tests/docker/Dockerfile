# tests/docker/Dockerfile
# Publishes ghcr.io/<owner>/luci-singbox/openwrt-test
# Build requires /dev/kvm (the savevm step boots qemu under KVM).
#
# Layer strategy:
#   1. Static apt deps (cache-stable across OpenWrt bumps)
#   2. Helper scripts (rebuilt when scripts change)
#   3. OpenWrt rootfs download (cache-stable per release)
#   4. Snapshot bake (rebuilt when scripts or rootfs change)
#
# OpenWrt version bumps: update IMAGE_URL + IMAGE_SHA256, re-trigger
# the test-image workflow.

FROM debian:12-slim

# Pin debian packages for repeatable builds. unattended apt upgrades on
# the runner do not affect what's frozen here.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        qemu-system-x86 \
        qemu-utils \
        openssh-client \
        sshpass \
        socat \
        expect \
        curl \
        ca-certificates \
        bash \
        tar \
        gzip \
        git \
        netcat-openbsd \
        unzip \
 && rm -rf /var/lib/apt/lists/*

# Helper scripts — kept in /opt for entrypoint.sh / build-snapshot.sh
# to source by absolute path regardless of WORKDIR.
COPY wait-ssh.sh              /opt/wait-ssh.sh
COPY build-snapshot.expect    /opt/build-snapshot.expect
COPY build-snapshot.sh        /opt/build-snapshot.sh
COPY entrypoint.sh            /opt/entrypoint.sh
RUN chmod +x /opt/wait-ssh.sh /opt/build-snapshot.sh /opt/entrypoint.sh

# bun — test runner (host side of the QEMU rig, NOT the OpenWrt guest).
# Pinned to match the CI setup-bun version (browser-test + typecheck/js-unit/
# packaging all use 1.2.21) so the in-container `test` lane runs the same bun
# as the host lanes.
ENV BUN_VERSION=1.2.21
ENV BUN_INSTALL=/opt/bun
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" \
 && ln -s /opt/bun/bin/bun /usr/local/bin/bun \
 && bun --version

# OpenWrt rootfs — version comes from tests/docker/openwrt-version.txt, passed
# in by the test-image workflow as --build-arg OPENWRT_VERSION=... (single
# source of truth). The ARG default keeps a bare `docker build` working. Only
# IMAGE_SHA256 stays an explicit pin — a checksum can't be derived from the
# version string, so bump it alongside the version file.
ARG OPENWRT_VERSION=25.12.3
ENV IMAGE_URL=https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/openwrt-${OPENWRT_VERSION}-x86-64-generic-squashfs-combined.img.gz
ENV IMAGE_FILE=openwrt-${OPENWRT_VERSION}-x86-64-generic-squashfs-combined.img.gz
ENV IMAGE_SHA256=41c52550808286fb609cee4ae2d903feb506a5404f499f2f3a24e52108f8a809

WORKDIR /var/lib/qemu-image
RUN curl -fsSL "$IMAGE_URL" -o "$IMAGE_FILE" \
 && echo "${IMAGE_SHA256}  ${IMAGE_FILE}" | sha256sum -c -

# Bake the snapshot. This step requires /dev/kvm at build time.
# In buildkit terms, this means:
#   docker buildx build --allow security.insecure ... + RUN --security=insecure
# or the legacy `docker build --privileged` (DOCKER_BUILDKIT=0).
# The image-build workflow uses the buildkit form.
RUN --security=insecure /opt/build-snapshot.sh

# Guest-side bun — the musl-baseline build streamed into the OpenWrt guest's
# /tmp (tmpfs) at run time by entrypoint.sh. Baseline is mandatory: the guest
# qemu64 CPU lacks AVX2 and the non-baseline build SIGILLs. Placed AFTER the
# snapshot bake so a BUN_VERSION bump rebuilds only this layer (no KVM).
RUN mkdir -p /opt/bun-guest \
 && curl -fsSL -o /tmp/bun-guest.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64-musl-baseline.zip" \
 && unzip -q /tmp/bun-guest.zip -d /tmp/bun-guest-unzip \
 && cp /tmp/bun-guest-unzip/bun-linux-x64-musl-baseline/bun /opt/bun-guest/bun \
 && chmod +x /opt/bun-guest/bun \
 && printf '%s\n' "${BUN_VERSION}" > /opt/bun-guest/VERSION \
 && rm -rf /tmp/bun-guest.zip /tmp/bun-guest-unzip

# Per-run entrypoint. Image consumers must pass:
#   docker run --device /dev/kvm -v <repo>:/work ...
ENTRYPOINT ["/opt/entrypoint.sh"]
