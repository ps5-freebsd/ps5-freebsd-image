#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO="ubuntu2604"
KERNEL_SRC=""
FREEBSD_SRC=""
FREEBSD_ROOT=""
FREEBSD_KERNEL=""
FREEBSD_BUILD=true
FREEBSD_BUILD_BACKEND="${FREEBSD_BUILD_BACKEND:-auto}"
FREEBSD_VM_IMAGE="${FREEBSD_VM_IMAGE:-}"
FREEBSD_VM_USER="${FREEBSD_VM_USER:-freebsd}"
FREEBSD_VM_SSH_KEY="${FREEBSD_VM_SSH_KEY:-}"
CLEAN=false
IMG_SIZE=12000
KERNEL_ONLY=false
PATCHES_REF="kernel-7.1.1-76db3a4"

MULTI_DISTROS="ubuntu2604 arch cachyos"

usage() {
    echo "Usage: $0 [--distro <distro>] [--kernel <path>] [--img-size <MB>] [--clean]"
    echo ""
    echo "Options:"
    echo "  --distro     Distribution to build: ubuntu2604, arch, cachyos, fedora, proxmox, debian, bazzite, bazzite-deck, batocera, freebsd, all (default: ubuntu2604)"
    echo "  --kernel     Path to kernel source directory (default: auto-clone to work/linux/)"
    echo "  --freebsd-src     Path to FreeBSD source tree (default: ../freebsd-stable15 when present)"
    echo "  --freebsd-root    Path to prebuilt FreeBSD DESTDIR/root tree"
    echo "  --freebsd-kernel  Path to FreeBSD kernel ELF for /PS5/FreeBSD/kernel"
    echo "  --freebsd-build-backend  FreeBSD build backend: auto, host, qemu (default: auto)"
    echo "  --freebsd-vm-image      FreeBSD QEMU base qcow2/raw image for qemu backend"
    echo "  --freebsd-vm-user       SSH user for qemu backend (default: freebsd)"
    echo "  --freebsd-vm-ssh-key    SSH private key for qemu backend"
    echo "  --skip-freebsd-build  Reuse --freebsd-root instead of running buildworld/installworld"
    echo "  --img-size   Disk image size in MB (default: 12000, 32000 for --distro all)"
    echo "  --clean      Remove all cached build artifacts and start from scratch"
    echo "  --clean-only Remove all cached build artifacts and exit"
    echo "  --kernel-only  Build and package the kernel only, then exit"
    echo "  --patches-ref  Branch, tag, or commit SHA for patches (default: v1.2)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)    DISTRO="$2";          shift 2 ;;
        --kernel)    KERNEL_SRC="$2";      shift 2 ;;
        --freebsd-src) FREEBSD_SRC="$2";   shift 2 ;;
        --freebsd-root) FREEBSD_ROOT="$2"; shift 2 ;;
        --freebsd-kernel) FREEBSD_KERNEL="$2"; shift 2 ;;
        --freebsd-build-backend) FREEBSD_BUILD_BACKEND="$2"; shift 2 ;;
        --freebsd-vm-image) FREEBSD_VM_IMAGE="$2"; shift 2 ;;
        --freebsd-vm-user) FREEBSD_VM_USER="$2"; shift 2 ;;
        --freebsd-vm-ssh-key) FREEBSD_VM_SSH_KEY="$2"; shift 2 ;;
        --skip-freebsd-build) FREEBSD_BUILD=false; shift ;;
        --img-size)  IMG_SIZE="$2";        shift 2 ;;
        --clean)     CLEAN=true;           shift ;;
        --clean-only) CLEAN=true; CLEAN_EXIT=true; shift ;;
        --kernel-only) KERNEL_ONLY=true;   shift ;;
        --patches-ref) [ -n "$2" ] && PATCHES_REF="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"

PATCHES_REPO="https://github.com/ps5-linux/ps5-linux-patches.git"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"



if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi
if [ "$DISTRO" = "freebsd" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=8000
fi

# Bazzite assembles the OCI rootfs + an embedded /sysroot/ostree/repo/objects
# (a deduplicated second copy of the same content) + the linux-ps5 kernel —
# 12 GB is not enough headroom. Bump the default for any bazzite* target.
# Batocera unsquashes to ~6 GB; 12 GB is tight once kernel + initrd +
# /userdata defaults are added. Bump to 16 GB.
case "$DISTRO" in
    bazzite*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=24000
        fi
        ;;
    batocera*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
esac

if [ -z "$FORMAT" ]; then
    case "$DISTRO" in
        arch|cachyos)        FORMAT="arch" ;;
        fedora|bazzite*)     FORMAT="rpm"  ;;
        freebsd)             FORMAT="freebsd" ;;
        all)                 FORMAT="all"  ;;
        *)                   FORMAT="deb"  ;;
    esac
fi

FREEBSD_DEFAULT_SRC="$SCRIPT_DIR/../freebsd-stable15"
FREEBSD_ROOT_DEFAULT="$SCRIPT_DIR/work/freebsd-root"
if [ -z "$FREEBSD_SRC" ] && [ -d "$FREEBSD_DEFAULT_SRC/sys" ]; then
    FREEBSD_SRC="$FREEBSD_DEFAULT_SRC"
fi
if [ -z "$FREEBSD_ROOT" ]; then
    FREEBSD_ROOT="$FREEBSD_ROOT_DEFAULT"
fi
if [ "$FREEBSD_BUILD_BACKEND" = "auto" ]; then
    if [ "$(uname -s)" = "FreeBSD" ]; then
        FREEBSD_BUILD_BACKEND="host"
    else
        FREEBSD_BUILD_BACKEND="qemu"
    fi
fi

KERNEL_BUILDER_PLATFORM="linux/amd64"
case "$(uname -m)" in
    aarch64|arm64) KERNEL_BUILDER_PLATFORM="linux/arm64" ;;
esac

# --- Signal trap: clean up docker containers and background jobs on exit ---
BUILD_PID=""

cleanup() {
    trap - INT TERM EXIT
    echo ""
    echo "Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache" "$OUTPUT_DIR"; do
        [ -d "$dir" ] && docker run --rm \
            -v "$(dirname "$dir")":/parent \
            alpine rm -rf "/parent/$(basename "$dir")"
    done
    echo "Done."
    [ "$CLEAN_EXIT" = true ] && exit 0
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    rpm)  ls "$KERNEL_OUT"/*.rpm 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

# --- Build plan summary ---
echo ""
if [ "$DISTRO" = "freebsd" ]; then
    echo "PS5 FreeBSD Image Builder"
    echo "========================="
    echo "  Image size:   ${IMG_SIZE}MB"
    echo "  FreeBSD src:  ${FREEBSD_SRC:-<prebuilt root only>}"
    echo "  FreeBSD root: $FREEBSD_ROOT"
    echo "  Build root:   $FREEBSD_BUILD"
    [ "$FREEBSD_BUILD" = true ] && echo "  Backend:      $FREEBSD_BUILD_BACKEND"
    echo ""
    echo "Stages:"
    if [ "$FREEBSD_BUILD" = true ]; then
        echo "  1. FreeBSD root      build"
    else
        echo "  1. FreeBSD root      prebuilt"
    fi
    echo "  2. Disk image        build"
else
    echo "PS5 Linux Image Builder"
    echo "======================="
    if [ "$KERNEL_ONLY" = true ]; then
        echo "  Mode:         kernel only"
        echo "  Format:       $FORMAT"
    else
        echo "  Distro:       $DISTRO"
        [ "$DISTRO" = "all" ] && echo "                ($MULTI_DISTROS)"
        echo "  Image size:   ${IMG_SIZE}MB"
    fi
    if [ -f "$PATCHES_DIR/.config" ]; then
        LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"
        echo "  Kernel:       $LINUX_BRANCH"
    else
        echo "  Kernel:       (will fetch)"
    fi
    echo "  Kernel src:   $KERNEL_SRC"
    echo ""
    echo "Stages:"
    if [ "$SKIP_KERNEL" = true ]; then
        echo "  1. Kernel            cached"
    elif [ -d "$KERNEL_SRC/.git" ]; then
        echo "  1. Kernel            build (source cached)"
    else
        echo "  1. Kernel            clone + build"
    fi
    if [ "$KERNEL_ONLY" = false ]; then
        if [ "$SKIP_CHROOT" = true ]; then
            echo "  2. Root filesystem   cached"
        else
            echo "  2. Root filesystem   build"
        fi
        echo "  3. Disk image        build"
    fi
fi
echo ""
echo "Logs: $LOG_FILE"
echo ""

# --- Logging + stage runner ---
: > "$LOG_FILE"

SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        if [ $rc -ne 0 ]; then
            echo "::error::Build failed at: $name"
            exit $rc
        fi
        return
    fi

    local status_msg="$name"
    local spin_i=0

    # Record log position so we only scan new lines for status updates
    local log_start
    log_start=$(wc -l < "$LOG_FILE")

    # Run command in background
    "$@" >> "$LOG_FILE" 2>&1 &
    BUILD_PID=$!

    # Spinner loop — pick up === status lines from the log
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if (( spin_i % 10 == 0 )); then
            local new
            new=$(tail -n +$((log_start + 1)) "$LOG_FILE" 2>/dev/null \
                | grep -oP '(?<=^=== ).*(?= ===$)' | tail -1)
            [ -n "$new" ] && status_msg="$new"
        fi
        printf "\r  %s %-60s" "${SPIN_CHARS:spin_i%${#SPIN_CHARS}:1}" "$status_msg"
        spin_i=$((spin_i + 1))
        sleep 0.1
    done

    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""

    if [ $rc -eq 0 ]; then
        printf "\r  ✓ %-60s\n" "$name"
    else
        printf "\r  ✗ %-60s\n" "$status_msg"
        echo ""
        echo "Build failed at: $status_msg"
        echo "Logs: $LOG_FILE"
        echo "Try running with --clean to start fresh."
        exit 1
    fi
}

# --- Setup directories ---
mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$CHROOT_DIR" "$CACHE_DIR" "$CCACHE_DIR"
if [ "$DISTRO" = "all" ]; then
    for d in $MULTI_DISTROS; do
        mkdir -p "$SCRIPT_DIR/work/chroot-$d"
    done
fi

if [ "$DISTRO" = "freebsd" ]; then
    if [ "$FREEBSD_BUILD" = true ]; then
        if [ -z "$FREEBSD_SRC" ] || [ ! -d "$FREEBSD_SRC/sys" ]; then
            echo "FreeBSD source tree not found. Pass --freebsd-src or --skip-freebsd-build --freebsd-root."
            exit 1
        fi
        FREEBSD_SRC="$(cd "$FREEBSD_SRC" && pwd)"
    fi
    mkdir -p "$(dirname "$FREEBSD_ROOT")" "$SCRIPT_DIR/work/freebsd-qemu"
    FREEBSD_ROOT="$(cd "$(dirname "$FREEBSD_ROOT")" && pwd)/$(basename "$FREEBSD_ROOT")"
    if [ -n "$FREEBSD_VM_IMAGE" ]; then
        FREEBSD_VM_IMAGE="$(cd "$(dirname "$FREEBSD_VM_IMAGE")" && pwd)/$(basename "$FREEBSD_VM_IMAGE")"
    fi
    if [ -n "$FREEBSD_VM_SSH_KEY" ]; then
        FREEBSD_VM_SSH_KEY="$(cd "$(dirname "$FREEBSD_VM_SSH_KEY")" && pwd)/$(basename "$FREEBSD_VM_SSH_KEY")"
    fi

    if [ "$FREEBSD_BUILD" = true ]; then
        case "$FREEBSD_BUILD_BACKEND" in
            host)
                run_stage "Build FreeBSD PS5 root (host)" \
                    "$SCRIPT_DIR/scripts/build-freebsd-root.sh" "$FREEBSD_SRC" "$FREEBSD_ROOT"
                ;;
            qemu)
                if [ -z "$FREEBSD_VM_IMAGE" ]; then
                    echo "QEMU backend requires --freebsd-vm-image or FREEBSD_VM_IMAGE."
                    echo "Use a FreeBSD VM image with SSH enabled and pass --freebsd-vm-ssh-key if needed."
                    exit 1
                fi
                run_stage "Build FreeBSD QEMU builder image" \
                    docker build --pull --no-cache \
                        -t ps5-freebsd-vm-builder \
                        -f "$SCRIPT_DIR/docker/freebsd-vm-builder/Dockerfile" "$SCRIPT_DIR"

                QEMU_DOCKER_ARGS=(
                    docker run --rm --privileged --name "$DOCKER_NAME"
                    -v "$FREEBSD_SRC":/freebsd-src:ro
                    -v "$(dirname "$FREEBSD_ROOT")":/out-root
                    -v "$(dirname "$FREEBSD_VM_IMAGE")":/vm:ro
                    -v "$SCRIPT_DIR/work/freebsd-qemu":/qemu-work
                    -e KERNCONF="${KERNCONF:-PS5}"
                    -e TARGET="${TARGET:-amd64}"
                    -e TARGET_ARCH="${TARGET_ARCH:-amd64}"
                    -e JOBS="${JOBS:-}"
                    -e FREEBSD_QEMU_WORKDIR=/qemu-work
                    -e FREEBSD_QEMU_SSH_PORT="${FREEBSD_QEMU_SSH_PORT:-10022}"
                    -e FREEBSD_QEMU_MEMORY="${FREEBSD_QEMU_MEMORY:-8192}"
                    -e FREEBSD_QEMU_CPUS="${FREEBSD_QEMU_CPUS:-}"
                )
                if [ -n "$FREEBSD_VM_SSH_KEY" ]; then
                    QEMU_DOCKER_ARGS+=(-v "$(dirname "$FREEBSD_VM_SSH_KEY")":/ssh-key:ro)
                    FREEBSD_VM_SSH_KEY_IN_CONTAINER="/ssh-key/$(basename "$FREEBSD_VM_SSH_KEY")"
                else
                    FREEBSD_VM_SSH_KEY_IN_CONTAINER=""
                fi
                QEMU_DOCKER_ARGS+=(
                    ps5-freebsd-vm-builder
                    /freebsd-src
                    "/out-root/$(basename "$FREEBSD_ROOT")"
                    "/vm/$(basename "$FREEBSD_VM_IMAGE")"
                    "$FREEBSD_VM_USER"
                    "$FREEBSD_VM_SSH_KEY_IN_CONTAINER"
                )
                run_stage "Build FreeBSD PS5 root (docker+qemu)" "${QEMU_DOCKER_ARGS[@]}"
                ;;
            *)
                echo "Unsupported FreeBSD build backend: $FREEBSD_BUILD_BACKEND"
                exit 1
                ;;
        esac
    elif [ ! -d "$FREEBSD_ROOT" ]; then
        echo "--skip-freebsd-build requires an existing --freebsd-root directory."
        exit 1
    fi

    if [ -z "$FREEBSD_KERNEL" ]; then
        FREEBSD_KERNEL="$FREEBSD_ROOT/boot/kernel/kernel"
    fi
    if [ ! -f "$FREEBSD_KERNEL" ]; then
        echo "FreeBSD kernel ELF not found at $FREEBSD_KERNEL"
        echo "Pass --freebsd-kernel or build/install KERNCONF=PS5 first."
        exit 1
    fi

    run_stage "Build FreeBSD image builder image" \
        docker build --pull --no-cache \
            -t ps5-freebsd-image-builder \
            -f "$SCRIPT_DIR/docker/freebsd-image-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Build FreeBSD image (${IMG_SIZE}MB)" \
        docker run --rm --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$OUTPUT_DIR":/output \
            -v "$FREEBSD_ROOT":/freebsd-root:ro \
            -v "$(dirname "$FREEBSD_KERNEL")":/freebsd-kernel:ro \
            -e FREEBSD_KERNEL="/freebsd-kernel/$(basename "$FREEBSD_KERNEL")" \
            -e IMG_SIZE="$IMG_SIZE" \
            ps5-freebsd-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-freebsd.img"
    echo ""
    echo "Done! Image: $IMG_PATH"
    echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
    exit 0
fi

# --- Step 1: Kernel ---
if [ "$SKIP_KERNEL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel packages (cached)"
else
    if [ ! -d "$KERNEL_SRC/.git" ]; then
        REPO_URL="$PATCHES_REPO"
        [ -n "$PATCHES_TOKEN" ] && REPO_URL="${PATCHES_REPO/https:\/\//https:\/\/${PATCHES_TOKEN}@}"


        mkdir -p "$PATCHES_DIR"
        run_stage "Fetch ps5-linux-patches ($PATCHES_REF)" bash -c '
            cd "'"$PATCHES_DIR"'"
            [ ! -d .git ] && git init && git remote add origin "'"$REPO_URL"'"
            git fetch --depth 1 origin "'"$PATCHES_REF"'" || git fetch origin "'"$PATCHES_REF"'"
            git reset --hard FETCH_HEAD
        '
        LINUX_TMP_DIR="${LINUX_DEFAULT_DIR}.tmp"
        for dir in "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"

        run_stage "Clone kernel $LINUX_BRANCH" \
            git clone --branch "$LINUX_BRANCH" --depth 1 "$LINUX_REPO" "$LINUX_TMP_DIR"

        run_stage "Apply patches" bash -c '
            set -e; shopt -s nullglob
            patches=("'"$PATCHES_DIR"'"/*.patch)
            [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$PATCHES_DIR"'"; exit 1; }
            for p in "${patches[@]}"; do
                echo "Applying $p"
                git -C "'"$LINUX_TMP_DIR"'" apply --exclude=Makefile "$p"
            done'

        run_stage "Copy kernel config" \
            cp "$PATCHES_DIR/.config" "$LINUX_TMP_DIR/.config"

        mv "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"

    rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.pkg.tar.zst "$KERNEL_OUT"/*.rpm

    run_stage "Build kernel builder image" \
        docker build --platform "$KERNEL_BUILDER_PLATFORM" -t ps5-kernel-builder \
            -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Compile kernel" \
        docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
            -v "$KERNEL_SRC":/src \
            -v "$KERNEL_OUT":/out \
            -v "$CCACHE_DIR":/ccache \
            ps5-kernel-builder

    ls "$KERNEL_OUT/staging/lib/modules/" | head -1 > "$KERNEL_OUT/VERSION"

    case "$FORMAT" in deb|all)
        run_stage "Package kernel (.deb)" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
                -v "$KERNEL_SRC":/src \
                -v "$KERNEL_OUT":/out \
                -v "$CCACHE_DIR":/ccache \
                ps5-kernel-builder \
                /package-deb.sh
    esac

    case "$FORMAT" in arch|all)
        run_stage "Build arch packager image" \
            docker build -t ps5-kernel-packager-arch \
                -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.pkg.tar.zst)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-arch
    esac

    case "$FORMAT" in rpm)
        run_stage "Build rpm packager image" \
            docker build -t ps5-kernel-packager-rpm \
                -f "$SCRIPT_DIR/docker/kernel-builder-rpm/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.rpm)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-rpm
    esac
fi

if [ "$KERNEL_ONLY" = true ]; then
    KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
    exit 0
fi

# --- Step 2: Build distribution image ---
run_stage "Build image builder image" \
    docker build --pull --no-cache \
        -t ps5-image-builder -f "$SCRIPT_DIR/docker/image-builder/Dockerfile" "$SCRIPT_DIR"

if [ "$DISTRO" = "all" ]; then
    DOCKER_ARGS=(
        docker run --rm --privileged --name "$DOCKER_NAME"
        --entrypoint /entrypoint-multi.sh
        -v "$SCRIPT_DIR":/repo:ro
        -v "$KERNEL_OUT":/kernel-debs:ro
        -v "$OUTPUT_DIR":/output
        -v "$CACHE_DIR":/build/cache
        -e IMG_SIZE="$IMG_SIZE"
        -e SKIP_CHROOT="$SKIP_CHROOT"
        -e "DISTROS=$MULTI_DISTROS"
    )
    for d in $MULTI_DISTROS; do
        DOCKER_ARGS+=(-v "$SCRIPT_DIR/work/chroot-$d:/build/chroot-$d")
    done
    DOCKER_ARGS+=(ps5-image-builder)

    run_stage "Build multi-distro image (${IMG_SIZE}MB)" "${DOCKER_ARGS[@]}"

    IMG_PATH="$OUTPUT_DIR/ps5-multi.img"
else
    run_stage "Build $DISTRO image (${IMG_SIZE}MB)" \
        docker run --rm --privileged --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$KERNEL_OUT":/kernel-debs:ro \
            -v "$OUTPUT_DIR":/output \
            -v "$CHROOT_DIR":/build/chroot \
            -v "$CACHE_DIR":/build/cache \
            -e DISTRO="$DISTRO" \
            -e IMG_SIZE="$IMG_SIZE" \
            -e SKIP_CHROOT="$SKIP_CHROOT" \
            ps5-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-${DISTRO}.img"
fi

echo ""
echo "Done! Image: $IMG_PATH"
echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
