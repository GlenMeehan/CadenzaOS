---
name: Bug Report
about: Report a bug or unexpected behaviour in CadenzaOS
title: '[BUG] '
labels: bug
assignees: ''
---

## Description
A clear and concise description of what the bug is.

## Environment
- **Zig version:** (run `zig version`)
- **QEMU version:** (run `qemu-system-x86_64 --version`)
- **Host OS:** (e.g. Fedora 39, Ubuntu 22.04)
- **Running on:** [ ] QEMU  [ ] Real hardware (specify machine/motherboard)

## Reproduction Steps
Exact sequence of shell commands that triggers the bug:
```
1. Boot CadenzaOS
2. Type: ...
3. Type: ...
4. ...
```

## Expected Behaviour
What you expected to happen.

## Actual Behaviour
What actually happened. Include any error messages printed to the VGA screen verbatim.

## qemu.log Output
If running in QEMU, paste the relevant tail of `qemu.log` (run QEMU with
`-d int,cpu_reset -D qemu.log` and reproduce the bug, then run
`tail -n 100 qemu.log`):

```
paste qemu.log output here
```

## Kernel Symbol (if applicable)
If you have a fault address, paste the objdump output:
```bash
objdump -d build/kernel.elf | grep -B5 "<fault_address_low_bits>"
```

```
paste objdump output here
```

## Is this reproducible?
[ ] Always  [ ] Intermittent (roughly how often?)  [ ] Happened once

## Additional Context
Any other information that might be relevant — e.g. does it only happen
after certain commands, after a specific number of spawned tasks, on a
fresh disk image vs preserved filesystem, etc.
