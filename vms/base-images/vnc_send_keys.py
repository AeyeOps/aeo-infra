#!/usr/bin/env python3
"""Extension of vnc_full.py: send named keys, modifier combos, or raw text
through the same full-RFB handshake.

Usage:
  vnc_send_keys.py --port 5902 --keys "Down Down Enter"
  vnc_send_keys.py --port 5902 --keys "Return"       # same as Enter
  vnc_send_keys.py --port 5902 --keys "F7 Enter"
  vnc_send_keys.py --port 5902 --keys "Super_L+r"
  vnc_send_keys.py --port 5902 --text "powershell"
"""
import argparse
import socket
import struct
import sys
import time

# X11 keysyms
KEYSYMS = {
    "Return": 0xFF0D,
    "Enter":  0xFF0D,
    "Tab":    0xFF09,
    "Backspace": 0xFF08,
    "Escape": 0xFF1B,
    "Esc":    0xFF1B,
    "Up":     0xFF52,
    "Down":   0xFF54,
    "Left":   0xFF51,
    "Right":  0xFF53,
    "Home":   0xFF50,
    "End":    0xFF57,
    "PageUp": 0xFF55,
    "PageDown": 0xFF56,
    "Space":  0x20,
    "F1": 0xFFBE, "F2": 0xFFBF, "F3": 0xFFC0, "F4": 0xFFC1,
    "F5": 0xFFC2, "F6": 0xFFC3, "F7": 0xFFC4, "F8": 0xFFC5,
    "F9": 0xFFC6, "F10": 0xFFC7, "F11": 0xFFC8, "F12": 0xFFC9,
    "Shift_L": 0xFFE1,
    "Shift_R": 0xFFE2,
    "Control_L": 0xFFE3,
    "Control_R": 0xFFE4,
    "Alt_L": 0xFFE9,
    "Alt_R": 0xFFEA,
    "Meta_L": 0xFFE7,
    "Meta_R": 0xFFE8,
    "Super_L": 0xFFEB,
    "Super_R": 0xFFEC,
    "Menu": 0xFF67,
    "Delete": 0xFFFF,
}


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError(f"socket closed, got {len(buf)}/{n}")
        buf += chunk
    return buf


def handshake(s):
    ver = s.recv(12)
    s.sendall(b"RFB 003.008\n")
    n = s.recv(1)[0]
    types = s.recv(n)
    s.sendall(b"\x01")
    (res,) = struct.unpack(">I", recv_exact(s, 4))
    if res != 0:
        raise RuntimeError(f"auth failed: {res}")
    s.sendall(b"\x01")
    si = recv_exact(s, 24)
    w, h = struct.unpack(">HH", si[:4])
    (nl,) = struct.unpack(">I", si[20:24])
    name = recv_exact(s, nl)
    return w, h, name


def set_client_state(s, w, h):
    pf = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    s.sendall(b"\x00\x00\x00\x00" + pf)
    s.sendall(struct.pack(">BxHI", 2, 1, 0))
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))


def drain_updates(s, quiet_ms=500):
    s.settimeout(quiet_ms / 1000.0)
    buf = bytearray()
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf.extend(chunk)
    except socket.timeout:
        pass
    s.settimeout(5)
    return bytes(buf)


def send_key(s, sym, down):
    s.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, sym))


def resolve_keyspec(keyspec):
    if keyspec in KEYSYMS:
        return KEYSYMS[keyspec]
    if len(keyspec) == 1:
        return ord(keyspec)
    return None


def press_and_release(s, sym, hold_ms, per_key_ms):
    send_key(s, sym, True)
    time.sleep(hold_ms / 1000.0)
    send_key(s, sym, False)
    time.sleep(per_key_ms / 1000.0)


def send_keyspec(s, keyspec, hold_ms, per_key_ms):
    parts = [part for part in keyspec.split("+") if part]
    if not parts:
        raise ValueError("empty keyspec")

    if len(parts) == 1:
        sym = resolve_keyspec(parts[0])
        if sym is None:
            raise ValueError(f"unknown key {keyspec!r}")
        press_and_release(s, sym, hold_ms, per_key_ms)
        return

    modifiers = parts[:-1]
    final = parts[-1]
    modifier_syms = []
    for mod in modifiers:
        sym = resolve_keyspec(mod)
        if sym is None:
            raise ValueError(f"unknown modifier {mod!r}")
        modifier_syms.append(sym)

    final_sym = resolve_keyspec(final)
    if final_sym is None:
        raise ValueError(f"unknown key {final!r}")

    for sym in modifier_syms:
        send_key(s, sym, True)
        time.sleep(0.02)

    press_and_release(s, final_sym, hold_ms, per_key_ms)

    for sym in reversed(modifier_syms):
        send_key(s, sym, False)
        time.sleep(0.02)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=5902)
    ap.add_argument("--keys",
                    help="Space-separated list of key names or combos (Up, Down, Enter, Super_L+r, ...)")
    ap.add_argument("--text",
                    help="Literal text to type one character at a time")
    ap.add_argument("--pre-delay", type=float, default=0.0)
    ap.add_argument("--post-delay", type=float, default=1.0)
    ap.add_argument("--per-key-ms", type=int, default=80,
                    help="Delay after key release before next key")
    ap.add_argument("--hold-ms", type=int, default=0,
                    help="How long to hold each key down (0 = use per-key-ms)")
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((args.host, args.port))
    w, h, name = handshake(s)
    print(f"[vnc] connected: {w}x{h} name={name!r}", file=sys.stderr)
    set_client_state(s, w, h)
    drain_updates(s, quiet_ms=600)

    if args.pre_delay:
        time.sleep(args.pre_delay)

    hold_ms = args.hold_ms if args.hold_ms > 0 else args.per_key_ms
    if not args.keys and args.text is None:
        print("[vnc] one of --keys or --text is required", file=sys.stderr)
        sys.exit(2)
    if args.keys and args.text is not None:
        print("[vnc] use either --keys or --text, not both", file=sys.stderr)
        sys.exit(2)

    if args.keys:
        for keyspec in args.keys.split():
            try:
                send_keyspec(s, keyspec, hold_ms, args.per_key_ms)
            except ValueError as exc:
                print(f"[vnc] {exc}", file=sys.stderr)
                sys.exit(2)
            print(f"[vnc] sent {keyspec}", file=sys.stderr)
    else:
        for ch in args.text:
            sym = resolve_keyspec(ch)
            if sym is None:
                print(f"[vnc] unknown text char {ch!r}", file=sys.stderr)
                sys.exit(2)
            press_and_release(s, sym, hold_ms, args.per_key_ms)
        print(f"[vnc] sent text ({len(args.text)} chars)", file=sys.stderr)

    if args.post_delay:
        time.sleep(args.post_delay)
    s.close()


if __name__ == "__main__":
    main()
