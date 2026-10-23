#!/bin/bash
# Smoke test for CadenzaOS. Run after: ./build.sh ci
#
# Stage 1: boot build/disk.img headless and wait for the shell prompt on serial.
# Stage 2: type commands through the QEMU monitor (sendkey) and check the output
#          on serial: program arguments, file create/delete, and that the system
#          is still alive afterwards.
#
# Uses bash's /dev/tcp for the monitor connection, so it needs no extra tools.
set -u

IMG=build/disk.img
LOG=smoke-serial.log
TIMEOUT=${TIMEOUT:-90}          # seconds to reach the shell (CI has no hardware acceleration)
CMD_TIMEOUT=${CMD_TIMEOUT:-30}  # seconds to wait for each command's output
MONPORT=${MONPORT:-45454}

FAILS=0
QPID=""
DPID=""

cleanup() {
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    FAILS=$((FAILS + 1))
}

finish() {
    if [ "$FAILS" -eq 0 ]; then
        echo "ALL CHECKS PASSED"
        exit 0
    fi
    echo "--- last lines of $LOG ---"
    tail -n 30 "$LOG" 2>/dev/null
    exit 1
}

# wait_for <pattern> <seconds>: 0 = found, 1 = timed out, 2 = QEMU exited
wait_for() {
    local i
    for i in $(seq 1 "$2"); do
        grep -aq -- "$1" "$LOG" 2>/dev/null && return 0
        kill -0 "$QPID" 2>/dev/null || return 2
        sleep 1
    done
    return 1
}

# check <description> <pattern> <seconds>
check() {
    wait_for "$2" "$3"
    case $? in
        0) echo "PASS: $1" ;;
        2) fail "$1 (QEMU exited early: triple fault?)"; finish ;;
        *) fail "$1 (no '$2' within ${3}s)" ;;
    esac
}

press() {
    echo "sendkey $1" >&3
    sleep 0.2
}

# type_line <text>: types letters, digits and spaces, then presses Enter
type_line() {
    local s="$1" i c k
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        if [ "$c" = " " ]; then k=spc; else k="$c"; fi
        press "$k"
    done
    press ret
}

if [ ! -f "$IMG" ]; then
    echo "FAIL: $IMG not found (run ./build.sh ci first)"
    exit 1
fi

rm -f "$LOG"
qemu-system-x86_64 \
    -drive format=raw,file="$IMG" \
    -m 1024 -display none -no-reboot \
    -monitor tcp:127.0.0.1:"$MONPORT",server,nowait \
    -serial file:"$LOG" &
QPID=$!

# ---- Stage 1: boot to the shell prompt ----
wait_for 'Cadenza />' "$TIMEOUT"
case $? in
    0) echo "PASS: shell prompt reached" ;;
    2) fail "QEMU exited early (triple fault?)"; finish ;;
    *) fail "no shell prompt within ${TIMEOUT}s"; finish ;;
esac

# ---- Stage 2: connect to the monitor and type commands ----
CONNECTED=0
for i in $(seq 1 20); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$MONPORT") 2>/dev/null; then CONNECTED=1; break; fi
    sleep 0.5
done
if [ "$CONNECTED" -ne 1 ]; then
    fail "could not connect to the QEMU monitor on port $MONPORT"
    finish
fi
exec 3<>/dev/tcp/127.0.0.1/"$MONPORT"
cat <&3 >/dev/null &      # drain monitor output so QEMU never blocks writing to us
DPID=$!

sleep 1                   # let the shell settle at its prompt

type_line "spawn prog1 hello"
check "spawn passes arguments" "arg: hello" "$CMD_TIMEOUT"
type_line "spawn hello"
check "second program installed and runs" "Hello from hello!" "$CMD_TIMEOUT"

type_line "touch smokef"
sleep 2

# check_absent <description> <pattern> <byte-offset>
# Passes if the pattern does NOT appear in the log after the given offset.
# Take the offset with: mark=$(stat -c %s "$LOG")
check_absent() {
    if tail -c +"$(( $3 + 1 ))" "$LOG" | grep -aq -- "$2"; then
        fail "$1 ('$2' found after the marker)"
    else
        echo "PASS: $1"
    fi
}


type_line "del smokef"
check "del asks for confirmation" "SAFETY" "$CMD_TIMEOUT"
press y
press ret
check "del removes the file" "File deleted successfully" "$CMD_TIMEOUT"

# A foreground program that reads the keyboard through the read and yield
# syscalls: wait until it announces itself, type a word, expect it back.
type_line "spawn kbecho"
check "read-test program started" "kbecho ready" "$CMD_TIMEOUT"
type_line "abc"
check "read syscall delivers typed input" "got: abc" "$CMD_TIMEOUT"

type_line "spawn prog1 again"
check "system still runs programs after del" "arg: again" "$CMD_TIMEOUT"

# Directory entries beyond the first block. The root directory holds about
# five entries per block and prog1, hello and kbecho already use three, so
# by f4 the entries are in the second block. mv with a relative name used
# to search only the first block and report FileNotFound.
# NOTE: needs a fresh image (./build.sh ci), because it creates "d".
type_line "mkdir d"
check "mkdir creates a directory" "Directory created successfully" "$CMD_TIMEOUT"
type_line "touch f1"
sleep 2
type_line "touch f2"
sleep 2
type_line "touch f3"
sleep 2
type_line "touch f4"
sleep 2
type_line "mv f4 d"
check "mv finds a file in the second directory block" "Move successful!" "$CMD_TIMEOUT"
type_line "ls d"
check "moved file is listed in the new directory" "\[FILE\] f4" "$CMD_TIMEOUT"

# A move, not a copy: the root listing must no longer contain f4. Only the
# output after the marker counts (the "ls d" output above also shows f4).
mark=$(stat -c %s "$LOG")
type_line "ls"
check "root listing shows the remaining files" "\[FILE\] f3" "$CMD_TIMEOUT"
sleep 2
check_absent "moved file is gone from the root" "\[FILE\] f4" "$mark"

finish
