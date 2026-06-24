FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates openssh-client qemu-system-x86 qemu-utils \
    coreutils findutils tar xz-utils rsync \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build-freebsd-root-qemu.sh /build-freebsd-root-qemu.sh
RUN chmod +x /build-freebsd-root-qemu.sh

ENTRYPOINT ["/build-freebsd-root-qemu.sh"]
