# PS5 A53 Southbridge Notes

The local `../a53` directory contains reverse-engineering output for the PS5
A53 southbridge firmware. It is useful as hardware reference material, but it
does not contain reusable build scripts or image-builder assets.

## What Matters For This Repo

- Keep the FreeBSD image builder focused on the USB handoff contract:
  `/PS5/FreeBSD/kernel`, `kenv.txt`, `vram.txt`, and a UFS root partition.
- Do not copy `a53.elf`, decompiler output, or firmware-derived binaries into
  generated images.
- The analysis reinforces that early FreeBSD images should keep generic PCI,
  MSI, NVMe, USB input/storage, and platform glue available while PS5-specific
  drivers are developed in the FreeBSD source tree.

## FreeBSD Driver Roadmap

The A53 analysis points to three driver areas that are separate from image
assembly:

| Area | Purpose | FreeBSD implication |
|------|---------|---------------------|
| A53 I/O controller | SSD access through NVMe-like rings over PCIe/shared memory | Future storage driver or NVMe quirk layer |
| SBRAM | Southbridge RAM used for metadata, boot config, and ring buffers | Future memory/block/platform service driver |
| ICC services | Power, boot flags, thermal, buttons, shutdown/reboot | Future platform service driver for proper power control |

Until those drivers exist, the image builder should not assume internal SSD or
southbridge services are available. The current FreeBSD target remains a USB
boot image with direct kernel handoff through `ps5-freebsd-loader`.

## Useful Reference Points

The `../a53` summaries identify these surfaces for later kernel work:

- A53 command/completion rings for I/O and memory-management commands.
- DVM mailbox doorbells for ring head/tail notifications.
- C2PMSG registers for low-level control messages.
- SBRAM as a shared-memory region used by the OS and the A53.
- ICC as the likely path for clean shutdown, reboot, thermal, and front-panel
  integration.

These details belong in FreeBSD kernel drivers, not in this image-build repo's
runtime output.
