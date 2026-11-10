# Running CadenzaOS on real hardware

CadenzaOS has been tested on **one** real machine. Treat QEMU as the supported way to run it, and read this page before writing anything to a physical disk.

## Tested hardware

| Item | Value |
|---|---|
| Machine | Dell OptiPlex 3020 |
| RAM | 8 GB |
| Boot mode | Legacy BIOS (not UEFI) |
| Storage | Internal SATA SSD, controller in **ATA/IDE mode** |
| Result | Boots to the shell |

Other machines may fail in ways not described here.

## BIOS settings

- **Boot mode:** legacy BIOS. UEFI is not supported.
- **SATA operation:** **ATA/IDE, not AHCI.** In AHCI mode the controller is a different PCI class and the ATA driver will not find it.

The kernel reads the IDE controller's ports from PCI when the controller is in native mode, and otherwise uses the legacy ports `0x1F0`/`0x3F6`. At boot it prints the ports it chose, for example `ATA cmd=...F110 ctl=...F102`.

## Building the image

./build.sh ci


This produces `build/disk.img` (10 MB). Always rebuild immediately before copying, because a stale image is easy to flash by mistake.

## Writing the image to a disk

**Warning: `dd` overwrites the target disk completely and without asking. If you name the wrong device you will destroy its contents. Check the device with `lsblk` first, and consider unplugging any disk you care about.**

The image is written to the start of the disk the machine boots from. One way to do this on a machine with no network is to boot a Linux live USB (for example Ventoy) on the target, with `disk.img` on the USB stick:

lsblk
sudo mount <usb data partition> /mnt
sudo dd if=/mnt/disk.img of=/dev/sdX bs=4M conv=fsync status=progress
sudo cmp -n 10485760 /dev/sdX /mnt/disk.img


Replace `sdX` with the target disk and `<usb data partition>` with the stick's data partition. These paths vary between machines.

`cmp` should print nothing. If it prints "differ", write the image again. Then **power the machine off completely** before booting it, since a warm reboot has been unreliable for testing.

## Serial debugging

Serial output is the most reliable way to see what the kernel is doing, since the screen output of a failing boot is not always readable.

- Connect a null-modem cable between the target's COM1 and a second machine.
- Settings: **38400 baud, 8N1.** Both stage 2 and the kernel use this.
- On the capturing machine (general command, adjust the device name):

sudo cat /dev/ttyS0 | sudo tee dell-serial.log


Start the capture before powering the target on, and give each run its own file name, because `tee` overwrites an existing file.

### What a good boot looks like

SA...13TK
CP1: fb.init done
CP2: splash.init done
ATA cmd=... ctl=...
STATUS: Filesystem is healthy.
CP5: disk/filesystem check done
CP3: bitmap init done
CP4: APIC mapped
AROCP6: about to call shell.run()
Cadenza />


The first line is stage 2's progress markers. The dots are kernel read chunks on builds that print them.

### Reading failures

| What you see | Likely meaning |
|---|---|
| Nothing at all, or a reboot loop | Stage 2 failed before the kernel ran. |
| `Error: Could not read MBR`, then a panic with `IoError` | The ATA driver did not find the disk. Check that SATA is in ATA/IDE mode. |
| Panic with "Bitmap storage too small" | Old build. Fixed in 0.7.0. |

## Known problems

- The uptime counter runs very slowly (the LAPIC timer is not calibrated).
- Only legacy BIOS boot and IDE mode are supported. There is no AHCI or UEFI support.
- Only one machine has been tested.
- The kernel manages only the first 1 GiB of RAM, and stage 2 maps only the first 64 MiB.
- `writeBlocks` has its own busy loop with no timeout.

If you try another machine, a serial capture of the boot is the most useful thing to include in a bug report.
