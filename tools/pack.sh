#!/bin/bash
# Pack program images into one bundle for the raw app staging area.
#
# Usage: tools/pack.sh <out-file> <max-sectors> <prog.bin> [<prog.bin> ...]
#
# Bundle format (version 1, little-endian), see src/kernel/bundlefmt.zig:
#   sector 0:  16-byte header, then up to 12 entries of 40 bytes each
#                header: magic "CDZB" (u32), version (u16), count (u16),
#                        total_sectors (u32), reserved (u32)
#                entry:  name (32 bytes, NUL padded), offset_sectors (u32),
#                        size_bytes (u32)
#   sector 1+: the program images, each starting on a sector boundary and
#              padded with zeros to a whole sector
#
# The program name is the file name without ".bin".
set -e

die() { echo "pack.sh: $1" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: pack.sh <out-file> <max-sectors> <prog.bin> [...]"
OUT="$1"
MAX="$2"
shift 2

SECTOR=512
NAMELEN=32
MAXENT=12

[ $# -le $MAXENT ] || die "too many programs ($# > $MAXENT)"

le16() { local v=$1; printf "$(printf '\\x%02x\\x%02x' $((v & 255)) $(((v >> 8) & 255)))"; }
le32() { local v=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255)))"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/table"

COUNT=$#
OFF=1                      # sector 0 holds the header and table; programs start at sector 1
for f in "$@"; do
    [ -f "$f" ] || die "not a file: $f"
    name=$(basename "$f" .bin)
    [ ${#name} -ge 1 ] && [ ${#name} -le $((NAMELEN - 1)) ] || die "bad program name length: $name"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "program name has unsupported characters: $name"
    size=$(stat -c %s "$f")
    [ "$size" -ge 16 ] || die "$f is too small to be a program"
    secs=$(( (size + SECTOR - 1) / SECTOR ))
    {
        printf '%s' "$name"
        head -c $((NAMELEN - ${#name})) /dev/zero
        le32 $OFF
        le32 "$size"
    } >> "$TMP/table"
    OFF=$((OFF + secs))
done
TOTAL=$OFF
[ "$TOTAL" -le "$MAX" ] || die "bundle needs $TOTAL sectors but the staging area holds $MAX"

{
    le32 $((0x425A4443))   # magic bytes 'C','D','Z','B'
    le16 1                 # version
    le16 "$COUNT"
    le32 "$TOTAL"
    le32 0                 # reserved
    cat "$TMP/table"
} > "$TMP/sector0"
truncate -s $SECTOR "$TMP/sector0"

cat "$TMP/sector0" > "$OUT"
for f in "$@"; do
    size=$(stat -c %s "$f")
    cat "$f" >> "$OUT"
    pad=$(( (SECTOR - size % SECTOR) % SECTOR ))
    [ "$pad" -eq 0 ] || head -c "$pad" /dev/zero >> "$OUT"
done

echo "pack.sh: $COUNT program(s), $TOTAL sectors -> $OUT"
