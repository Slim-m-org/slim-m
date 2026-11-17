# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Carries the e2e SFU's webhook deliveries from the docker bridge to the loopback-only server.

The server binds 127.0.0.1 on purpose (the first account to register owns the deployment), and
the LiveKit container cannot reach the host's loopback, so this listens on the bridge's gateway
address alone, which only the host and its containers can reach.

Usage: e2e_webhook_relay.py <listen-address> <listen-port> <loopback-port>
"""
import socket
import sys
import threading


def _pipe(src, dst):
    try:
        while chunk := src.recv(65536):
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        for sock in (dst, src):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _serve_one(client, target_port):
    try:
        upstream = socket.create_connection(("127.0.0.1", target_port), timeout=5)
    except OSError:
        client.close()
        return
    upstream.settimeout(None)
    threading.Thread(target=_pipe, args=(client, upstream), daemon=True).start()
    _pipe(upstream, client)


def main(argv):
    if len(argv) != 4:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    address, port, target_port = argv[1], int(argv[2]), int(argv[3])
    if address in ("", "0.0.0.0", "::"):
        raise SystemExit("refusing to listen on every interface")
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((address, port))
    listener.listen(16)
    while True:
        client, _ = listener.accept()
        threading.Thread(target=_serve_one, args=(client, target_port), daemon=True).start()


if __name__ == "__main__":
    main(sys.argv)
