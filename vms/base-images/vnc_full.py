#!/usr/bin/env python3
"""Full RFB 3.8 client: type text and/or capture framebuffer as PPM.

Usage:
  vnc_full.py --host localhost --port 5902 --type "bcfg boot dump\n"
  vnc_full.py --host localhost --port 5902 --screenshot /tmp/winboot/shot.ppm
  vnc_full.py --host localhost --port 5902 --screenshot shot.ppm --type "map\n"

The full handshake is mandatory: SetPixelFormat -> SetEncodings -> FBUpdateReq
-> drain first update -> only then keys (or capture).
"""
import argparse
import socket
import struct
import sys
import time


# Keysym table: characters we expect to type in a UEFI Shell
# Shell is case-insensitive for commands, but paths may be case-sensitive
_KS = {
    "\n": 0xFF0D,  # Return
    "\t": 0xFF09,  # Tab
    "\b": 0xFF08,  # Backspace
    " ": 0x20,
    "!": 0x21, "\"": 0x22, "#": 0x23, "$": 0x24, "%": 0x25, "&": 0x26,
    "'": 0x27, "(": 0x28, ")": 0x29, "*": 0x2A, "+": 0x2B, ",": 0x2C,
    "-": 0x2D, ".": 0x2E, "/": 0x2F, ":": 0x3A, ";": 0x3B, "<": 0x3C,
    "=": 0x3D, ">": 0x3E, "?": 0x3F, "@": 0x40, "[": 0x5B, "\\": 0x5C,
    "]": 0x5D, "^": 0x5E, "_": 0x5F, "`": 0x60, "{": 0x7B, "|": 0x7C,
    "}": 0x7D, "~": 0x7E,
}


def keysym(ch: str) -> int:
    if ch in _KS:
        return _KS[ch]
    return ord(ch)


def shift_needed(ch: str) -> bool:
    if ch.isupper():
        return True
    return ch in '~!@#$%^&*()_+{}|:"<>?'


def recv_exact(s: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError(f"socket closed, got {len(buf)}/{n}")
        buf += chunk
    return buf


def handshake(s: socket.socket):
    # Version
    ver = s.recv(12)
    if not ver.startswith(b"RFB 003."):
        raise RuntimeError(f"bad version: {ver!r}")
    s.sendall(b"RFB 003.008\n")
    # Security types list
    n = s.recv(1)[0]
    types = s.recv(n)
    if 1 not in types:
        raise RuntimeError(f"no None auth available: {types!r}")
    s.sendall(b"\x01")
    # Auth result
    (res,) = struct.unpack(">I", recv_exact(s, 4))
    if res != 0:
        raise RuntimeError(f"auth failed: {res}")
    # ClientInit (shared)
    s.sendall(b"\x01")
    # ServerInit: width, height, pixel format (16 bytes), name length, name
    si = recv_exact(s, 24)
    w, h = struct.unpack(">HH", si[:4])
    # pixel format bytes 4..20 (16 bytes)
    (nl,) = struct.unpack(">I", si[20:24])
    name = recv_exact(s, nl)
    return w, h, name


def set_client_state(s: socket.socket, w: int, h: int):
    # SetPixelFormat: msg 0, padding x3, then 16-byte pixel format
    # 32 bpp, 24 depth, big-endian=0, true-color=1, R/G/B max 255, shift 16/8/0
    pf = struct.pack(">BBBBHHHBBBxxx",
                     32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    s.sendall(b"\x00\x00\x00\x00" + pf)
    # SetEncodings: msg 2, pad, n-encodings=1, Raw=0
    s.sendall(struct.pack(">BxHI", 2, 1, 0))
    # FramebufferUpdateRequest (non-incremental full): msg 3
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))


def drain_updates(s: socket.socket, quiet_ms: int = 500) -> bytes:
    """Read until quiet period reached. Return raw bytes for optional parsing."""
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


def parse_fb_update(data: bytes, w: int, h: int) -> bytes | None:
    """Parse a Raw FramebufferUpdate message. Return raw RGBA pixels (w*h*4)."""
    # msg-type 0, padding, n-rects (2), rects...
    if len(data) < 4 or data[0] != 0:
        return None
    (nrects,) = struct.unpack(">H", data[2:4])
    off = 4
    # Allocate full-frame buffer (may be only partial rect — caller handles)
    pixels = bytearray(w * h * 4)
    for _ in range(nrects):
        if len(data) - off < 12:
            return None
        x, y, rw, rh, enc = struct.unpack(">HHHHi", data[off:off + 12])
        off += 12
        if enc != 0:  # only Raw supported here
            return None
        need = rw * rh * 4
        if len(data) - off < need:
            return None
        # Copy rect into pixels
        for row in range(rh):
            src = off + row * rw * 4
            dst = ((y + row) * w + x) * 4
            pixels[dst:dst + rw * 4] = data[src:src + rw * 4]
        off += need
    return bytes(pixels)


def save_ppm(path: str, pixels: bytes, w: int, h: int):
    """Save RGBA pixels (our pixel format: R@16, G@8, B@0 in a 32-bit BE word) as PPM."""
    # Our SetPixelFormat was 32bpp, BE, max=255 for R/G/B, shift R=16 G=8 B=0.
    # That means each pixel (4 bytes) in memory is: byte0=0 byte1=R byte2=G byte3=B (big-endian word view)
    # Wait: for BE + shift R=16 means R occupies bits 23..16, G 15..8, B 7..0, top 8 bits unused.
    # Word stored big-endian: bytes are [00, R, G, B].
    out = bytearray()
    out.extend(f"P6\n{w} {h}\n255\n".encode())
    for i in range(0, len(pixels), 4):
        out.append(pixels[i + 1])  # R
        out.append(pixels[i + 2])  # G
        out.append(pixels[i + 3])  # B
    with open(path, "wb") as f:
        f.write(out)


def send_key(s: socket.socket, sym: int, down: bool):
    s.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, sym))


def type_text(s: socket.socket, text: str, per_key_ms: int = 40):
    SHIFT = 0xFFE1
    for ch in text:
        needs_shift = shift_needed(ch)
        sym = keysym(ch)
        if needs_shift:
            send_key(s, SHIFT, True)
        send_key(s, sym, True)
        time.sleep(per_key_ms / 1000.0)
        send_key(s, sym, False)
        if needs_shift:
            send_key(s, SHIFT, False)
        time.sleep(per_key_ms / 1000.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=5902)
    ap.add_argument("--type", dest="text", default="", help="Text to type")
    ap.add_argument("--screenshot", default="", help="PPM output path")
    ap.add_argument("--pre-delay", type=float, default=0.0,
                    help="Seconds to wait after handshake before action")
    ap.add_argument("--post-delay", type=float, default=1.0,
                    help="Seconds to wait after typing before screenshot/close")
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((args.host, args.port))
    w, h, name = handshake(s)
    print(f"[vnc] connected: {w}x{h} name={name!r}", file=sys.stderr)
    set_client_state(s, w, h)

    # Drain initial framebuffer update
    initial = drain_updates(s, quiet_ms=600)
    print(f"[vnc] initial update bytes={len(initial)}", file=sys.stderr)

    if args.pre_delay:
        time.sleep(args.pre_delay)

    if args.text:
        type_text(s, args.text)
        print(f"[vnc] typed {len(args.text)} chars", file=sys.stderr)

    if args.post_delay:
        time.sleep(args.post_delay)

    if args.screenshot:
        # Request a fresh framebuffer
        s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
        fb = drain_updates(s, quiet_ms=800)
        pixels = parse_fb_update(fb, w, h)
        if pixels is None:
            print(f"[vnc] FB parse failed; raw bytes={len(fb)}", file=sys.stderr)
            sys.exit(2)
        save_ppm(args.screenshot, pixels, w, h)
        print(f"[vnc] saved {args.screenshot}", file=sys.stderr)

    s.close()


if __name__ == "__main__":
    main()
