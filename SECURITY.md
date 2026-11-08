# Security Policy

CadenzaOS is an early research project: a hobby 64-bit x86-64 operating system.
Please read the status section of the README before relying on it.

## Supported versions

Only the latest release and the `dev` branch are supported. Fixes are made on
`dev` and shipped in the next release; older releases are not patched.

| Version | Supported |
|---|---|
| 0.6.x (latest) | ✅ |
| `dev` branch | ✅ |
| 0.5.x and earlier | ❌ |

## Known limitations (not vulnerabilities)

Everything currently runs in ring 0 with no memory protection, so a program can
read and overwrite kernel memory. This is documented and by design until
privilege separation (ring 3, per-process page tables) is built. A report that
only demonstrates this is not treated as a vulnerability.

## What is in scope

- Kernel code that handles untrusted input: syscall arguments (for example,
  pointer and length validation), the program header (`CDZP`) and bundle
  (`CDZB`) parsers, and the CodaFS on-disk structures.
- The build scripts and GitHub Actions workflows.

## Reporting a vulnerability

Please report privately, not in a public issue or pull request: open the
**Security and quality** tab of this repository, go to **Advisories**, and
choose **Report a vulnerability**.

Include the version or commit, how you ran it (QEMU or real hardware), the
steps to reproduce, and what you think the impact is.

## What to expect

CadenzaOS is maintained by one person. You can expect an acknowledgement within
7 days, and an update when there is something to report. I will tell you whether
the report is accepted or declined and why. Accepted reports are fixed on `dev`
first, and reporters are credited in the release notes unless they prefer not to
be.
