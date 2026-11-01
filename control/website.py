"""The connection with the external registration website: visitors register
there with their QR card, and it syncs them to this server (PUT /api/cards).
Its health endpoint is checked every `interval` s; the dashboard and the
gamemaster app show it, so the crew knows when registrations stop coming in.

    --website=https://.../health   the website's health endpoint (HTTP 200 = up)
    (none: a mock, switched off / on with POST /api/website/mock {"up": false})
"""

import threading
import time
import urllib.request
from collections import deque


class Website:
    def __init__(self, url="", interval=15.0, on_change=None):
        self.url = url
        self.mock = not url
        self.mock_up = True
        self.interval = interval
        self.on_change = on_change or (lambda: None)
        self.status = "unknown"              # ok / down / unknown (not checked yet)
        self.checked = None                  # time of the last check
        self.last_ok = None
        self.error = ""
        self.latency_ms = None
        self.last_sync = None                # the last registration that came in (PUT /api/cards)
        self.syncs = 0
        self.history = deque(maxlen=40)      # [{time, ok, ms, error}]
        self._stop = threading.Event()

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def stop(self):
        self._stop.set()

    def synced(self):
        """A registration came in from the website."""
        self.last_sync = time.time()
        self.syncs += 1

    def check(self):
        t0 = time.time()
        if self.mock:
            ok, err = self.mock_up, "" if self.mock_up else "mock: uitgeschakeld"
        else:
            try:
                with urllib.request.urlopen(self.url, timeout=5) as r:
                    ok, err = 200 <= r.status < 300, "" if 200 <= r.status < 300 else f"HTTP {r.status}"
            except Exception as e:           # noqa: BLE001 - every failure means: not reachable
                ok, err = False, str(e)[:200]
        ms = round((time.time() - t0) * 1000)
        was = self.status
        self.status = "ok" if ok else "down"
        self.checked = time.time()
        self.error = err
        self.latency_ms = ms if ok else None
        if ok:
            self.last_ok = self.checked
        self.history.appendleft({"time": time.strftime("%H:%M:%S"), "ok": ok, "ms": ms, "error": err})
        if was != self.status:
            self.on_change()

    def snapshot(self):
        def ago(t):
            return None if t is None else round(time.time() - t)
        return {"status": self.status, "url": self.url or "mock", "mock": self.mock, "mock_up": self.mock_up,
                "checked_ago": ago(self.checked), "last_ok_ago": ago(self.last_ok), "error": self.error,
                "latency_ms": self.latency_ms, "last_sync_ago": ago(self.last_sync), "syncs": self.syncs,
                "interval": self.interval, "history": list(self.history)}

    def _run(self):
        while not self._stop.is_set():
            self.check()
            self._stop.wait(self.interval)
