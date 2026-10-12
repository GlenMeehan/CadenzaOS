#!/bin/bash
# Boot smoke test: boots build/disk.img headless and passes if the shell
# prompt appears on the serial port. Run after: ./build.sh ci
set -u

IMG=build/disk.img
LOG=smoke-serial.log
TIMEOUT=${TIMEOUT:-90}      # seconds; CI runners emulate without hardware acceleration

if [ ! -f "$IMG" ]; then
    echo "FAIL: $IMG not found (run ./build.sh ci first)"
    exit 1
fi

rm -f "$LOG"
qemu-system-x86_64 \
    -drive format=raw,file="$IMG" \
    -m 1024 -display none -monitor none -no-reboot \
    -serial file:"$LOG" &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

for i in $(seq 1 "$TIMEOUT"); do
    if grep -aq 'Cadenza />' "$LOG" 2>/dev/null; then
        echo "PASS: shell prompt reached after ${i}s"
        exit 0
    fi
    if ! kill -0 $QPID 2>/dev/null; then
        echo "FAIL: QEMU exited early (triple fault?)"
        tail -n 30 "$LOG" 2>/dev/null
        exit 1
    fi
    sleep 1
done

echo "FAIL: no shell prompt within ${TIMEOUT}s"
tail -n 30 "$LOG" 2>/dev/null
exit 1
