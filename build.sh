#!/bin/bash
set -e

# --- Configuration ---
#ZIG="/home/glen/zig/zig-0.16-dev/zig"
ZIG="/home/glen/zig/stable-0.16.0/zig"
ROOT=$(dirname "$0")
SRC="$ROOT/src"
BUILD="$ROOT/build"
IMG="$BUILD/disk.img"

# --- Argument Check ---
if [ "$1" == "run" ]; then
    if [ ! -f "$IMG" ]; then
        echo "❌ Error: disk.img not found. Run ./build.sh first."
        exit 1
    fi
    echo "🚀 Just launching QEMU (Existing disk state preserved)..."
    qemu-system-x86_64 \
      -drive format=raw,file=$IMG \
      -m 1024 -monitor stdio -no-reboot -no-shutdown -vga std \
      -serial file:serial.log
    exit 0
fi

if [ "$1" == "clean" ]; then
    echo "🧹 Removing disk image..."
    rm -f "$IMG"
    echo "✅ Disk image removed. Run ./build.sh to create a fresh one."
    exit 0
fi

# --- 1. Clean Phase ---
# Since we are not in 'run' mode, we perform a full rebuild.
# Check if an existing disk image is present and ask the user whether to
# preserve the filesystem or start fresh.
PRESERVE_FS=false
if [ -f "$IMG" ]; then
    echo "💾 Existing disk image found."
    read -p "Preserve filesystem? [Y/n]: " choice
    case "$choice" in
        n|N)
            echo "🧹 Cleaning old disk image..."
            rm -f "$IMG"
            ;;
        *)
            echo "✅ Filesystem will be preserved."
            PRESERVE_FS=true
            ;;
    esac
else
    # No existing image — nothing to clean
    echo "🆕 No existing disk image found. A fresh one will be created."
fi

mkdir -p "$BUILD"

# --- 2. Build Phase ---
echo "[1/6] Assembling bootloader..."
nasm -f bin "$SRC/boot/boot.asm" -o "$BUILD/boot.bin"

echo "[2/6] Compiling 64-bit Zig kernel..."
# Periodically replace -O Debug \ with -Doptimize=ReleaseSafe \ to check for any issue with production
$ZIG build-obj "$SRC/kernel/kernel.zig" \
    -target x86_64-freestanding -mcpu=x86_64 -mcmodel=kernel -fPIC -O Debug \
    -fno-stack-protector -freference-trace=12 -femit-bin="$BUILD/kernel.o"

nasm -f elf64 "$SRC/kernel/interrupts/irq_stubs.asm" -o "$BUILD/irq_stubs.o"
as --64 "$SRC/kernel/arch_utils.s" -o "$BUILD/arch_util.o"

echo "[3/6] Linking..."
ld -m elf_x86_64 -z max-page-size=0x1000 -T "$ROOT/linker.ld" -o "$BUILD/kernel.elf" \
    "$BUILD/kernel.o" "$BUILD/irq_stubs.o" "$BUILD/arch_util.o"

ENTRY_POINT=$(readelf -h "$BUILD/kernel.elf" | grep "Entry point" | awk '{print $4}')
objcopy -O binary "$BUILD/kernel.elf" "$BUILD/kernel.bin"

echo "[4/6] Config..."
KERNEL_SIZE=$(stat -c %s "$BUILD/kernel.bin")
KERNEL_SECTORS=$(( (KERNEL_SIZE + 511) / 512 ))
echo "KERNEL_SECTORS equ $KERNEL_SECTORS" > "$BUILD/kernel_info.inc"
echo "KERNEL_ENTRY equ $ENTRY_POINT" >> "$BUILD/kernel_info.inc"

echo "----------------------------------------"
echo "📏 Kernel Size Report"
echo "Bytes:          $KERNEL_SIZE"
echo "512-byte Sectors: $KERNEL_SECTORS"
echo "ELF Entry:      $ENTRY_POINT"
echo "Kernel written to disk at LBA 3"
echo "----------------------------------------"

echo "[5/6] Stage2..."
nasm -f bin "$SRC/stage2/stage2.asm" -o "$BUILD/stage2.bin"
#truncate -s 4096 "$BUILD/stage2.bin"

# --- 6. Install Phase ---
if [ "$PRESERVE_FS" = false ]; then
    # Create a fresh 10MB disk image
    echo "🆕 Creating new 10MB disk image..."
    dd if=/dev/zero of="$IMG" bs=512 count=20480 status=none
fi

echo "💾 Writing OS sectors..."
# We use conv=notrunc so dd doesn't wipe the rest of the 10MB image.
# When preserving the filesystem, only the boot/stage2/kernel sectors
# (0..2047) are overwritten — the CodaFS partition (2048+) is untouched.
dd if="$BUILD/boot.bin" of="$IMG" bs=512 count=1 conv=notrunc status=none
dd if="$BUILD/stage2.bin" of="$IMG" bs=512 seek=1 conv=notrunc status=none
dd if="$BUILD/kernel.bin" of="$IMG" bs=512 seek=16 conv=notrunc status=none

# -------------------------------------------------------------------------
#  APPLICATION BINARY STORE STAGING
# -------------------------------------------------------------------------
APPS_DIR="$BUILD/apps"
if [ -f "$APPS_DIR/prog1.bin" ]; then
    echo "📦 Staging prog1.bin into disk image at LBA 1024..."
    dd if="$APPS_DIR/prog1.bin" of="$IMG" bs=512 seek=2000 conv=notrunc status=none
else
    echo "⚠️ Warning: prog1.bin not found in $APPS_DIR, skipping binary store injection."
fi
# -------------------------------------------------------------------------

echo "✅ Build & Update complete."

# Launch QEMU automatically after build
qemu-system-x86_64 \
      -drive format=raw,file=$IMG,cache=directsync,snapshot=off \
      -m 1024 -monitor stdio -no-reboot -no-shutdown -vga std \
      -d int,cpu_reset -D qemu.log \
      -serial file:serial.log

#sudo qemu-system-x86_64 \
    #-device usb-ehci,id=ehci \
    #-drive format=raw,file=/dev/sdb

