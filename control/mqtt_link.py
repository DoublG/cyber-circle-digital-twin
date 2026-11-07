"""MQTT side of the control server: follows the Godot processes and the game,
sends commands. Topics (prefix "cybercircle"):
  node/<id>     process -> all   retained announcement {id, role, host, port, screens, version, ...}
  metrics/<id>  process -> all   every 2 s: fps, frame times, CPU, memory, the mirror links (Prestaties tab;
                                 kept here with 5 minutes of history, not in the traffic log)
  $SYS/broker/#  broker -> all   Mosquitto's own counters (clients, messages/s, bytes/s) and, with
                                 log_dest topic, its log lines: who connects / leaves (the client list)
  state         master -> all    retained game state {state, round, time, players, pending, ...}
  event         master -> all    {text, color} (the overview's event feed)
  master        control -> all   retained {node, host, port}: the chosen master
  cmd           control -> game  any arena.apply_command message ({"game": "start"}, {"assign": 42}, ...)
  device/<dev>/hello    tile -> all     retained: a physical tile announces itself {device, fw, ...}
  device/<dev>/config   control -> tile retained {"tile": n}: the place it stands on (0 = none) -
                                        the tile then uses tile/<n>/cmd and tile/<n>/event
  tiles         control -> game  retained {"enabled": {"1": true, ...}, "devices": {"1": "dev", ...}}
  mode          control -> game  retained {"mode": "setup" | "closed" | "open" | "paused"}
  settings      control -> game  retained {"game": {"tempo": 1.2, ...}, "quiz": {...}, ...}
  settings/schema  master -> all retained [{group, title, items: [{key, label, min, max, step, unit,
                                 default, value}]}]: every setting the game has
"""

import json
import re
import threading
import time
from collections import deque
from urllib.parse import urlparse

import paho.mqtt.client as mqtt

NODE_TIMEOUT = 30.0                      # s without an announcement: offline
# Mosquitto's log lines (log_dest topic: $SYS/broker/log/N), e.g.
#   "1700000000: New client connected from 192.168.1.31:51234 as tile-0200000003 (p2, c1, k30, u'cybercircle')."
#   "1700000000: Client tile-0200000003 closed its connection." / "... disconnected." / "Socket error on client X ..."
LOG_CONNECT = re.compile(r"New client connected from (\S+) as (\S+) \(([^)]*)\)")
LOG_GONE = re.compile(r"(?:Client (\S+) (closed its connection|disconnected|has exceeded timeout)|"
                      r"Socket error on client (\S+))")


class MqttLink:
    def __init__(self, url, prefix="cybercircle", username="", password="", on_change=None, ca=""):
        self.url = url                       # (the gamemaster app asks where the broker is)
        self.prefix = prefix
        self.on_change = on_change or (lambda kind: None)
        self.nodes = {}                      # id -> announcement + "seen"
        self.schema = []                     # the game's settings (settings/schema)
        self.sounds = {}                     # the sounds the game can play: event -> [file] (sounds)
        self.text_defaults = {}              # the game's texts as they are without changes (texts/defaults)
        self.devices = {}                    # physical tile id -> hello + "seen"
        self.presses = {}                    # place number -> {"button", "at"}: its last press (Tegels › Diagnose)
        self.state = {}
        self.events = deque(maxlen=60)
        self.voice = deque(maxlen=200)       # the lines the game reads out (voice), each with "seq" (the a11y pages)
        self.voice_seq = 0
        self.streams = {}                    # tile -> the companion video's last state (stream)
        self.traffic = deque(maxlen=1000)    # the raw messages (web interface: MQTT): {seq, time, topic, payload, retained}
        self.traffic_seq = 0
        self.master = {}
        self.db_notice = {}
        self.online = False
        self.lock = threading.Lock()
        self.metrics = {}                    # node id -> {"last": the latest metrics, "hist": deque of [t, fps, frame_ms, worst_ms, cpu]}
        self.broker = {}                     # $SYS/broker/... -> value (Mosquitto, every sys_interval s)
        self.rx_msgs = 0                     # (this link's counters: the control server's own metrics)
        self.rx_bytes = 0
        self.connects = 0
        self.connected_at = 0.0
        self.mqtt_clients = {}               # client id -> {id, ip, user, since, keepalive}: connected now (the broker's log)
        self.client_events = deque(maxlen=40)   # recent connects / leaves {time, id, event}
        self.clients_since = time.time()
        self.robot = {}                      # the real robot: {"state": robot/state, "hello": robot/hello, "seen"}     # (the list knows who connected after this: the broker has no list)
        u = urlparse(url)
        ws = u.scheme in ("ws", "wss")
        self.client_id = "cybercircle-control"
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=self.client_id,
                                  transport="websockets" if ws else "tcp")
        if ws:
            self.client.ws_set_options(path=u.path or "/mqtt")
        if u.scheme in ("wss", "mqtts"):
            self.client.tls_set(ca_certs=ca or None)     # ca: the installation's own CA (deploy/certs/ca.pem)
        if username:
            self.client.username_pw_set(username, password)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(1, 10)
        self.host, self.port = u.hostname or "localhost", u.port or (9001 if ws else 1883)

    def start(self):
        self.client.connect_async(self.host, self.port, keepalive=30)
        self.client.loop_start()

    def stop(self):
        self.client.loop_stop()
        self.client.disconnect()

    # ------------------------------------------------------------ incoming

    def _on_connect(self, client, userdata, flags, reason, props):
        self.online = not reason.is_failure
        client.subscribe(f"{self.prefix}/#")   # everything: the topics below + the raw traffic log
        client.subscribe("$SYS/broker/#")      # the broker's counters (Mosquitto; ignored by brokers without them)
        if self.online:
            self.connects += 1
            self.connected_at = time.time()
        self.on_change("mqtt")

    def _on_disconnect(self, client, userdata, flags, reason, props):
        self.online = False
        self.on_change("mqtt")

    def _on_message(self, client, userdata, msg):
        self.rx_msgs += 1
        self.rx_bytes += len(msg.payload)
        if msg.topic.startswith("$SYS/broker/log/"):
            self._broker_log(msg.payload.decode(errors="replace"))
            return
        if msg.topic.startswith("$SYS/"):
            with self.lock:
                self.broker[msg.topic[len("$SYS/broker/"):]] = msg.payload.decode(errors="replace")
            return
        if msg.topic.startswith(self.prefix + "/metrics/"):
            try:
                data = json.loads(msg.payload.decode() or "null")
            except ValueError:
                return
            if isinstance(data, dict):
                node = msg.topic.rsplit("/", 1)[1]
                data["seen"] = time.time()
                with self.lock:
                    m = self.metrics.setdefault(node, {"hist": deque(maxlen=150)})   # 5 min at 2 s
                    m["last"] = data
                    m["hist"].append([round(data["seen"], 1), data.get("fps", 0), data.get("frame_ms", 0),
                                      data.get("worst_ms", 0), data.get("cpu", 0)])
            return                              # (every 2 s per process: not in the traffic log, no live push)
        self.traffic_seq += 1
        self.traffic.append({"seq": self.traffic_seq, "time": time.strftime("%H:%M:%S") + ".%03d" % (time.time() % 1 * 1000),
                             "topic": msg.topic, "payload": msg.payload[:4000].decode(errors="replace"),
                             "retained": bool(msg.retain)})
        topic = msg.topic.removeprefix(self.prefix + "/")
        try:
            data = json.loads(msg.payload.decode() or "null")
        except ValueError:
            data = msg.payload.decode(errors="replace")
        with self.lock:
            if topic.startswith("device/") and topic.endswith("/hello"):
                dev = topic.split("/")[1]
                new = dev not in self.devices
                if data:
                    self.devices[dev] = {**(data if isinstance(data, dict) else {}), "device": dev, "seen": time.time()}
                else:
                    self.devices.pop(dev, None)
                kind = "devices" if new else "device"
            elif topic.startswith("node/"):
                if data:
                    data["seen"] = time.time()
                    self.nodes[topic[5:]] = data
                else:                           # empty retained message: node removed
                    self.nodes.pop(topic[5:], None)
                kind = "nodes"
            elif topic == "state":
                self.state = data or {}
                kind = "state"
            elif topic == "settings/schema":
                self.schema = data or []
                kind = "settings"
            elif topic == "sounds":
                self.sounds = (data or {}).get("events", {}) if isinstance(data, dict) else {}
                kind = "sounds"
            elif topic == "texts/defaults":
                self.text_defaults = data or {}
                kind = "texts"
            elif topic in ("robot/state", "robot/hello"):
                self.robot[topic.split("/")[1]] = data if isinstance(data, dict) else {}
                self.robot["seen"] = time.time()
                kind = "robot"
            elif topic == "master":
                self.master = data or {}
                kind = "master"
            elif topic == "voice" and isinstance(data, dict):
                self.voice_seq += 1
                self.voice.append({**data, "seq": self.voice_seq, "at": time.time()})
                kind = "voice"
            elif topic == "stream" and isinstance(data, dict):
                self.streams[int(data.get("tile", 0))] = data
                kind = "stream"
            elif topic.startswith("tile/") and topic.endswith("/event"):
                if isinstance(data, dict) and data.get("press"):
                    try:
                        self.presses[int(topic.split("/")[1])] = {"button": str(data["press"]), "at": time.time()}
                    except ValueError:
                        pass
                return                          # (polled: no live update per press)
            elif topic == "event":
                self.events.appendleft({**(data if isinstance(data, dict) else {"text": str(data)}),
                                        "time": time.strftime("%H:%M:%S")})
                kind = "event"
            else:
                return
        self.on_change(kind)

    def device_list(self):
        now = time.time()
        with self.lock:
            return sorted(({**d, "online": now - d.get("seen", 0) < NODE_TIMEOUT}
                           for d in self.devices.values()), key=lambda d: d["device"])

    def _broker_log(self, line):
        """A Mosquitto log line: a client connected or left (the client list)."""
        now = time.time()
        m = LOG_CONNECT.search(line)
        if m:
            addr, cid, params = m.groups()
            user = re.search(r"u'([^']*)'", params)
            keep = re.search(r"\bk(\d+)", params)
            with self.lock:
                self.mqtt_clients[cid] = {"id": cid, "ip": addr.rsplit(":", 1)[0].removeprefix("::ffff:"),
                                          "user": user.group(1) if user else "", "since": now,
                                          "keepalive": int(keep.group(1)) if keep else 0}
                self.client_events.appendleft({"time": now, "id": cid, "event": "verbonden"})
            self.on_change("clients")
            return
        m = LOG_GONE.search(line)
        if m:
            cid = m.group(1) or m.group(3)
            why = {"closed its connection": "weg", "disconnected": "weg",
                   "has exceeded timeout": "time-out"}.get(m.group(2) or "", "verbinding verbroken")
            with self.lock:
                self.mqtt_clients.pop(cid, None)
                self.client_events.appendleft({"time": now, "id": cid, "event": why})
            self.on_change("clients")

    def client_list(self):
        with self.lock:
            now = dict(self.mqtt_clients)
            events = list(self.client_events)
        own = self.client_id
        if self.online and own not in now:      # itself (it connects before it hears the log)
            now[own] = {"id": own, "ip": "(deze server)", "user": "", "since": self.connected_at, "keepalive": 60}
        return list(now.values()), events

    def metrics_list(self):
        """Every process's latest metrics and its history (the Prestaties tab)."""
        now = time.time()
        with self.lock:
            return sorted(({**m["last"], "age": round(now - m["last"]["seen"], 1),
                            "online": now - m["last"]["seen"] < 10, "hist": list(m["hist"])}
                           for m in self.metrics.values()), key=lambda m: (m.get("role") != "master", m.get("id", "")))

    def broker_stats(self):
        with self.lock:
            b = dict(self.broker)

        def num(k):
            try:
                return float(b[k])
            except (KeyError, ValueError):
                return None
        if not b:
            return {}
        return {"version": b.get("version", ""), "uptime": b.get("uptime", ""),
                "clients": num("clients/connected"), "clients_max": num("clients/maximum"),
                "subscriptions": num("subscriptions/count"), "retained": num("retained messages/count"),
                "msgs_in_min": num("load/messages/received/1min"), "msgs_out_min": num("load/messages/sent/1min"),
                "bytes_in_min": num("load/bytes/received/1min"), "bytes_out_min": num("load/bytes/sent/1min"),
                "dropped": num("publish/messages/dropped"), "heap": num("heap/current")}

    def node_list(self):
        now = time.time()
        with self.lock:
            return sorted(({**n, "online": now - n.get("seen", 0) < NODE_TIMEOUT}
                           for n in self.nodes.values()), key=lambda n: n.get("id", ""))

    # ------------------------------------------------------------ outgoing

    def identify(self, device, seconds=6):
        """A physical tile lights up so the crew can find it (also before it has a place)."""
        self.client.publish(f"{self.prefix}/device/{device}/identify", json.dumps({"seconds": seconds}))

    def db_changed(self, what):
        """The database changed (players, questions, ranking): the game fetches
        it again right away instead of at its next refresh."""
        self.client.publish(f"{self.prefix}/db", json.dumps({"changed": what, "time": time.time()}))
        self.db_notice = {"what": what, "time": time.time()}     # (the web interface: Herstel)

    def robot_command(self, msg):
        """The real robot directly (the web interface's buttons: home, stop, smoke ...)."""
        self.client.publish(f"{self.prefix}/robot/cmd", json.dumps(msg))

    def publish_robot_config(self, cfg):
        """The robot's settings (retained: it gets them whenever it connects; it keeps them in flash)."""
        self.client.publish(f"{self.prefix}/robot/config", json.dumps(cfg), retain=True)

    def command(self, msg):
        self.client.publish(f"{self.prefix}/cmd", json.dumps(msg))

    def publish_tiles(self, tiles, installed=None):
        """Tell every physical tile its place, and the game which places are in
        service and which are installed at all (a partial installation)."""
        placed = {t["device"]: t["number"] for t in tiles if t["device"]}
        for dev in set(placed) | set(self.devices):
            self.client.publish(f"{self.prefix}/device/{dev}/config", json.dumps({"tile": placed.get(dev, 0)}),
                                retain=True)
        self.client.publish(f"{self.prefix}/tiles", json.dumps({
            "enabled": {str(t["number"]): bool(t["enabled"]) for t in tiles},
            "devices": {str(t["number"]): t["device"] for t in tiles if t["device"]},
            **({"installed": installed} if installed is not None else {})}), retain=True)

    def publish_mode(self, mode):
        self.client.publish(f"{self.prefix}/mode", json.dumps({"mode": mode}), retain=True)

    def publish_texts(self, values):
        self.client.publish(f"{self.prefix}/texts", json.dumps(values), retain=True)

    def publish_settings(self, values):
        self.client.publish(f"{self.prefix}/settings", json.dumps(values), retain=True)

    def set_master(self, master):
        self.master = master
        self.client.publish(f"{self.prefix}/master", json.dumps(master), retain=True)
