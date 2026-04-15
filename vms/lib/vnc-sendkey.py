#!/usr/bin/env python3
"""Send a keystroke to a VNC server. Used to dismiss 'Press any key to boot from CD'.

QEMU's HMP 'sendkey' command doesn't reach USB keyboard on ARM64 virt.
VNC key events route through the display input layer, which does work.

Usage: vnc-sendkey.py <host> <port> [key_sym]
  key_sym defaults to 0xff0d (Return/Enter)
"""
import socket, struct, sys, time

def vnc_send_key(host, port, key_sym=0xff0d):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((host, port))

    # RFB version handshake
    server_ver = s.recv(12)
    s.send(b'RFB 003.008\n')

    # Security types
    num_types = struct.unpack('B', s.recv(1))[0]
    sec_types = s.recv(num_types)
    # Select None auth (type 1) or VNC auth (type 2)
    if 1 in sec_types:
        s.send(struct.pack('B', 1))
    else:
        s.close()
        return False

    # Security result
    result = struct.unpack('>I', s.recv(4))[0]
    if result != 0:
        s.close()
        return False

    # ClientInit: shared=True
    s.send(struct.pack('B', 1))

    # ServerInit: read framebuffer params + name
    si = s.recv(24)
    name_len = struct.unpack('>I', si[20:24])[0]
    s.recv(name_len)

    # Key press (message type 4)
    # Format: [type=1B][down-flag=1B][padding=2B][key=4B]
    s.send(struct.pack('>BBxxI', 4, 1, key_sym))  # key down
    time.sleep(0.05)
    s.send(struct.pack('>BBxxI', 4, 0, key_sym))  # key up

    s.close()
    return True

if __name__ == '__main__':
    host = sys.argv[1] if len(sys.argv) > 1 else 'localhost'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5909
    key = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0xff0d

    try:
        if vnc_send_key(host, port, key):
            print(f"Sent key 0x{key:04x} to {host}:{port}")
        else:
            print(f"Failed to send key to {host}:{port}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
