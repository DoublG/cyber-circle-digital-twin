"""The accessible companion page for blind and partially sighted players.

A player gets their own link (a random token, as a QR code from the
gamemaster app) and opens it on their own phone or tablet - with their own
screen reader (VoiceOver, TalkBack, NVDA) and settings:

  /a11y/<token>                   the page (static/a11y.html): semantic HTML, ARIA live regions
  /api/a11y/<token>/events        Server-Sent Events, ONLY this player: the shared lines
                                  (question, answers with their place on the tile, round,
                                  time up) and their own (their answer, right / wrong, hit,
                                  their place), plus their status (place, lives, round)
  /api/a11y/<token>/press         the 4 answer buttons on the page (a tile press) - optional
  /api/a11y/<token>/video         the live video of their screen (partially sighted players):
                                  starts / keeps alive / stops the game's CompanionStream
  /api/a11y/stream-auth           MediaMTX asks here who may publish / watch (authHTTPAddress)
  /api/players/<id>/a11y          the gamemaster app: make (or get) a player's link
  /api/a11y/<token>/qr.png        that link as a QR code

The lines come from the game's read-aloud track (MQTT <prefix>/voice): this
server is the gateway - the broker and the other players' data stay private.
Nothing here runs unless a page is open; the video only while one is watched.
"""

import asyncio
import io
import json
import secrets
import time
from urllib.parse import parse_qs

import segno
from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

ICONS = ["Vierkant", "Driehoek", "Kruis", "Cirkel"]                      # answer 1..4
ON_TILE = ["links boven", "rechts boven", "links onder", "rechts onder"]  # where on the tile (seen standing on it)
BUTTONS = ["Square", "Triangle", "Cross", "Circle"]
TOKEN_HOURS = 12                         # a link works this long (a session day)
URGENT = {"time_up", "personal_hit", "personal_death", "personal_wrong", "personal_answer", "personal_right"}


class PressIn(BaseModel):
    button: str


class VideoIn(BaseModel):
    on: bool = True


def add_routes(app, db, link, listeners, label, opts, static_dir):
    """opts: stream_publish (rtsp://user:pass@host:8554, where the game publishes;
    empty = no video), stream_view (http://host:8889, where browsers watch),
    stream_user / stream_password (the publish login MediaMTX checks here),
    encoder, fps, buttons (the page may answer)."""
    watching = {}                        # token -> time of the last video keep-alive

    # ------------------------------------------------------------ tokens

    def tokens():
        try:
            all_ = json.loads(db.setting("a11y_tokens", "{}"))
        except ValueError:
            all_ = {}
        now = time.time()
        return {t: r for t, r in all_.items() if now - r.get("created", 0) < TOKEN_HOURS * 3600}

    def token_record(token):
        rec = tokens().get(token)
        if not rec:
            raise HTTPException(404, "unknown or expired link")
        return rec

    def where(player_id):
        """(tile, playing) of a player now, or (0, False)."""
        st = link.state or {}
        for p in st.get("players", []):
            if p.get("player_id") == player_id:
                return int(p["tile"]), True
        for p in st.get("pending", []):
            if p.get("player_id") == player_id:
                return int(p["tile"]), False
        return 0, False

    @app.post("/api/players/{pid}/a11y")
    def make_link(pid: int, request: Request):
        """The player's accessible page (one link per player, reused while valid)."""
        if not db.player(pid):
            raise HTTPException(404, "unknown player")
        all_ = tokens()
        token = next((t for t, r in all_.items() if r["player"] == pid), None)
        if token is None:
            token = secrets.token_urlsafe(12)
            all_[token] = {"player": pid, "created": time.time(), "path": "a11y-" + secrets.token_hex(6)}
            db.set_setting("a11y_tokens", json.dumps(all_))
        base = str(request.base_url).rstrip("/")
        return {"token": token, "url": f"{base}/a11y/{token}", "qr": f"{base}/api/a11y/{token}/qr.png",
                "video": bool(opts.get("stream_publish"))}

    @app.get("/api/a11y/{token}/qr.png")
    def qr(token: str, request: Request):
        token_record(token)
        buf = io.BytesIO()
        segno.make(f"{str(request.base_url).rstrip('/')}/a11y/{token}", error="m").save(buf, kind="png", scale=8, border=2)
        return Response(buf.getvalue(), media_type="image/png")

    @app.get("/a11y/{token}")
    def page(token: str):
        token_record(token)
        return FileResponse(static_dir + "/a11y.html", headers={"Cache-Control": "no-store"})

    @app.get("/api/a11y/{token}/info")
    def info(token: str):
        rec = token_record(token)
        player = db.player(rec["player"]) or {}
        tile, playing = where(rec["player"])
        return {"name": player.get("name", ""), "tile": tile, "place": label(tile) if tile else "",
                "playing": playing, "video": bool(opts.get("stream_publish")), "buttons": bool(opts.get("buttons", True))}

    # ------------------------------------------------------------ the live text

    def to_message(line, tile):
        """A voice line -> what the page shows / its screen reader says, or None (not for this player)."""
        if line.get("tile") and int(line["tile"]) != tile:
            return None
        kind = line.get("kind", "")
        text = str(line.get("text", ""))
        if kind == "answer":
            n = int(line.get("answer", 0))
            if 1 <= n <= 4:
                body = text.split(":", 1)[1].strip() if ":" in text else text
                return {"type": "answer", "n": n, "icon": ICONS[n - 1], "where": ON_TILE[n - 1], "answer": body,
                        "text": f"{ICONS[n - 1]}, {ON_TILE[n - 1]}: {body}"}
        if kind == "question":
            return {"type": "question", "text": text}
        if kind == "round":
            return {"type": "round", "text": "Nieuwe ronde. " + text}
        name = str(line.get("name", ""))
        return {"type": "say", "text": text, "urgent": name in URGENT or kind in URGENT}

    def status(rec):
        st = link.state or {}
        tile, playing = where(rec["player"])
        if not tile:
            return {"type": "status", "text": "Je staat nog niet op een plaats. Vraag het aan de gamemaster.", "tile": 0}
        p = next((p for p in st.get("players", []) if int(p.get("tile", 0)) == tile), None)
        parts = [f"Plaats {label(tile)}"]
        if not playing:
            parts.append("druk op de 4 iconen om mee te doen")
        elif p:
            parts.append(f"{p.get('lives', 0)} {'leven' if p.get('lives') == 1 else 'levens'}")
            if p.get("out"):
                parts.append("uit het spel")
        state = st.get("state", "")
        if state and state != "LOBBY" and st.get("round"):
            parts.append(f"ronde: {st.get('round')}")
        return {"type": "status", "text": ", ".join(parts) + ".", "tile": tile, "playing": playing,
                "lives": p.get("lives") if p else None, "state": state}

    @app.get("/api/a11y/{token}/events")
    async def events(token: str):
        rec = token_record(token)
        q: asyncio.Queue = asyncio.Queue()
        listeners.add(q)

        async def stream():
            last = link.voice_seq
            shown_status = None
            try:
                st = status(rec)
                shown_status = st["text"]
                yield f"data: {json.dumps(st)}\n\n"
                # the question being asked now (when the page opens in the middle of it)
                lines = list(link.voice)
                start = next((i for i in range(len(lines) - 1, -1, -1)
                              if lines[i].get("kind") in ("question", "round") and time.time() - lines[i].get("at", 0) < 90), None)
                for line in lines[start:] if start is not None else []:
                    msg = to_message(line, st.get("tile", 0))
                    if msg and line.get("kind") in ("question", "answer", "round"):
                        yield f"data: {json.dumps({**msg, 'replay': True})}\n\n"
                while True:
                    try:
                        await asyncio.wait_for(q.get(), timeout=15.0)
                        while not q.empty():
                            q.get_nowait()
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"                     # (keeps proxies and phones from closing it)
                    st = status(rec)
                    for line in [l for l in list(link.voice) if l["seq"] > last]:
                        last = line["seq"]
                        msg = to_message(line, st.get("tile", 0))
                        if msg:
                            yield f"data: {json.dumps(msg)}\n\n"
                    if st["text"] != shown_status:
                        shown_status = st["text"]
                        yield f"data: {json.dumps(st)}\n\n"
            finally:
                listeners.discard(q)
                if token in watching:                          # the page is gone: its video too
                    try:
                        video(token, VideoIn(on=False))
                    except HTTPException:
                        watching.pop(token, None)                  # (left already: the game stops it itself)

        return StreamingResponse(stream(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

    @app.post("/api/a11y/{token}/press")
    def press(token: str, p: PressIn):
        """An answer button on the page = pressing that icon on the tile."""
        rec = token_record(token)
        if not opts.get("buttons", True):
            raise HTTPException(403, "answer buttons are off")
        if p.button not in BUTTONS:
            raise HTTPException(400, "unknown button")
        tile, _ = where(rec["player"])
        if not tile:
            raise HTTPException(409, "not on a place")
        link.command({"tile": tile, "press": p.button})
        return {"ok": True}

    # ------------------------------------------------------------ the video (partially sighted players)

    @app.post("/api/a11y/{token}/video")
    def video(token: str, v: VideoIn):
        """Start / keep alive (every ~10 s) / stop the video of the player's screen."""
        rec = token_record(token)
        if not opts.get("stream_publish"):
            raise HTTPException(404, "no video on this installation")
        tile, _ = where(rec["player"])
        if not tile:
            raise HTTPException(409, "not on a place")
        if v.on:
            watching[token] = time.time()
            link.command({"stream": {"tile": tile, "on": True, "url": f"{opts['stream_publish']}/{rec['path']}",
                                     "fps": opts.get("fps", 15), "encoder": opts.get("encoder", "auto")}})
            return {"whep": f"{opts['stream_view']}/{rec['path']}/whep?token={token}",
                    "state": link.streams.get(tile, {})}
        watching.pop(token, None)
        link.command({"stream": {"tile": tile, "on": False}})
        return {"ok": True}

    @app.post("/api/a11y/stream-auth")
    async def stream_auth(request: Request):
        """MediaMTX (authMethod: http): may this publish / read this path?
        Publish: the game, with the stream login. Read: a page with a valid
        token for exactly this path."""
        try:
            a = await request.json()
        except ValueError:
            raise HTTPException(400, "json")
        action = a.get("action", "")
        if action == "publish":
            if opts.get("stream_user") and a.get("user") == opts.get("stream_user") \
                    and secrets.compare_digest(str(a.get("password", "")), str(opts.get("stream_password", ""))):
                return {"ok": True}
            raise HTTPException(401, "publish: bad login")
        if action in ("read", "playback"):
            token = (parse_qs(a.get("query", "")).get("token") or [""])[0]
            rec = tokens().get(token)
            if rec and rec.get("path") == a.get("path"):
                return {"ok": True}
            raise HTTPException(401, "read: no valid link for this stream")
        raise HTTPException(401, "not allowed")
