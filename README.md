# PS5 Linux / FreeBSD Image Builder

Builds bootable Linux USB images and staged FreeBSD USB images for PlayStation
5 using Docker containers. Linux targets support Ubuntu 26.04, Arch, CachyOS
(Gamescope + Steam), Fedora (GNOME), individually or as a multi-distro image
with kexec switching. The FreeBSD target builds the USB layout expected by
`ps5-freebsd-loader`.

## Prerequisites

- Docker (with permission to run `--privileged` containers) — install as per your distro's instructions
- ~30GB free disk space for Ubuntu, Arch, or CachyOS

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build a single Ubuntu 26.04 image
./build_image.sh --distro ubuntu2604

OR

# Build CachyOS (Arch-based, Gamescope + Steam Big Picture)
./build_image.sh --distro cachyos

OR

# Build Fedora (GNOME desktop)
./build_image.sh --distro fedora

OR

# Build a FreeBSD image from a built FreeBSD DESTDIR
./build_image.sh --distro freebsd --skip-freebsd-build --freebsd-root /path/to/freebsd-root

OR

# Build a multi-distro image (ubuntu2604 + arch + cachyos)
./build_image.sh --distro all
```

For Linux targets, the script auto-clones the kernel source, applies PS5
patches, compiles, and builds the image. FreeBSD targets use a FreeBSD source
tree, prebuilt DESTDIR, or Docker+QEMU build VM. Subsequent runs reuse cached
artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
sudo dd if=output/ps5-ubuntu2604.img of=/dev/sdX bs=4M status=progress
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--distro` | `ubuntu2604`, `arch`, `cachyos`, `fedora`, `freebsd`, or `all` | `ubuntu2604` |
| `--kernel` | Path to kernel source directory | auto-clone version selected by PS5 patch set |
| `--freebsd-src` | Path to FreeBSD source tree for `--distro freebsd` | `../freebsd-stable15` when present |
| `--freebsd-root` | Prebuilt FreeBSD DESTDIR/root tree for `--distro freebsd` | `work/freebsd-root` |
| `--freebsd-kernel` | Kernel ELF copied to `/PS5/FreeBSD/kernel` | `$freebsd_root/boot/kernel/kernel` |
| `--freebsd-build-backend` | FreeBSD build backend: `auto`, `host`, or `qemu` | `auto` |
| `--freebsd-vm-image` | FreeBSD QEMU base image for the `qemu` backend | unset |
| `--freebsd-vm-user` | SSH user for the `qemu` backend | `freebsd` |
| `--freebsd-vm-ssh-key` | SSH private key for the `qemu` backend | unset |
| `--skip-freebsd-build` | Reuse `--freebsd-root` instead of running FreeBSD build/install | off |
| `--img-size` | Disk image size in MB | `12000` (`8000` for `freebsd`, `32000` for `all`) |
| `--clean` | Remove all cached build artifacts and start fresh | off |
| `--kernel-only` | Build and package the kernel only, then exit | off |
| `--patches-ref` | Branch, tag, or commit SHA for patches | `v1.2` |

## Caching

The build automatically skips stages that have already completed:

- **Kernel source** — reused if `work/linux/` exists
- **Kernel packages** — reused if `.deb`/`.pkg.tar.zst` files exist in `linux-bin/`
- **Root filesystem** — reused if chroot directories are populated

Use `--clean` to wipe everything and rebuild from scratch. The build will also suggest `--clean` if a stage fails.

## Build Output

```
PS5 Linux Image Builder
=======================
  Distro:       all
                (ubuntu2604 arch cachyos)
  Image size:   32000MB
  Kernel src:   /path/to/work/linux

Stages:
  1. Kernel            cached
  2. Root filesystem   build
  3. Disk image        build

Logs: /path/to/build.log

  ✓ Kernel packages (cached)
  ✓ Build image builder image
  ⠹ Building arch rootfs
```

All verbose output goes to `build.log`. The terminal shows a spinner with live progress.

## FreeBSD Image

The FreeBSD target creates a GPT image with:

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 ESP | `PS5BOOT` | `/PS5/FreeBSD/kernel`, `kenv.txt`, `vram.txt` |
| p2 | FreeBSD UFS | `ps5root` | FreeBSD root filesystem |

The FAT partition matches the direct handoff contract in `ps5-freebsd-loader`:

- `/PS5/FreeBSD/kernel` is the required amd64 FreeBSD kernel ELF.
- `/PS5/FreeBSD/kenv.txt` provides `vfs.root.mountfrom=ufs:/dev/gpt/ps5root`
  and early PS5 tunables.
- `/PS5/FreeBSD/vram.txt` keeps the same hex VRAM size convention as the Linux
  images.

To build from an already-installed FreeBSD root:

```bash
./build_image.sh --distro freebsd \
  --skip-freebsd-build \
  --freebsd-root /path/to/freebsd-root \
  --freebsd-kernel /path/to/freebsd-root/boot/kernel/kernel
```

To build FreeBSD on a native FreeBSD host:

```bash
./build_image.sh --distro freebsd \
  --freebsd-build-backend host \
  --freebsd-src ../freebsd-stable15
```

On Linux hosts, prefer the Docker+QEMU backend so `buildworld` and
`buildkernel KERNCONF=PS5` run inside a native FreeBSD VM:

```bash
./build_image.sh --distro freebsd \
  --freebsd-build-backend qemu \
  --freebsd-src ../freebsd-stable15 \
  --freebsd-vm-image /path/to/freebsd-build-vm.qcow2 \
  --freebsd-vm-user freebsd \
  --freebsd-vm-ssh-key ~/.ssh/freebsd-build
```

The QEMU VM image must boot FreeBSD, run SSH, allow the selected user to use
passwordless `sudo make`, and have enough disk space for `buildworld`,
`buildkernel KERNCONF=PS5`, and the installed DESTDIR. The builder copies the
source tree into the VM, runs the native FreeBSD build/install sequence, copies
the resulting DESTDIR back to `work/freebsd-root`, then assembles the PS5 USB
image on the Linux host.

The FreeBSD OCI images on Docker Hub are useful as future native-FreeBSD
container inputs or root filesystem seeds, but they do not replace the QEMU
backend on a Linux Docker host. Linux containers share the Linux host kernel,
while this build needs FreeBSD userland and kernel semantics for `buildworld`
and `buildkernel`.

## Distributions

| Distro | Desktop | Kernel format | Init |
|--------|---------|---------------|------|
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd |
| Arch | Sway | `.pkg.tar.zst` | systemd |
| CachyOS | Gamescope + Steam Big Picture (Arch + `[cachyos]` repo, no v3 migration in image build) | `.pkg.tar.zst` | systemd |

## Multi-distro Image

`--distro all` builds a 32GB image with 4 partitions (one EFI boot partition plus three root filesystems):

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 | boot | Shared kernel, per-distro initrds, kexec scripts |
| p2 | ext4 | ubuntu2604 | Ubuntu 26.04 rootfs |
| p3 | ext4 | arch | Arch rootfs |
| p4 | ext4 | cachyos | CachyOS rootfs |

The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 26.04 is the default boot target.

## Building the Kernel Standalone

Use `--kernel-only` to compile the PS5 kernel and produce installable packages without building a full disk image.

```bash
./build_image.sh --kernel-only                                # .deb (default)
./build_image.sh --kernel-only --distro all                   # .deb + .pkg.tar.zst
./build_image.sh --kernel-only --patches-ref main             # fetch from specific branch/tag
./build_image.sh --kernel-only --clean                        # wipe and rebuild from scratch
```

Output packages are written to `linux-bin/`. Install on a running PS5 Linux system:

```bash
sudo dpkg -i linux-bin/linux-ps5_*.deb
```

## Directory Layout

```
build_image.sh                  # Image builder (also supports --kernel-only)
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/          # Repackages .deb kernel as .pkg.tar.zst
  freebsd-image-builder/        # FreeBSD GPT/FAT/UFS image assembler
  freebsd-vm-builder/           # Linux container that runs FreeBSD in QEMU
  image-builder/
    Dockerfile                  # Image building container (distrobuilder)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
scripts/
  build-freebsd-root.sh         # Native FreeBSD buildworld/installworld helper
  build-freebsd-root-qemu.sh    # QEMU-in-Docker FreeBSD build helper
distros/
  ubuntu2604/                   # Ubuntu 26.04 (Resolute)
  arch/                         # Arch Linux
  cachyos/                      # CachyOS repos + Gamescope/Steam
  shared/                       # Kernel postinst hooks (single + multi)
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  freebsd/kenv.txt              # FreeBSD loader kenv for direct handoff
  freebsd/vram.txt              # FreeBSD VRAM size
  vram.txt                      # VRAM allocation
  kexec-{ubuntu2604,arch,cachyos}.sh
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages
output/                         # Final .img files
```
