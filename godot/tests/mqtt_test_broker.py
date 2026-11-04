#!/usr/bin/env python3
"""Tiny MQTT 3.1.1 broker over WebSocket (and plain TCP: the tiles), Python
stdlib only - for tests and the tile emulator. QoS 0, retained messages,
+ and # wildcards. Not for production: use Mosquitto / EMQX etc. on the
installation.

    python3 tests/mqtt_test_broker.py [port] [--tcp PORT]   (default 9001, path ignored;
                                                             --tcp 1883: plain MQTT too)
"""
import asyncio, base64, hashlib, struct, sys, time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
clients = {}      # writer -> list of topic filters
raw = set()       # writers on plain TCP (no websocket frames)
retained = {}     # topic -> payload


def match(filt, topic):
    f, t = filt.split("/"), topic.split("/")
    for i, part in enumerate(f):
        if part == "#":
            return True
        if i >= len(t) or (part != "+" and part != t[i]):
            return False
    return len(f) == len(t)


def mqtt_packet(header, body):
    n, rl = len(body), bytearray()
    while True:
        b, n = n % 128, n // 128
        rl.append(b | (0x80 if n else 0))
        if not n:
            break
    return bytes([header]) + bytes(rl) + body


def ws_frame(data):
    n = len(data)
    if n < 126:
        head = struct.pack("!BB", 0x82, n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x82, 126, n)
    else:
        head = struct.pack("!BBQ", 0x82, 127, n)
    return head + data


async def send(writer, header, body):
    packet = mqtt_packet(header, body)
    writer.write(packet if writer in raw else ws_frame(packet))
    await asyncio.wait_for(writer.drain(), 2)       # (a killed client must not block the others)


async def publish(topic, payload, retain):
    if retain:
        retained[topic] = payload
    t = topic.encode()
    body = struct.pack("!H", len(t)) + t + payload
    for w, subs in list(clients.items()):
        if any(match(s, topic) for s in subs):
            try:
                await send(w, 0x30, body)
            except Exception:                    # gone (killed): forget it
                clients.pop(w, None)
                w.close()


names = {}                                          # writer -> client id (the $SYS log lines)


async def sys_log(text):
    """As Mosquitto with log_dest topic: its log lines on $SYS/broker/log/N."""
    await publish("$SYS/broker/log/N", f"{int(time.time())}: {text}".encode(), False)


async def handle_mqtt(writer, header, body):
    kind = header >> 4
    if kind == 1:                                   # CONNECT
        clients[writer] = []
        await send(writer, 0x20, b"\x00\x00")
        try:                                        # the client id, keepalive, user: for the log line
            n = struct.unpack("!H", body[:2])[0]
            p = 2 + n
            flags = body[p + 1]
            keep = struct.unpack("!H", body[p + 2:p + 4])[0]
            p += 4
            cid_len = struct.unpack("!H", body[p:p + 2])[0]
            cid = body[p + 2:p + 2 + cid_len].decode()
            p += 2 + cid_len
            if flags & 0x04:                        # will topic + message
                for _ in range(2):
                    p += 2 + struct.unpack("!H", body[p:p + 2])[0]
            user = ""
            if flags & 0x80:
                ul = struct.unpack("!H", body[p:p + 2])[0]
                user = body[p + 2:p + 2 + ul].decode()
            names[writer] = cid
            peer = writer.get_extra_info("peername") or ("?", 0)
            await sys_log(f"New client connected from {peer[0]}:{peer[1]} as {cid} (p2, c1, k{keep}"
                          + (f", u'{user}'" if user else "") + ").")
        except Exception:
            pass
    elif kind == 8:                                 # SUBSCRIBE
        pid, p, granted = body[:2], 2, b""
        while p < len(body):
            n = struct.unpack("!H", body[p:p + 2])[0]
            topic = body[p + 2:p + 2 + n].decode()
            p += 3 + n
            clients[writer].append(topic)
            granted += b"\x00"
        await send(writer, 0x90, pid + granted)
        for t, payload in retained.items():
            if any(match(s, t) for s in clients[writer]):
                tb = t.encode()
                await send(writer, 0x31, struct.pack("!H", len(tb)) + tb + payload)
    elif kind == 3:                                 # PUBLISH (QoS 0)
        n = struct.unpack("!H", body[:2])[0]
        topic = body[2:2 + n].decode()
        p = 2 + n + (2 if (header >> 1) & 3 else 0)
        print("publish", topic, body[p:].decode(errors="replace")[:120], flush=True)
        await publish(topic, body[p:], header & 1)
    elif kind == 10:                                # UNSUBSCRIBE
        pid, p = body[:2], 2
        while p < len(body):
            n = struct.unpack("!H", body[p:p + 2])[0]
            topic = body[p + 2:p + 2 + n].decode()
            p += 2 + n
            if topic in clients.get(writer, []):
                clients[writer].remove(topic)
        await send(writer, 0xB0, pid)
    elif kind == 12:                                # PINGREQ
        await send(writer, 0xD0, b"")


async def client(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    headers = {}
    for line in request.decode().split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest())
    writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 b"Sec-WebSocket-Accept: " + accept + b"\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n")
    await writer.drain()
    buf = bytearray()
    try:
        while True:
            b0, b1 = await reader.readexactly(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", await reader.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", await reader.readexactly(8))[0]
            mask = await reader.readexactly(4) if b1 & 0x80 else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(await reader.readexactly(n)))
            if b0 & 0x0F == 8:                      # close
                break
            if b0 & 0x0F not in (0, 1, 2):
                continue
            buf += data
            while len(buf) >= 2:                    # MQTT packets in the stream
                length, mult, i = 0, 1, 1
                while True:
                    if i >= len(buf):
                        break
                    length += (buf[i] & 0x7F) * mult
                    mult *= 128
                    i += 1
                    if not buf[i - 1] & 0x80:
                        break
                if len(buf) < i + length:
                    break
                header, body = buf[0], bytes(buf[i:i + length])
                del buf[:i + length]
                await handle_mqtt(writer, header, body)
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    clients.pop(writer, None)
    writer.close()
    if writer in names:
        await sys_log(f"Client {names.pop(writer)} closed its connection.")


async def tcp_client(reader, writer):
    """Plain MQTT over TCP (the tiles): the same packets, no websocket frames."""
    raw.add(writer)
    buf = bytearray()
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            buf += data
            while len(buf) >= 2:
                length, mult, i = 0, 1, 1
                while True:
                    if i >= len(buf):
                        break
                    length += (buf[i] & 0x7F) * mult
                    mult *= 128
                    i += 1
                    if not buf[i - 1] & 0x80:
                        break
                if len(buf) < i + length:
                    break
                header, body = buf[0], bytes(buf[i:i + length])
                del buf[:i + length]
                if header >> 4 == 14:               # DISCONNECT
                    raise ConnectionError
                await handle_mqtt(writer, header, body)
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    clients.pop(writer, None)
    raw.discard(writer)
    writer.close()
    if writer in names:
        await sys_log(f"Client {names.pop(writer)} closed its connection.")


async def main():
    args = [a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith("--") and sys.argv[i - 1] != "--tcp"]
    port = int(args[0]) if args else 9001
    server = await asyncio.start_server(client, "127.0.0.1", port)
    print("mqtt test broker on ws://127.0.0.1:%d" % port, flush=True)
    servers = [server]
    if "--tcp" in sys.argv:
        tcp = int(sys.argv[sys.argv.index("--tcp") + 1])
        servers.append(await asyncio.start_server(tcp_client, "0.0.0.0", tcp))
        print("mqtt test broker on mqtt://0.0.0.0:%d (plain: the tiles)" % tcp, flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))

asyncio.run(main())
