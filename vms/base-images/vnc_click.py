#!/usr/bin/env python3
"""Send a left-click to a VNC server at a fixed coordinate.

Usage:
  vnc_click.py --port 5909 --x 545 --y 378
"""

import argparse
import socket
import struct
import time


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("socket closed")
        buf += chunk
    return buf


def handshake(sock):
    sock.recv(12)
    sock.sendall(b"RFB 003.008\n")
    n = sock.recv(1)[0]
    sock.recv(n)
    sock.sendall(b"\x01")
    recv_exact(sock, 4)
    sock.sendall(b"\x01")
    si = recv_exact(sock, 24)
    width, height = struct.unpack(">HH", si[:4])
    name_len = struct.unpack(">I", si[20:24])[0]
    recv_exact(sock, name_len)
    return width, height


def set_client_state(sock, width, height):
    pixel_format = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    sock.sendall(b"\x00\x00\x00\x00" + pixel_format)
    sock.sendall(struct.pack(">BxHI", 2, 1, 0))
    sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))


def send_pointer(sock, mask, x, y):
    sock.sendall(struct.pack(">BBHH", 5, mask, x, y))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=5902)
    ap.add_argument("--x", type=int, required=True)
    ap.add_argument("--y", type=int, required=True)
    ap.add_argument("--settle-ms", type=int, default=500)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect((args.host, args.port))
    width, height = handshake(sock)
    set_client_state(sock, width, height)
    time.sleep(args.settle_ms / 1000.0)
    send_pointer(sock, 0, args.x, args.y)
    time.sleep(0.1)
    send_pointer(sock, 1, args.x, args.y)
    time.sleep(0.1)
    send_pointer(sock, 0, args.x, args.y)
    time.sleep(0.2)
    sock.close()


if __name__ == "__main__":
    main()
