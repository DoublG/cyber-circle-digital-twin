#!/usr/bin/env python3
"""Checks the compose test setup (deploy/docker-compose.yml) end to end: the
certificates, the lookup by name and every link between the parts.
Python standard library + docker; with the compose up:
    python3 deploy/check.py            (ports: the same as in deploy/.env, or the defaults)
"""
import json, os, socket, ssl, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CA = os.path.join(HERE, "certs", "ca.pem")


def env(name, default):                      # the mapping in deploy/.env
    try:
        for line in open(os.path.join(HERE, ".env")):
            k, _, v = line.strip().partition("=")
            if k == name and v:
                return v
    except OSError:
        pass
    return os.environ.get(name, default)


PORTS = {"control (https)": int(env("CONTROL_PORT", 8443)), "broker (mqtts)": int(env("MQTTS_PORT", 8883)),
         "broker (wss)": int(env("WSS_PORT", 9443))}
BASE = "https://localhost:%d" % PORTS["control (https)"]
TILE_WEB = int(env("TILE1_PORT", 8191))
CTX = ssl.create_default_context(cafile=CA)
fails = 0


def check(ok, what):
    global fails
    print(("  [ok] " if ok else "  [FAIL] ") + what, flush=True)
    fails += 0 if ok else 1
    return ok


def tls(host, port, ctx, name=None):
    with socket.create_connection((host, port), timeout=5) as s:
        with ctx.wrap_socket(s, server_hostname=name or host) as t:
            return t.getpeercert()


def call(method, path, body=None):
    r = urllib.request.Request(BASE + path, method=method, headers={"Content-Type": "application/json"},
                               data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(r, context=CTX, timeout=8) as x:
        return json.loads(x.read() or b"null")


def live():
    with urllib.request.urlopen(BASE + "/api/live", context=CTX, timeout=8) as x:
        return json.loads(x.readline().decode()[6:])


def until(f, t=30):
    end = time.time() + t
    while time.time() < end:
        try:
            v = f()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.5)
    return None


print("certificates (this PC, the mapped ports):")
for what, port in PORTS.items():
    try:
        cert = tls("localhost", port, CTX)
        check(True, "%s on localhost:%d: signed by our CA, valid for localhost (until %s)" % (what, port, cert["notAfter"]))
    except Exception as e:
        check(False, "%s on localhost:%d: %s" % (what, port, e))
try:
    tls("localhost", PORTS["control (https)"], ssl.create_default_context())
    check(False, "without our CA the connection should be refused")
except ssl.SSLCertVerificationError:
    check(True, "without our CA: refused (the system does not trust it - as it should)")
except OSError as e:
    check(False, "without our CA: %s" % e)
try:
    tls("127.0.0.1", PORTS["control (https)"], CTX, name="wrong-name.example")
    check(False, "a name not in the certificate should be refused")
except ssl.SSLCertVerificationError:
    check(True, "a name not in the certificate: refused (hostname check)")
except OSError as e:
    check(False, "hostname check: %s" % e)
if fails:
    print("DONE: %d failure(s) - is the compose up? (cd deploy && docker compose up -d)" % fails)
    sys.exit(1)

print("lookup by name inside the compose network (from the control container):")
probe = ("import socket,ssl;c=ssl.create_default_context(cafile='/certs/ca.pem')\n"
         "for h,p in (('broker',8883),('broker',9443),('control',8443)):\n"
         "  s=c.wrap_socket(socket.create_connection((h,p),5),server_hostname=h);"
         "print(h,p,socket.gethostbyname(h),s.version());s.close()")
r = subprocess.run(["docker", "exec", "cybercircle-control-1", "python", "-c", probe],
                   capture_output=True, text=True)
for line in r.stdout.split("\n"):
    if line.strip():
        h, p, ip, v = line.split()
        check(True, "%s:%s -> %s, %s, certificate valid for '%s'" % (h, p, ip, v, h))
if r.returncode:
    check(False, "lookup / TLS inside the network: " + r.stderr.strip().split("\n")[-1])

print("the links:")
cfg = call("GET", "/api/config")
check(cfg["mqtt"].startswith("wss://localhost:"), "the app is told the broker: %s" % cfg["mqtt"])
snap = live()
check(snap["mqtt"], "control server -> broker over wss (with our CA)")
nodes = {n["id"]: n for n in snap["nodes"] if n.get("online")}
check("screen-pc" in nodes, "the game on the screen PC announces itself: %s" % (nodes.get("screen-pc", {}).get("host", "-")))
check(bool((snap["state"] or {}).get("state")), "the game's state reaches the control server over MQTT: %s, mode %s"
      % ((snap["state"] or {}).get("state"), snap["mode"]))
devs = {d["device"]: d for d in snap["devices"] if d["online"]}
check(len(devs) >= 3, "the emulated tiles over plain MQTT: %s" % ", ".join(sorted(devs)))

print("a visitor plays on an emulated tile (the game asks the control server over https):")
if not any(t["number"] == 1 and t["device"] == "02:00:00:00:00:01" for t in call("GET", "/api/tiles")["tiles"]):
    call("PUT", "/api/tiles/1", {"device": "02:00:00:00:00:01"})   # (once: refused while the game is open)
call("POST", "/api/mode", {"mode": "closed"}); time.sleep(0.5); call("POST", "/api/mode", {"mode": "open"})
time.sleep(2)
name = "Check %d" % (time.time() % 10000)
pid = call("POST", "/api/players", {"name": name, "age": 12})["id"]
call("POST", "/api/players/%d/assign" % pid, {"tile": 1, "color": "#33ccff"})
inv = until(lambda: any(p["tile"] == 1 for p in live()["state"].get("pending", [])))
check(bool(inv), "invited on T01: the game fetched the player from the control server (https)")
time.sleep(1.5)
for i in range(4):                           # the 4 icons, as on the tile's top in the browser
    for down in (1, 0):
        urllib.request.urlopen("http://localhost:%d/press?i=%d&down=%d" % (TILE_WEB, i, down), timeout=3).read()
        time.sleep(0.25)
check(bool(until(lambda: any(p["tile"] == 1 and p["name"] == name for p in live()["state"]["players"]))),
      "'%s' plays on T01: activated with the emulated tile's icons" % name)
r = subprocess.run(["docker", "exec", "cybercircle-mysql-1", "sh", "-c",
                    'mysql -N -ucybercircle -p"$MYSQL_PASSWORD" cybercircle -e "SELECT COUNT(*) FROM players WHERE name = \'%s\'"' % name],
                   capture_output=True, text=True)
check(r.stdout.strip() == "1", "'%s' is stored in MySQL (players: %s)" % (name, r.stdout.strip() or r.stderr.strip()[-80:]))

print("the game crashes and comes back from the control server's copy (a new container: no local file):")
lives = next(p["lives"] for p in live()["state"]["players"] if p["tile"] == 1)
time.sleep(1.5)                                 # (a checkpoint every 0.5 s at most)
compose = ["docker", "compose", "--project-directory", HERE]
subprocess.run(compose + ["rm", "-sf", "game"], capture_output=True)
since = call("GET", "/api/mqtt/log?limit=1")["seq"]
subprocess.run(compose + ["up", "-d", "game"], capture_output=True)
until(lambda: call("GET", "/api/mqtt/log?since=%d&filter=cybercircle/state" % since)["messages"], 90)
back = until(lambda: next((p for p in live()["state"]["players"] if p["tile"] == 1 and p["name"] == name), None), 30)
check(bool(back) and back["lives"] == lives, "'%s' back on T01 with %s lives after the game was recreated" % (name, lives))
call("POST", "/api/tiles/1/leave")
print("DONE: %d failure(s)" % fails)
sys.exit(1 if fails else 0)
