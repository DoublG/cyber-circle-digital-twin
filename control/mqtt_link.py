"""MQTT side of the control server: follows the Godot processes and the game,
sends commands. Topics (prefix "cybercircle"):
  node/<id>     process -> all   retained announcement {id, role, host, port, screens, version, ...}
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
import threading
import time
from collections import deque
from urllib.parse import urlparse

import paho.mqtt.client as mqtt

NODE_TIMEOUT = 30.0                      # s without an announcement: offline


class MqttLink:
    def __init__(self, url, prefix="cybercircle", username="", password="", on_change=None):
        self.prefix = prefix
        self.on_change = on_change or (lambda kind: None)
        self.nodes = {}                      # id -> announcement + "seen"
        self.schema = []                     # the game's settings (settings/schema)
        self.devices = {}                    # physical tile id -> hello + "seen"
        self.state = {}
        self.events = deque(maxlen=60)
        self.master = {}
        self.online = False
        self.lock = threading.Lock()
        u = urlparse(url)
        ws = u.scheme in ("ws", "wss")
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="cybercircle-control",
                                  transport="websockets" if ws else "tcp")
        if ws:
            self.client.ws_set_options(path=u.path or "/mqtt")
        if u.scheme in ("wss", "mqtts"):
            self.client.tls_set()
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
        for t in ("node/+", "device/+/hello", "state", "event", "master", "registered", "activated", "status",
                  "settings/schema"):
            client.subscribe(f"{self.prefix}/{t}")
        self.on_change("mqtt")

    def _on_disconnect(self, client, userdata, flags, reason, props):
        self.online = False
        self.on_change("mqtt")

    def _on_message(self, client, userdata, msg):
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
            elif topic == "master":
                self.master = data or {}
                kind = "master"
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

    def node_list(self):
        now = time.time()
        with self.lock:
            return sorted(({**n, "online": now - n.get("seen", 0) < NODE_TIMEOUT}
                           for n in self.nodes.values()), key=lambda n: n.get("id", ""))

    # ------------------------------------------------------------ outgoing

    def command(self, msg):
        self.client.publish(f"{self.prefix}/cmd", json.dumps(msg))

    def publish_tiles(self, tiles):
        """Tell every physical tile its place, and the game which places are in service."""
        placed = {t["device"]: t["number"] for t in tiles if t["device"]}
        for dev in set(placed) | set(self.devices):
            self.client.publish(f"{self.prefix}/device/{dev}/config", json.dumps({"tile": placed.get(dev, 0)}),
                                retain=True)
        self.client.publish(f"{self.prefix}/tiles", json.dumps({
            "enabled": {str(t["number"]): bool(t["enabled"]) for t in tiles},
            "devices": {str(t["number"]): t["device"] for t in tiles if t["device"]}}), retain=True)

    def publish_mode(self, mode):
        self.client.publish(f"{self.prefix}/mode", json.dumps({"mode": mode}), retain=True)

    def publish_settings(self, values):
        self.client.publish(f"{self.prefix}/settings", json.dumps(values), retain=True)

    def set_master(self, master):
        self.master = master
        self.client.publish(f"{self.prefix}/master", json.dumps(master), retain=True)
