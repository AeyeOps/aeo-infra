#!/usr/bin/env python3
"""Single-connection key spammer — maintains one RFB connection, sends keys
repeatedly over a duration window. Good for racing against time-sensitive
boot prompts like cdboot's 'Press any key'.

Usage:
  vnc_spam_keys.py --port 5902 --key Space --duration 20 --rate 5
"""
import argparse
import socket
import struct
import sys
import time

KEYSYMS = {
    "Return": 0xFF0D, "Enter": 0xFF0D, "Tab": 0xFF09, "Backspace": 0xFF08,
    "Escape": 0xFF1B, "Up": 0xFF52, "Down": 0xFF54, "Left": 0xFF51, "Right": 0xFF53,
    "Space": 0x20, "a": 0x61, "A": 0x41,
}


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError(f"closed {len(buf)}/{n}")
        buf += chunk
    return buf


def handshake(s):
    s.recv(12); s.sendall(b"RFB 003.008\n")
    n = s.recv(1)[0]; s.recv(n); s.sendall(b"\x01")
    struct.unpack(">I", recv_exact(s, 4))
    s.sendall(b"\x01")
    si = recv_exact(s, 24)
    w, h = struct.unpack(">HH", si[:4])
    (nl,) = struct.unpack(">I", si[20:24])
    recv_exact(s, nl)
    return w, h


def setup(s, w, h):
    pf = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    s.sendall(b"\x00\x00\x00\x00" + pf)
    s.sendall(struct.pack(">BxHI", 2, 1, 0))
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    s.settimeout(0.6)
    try:
        while s.recv(65536):
            pass
    except socket.timeout:
        pass
    s.settimeout(5)


def send_key(s, sym, down):
    s.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, sym))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=5902)
    ap.add_argument("--key", default="Space")
    ap.add_argument("--duration", type=float, default=20.0,
                    help="Total seconds to spam")
    ap.add_argument("--rate", type=float, default=5.0,
                    help="Key presses per second")
    ap.add_argument("--hold-ms", type=int, default=80)
    args = ap.parse_args()

    sym = KEYSYMS.get(args.key, ord(args.key) if len(args.key) == 1 else None)
    if sym is None:
        print(f"unknown key {args.key!r}", file=sys.stderr); sys.exit(2)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((args.host, args.port))
    w, h = handshake(s)
    setup(s, w, h)
    print(f"[spam] connected {w}x{h}, spamming {args.key} for {args.duration}s at {args.rate}/s", file=sys.stderr)

    start = time.time()
    interval = 1.0 / args.rate
    count = 0
    while time.time() - start < args.duration:
        send_key(s, sym, True)
        time.sleep(args.hold_ms / 1000.0)
        send_key(s, sym, False)
        time.sleep(max(0, interval - args.hold_ms / 1000.0))
        count += 1
    s.close()
    print(f"[spam] done, sent {count} key presses in {time.time()-start:.1f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
