#!/bin/bash
set -e

# Choose which Zig to use:
# System / existing Zig:
# ZIG="/opt/zig/zig-x86_64-linux-0.16.0-dev.747+493ad58ff/zig"
# New Zig dev build:
# ZIG="/home/glen/zig/zig-0.16-dev/zig"
# Default to system Zig if ZIG is not set externally
#: "${ZIG:=/opt/zig/zig-x86_64-linux-0.16.0-dev.747+493ad58ff/zig}"
: "${ZIG:=/home/glen/zig/zig-0.16-dev/zig}"
echo "Using Zig at: $ZIG"
$ZIG version



ROOT=$(dirname "$0")
SRC="$ROOT/src"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

echo "[1/6] Assembling bootloader..."
nasm -f bin "$SRC/boot/boot.asm" -o "$BUILD/boot.bin"

echo "[2/6] Compiling 64-bit Zig kernel..."
$ZIG build-obj "$SRC/kernel/kernel.zig" \
    -target x86_64-freestanding \
    -mcpu=x86_64 \
    -mcmodel=large \
    -O ReleaseSmall \
    -fno-stack-protector \
    -femit-bin="$BUILD/kernel.o"

echo "[2.5/6] Assembling IRQ stubs..."
nasm -f elf64 "$SRC/kernel/interrupts/irq_stubs.asm" -o "$BUILD/irq_stubs.o"

echo "[3/6] Linking 64-bit kernel..."
# Step 1: Link to ELF (keeps entry point info)
ld -m elf_x86_64 -T "$ROOT/linker.ld" -o "$BUILD/kernel.elf" \
    "$BUILD/kernel.o" \
    "$BUILD/irq_stubs.o"


# Step 2: Extract the entry point address
ENTRY_POINT=$(readelf -h "$BUILD/kernel.elf" | grep "Entry point" | awk '{print $4}')
echo "Kernel entry point: $ENTRY_POINT"


# Step 3: Extract binary
objcopy -O binary "$BUILD/kernel.elf" "$BUILD/kernel.bin"

echo "[4/6] Calculating kernel size and generating config..."
KERNEL_SIZE=$(stat -c %s "$BUILD/kernel.bin")
KERNEL_SECTORS=$(( (KERNEL_SIZE + 511) / 512 ))
echo "KERNEL_SECTORS equ $KERNEL_SECTORS" > "$BUILD/kernel_info.inc"
echo "Kernel: $KERNEL_SIZE bytes = $KERNEL_SECTORS sectors"
echo "KERNEL_ENTRY equ $ENTRY_POINT" >> "$BUILD/kernel_info.inc"

echo "[5/6] Assembling stage2 with kernel info..."
nasm -f bin "$SRC/stage2/stage2.asm" -o "$BUILD/stage2.bin"

# Pad stage2 to 1024 bytes (2 sectors)
truncate -s 1024 "$BUILD/stage2.bin"

echo "[6/6] Creating disk image..."
dd if=/dev/zero of="$BUILD/disk.img" bs=512 count=20480 status=none
dd if="$BUILD/boot.bin" of="$BUILD/disk.img" bs=512 count=1 conv=notrunc status=none
dd if="$BUILD/stage2.bin" of="$BUILD/disk.img" bs=512 seek=1 conv=notrunc status=none
dd if="$BUILD/kernel.bin" of="$BUILD/disk.img" bs=512 seek=3 conv=notrunc status=none count=$KERNEL_SECTORS

echo "✅ Build complete."

qemu-system-x86_64 \
  -drive format=raw,file=$BUILD/disk.img \
  -boot order=a \
  -m 1024 \
  -monitor stdio \
  -no-reboot \
  -no-shutdown \
  -D qemu.log \
  -d int,cpu_reset,in_asm \
  -vga std
#qemu-system-x86_64 -drive format=raw,file="$BUILD/disk.img" -no-reboot -monitor stdio
#qemu-system-x86_64 -drive format=raw,file=build/disk.img -no-reboot -d int -monitor stdio
#qemu-system-i386 -cpu qemu64 -drive format=raw,file=build/disk.img -no-reboot -d int -monitor stdio
#qemu-system-i386 -drive format=raw,file="$BUILD/disk.img" -no-reboot -d int -monitor stdio
#qemu-system-i386 -drive format=raw,file="$BUILD/disk.img"
#qemu-system-i386 -s -S -driveformat=raw,file="$BUILD/disk.img"
