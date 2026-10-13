# Dependencies

Cadenza builds on Linux. Building and running need the tools below. The OS
itself has no runtime dependencies: only the build and the emulator do.

`./build.sh` builds everything, including the `prog1` demo program from
`userland/prog1/`, so there is no separate program build step.

## Required

| Tool | Version | Used for |
|---|---|---|
| [Zig](https://ziglang.org/download/) | **0.16.0** | kernel and program compilation |
| nasm | tested with 3.02 | bootloader, stage 2, interrupt stubs |
| GNU binutils (`as`, `ld`, `objcopy`, `readelf`) | tested with 2.46.1 | assembling, linking, flat binary, layout checks |
| QEMU (`qemu-system-x86_64`) | tested with 10.2.2 | running the image |
| git | any | build metadata (hash, dirty flag) |
| coreutils, `sed`, `awk`, `dd` | any | build script |

Zig is not packaged consistently by distributions. Download 0.16.0 from
ziglang.org, unpack it anywhere, and either put it on your `PATH` or point
the build at it:

    export ZIG=/path/to/zig-0.16.0/zig

## Optional (debugging)

| Tool | Used for |
|---|---|
| gdb | resolving fault addresses (`info symbol <addr>`) |
| xxd | inspecting the disk image and program headers |

## Install

Fedora:

    sudo dnf install nasm binutils qemu-system-x86 git gdb vim-common

Ubuntu / Debian:

    sudo apt install nasm binutils qemu-system-x86 git gdb xxd

## Verify

    zig version          # 0.16.0
    NASM version 3.02 compiled on Jul 14 2026
    ld --version | head -n 1
    qemu-system-x86_64 --version | head -n 1

Then build and boot:

    ./build.sh

You should see the splash screen followed by a `Cadenza />` prompt.

## Continuous integration

Every push is built from a clean checkout on Ubuntu 24.04 and booted headless
in QEMU, and passes if the shell prompt appears on the serial port. See
`.github/workflows/smoke.yml` and `tests/smoke.sh`. To run the same check
locally:

    ./build.sh ci && ./tests/smoke.sh

## Real hardware (optional)

Cadenza has been run on a Dell OptiPlex 3020 (legacy BIOS). Writing the image
to a disk replaces its contents, so check the device name carefully:

    lsblk
    sudo dd if=build/disk.img of=/dev/sdX bs=4M conv=fsync
