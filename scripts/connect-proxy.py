#!/usr/bin/env python3
"""ProxyCommand для SSH через HTTP CONNECT-прокси.

Зачем: macOS-овский `nc -X connect` принимает только ответ `HTTP/1.0 200`
и падает на `HTTP/1.1 200 Connection established`, который присылает Happ
(Xray) — при том, что соединение реально установлено.

Использование:
    ssh -o ProxyCommand='/usr/bin/python3 <путь>/connect-proxy.py 127.0.0.1 10809 %h %p' host
"""
import selectors
import socket
import sys


def main() -> int:
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: connect-proxy.py <proxy_host> <proxy_port> <dest_host> <dest_port>\n")
        return 2
    phost, pport, dhost, dport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

    sock = socket.create_connection((phost, pport), timeout=30)
    sock.sendall(
        f"CONNECT {dhost}:{dport} HTTP/1.1\r\nHost: {dhost}:{dport}\r\n"
        f"Proxy-Connection: keep-alive\r\n\r\n".encode())

    # Дочитываем заголовки ответа побайтно, чтобы не проглотить первые байты SSH.
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1)
        if not chunk:
            sys.stderr.write("proxy closed during CONNECT\n")
            return 1
        buf += chunk
    status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 200" not in status:
        sys.stderr.write(f"proxy refused: {status}\n")
        return 1

    leftover = buf.split(b"\r\n\r\n", 1)[1]
    if leftover:
        sys.stdout.buffer.write(leftover)
        sys.stdout.buffer.flush()

    sock.setblocking(False)
    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ, "net")
    sel.register(sys.stdin.buffer.raw, selectors.EVENT_READ, "in")

    while True:
        for key, _ in sel.select():
            if key.data == "net":
                try:
                    data = sock.recv(65536)
                except BlockingIOError:
                    continue
                if not data:
                    return 0
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            else:
                data = sys.stdin.buffer.raw.read(65536)
                if not data:
                    return 0
                sock.sendall(data)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)
