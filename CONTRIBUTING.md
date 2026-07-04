# Contributing to CadenzaOS

Thank you for your interest in contributing to CadenzaOS. This document
explains how to get set up, how to submit contributions, and what we expect
from pull requests.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Build Requirements](#build-requirements)
3. [Branch Policy](#branch-policy)
4. [Submitting a Pull Request](#submitting-a-pull-request)
5. [Commit Sign-Off (DCO)](#commit-sign-off-dco)
6. [Coding Style](#coding-style)
7. [Reporting Bugs](#reporting-bugs)
8. [Suggesting Features](#suggesting-features)
9. [Good First Issues](#good-first-issues)
10. [Code of Conduct](#code-of-conduct)

---

## Getting Started

Clone the repository and build the project:

```bash
git clone https://github.com/<your-username>/cadenzaos.git
cd cadenzaos
./build.sh
```

This will assemble the bootloader, compile the kernel, link everything, create
a 10MB disk image, and launch QEMU automatically.

To run an existing disk image without rebuilding:
```bash
./build.sh run
```

To wipe the disk image and start fresh:
```bash
./build.sh clean
./build.sh
```

---

## Build Requirements

You will need the following tools installed:

| Tool | Version | Purpose |
|------|---------|---------|
| Zig | **0.16.0 exactly** | Kernel compilation |
| NASM | Any recent | Bootloader assembly |
| GNU as | Any recent | arch_utils assembly |
| GNU ld | Any recent | Kernel linking |
| QEMU | 6.0+ | Testing |
| dd, objcopy | Standard | Image creation |

**Important:** CadenzaOS is built with Zig 0.16.0 specifically. Zig has
breaking changes between releases — other versions are not supported and will
likely fail to compile.

The stable Zig 0.16.0 binary can be downloaded from:
https://ziglang.org/download/

---

## Branch Policy

- `main` — always stable and bootable. Never commit directly to `main`.
- `dev` — active development target. Submit all Pull Requests here.

The Project Lead merges `dev` into `main` when a set of features is stable
and tested. If you are working on a larger feature, create a feature branch
from `dev`:

```bash
git checkout dev
git pull
git checkout -b feature/your-feature-name
```

---

## Submitting a Pull Request

1. **Fork** the repository and create your branch from `dev`.
2. **Make your changes** — keep commits focused and atomic. One logical change
   per commit is strongly preferred over large, sprawling commits.
3. **Test your changes** — at minimum, confirm the OS boots in QEMU and the
   shell functions correctly after your change. If your change touches the
   scheduler, memory management, or filesystem, run a more thorough session
   (spawn tasks, create/delete files, check persistence across reboots).
4. **Sign off** your commits — see [Commit Sign-Off](#commit-sign-off-dco).
5. **Open a PR** targeting the `dev` branch with:
   - A clear title describing what the PR does.
   - A description explaining *why* the change is needed and *how* it works.
   - Evidence of testing (QEMU output, qemu.log if relevant).
   - References to any related issues.

PRs that touch the following areas require extra care and will receive closer
review:
- Bootloader (`src/boot/`, `src/stage2/`)
- Scheduler (`src/kernel/scheduler.zig`)
- Memory management (`src/kernel/bitmap.zig`, `src/kernel/memory.zig`)
- Filesystem (`src/kernel/fs/`)
- Syscall interface (`int $0x80` dispatch in `scheduler.zig`)

For significant architectural changes (new subsystem, syscall ABI change,
filesystem format change), please open an issue for discussion *before*
writing code. This avoids wasted effort if the direction doesn't align with
the roadmap.

---

## Commit Sign-Off (DCO)

Every commit must be signed off using the Linux Foundation Developer
Certificate of Origin (DCO v1.1). Add the following line to the end of your
commit message:

```
Signed-off-by: Your Name <your@email.com>
```

By adding this line you certify that:

- The contribution was created in whole or in part by you, and you have the
  right to submit it under the Apache 2.0 license; or
- The contribution is based upon previous work that is covered under an
  appropriate open source license; or
- The contribution was provided directly to you by some other person who made
  one of the above certifications.

You can add the sign-off automatically with:
```bash
git commit -s -m "your commit message"
```

PRs containing unsigned commits will be asked to resubmit before merging.

---

## Coding Style

CadenzaOS is written in Zig. Follow these conventions:

- **Formatting:** Run `zig fmt` on any Zig files you modify before committing.
- **Naming:** `snake_case` for variables and functions, `PascalCase` for
  types and structs — consistent with the existing codebase.
- **Comments:** Explain *why*, not *what*. The code shows what; comments
  should explain reasoning, constraints, and non-obvious decisions.
- **Error handling:** Never silently swallow errors with bare `catch {}` in
  new code unless you have a specific, documented reason. Prefer explicit
  error propagation or at minimum a logged failure.
- **Memory:** Use `cmd_fba` (reset per shell command) for temporary filesystem
  allocations in shell commands. Do not use `g_allocator` for repeated or
  interleaved allocations — see the architecture notes in `ARCHITECTURE.md`
  (coming soon) for the full allocator policy.
- **Hardware access:** All hardware interaction (VGA, ATA, keyboard, timer)
  must go through the existing driver modules. Do not write directly to
  hardware registers from non-driver code.
- **Syscalls:** New syscalls must be added to the `int $0x80` dispatch in
  `scheduler.zig` with a clear `rax` number, documented here and in the
  wiki syscall reference.

For assembly files (NASM/GAS), follow the style of the existing stubs in
`src/kernel/interrupts/irq_stubs.asm` — clear section labels, comments on
non-obvious register usage, and consistent indentation.

---

## Reporting Bugs

Use the GitHub issue tracker. Please include:

- **QEMU version** (`qemu-system-x86_64 --version`)
- **Zig version** (`zig version`)
- **Exact reproduction steps** — what commands did you type in the shell?
- **Expected behaviour** vs **actual behaviour**
- **`qemu.log` output** — run with `-d int,cpu_reset -D qemu.log` and paste
  the relevant tail of the log
- **Whether it's reproducible** — always, intermittent, or one-off?

For crashes or triple faults, also paste the output of:
```bash
objdump -d build/kernel.elf | grep -B5 "<fault_address_low_bits>"
```

---

## Suggesting Features

Open a GitHub issue with the label `enhancement`. Describe:

- What you want to add and why it fits the project's goals
- How you imagine it working at a high level
- Whether you're willing to implement it yourself or are requesting it

For large features (new filesystem, networking, graphics mode, ring 3
separation), a discussion issue is strongly preferred before any code is
written — these touch multiple subsystems and need architectural alignment
with the roadmap before implementation begins.

---

## Good First Issues

If you're new to the project or to OS development, look for issues tagged
`good first issue` on the tracker. These are intentionally scoped to not
require deep knowledge of the scheduler or memory subsystems. Examples of
the kind of thing that qualifies:

- New shell commands (using existing filesystem/VGA APIs)
- Documentation improvements
- Additional filesystem utilities
- New external binary programs (using the existing syscall interface)
- Build system improvements

---

## Code of Conduct

All contributors are expected to follow the CadenzaOS Code of Conduct. See
`CODE_OF_CONDUCT.md` for the full text. Be kind, be constructive, and
remember that everyone was a beginner once.
