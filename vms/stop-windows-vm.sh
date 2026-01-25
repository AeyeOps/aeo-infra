#!/bin/bash
# Stop Windows VM gracefully
# Run with sudo: sudo ./stop-windows-vm.sh

PID_FILE="/run/shm/qemu.pid"
MONITOR_PORT="7100"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

if [[ ! -f "$PID_FILE" ]]; then
    echo "Windows VM doesn't appear to be running (no PID file)"
    exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    echo "Windows VM not running (stale PID file)"
    rm -f "$PID_FILE"
    exit 0
fi

echo "Sending ACPI shutdown to Windows VM..."
echo "system_powerdown" | nc -q1 localhost "$MONITOR_PORT" 2>/dev/null || true

echo "Waiting for VM to shut down (max 60s for Windows)..."
for i in {1..60}; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "VM shut down cleanly"
        rm -f "$PID_FILE"
        exit 0
    fi
    sleep 1
done

echo "VM didn't respond, forcing quit..."
echo "quit" | nc -q1 localhost "$MONITOR_PORT" 2>/dev/null || kill "$PID" 2>/dev/null || true

sleep 2
rm -f "$PID_FILE"
echo "Done"
