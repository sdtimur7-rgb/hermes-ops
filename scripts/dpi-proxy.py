#!/usr/bin/env python3
"""
Локальный TCP-прокси для обхода DPI-фильтрации SSH.

Идея: провайдер опознаёт SSH по клиентскому баннеру ("SSH-2.0-OpenSSH_...")
в первом пакете. Прокси разбивает этот баннер на мелкие фрагменты с
микрозадержками — сигнатура не собирается в одном сегменте, а самому SSH
разбиение TCP-потока безразлично (версия в обмене ключей не меняется,
поэтому аутентификация не ломается).

Запуск:
    python3 dpi-proxy.py 147.45.174.117 22 2222
Использование:
    ssh -p 2222 root@127.0.0.1
"""
import socket
import sys
import threading
import time

FRAG = 2          # байт в одном фрагменте
DELAY = 0.02      # пауза между фрагментами, с
BUF = 65536
FRAG_BYTES = 4096  # сколько первых байт клиент→сервер дробить (баннер + KEXINIT)


def relay(src: socket.socket, dst: socket.socket, frag_first: int = 0) -> None:
    """Пересылка. Первые frag_first байт отправляются мелкими фрагментами."""
    remaining = frag_first
    try:
        while True:
            data = src.recv(BUF)
            if not data:
                break
            if remaining > 0:
                head, tail = data[:remaining], data[remaining:]
                send_fragmented(dst, head)
                remaining -= len(head)
                if tail:
                    dst.sendall(tail)
            else:
                dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def send_fragmented(sock: socket.socket, data: bytes) -> None:
    """Отправить побайтово-мелкими кусками, чтобы DPI не увидел сигнатуру."""
    for i in range(0, len(data), FRAG):
        sock.sendall(data[i:i + FRAG])
        time.sleep(DELAY)


def handle(client: socket.socket, host: str, port: int, n: int) -> None:
    peer = "?"
    try:
        peer = "%s:%d" % client.getpeername()[:2]
        upstream = socket.create_connection((host, port), timeout=20)
        upstream.settimeout(None)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("[%d] соединение с %s:%d установлено, дроблю первые %d Б"
              % (n, host, port, FRAG_BYTES), flush=True)

        # клиент → сервер: начало потока дробим (баннер + KEXINIT)
        threading.Thread(target=relay, args=(client, upstream, FRAG_BYTES),
                         daemon=True).start()
        # сервер → клиент: как есть
        relay(upstream, client)
        print("[%d] соединение закрыто (%s)" % (n, peer), flush=True)
    except Exception as exc:
        print("[%d] ошибка: %s: %s" % (n, type(exc).__name__, exc), flush=True)
    finally:
        try:
            client.close()
        except OSError:
            pass


def main() -> None:
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    host, port, listen = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen))
    srv.listen(16)
    print("прокси слушает 127.0.0.1:%d → %s:%d  (фрагмент %d Б, пауза %.0f мс)"
          % (listen, host, port, FRAG, DELAY * 1000), flush=True)
    print("подключаться: ssh -p %d root@127.0.0.1" % listen, flush=True)

    n = 0
    while True:
        try:
            client, _ = srv.accept()
        except KeyboardInterrupt:
            break
        n += 1
        threading.Thread(target=handle, args=(client, host, port, n), daemon=True).start()


if __name__ == "__main__":
    main()
