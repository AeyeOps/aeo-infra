#!/usr/bin/env bash
# Build a bootable ESP disk with a rewritten BCD for hard-disk boot.
#
# The Windows ISO's BCD is configured for CD-ramdisk boot — bootmgfw
# silently exits when launched from a non-CD context. This script:
#   1. Extracts BCD + bootmgfw + boot.wim + boot.sdi from the ISO
#   2. Rewrites BCD device elements from [boot] (CD) to partition (HD)
#   3. Packs everything into a GPT + FAT32 ESP disk image
#
# The resulting espboot.img can boot WinPE/Setup on ARM64 QEMU without
# cdboot, without input injection, deterministically.
#
# Usage: ./build-esp.sh <windows-iso> <output-esp.img> [work-dir]
set -euo pipefail

ISO="${1:?Usage: $0 <windows-iso> <output-esp.img> [work-dir]}"
OUT="${2:?Usage: $0 <windows-iso> <output-esp.img> [work-dir]}"
WORK="${3:-/tmp/build-esp-$$}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check dependencies
for cmd in 7z hivexsh sgdisk mkfs.fat; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done

echo "=== Building ESP from $ISO ==="
mkdir -p "$WORK/iso-extract"

# 1. Extract boot files from ISO
echo "Extracting boot files from ISO..."
7z e "$ISO" -o"$WORK/iso-extract" \
    efi/boot/bootaa64.efi \
    efi/microsoft/boot/BCD \
    boot/boot.sdi \
    sources/boot.wim \
    -aoa -bso0 -bsp0

# Verify files exist
for f in bootaa64.efi BCD boot.sdi boot.wim; do
    [ -f "$WORK/iso-extract/$f" ] || { echo "Missing from ISO: $f"; exit 1; }
done
echo "  bootaa64.efi: $(wc -c < "$WORK/iso-extract/bootaa64.efi") bytes"
echo "  BCD:          $(wc -c < "$WORK/iso-extract/BCD") bytes"
echo "  boot.sdi:     $(wc -c < "$WORK/iso-extract/boot.sdi") bytes"
echo "  boot.wim:     $(wc -c < "$WORK/iso-extract/boot.wim") bytes"

# 2. Rewrite BCD for hard-disk boot
echo "Rewriting BCD for partition boot..."
cp "$WORK/iso-extract/BCD" "$WORK/bcd-modified"

# Get ESP partition GUID (will be set during disk creation)
ESP_PART_GUID="F5F5F5F5-6A6A-7B7B-8C8C-9D9D9D9D9D9D"
# Encode partition GUID as little-endian bytes for BCD
# F5F5F5F5-6A6A-7B7B-8C8C-9D9D9D9D9D9D
ESP_GUID_LE="f5,f5,f5,f5,6a,6a,7b,7b,8c,8c,9d,9d,9d,9d,9d,9d"

# Disk signature (zeros = match any disk)
DISK_SIG="00,00,00,00,00,00,00,00,a0,a0,a0,a0,b1,b1,c2,c2,d3,d3,e4,e4,e4,e4,e4,e4"

# Build the partition-device binary blob for BCD elements 11000001 and 21000001.
# This encodes: ramdisk options GUID + flags + partition GUID + disk signature + path to boot.wim
# Format matches Windows BCD_DEVICE_PARTITION_DATA structure.
RAMDISK_GUID="c8,dc,19,76,fe,fa,d9,11,b4,11,00,04,76,eb,a2,5f"
BOOT_WIM_PATH="5c,00,73,00,6f,00,75,00,72,00,63,00,65,00,73,00,5c,00,62,00,6f,00,6f,00,74,00,2e,00,77,00,69,00,6d,00,00,00"

DEVICE_BLOB="${RAMDISK_GUID},00,00,00,00,01,00,00,00,a0,00,00,00,00,00,00,00,03,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,01,00,00,00,78,00,00,00,06,00,00,00,06,00,00,00,00,00,00,00,48,00,00,00,00,00,00,00,${ESP_GUID_LE},00,00,00,00,00,00,00,00,${DISK_SIG},00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,${BOOT_WIM_PATH}"

# Ramdisk source element (31000003) — partition reference without the path
RAMDISK_BLOB="00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,06,00,00,00,00,00,00,00,48,00,00,00,00,00,00,00,${ESP_GUID_LE},00,00,00,00,00,00,00,00,${DISK_SIG},00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00"

hivexsh -w "$WORK/bcd-modified" <<HIVEX
cd \\Objects\\{7619dcc9-fafe-11d9-b411-000476eba25f}\\Elements\\11000001
setval 1
Element
hex(3):${DEVICE_BLOB}

cd \\Objects\\{7619dcc9-fafe-11d9-b411-000476eba25f}\\Elements\\21000001
setval 1
Element
hex(3):${DEVICE_BLOB}

cd \\Objects\\{7619dcc8-fafe-11d9-b411-000476eba25f}\\Elements\\31000003
setval 1
Element
hex(3):${RAMDISK_BLOB}

commit $WORK/bcd-modified
HIVEX

echo "  BCD rewritten ($(wc -c < "$WORK/bcd-modified") bytes)"

# 3. Build ESP disk image
echo "Building ESP disk..."
rm -f "$OUT"
truncate -s 2G "$OUT"
sgdisk -Z "$OUT" >/dev/null 2>&1
sgdisk -n 1:2048:+1900M -t 1:EF00 -c 1:ESP \
    -u 1:${ESP_PART_GUID} "$OUT" >/dev/null 2>&1

# Format the ESP partition via losetup
LOOP=$(sudo -n losetup --find --show --offset $((2048*512)) \
    --sizelimit $((1900*1024*1024)) "$OUT")
sudo -n mkfs.fat -F 32 -n ESP "$LOOP" >/dev/null

MNT=$(mktemp -d)
sudo -n mount "$LOOP" "$MNT"

# Populate ESP
sudo -n mkdir -p "$MNT/EFI/BOOT" "$MNT/EFI/Microsoft/Boot" \
    "$MNT/boot" "$MNT/sources"
sudo -n cp "$WORK/iso-extract/bootaa64.efi" "$MNT/EFI/BOOT/BOOTAA64.EFI"
sudo -n cp "$WORK/iso-extract/bootaa64.efi" "$MNT/EFI/BOOT/bootmgfw.efi"
sudo -n cp "$WORK/bcd-modified"             "$MNT/EFI/Microsoft/Boot/BCD"
sudo -n cp "$WORK/iso-extract/boot.sdi"     "$MNT/boot/boot.sdi"
sudo -n cp "$WORK/iso-extract/boot.wim"     "$MNT/sources/boot.wim"

# startup.nsh fallback — if firmware doesn't auto-boot the ESP,
# the embedded UEFI Shell will run this script
sudo -n tee "$MNT/startup.nsh" >/dev/null <<'NSH'
@echo -off
map -r
FS0:\EFI\BOOT\bootmgfw.efi
FS1:\EFI\BOOT\bootmgfw.efi
FS2:\EFI\BOOT\bootmgfw.efi
FS3:\EFI\BOOT\bootmgfw.efi
NSH

sudo -n umount "$MNT"
rmdir "$MNT"
sudo -n losetup -d "$LOOP"

echo ""
echo "=== ESP built: $OUT ==="
echo "  Size: $(du -h "$OUT" | cut -f1)"
echo ""
echo "To test:"
echo "  rm -f build.vars && truncate -s 64M build.vars"
echo "  sudo qemu-system-aarch64 \\"
echo "    -nodefaults -cpu host -enable-kvm \\"
echo "    -machine type=virt,secure=off,gic-version=max,accel=kvm \\"
echo "    -smp 4 -m 8G -display vnc=:2 \\"
echo "    -device ramfb -device qemu-xhci -device usb-kbd \\"
echo "    -device virtio-scsi-pci,id=scsi0 \\"
echo "    -drive file=$OUT,id=disk0,format=raw,if=none \\"
echo "    -device scsi-hd,drive=disk0,bus=scsi0.0 \\"
echo "    -drive file=build.rom,if=pflash,unit=0,format=raw,readonly=on \\"
echo "    -drive file=build.vars,if=pflash,unit=1,format=raw"
echo ""
echo "  VNC: vncviewer localhost:5902"
echo "  Expected: Windows Setup 'Select language settings' within ~30s"
