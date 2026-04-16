#!/usr/bin/env python3
"""QMP-based key spammer using input-send-event.

Maintains a single QMP connection open, repeatedly sends 'ret' (or chosen)
key events to QEMU. Designed to run in parallel with vnc_spam_keys.py to
saturate cdboot's SimpleTextInput poll from two independent input channels.

Usage:
  qmp_spam_keys.py --sock /tmp/winboot/qmp-run.sock --key ret --duration 22 --rate 8
"""
import argparse
import json
import socket
import sys
import time


def recv_until_brace(s):
    buf = b""
    depth = 0
    started = False
    while True:
        b = s.recv(1)
        if not b:
            return buf
        buf += b
        if b == b"{":
            depth += 1
            started = True
        elif b == b"}":
            depth -= 1
            if started and depth == 0:
                return buf


def send(s, obj):
    s.sendall((json.dumps(obj) + "\n").encode())


def recv_response(s, timeout=2.0):
    s.settimeout(timeout)
    try:
        # QMP uses newline-delimited JSON
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return data
    except socket.timeout:
        return b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--key", default="ret",
                    help="QKeyCode name: ret, spc, esc, etc")
    ap.add_argument("--duration", type=float, default=22.0)
    ap.add_argument("--rate", type=float, default=8.0)
    ap.add_argument("--hold-ms", type=int, default=60)
    ap.add_argument("--connect-timeout", type=float, default=10.0)
    args = ap.parse_args()

    # Wait for socket to exist
    deadline = time.time() + args.connect_timeout
    while not _exists(args.sock):
        if time.time() > deadline:
            print(f"[qmp] socket {args.sock} did not appear", file=sys.stderr)
            sys.exit(2)
        time.sleep(0.2)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.sock)
    # Greeting
    _ = recv_response(s, 3.0)
    send(s, {"execute": "qmp_capabilities"})
    _ = recv_response(s, 3.0)

    interval = 1.0 / args.rate
    hold = args.hold_ms / 1000.0
    start = time.time()
    count = 0
    print(f"[qmp] spamming key={args.key} for {args.duration}s at {args.rate}/s",
          file=sys.stderr)
    while time.time() - start < args.duration:
        # Press
        send(s, {
            "execute": "input-send-event",
            "arguments": {"events": [
                {"type": "key", "data": {"down": True,
                                          "key": {"type": "qcode",
                                                  "data": args.key}}}
            ]},
        })
        _ = recv_response(s, 0.5)
        time.sleep(hold)
        # Release
        send(s, {
            "execute": "input-send-event",
            "arguments": {"events": [
                {"type": "key", "data": {"down": False,
                                          "key": {"type": "qcode",
                                                  "data": args.key}}}
            ]},
        })
        _ = recv_response(s, 0.5)
        time.sleep(max(0, interval - hold))
        count += 1
    print(f"[qmp] done, sent {count} key events in {time.time()-start:.1f}s",
          file=sys.stderr)
    s.close()


def _exists(path):
    import os
    return os.path.exists(path)


if __name__ == "__main__":
    main()
