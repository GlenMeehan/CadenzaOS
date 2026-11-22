# Accessibility

CadenzaOS is an early research project, and accessibility is not yet well covered. This page says what to expect.

## Current state

- The OS is text-driven. The shell is operated entirely from the keyboard.
- Output is on screen (VGA or framebuffer) and mirrored to serial (COM1, 38400 baud, 8N1). The serial output can be captured or read by assistive tools on a host machine.
- There is no screen reader, no text scaling and no high-contrast mode inside the OS.
- The framebuffer font is fixed at 8x16.

## Documentation and project spaces

- Documentation is written in Markdown with headings and plain-text tables, so it works with screen readers.
- Images and videos should have a text description. The demo video is described in the README.
- If something in the docs, issue templates or the repository is hard for you to use, please open an issue or start a Discussion and I will try to fix it.

## Contributing

Contributions that improve accessibility, such as serial-based interaction, larger or configurable fonts, or colour contrast options, are welcome.
