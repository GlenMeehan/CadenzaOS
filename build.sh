#!/bin/bash
#
# Cadenza OS build script.
#
# Assumes a GNU/Linux toolchain: stat -c %s is GNU syntax (BSD uses stat -f),
# and the script relies on readelf, objcopy, as, ld and nasm.
#
# Usage:
#   ./build.sh         full build (asks whether to preserve the filesystem), then runs QEMU
#   ./build.sh run     launch QEMU on the existing disk image
#   ./build.sh clean   remove the disk image
#   ./build.sh ci       ci smoke test
set -e

# --- Configuration ---
ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1; then
    echo "❌ Zig not found. Install Zig 0.16 or set ZIG=/path/to/zig"
    exit 1
fi
ROOT=$(dirname "$0")
SRC="$ROOT/src"
BUILD="$ROOT/build"
IMG="$BUILD/disk.img"

# --- Disk layout (sectors) ---
KERNEL_LBA=16        # kernel written here
PARTITION_LBA=4096   # CodaFS partition starts here (PARTITION_START_LBA in config.zig)

# APP_LBA_START lives in config.zig and is also used by binary_loader.zig,
# so read it from there instead of keeping a second copy.
# (POSIX sed, so this works without GNU grep.)
APP_LBA=$(sed -n 's/.*APP_LBA_START: u64 = \([0-9][0-9]*\).*/\1/p' "$SRC/kernel/config.zig" | head -n 1)
if [ -z "$APP_LBA" ]; then
    echo "❌ ERROR: could not read APP_LBA_START from config.zig"
    exit 1
fi

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

# CI mode: always start from a fresh image, never ask questions
if [ "$1" == "ci" ]; then rm -f "$IMG"; fi

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

# --- Git / build metadata ---
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    GIT_DIRTY="dirty"
else
    GIT_DIRTY="clean"
fi
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Convert dirty/clean into a Zig boolean
if [ "$GIT_DIRTY" = "dirty" ]; then
    GIT_DIRTY_BOOL=true
else
    GIT_DIRTY_BOOL=false
fi

# --- Generate version.zig ---
cat > "$SRC/kernel/version.zig" <<EOF
pub const git_hash: []const u8 = "$GIT_HASH";
pub const git_dirty: bool = $GIT_DIRTY_BOOL;
pub const build_ts: []const u8 = "$BUILD_TS";
EOF

echo "[2/6] Compiling kernel..."
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

# The kernel starts at KERNEL_LBA and must not run into the app staging area,
# which in turn sits below the CodaFS partition.
KERNEL_MAX_SECTORS=$(( APP_LBA - KERNEL_LBA ))
if [ "$KERNEL_SECTORS" -gt "$KERNEL_MAX_SECTORS" ]; then
    echo "❌ ERROR: Kernel ($KERNEL_SECTORS sectors) would overwrite the app staging area at sector $APP_LBA (max $KERNEL_MAX_SECTORS)!"
    exit 1
fi

# --- Derive BSS physical address + size from the real, current ELF layout ---
# (readelf -W keeps each LOAD entry on one line, avoiding the wrapped output
#  of plain `readelf -l`)
BSS_LINE=$(readelf -W -l "$BUILD/kernel.elf" | awk '/^ *LOAD/{print}' | sed -n '2p')
BSS_PHYS=$(echo "$BSS_LINE" | awk '{print $4}')
BSS_MEMSIZE=$(echo "$BSS_LINE" | awk '{print $6}')
BSS_SIZE_DWORDS=$(( (BSS_MEMSIZE + 3) / 4 ))

echo "BSS_PHYS equ $BSS_PHYS" >> "$BUILD/kernel_info.inc"
echo "BSS_SIZE_DWORDS equ $BSS_SIZE_DWORDS" >> "$BUILD/kernel_info.inc"

echo "----------------------------------------"
echo "📏 Kernel Size Report"
echo "Bytes:          $KERNEL_SIZE"
echo "512-byte Sectors: $KERNEL_SECTORS (max $KERNEL_MAX_SECTORS)"
echo "ELF Entry:      $ENTRY_POINT"
echo "Kernel written to disk at LBA $KERNEL_LBA"
echo "----------------------------------------"

echo "[5/6] Stage2..."
nasm -f bin "$SRC/stage2/stage2.asm" -o "$BUILD/stage2.bin"

# --- 6. Install Phase ---
if [ "$PRESERVE_FS" = false ]; then
    # Create a fresh 10MB disk image
    echo "🆕 Creating new 10MB disk image..."
    dd if=/dev/zero of="$IMG" bs=512 count=20480 status=none
fi

echo "💾 Writing OS sectors..."
# We use conv=notrunc so dd doesn't wipe the rest of the 10MB image.
# When preserving the filesystem, only the boot, stage2, kernel and app staging
# sectors (below sector $PARTITION_LBA) are overwritten — the CodaFS partition
# ($PARTITION_LBA onwards) is untouched.
dd if="$BUILD/boot.bin" of="$IMG" bs=512 count=1 conv=notrunc status=none
dd if="$BUILD/stage2.bin" of="$IMG" bs=512 seek=1 conv=notrunc status=none
dd if="$BUILD/kernel.bin" of="$IMG" bs=512 seek=$KERNEL_LBA conv=notrunc status=none

# -------------------------------------------------------------------------
#  USERLAND: build prog1 from source, then stage it into the disk image
# -------------------------------------------------------------------------
APPS_DIR="$BUILD/apps"
mkdir -p "$APPS_DIR"

echo "[prog1] Building userland program..."
$ZIG build-exe "$ROOT/userland/prog1/prog1.zig" \
    -target x86_64-freestanding \
    -O ReleaseSmall \
    -fstrip \
    -T "$ROOT/userland/prog1/linker.ld" \
    --name "prog1.elf"

# build-exe leaves the ELF in the current directory, as env.sh did
mv prog1.elf "$APPS_DIR/prog1.elf"
$ZIG objcopy -O binary "$APPS_DIR/prog1.elf" "$APPS_DIR/prog1.bin"

# Sanity check: the program header magic must be present ("CDZP")
if [ "$(head -c 4 "$APPS_DIR/prog1.bin")" != "CDZP" ]; then
    echo "❌ ERROR: prog1.bin has no valid header (linker script or header block broken)"
    exit 1
fi

echo "📦 Staging prog1.bin into disk image at LBA $APP_LBA..."
dd if="$APPS_DIR/prog1.bin" of="$IMG" bs=512 seek=$APP_LBA conv=notrunc status=none
# -------------------------------------------------------------------------

echo "✅ Build & Update complete."

# CI mode: stop here, don't launch QEMU (the smoke test does that)
if [ "$1" == "ci" ]; then exit 0; fi

# Launch QEMU automatically after build
qemu-system-x86_64 \
      -drive format=raw,file=$IMG,cache=directsync,snapshot=off \
      -m 1024 -monitor stdio -no-reboot -no-shutdown -vga std \
      -d int,cpu_reset -D qemu.log \
      -serial file:serial.log

#sudo qemu-system-x86_64 \
    #-device usb-ehci,id=ehci \
    #-drive format=raw,file=/dev/sdb

