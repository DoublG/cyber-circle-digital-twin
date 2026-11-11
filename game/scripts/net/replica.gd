class_name Replica
extends Node
## Game-state replication between the master and the display nodes (a
## Raspberry Pi per 2 split screens), with Godot's high-level multiplayer:
## ENetMultiplayerPeer + RPCs (docs/SETUP.md §4 *Display nodes*).
##
## The master runs the game; a display node (arena.tscn -- --replica) runs the
## same scene - the same 3D world, the same screens and views - but no game
## logic: it follows the master's state and plays its visual events, so it
## renders on its own and keeps animating when the network hiccups.
##   fields   the state the screens read (players, invites, lives, the game's
##            state, the round and what its views show: ArenaMirror.fields,
##            GameManager.replica_fields), sent as deltas on change (reliable);
##            a full snapshot when a display (re)connects
##   events   what happens (relay(): a popup, the robot fires, a tile explodes,
##            a sound, a light cue, a tile program ...): reliable, in order -
##            every event goes out after the fields it depends on
##   live     what changes every frame (the game clock, round timers, a view's
##            state: relay_live()): unreliable, the latest wins, 15 Hz (more
##            than one packet: reliable, on a channel of its own)
## Only the master talks to MQTT and the control server; a display node may
## read its own tiles' MQTT topics (Arena: --mqtt on a replica).
##
## Master:  --serve-replicas[=7350]          a UDP beacon on BEACON_PORT says where
## Display: --replica --master=HOST[:PORT]   (no --master: the beacon)

signal online_changed(on: bool)          # display: connected to the master / lost it
signal peers_changed                     # master: a display came or went

const PORT := 7350
const BEACON_PORT := 7351
const VERSION := 1
const LIVE_HZ := 15.0
const FIELDS_HZ := 10.0
const CLOCK_WINDOW := 6                   # live messages (0.4 s): the least late one tells the master's clock
const CLOCK_JUMP := 0.15                  # s: a display's game clock this far off jumps to the master's ...
const CLOCK_NUDGE := 0.01                 # ... and closer, it eases there: at most this per CLOCK_WINDOW
const RECONNECT := [1.0, 2.0, 3.0, 5.0]   # s between attempts (then 5 s)

static var server := false               # this is the master, serving displays
static var client := false               # this is a display node
static var _self: Replica
static var debug := OS.get_environment("REPLICA_DEBUG") == "1"   # (tests: what it takes from where)

var arena: Arena
var port := PORT
var master_host := ""                    # display: "" = from the beacon
var node_id := ""
var screens: Array = []                  # display: the screen numbers it shows
var online := false
var peers := {}                          # master: peer id -> {node, screens, since, metrics, host}
var stats := {"events": 0, "deltas": 0, "snapshots": 0, "live": 0, "connects": 0,
	"connected_at": 0.0, "bytes": 0}
var on_metrics := Callable()             # master: (peer info, metrics) -> publish them (MqttBridge)

var _peer: ENetMultiplayerPeer
var _sent := {}                          # master: field -> value last sent
var _live := {}                          # master: key -> args waiting for the next live send
var _live_last := {}                     # master: key -> args sent last (dedupe)
var _t_fields := 0.0
var _t_live := 0.0
var _t_beacon := 0.0
var _t_retry := 0.0
var _attempt := 0
var _beacon: PacketPeerUDP
var _since_snapshot := false             # display: a snapshot arrived on this connection
var _drifts: Array[float] = []           # display: the master's clock - ours, per live message (CLOCK_WINDOW)
var _rx_msec := 0                        # display: when the master's last message came in
var _live_n := 0


# ---------------------------------------------------------------- start

## Master: listen for display nodes. false: the port is taken.
func serve() -> bool:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, 16, 2)
	if err != OK:
		push_warning("replica: cannot listen on UDP %d (%s)" % [port, error_string(err)])
		return false
	_peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = _peer
	multiplayer.server_relay = false
	multiplayer.peer_connected.connect(func(id):
		print("replica: a display connected (peer %d)" % id)
		if _peer.get_peer(id):
			_peer.get_peer(id).set_timeout(32, 3000, 6000))   # (a dead display goes in ~6 s, not 30)
	multiplayer.peer_disconnected.connect(func(id):
		var p: Dictionary = peers.get(id, {})
		print("replica: display %s left" % p.get("node", str(id)))
		peers.erase(id)
		peers_changed.emit())
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	server = true
	_self = self
	print("replica: serving display nodes on UDP %d" % port)
	return true


## Display: connect to the master (and keep reconnecting).
func join() -> void:
	client = true
	_self = self
	if master_host == "":
		_beacon = PacketPeerUDP.new()
		if _beacon.bind(BEACON_PORT) != OK:
			push_warning("replica: cannot listen for the master's beacon on UDP %d" % BEACON_PORT)
	_t_retry = 0.0


func _connect() -> void:
	if master_host == "":
		return
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(master_host, port, 2)
	if err != OK:
		push_warning("replica: cannot reach %s:%d (%s)" % [master_host, port, error_string(err)])
		_peer = null
		return
	_peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_lost)
		multiplayer.server_disconnected.connect(_on_lost)
	# (lost faster than ENet's default 30 s: the badge, then reconnect)
	_peer.get_peer(1).set_timeout(32, 3000, 6000)


func _on_connected() -> void:
	_attempt = 0
	stats.connects += 1
	stats.connected_at = Time.get_unix_time_from_system()
	_since_snapshot = false
	print("replica: connected to the master %s:%d" % [master_host, port])
	_hello.rpc_id(1, {"node": node_id, "screens": screens, "version": VERSION})


func _on_lost() -> void:
	if online:
		print("replica: lost the master")
	online = false
	_since_snapshot = false
	multiplayer.multiplayer_peer = null
	_peer = null
	_t_retry = RECONNECT[mini(_attempt, RECONNECT.size() - 1)]
	_attempt += 1
	online_changed.emit(false)


# ---------------------------------------------------------------- master: sending

## An event for every display: target.method(args) runs there (relay targets:
## ArenaMirror.target). The fields it depends on go out first. Callables and
## objects can't travel: they are left out (null).
static func relay(target: String, method: StringName, args := []) -> void:
	if not server or _self == null or _self.peers.is_empty():
		return
	_self._flush_fields()
	_self._event.rpc(target, method, _clean(args))
	_self.stats.events += 1


## The same, only for the displays showing one of these screens (a voice line).
static func relay_to_screens(screen_numbers: Array, target: String, method: StringName, args := []) -> void:
	if not server or _self == null or _self.peers.is_empty():
		return
	_self._flush_fields()
	for id in _self.peers:
		var shown: Array = _self.peers[id].get("screens", [])
		if screen_numbers.is_empty() or shown.any(func(k): return k in screen_numbers):
			_self._event.rpc_id(id, target, method, _clean(args))
	_self.stats.events += 1


## A call that is made every frame with the latest state (a view's countdown,
## the timer label): only the latest goes out, LIVE_HZ, unreliable - and once
## a second reliably (a lost one is replaced anyway). Repeats are not sent.
static func relay_live(target: String, method: StringName, args := []) -> void:
	if not server or _self == null or _self.peers.is_empty():
		return
	_self._live["%s|%s" % [target, method]] = [target, method, _clean(args)]


## Tests: a digest per field (the round's own id left out: it differs per node).
static func digests(fields: Dictionary) -> Dictionary:
	var out := {}
	for k in fields:
		var v = fields[k]
		if k == "round" and v is Dictionary:
			v = v.duplicate()
			v.erase("id")
		out[k] = JSON.stringify(v, "", true).sha1_text().left(10)
	return out


static func is_display() -> bool:
	return client


static func _clean(v):
	if v is Callable or (v is Object and not v is Resource):
		return null
	if v is Resource:
		return (v as Resource).resource_path if (v as Resource).resource_path != "" else null
	if v is Array:
		return v.map(func(x): return _clean(x))
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _clean(v[k])
		return out
	return v


## Fields that changed since they were last sent (deltas, reliable).
func _flush_fields() -> void:
	if peers.is_empty():
		return
	var now: Dictionary = arena.mirror.fields()
	var delta := {}
	for k in now:
		if not _sent.has(k) or not _same(_sent[k], now[k]):
			delta[k] = now[k]
			_sent[k] = now[k].duplicate(true) if now[k] is Dictionary or now[k] is Array else now[k]
	if not delta.is_empty():
		_delta.rpc(delta)
		stats.deltas += 1


static func _same(a, b) -> bool:
	return typeof(a) == typeof(b) and a == b


func _send_live() -> void:
	_live_n += 1
	var force := _live_n % int(LIVE_HZ) == 0           # (once a second everything again: a lost one)
	var calls := []
	for key in _live:
		var c: Array = _live[key]
		if force or not _live_last.has(key) or not _same(_live_last[key], c):
			calls.append(c)
			_live_last[key] = c
	_live.clear()
	var data := {"clock": arena.clock, "fast": arena.mirror.fast(), "calls": calls}
	if var_to_bytes(data).size() > 1200:      # (more than one UDP packet: unreliable fragments get lost)
		_live_big.rpc(data)
	else:
		_live_msg.rpc(data)
	stats.live += 1


func _process(delta: float) -> void:
	if server:
		_t_beacon -= delta
		if _t_beacon <= 0.0 and _beacon:
			_t_beacon = 1.0
			_beacon.set_dest_address("255.255.255.255", BEACON_PORT)
			_beacon.put_packet(JSON.stringify({"cybercircle": "master", "port": port, "node": node_id}).to_utf8_buffer())
		if peers.is_empty():
			return
		_t_fields -= delta
		if _t_fields <= 0.0:
			_t_fields = 1.0 / FIELDS_HZ
			_flush_fields()
		_t_live -= delta
		if _t_live <= 0.0:
			_t_live = 1.0 / LIVE_HZ
			_send_live()
	elif client:
		if _beacon and _beacon.is_bound():
			while _beacon.get_available_packet_count() > 0:
				var data = JSON.parse_string(_beacon.get_packet().get_string_from_utf8())
				var from := _beacon.get_packet_ip()
				if data is Dictionary and data.get("cybercircle") == "master" and from != "":
					if from != master_host or int(data.get("port", PORT)) != port:
						print("replica: the master is at %s:%d (beacon)" % [from, int(data.get("port", PORT))])
						master_host = from
						port = int(data.get("port", PORT))
						if _peer:
							_peer.close()
							_on_lost()
						_t_retry = 0.0
		if _peer == null:
			_t_retry -= delta
			if _t_retry <= 0.0:
				_t_retry = RECONNECT[mini(_attempt, RECONNECT.size() - 1)]
				_attempt += 1
				_connect()


# ---------------------------------------------------------------- RPCs

## display -> master: who it is and which screens it shows; answered with a snapshot.
@rpc("any_peer", "call_remote", "reliable")
func _hello(info: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	var host := ""
	if _peer and _peer.get_peer(id):
		host = _peer.get_peer(id).get_remote_address()
	peers[id] = {"node": str(info.get("node", "display-%d" % id)), "screens": info.get("screens", []),
		"since": Time.get_unix_time_from_system(), "host": host, "metrics": {}}
	print("replica: display %s (%s) shows screen(s) %s" % [peers[id].node, host, peers[id].screens])
	_flush_fields()                        # (the others are up to date: the deltas from here go to all)
	_snapshot.rpc_id(id, {"fields": arena.mirror.fields(), "clock": arena.clock, "fast": arena.mirror.fast()})
	stats.snapshots += 1
	peers_changed.emit()


## display -> master: its performance (NodeMetrics), every 2 s.
@rpc("any_peer", "call_remote", "unreliable")
func _metrics(m: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		return
	peers[id].metrics = m
	if on_metrics.is_valid():
		on_metrics.call(peers[id], m.merged({"link": peer_link(id)}, true))


## The ENet link to one display, as the master sees it.
func peer_link(id: int) -> Dictionary:
	if _peer == null or _peer.get_peer(id) == null:
		return {}
	var p := _peer.get_peer(id)
	return {"rtt_ms": p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
		"rtt_var_ms": p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
		"loss": snappedf(
			p.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / float(ENetPacketPeer.PACKET_LOSS_SCALE) * 100.0, 0.01),
		"throttle": p.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE),
		"host": peers.get(id, {}).get("host", ""),
		"connected_s": int(Time.get_unix_time_from_system() - float(peers.get(id, {}).get("since", 0.0)))}


## Every display as the master sees it (the Prestaties tab).
func peer_list() -> Array:
	var out := []
	for id in peers:
		out.append({"node": peers[id].node, "screens": peers[id].screens}.merged(peer_link(id), true))
	return out


## display: the game clock in step with the master's. A message is never early,
## only late (after a hitch here a few old ones come at once), so of the last
## CLOCK_WINDOW the one that is furthest on tells the master's clock. A small
## difference is eased away, without a visible jump.
func _follow_clock(master: float) -> void:
	_drifts.append(master - arena.clock)
	if _drifts.size() < CLOCK_WINDOW:
		return
	var drift: float = _drifts.max()
	_drifts.clear()
	arena.clock += drift if absf(drift) > CLOCK_JUMP else clampf(drift, -CLOCK_NUDGE, CLOCK_NUDGE)


## master -> display: everything, on (re)connect.
@rpc("authority", "call_remote", "reliable")
func _snapshot(data: Dictionary) -> void:
	arena.clock = float(data.get("clock", arena.clock))
	_drifts.clear()
	arena.mirror.apply(data.get("fields", {}), true)
	arena.mirror.apply_fast(data.get("fast", {}))
	stats.snapshots += 1
	_rx_msec = Time.get_ticks_msec()
	_since_snapshot = true
	if not online:
		online = true
		online_changed.emit(true)


@rpc("authority", "call_remote", "reliable")
func _delta(fields: Dictionary) -> void:
	if not _since_snapshot:
		return
	arena.mirror.apply(fields, false)
	stats.deltas += 1
	_rx_msec = Time.get_ticks_msec()


@rpc("authority", "call_remote", "reliable")
func _event(target: String, method: StringName, args: Array) -> void:
	if not _since_snapshot:
		return
	stats.events += 1
	_rx_msec = Time.get_ticks_msec()
	if arena.mirror.skip(target, method, args):
		if debug:
			print("replica: skipped %s.%s (its own tile: from MQTT)" % [target, method])
		return                               # (its own tiles: it had that from MQTT already)
	var obj: Object = arena.mirror.target(target)
	if obj == null or not obj.has_method(method):
		push_warning("replica: no %s.%s" % [target, method])
		return
	obj.callv(method, args)


## The same when it is too big for one packet (the quiz's screen): reliable,
## on its own channel (the events don't wait for it).
@rpc("authority", "call_remote", "reliable", 1)
func _live_big(data: Dictionary) -> void:
	_live_msg(data)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _live_msg(data: Dictionary) -> void:
	if not _since_snapshot:
		return
	stats.live += 1
	_rx_msec = Time.get_ticks_msec()
	_follow_clock(float(data.get("clock", arena.clock)))
	arena.mirror.apply_fast(data.get("fast", {}))
	for call in data.get("calls", []):
		var obj: Object = arena.mirror.target(str(call[0]))
		if obj and obj.has_method(call[1]):
			obj.callv(call[1], call[2])


## Display: send its metrics to the master (NodeMetrics extra on a display).
func send_metrics(m: Dictionary) -> void:
	if client and online:
		_metrics.rpc_id(1, m)


## Display: the link to the master (its own side).
func link() -> Dictionary:
	if _peer == null or _peer.get_peer(1) == null:
		return {"online": false, "master": "%s:%d" % [master_host, port] if master_host != "" else ""}
	var p := _peer.get_peer(1)
	return {"online": online, "master": "%s:%d" % [master_host, port],
		"rtt_ms": p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
		"rtt_var_ms": p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
		"loss": snappedf(
			p.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / float(ENetPacketPeer.PACKET_LOSS_SCALE) * 100.0, 0.01),
		"events": stats.events, "deltas": stats.deltas, "snapshots": stats.snapshots, "live": stats.live,
		"connects": stats.connects,
		"last_rx_s": snappedf((Time.get_ticks_msec() - _rx_msec) / 1000.0, 0.1) if _rx_msec > 0 else -1.0,
		"connected_s": int(Time.get_unix_time_from_system() - stats.connected_at) if online else 0}
