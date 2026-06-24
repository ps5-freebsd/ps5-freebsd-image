FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash coreutils findutils util-linux \
    gdisk dosfstools mtools makefs rsync xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY docker/freebsd-image-builder/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
