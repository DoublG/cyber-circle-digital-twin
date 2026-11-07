"""A bad network between a display node and the master (tests/run_replica_test.sh):
a UDP proxy that loses packets, delays them (jitter: out of order too) and can
go dark for a while.

  python3 tests/udp_proxy.py --listen 7371 --to 127.0.0.1:7361 [--loss 10] [--delay 20]
         [--jitter 50] [--blackout 18:8]      (from 18 s after the start, 8 s nothing gets through)
"""

import argparse
import random
import select
import socket
import time
import heapq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--loss", type=float, default=0.0, help="%% of the packets lost (each way)")
    ap.add_argument("--delay", type=float, default=0.0, help="ms added to every packet")
    ap.add_argument("--jitter", type=float, default=0.0, help="ms of random extra delay (reorders)")
    ap.add_argument("--blackout", default="", help="START:SECONDS - nothing gets through")
    a = ap.parse_args()
    host, port = a.to.rsplit(":", 1)
    server = (host, int(port))
    black = [float(x) for x in a.blackout.split(":")] if a.blackout else None
    t0 = time.time()

    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(("127.0.0.1", a.listen))
    back = {}          # client address -> socket to the server
    owner = {}         # back socket -> client address
    queue = []         # (due, seq, socket, data, address)
    seq = 0
    stats = {"in": 0, "lost": 0, "dark": 0}
    last_report = time.time()

    def send_later(sock, data, addr):
        nonlocal seq
        now = time.time()
        if black and black[0] <= now - t0 < black[0] + black[1]:
            stats["dark"] += 1
            return
        if random.random() * 100 < a.loss:
            stats["lost"] += 1
            return
        due = now + (a.delay + random.random() * a.jitter) / 1000.0
        seq += 1
        heapq.heappush(queue, (due, seq, sock, data, addr))

    while True:
        timeout = max(0.0, queue[0][0] - time.time()) if queue else 0.05
        socks = [front] + list(owner)
        ready, _, _ = select.select(socks, [], [], min(timeout, 0.05))
        for s in ready:
            data, addr = s.recvfrom(65535)
            stats["in"] += 1
            if s is front:
                if addr not in back:
                    b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    b.bind(("127.0.0.1", 0))
                    back[addr] = b
                    owner[b] = addr
                send_later(back[addr], data, server)
            else:
                send_later(front, data, owner[s])
        now = time.time()
        while queue and queue[0][0] <= now:
            _, _, sock, data, addr = heapq.heappop(queue)
            sock.sendto(data, addr)
        if now - last_report > 5:
            last_report = now
            print("proxy: t=%.0f s %s" % (now - t0, stats), flush=True)


if __name__ == "__main__":
    main()
