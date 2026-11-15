"""The connection with the external registration website (website/: Django):
visitors register there with their QR card. Its health endpoint is checked
every `interval` s; the dashboard and the gamemaster app show it, so the crew
knows when registrations stop coming in.

    --website=https://.../health   the website's health endpoint (HTTP 200 = up)
    (none: a mock, switched off / on with POST /api/website/mock {"up": false})

The sync (--website-api https://site --website-token SECRET): this server
calls out - the installation is on its own network, the website can't call
in. Every `sync_interval` s:
    pull   GET  <api>/api/sync/registrations?since=N  -> new / changed cards
           (card, name, age; on_registrations stores them; N kept by cursor)
    push   PUT  <api>/api/sync/scoreboard              the current event's ranking
           (scoreboard(): sent when it changed, else every PUSH_EVERY s)
(The website can also push a registration itself: PUT /api/cards/{code}.)
"""

import hashlib
import json
import threading
import time
import urllib.request
from collections import deque

PUSH_EVERY = 300.0                           # s: the scoreboard again even when unchanged


class Website:
    def __init__(self, url="", interval=15.0, on_change=None, api="", token="", sync_interval=5.0):
        self.api = api.rstrip("/")
        self.token = token
        self.sync_interval = sync_interval
        url = url or (self.api + "/api/health" if self.api else "")
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
        # the sync (set by the server): where the cursor is kept, what to do with registrations, the board
        self.get_cursor = lambda: 0
        self.set_cursor = lambda n: None
        self.on_registrations = lambda regs: None
        self.scoreboard = lambda: None
        self.pulled = 0                      # registrations pulled since the start
        self.last_pull = self.last_push = None
        self.sync_error = ""
        self._pushed = ("", 0.0)             # (hash, time) of the last board sent

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
                "interval": self.interval, "history": list(self.history),
                "sync": {"api": self.api, "pulled": self.pulled, "last_pull_ago": ago(self.last_pull),
                         "last_push_ago": ago(self.last_push), "error": self.sync_error} if self.api else None}

    def _run(self):
        next_check = 0.0
        while not self._stop.is_set():
            if time.time() >= next_check:
                self.check()
                next_check = time.time() + self.interval
            if self.api:
                self.sync()
            self._stop.wait(min(self.interval, self.sync_interval) if self.api else self.interval)

    # ---------------------------------------------------------------- the sync

    def _call(self, method, path, body=None):
        req = urllib.request.Request(self.api + path, method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {self.token}",
                                              "Content-Type": "application/json", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"null")

    def sync(self):
        """Pull the new registrations, push the scoreboard if it changed. Errors
        are kept (the dashboard shows them) and tried again next time."""
        errors = []
        try:
            for _ in range(20):              # (a batch at a time: catching up after a while offline)
                since = int(self.get_cursor())
                j = self._call("GET", f"/api/sync/registrations?since={since}")
                if int(j.get("last", since)) < since:     # the website's database is new: from the start
                    self.set_cursor(0)
                    continue
                regs = j.get("registrations", [])
                if regs:
                    self.on_registrations(regs)
                    self.pulled += len(regs)
                    for _r in regs:
                        self.synced()
                self.set_cursor(int(j.get("next", 0)))
                self.last_pull = time.time()
                if not j.get("more"):
                    break
        except Exception as e:               # noqa: BLE001 - offline, the website down: next time
            errors.append(f"ophalen: {str(e)[:150]}")
        try:
            board = self.scoreboard()
            if board:
                h = hashlib.sha1(json.dumps(board, sort_keys=True).encode()).hexdigest()
                if h != self._pushed[0] or time.time() - self._pushed[1] > PUSH_EVERY:
                    self._call("PUT", "/api/sync/scoreboard", board)
                    self._pushed = (h, time.time())
                    self.last_push = time.time()
        except Exception as e:               # noqa: BLE001
            errors.append(f"scorebord: {str(e)[:150]}")
        was = self.sync_error
        self.sync_error = "; ".join(errors)
        if was != self.sync_error:
            self.on_change()
