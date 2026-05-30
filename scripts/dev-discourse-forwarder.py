#!/usr/bin/env python3
"""Dev-only TCP forwarder for the local Discourse <-> term-llm setup.

Discourse's dev server listens on 127.0.0.1:3000 only, so a term-llm container
can't reach it (the container's localhost is its own). This exposes Discourse on
the docker bridge gateway so the container can connect to it.

Usage:
    ./dev-discourse-forwarder.py [LISTEN_IP] [LISTEN_PORT] [TARGET_IP] [TARGET_PORT]

Defaults: listen on 172.18.0.1:3000, forward to 127.0.0.1:3000.
Find your LISTEN_IP with: docker network inspect <stan-network> -f '{{(index .IPAM.Config 0).Gateway}}'
Run it in the background (e.g. `nohup ./dev-discourse-forwarder.py &`) for your dev session.
"""
import socket
import sys
import threading

LISTEN = (sys.argv[1] if len(sys.argv) > 1 else "172.18.0.1",
          int(sys.argv[2]) if len(sys.argv) > 2 else 3000)
TARGET = (sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1",
          int(sys.argv[4]) if len(sys.argv) > 4 else 3000)


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    try:
        upstream = socket.create_connection(TARGET)
    except OSError:
        client.close()
        return
    t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    t2 = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()
    client.close(); upstream.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(128)
    print("forwarding %s:%d -> %s:%d" % (LISTEN + TARGET), flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
