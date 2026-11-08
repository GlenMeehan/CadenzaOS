# Running CadenzaOS on real hardware

CadenzaOS has been tested on **one** real machine. Treat QEMU as the supported way to run it, and read this page before writing anything to a physical disk.

## Tested hardware

| Item | Value |
|---|---|
| Machine | Dell OptiPlex 3020 |
| RAM | 8 GB |
| Boot mode | Legacy BIOS (not UEFI) |
| Storage | Internal SATA SSD, controller in **ATA/IDE mode** |
| Result | Boots to the shell. Keyboard input is doubled (see Known problems). |

Other machines may fail in ways not described here.

## BIOS settings

- **Boot mode:** legacy BIOS. UEFI is not supported.
- **SATA operation:** **ATA/IDE, not AHCI.** In AHCI mode the controller is a different PCI class and the ATA driver will not find it.

The kernel reads the IDE controller's ports from PCI when the controller is in native mode, and otherwise uses the legacy ports `0x1F0`/`0x3F6`. At boot it prints the ports it chose, for example `ATA cmd=...F110 ctl=...F102`.

## Building the image
