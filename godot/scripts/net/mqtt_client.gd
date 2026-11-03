class_name MqttClient
extends Node
## Minimal MQTT 3.1.1 client over WebSocket ("MQTT over HTTP", e.g.
## ws://broker:9001/mqtt or wss://...). Enough for the installation:
## CONNECT (+ user/password), SUBSCRIBE, PUBLISH QoS 0 (receives QoS 0/1),
## keep-alive pings and automatic reconnect.

signal connected
signal disconnected
signal message(topic: String, payload: PackedByteArray)

@export var url := "ws://localhost:9001/mqtt"
@export var client_id := "cybercircle-godot"
@export var username := ""
@export var password := ""
@export var keep_alive := 30               # seconds
@export var reconnect_delay := 3.0

var online := false
var msgs_in := 0                           # (counters: the Prestaties tab, NodeMetrics)
var msgs_out := 0
var bytes_in := 0
var bytes_out := 0
var reconnects := 0                        # connections lost since the start
var _ws := WebSocketPeer.new()
var _subs: Array[String] = []
var _rx := PackedByteArray()
var _packet_id := 0
var _ping_timer := 0.0
var _retry := -1.0                         # >= 0: seconds until reconnect
var _was_open := false


func _ready() -> void:
	set_process(false)                     # idle until start()


func start() -> void:
	set_process(true)
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["mqtt"])
	_rx.clear()
	_was_open = false
	var err := _ws.connect_to_url(url, TlsTrust.options if url.begins_with("wss") else null)
	if err != OK:
		push_warning("mqtt: cannot connect to %s (%s)" % [url, error_string(err)])
		_retry = reconnect_delay


func subscribe(topic: String) -> void:
	if topic not in _subs:
		_subs.append(topic)
	if online:
		_send_subscribe(topic)


func publish(topic: String, payload, retain := false) -> void:
	if not online:
		return
	var body: PackedByteArray = payload.to_utf8_buffer() if payload is String else payload
	var v := _str(topic)
	v.append_array(body)
	_send(0x30 | (0x01 if retain else 0x00), v)


func publish_json(topic: String, data, retain := false) -> void:
	publish(topic, JSON.stringify(data), retain)


func _process(delta: float) -> void:
	if _retry >= 0.0:
		_retry -= delta
		if _retry < 0.0:
			start()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				_send_connect()
			while _ws.get_available_packet_count() > 0:
				_rx.append_array(_ws.get_packet())
			_parse()
			if online:
				_ping_timer += delta
				if _ping_timer >= keep_alive * 0.5:
					_ping_timer = 0.0
					_send(0xC0, PackedByteArray())    # PINGREQ
		WebSocketPeer.STATE_CLOSED:
			if online or _was_open:
				if online:
					reconnects += 1
				online = false
				disconnected.emit()
			_retry = reconnect_delay


# ---------------------------------------------------------------- packets

func _send_connect() -> void:
	var flags := 0x02                          # clean session
	var payload := _str(client_id)
	if username != "":
		flags |= 0x80
		payload.append_array(_str(username))
		if password != "":
			flags |= 0x40
			payload.append_array(_str(password))
	var v := _str("MQTT")
	v.append_array(PackedByteArray([4, flags, keep_alive >> 8, keep_alive & 0xFF]))
	v.append_array(payload)
	_send(0x10, v)


func _send_subscribe(topic: String) -> void:
	_packet_id = _packet_id % 65535 + 1
	var v := PackedByteArray([_packet_id >> 8, _packet_id & 0xFF])
	v.append_array(_str(topic))
	v.append(0)                                # QoS 0
	_send(0x82, v)


func _parse() -> void:
	while _rx.size() >= 2:
		var length := 0
		var mult := 1
		var i := 1
		while true:
			if i >= _rx.size():
				return                         # length not complete yet
			var b := _rx[i]
			length += (b & 0x7F) * mult
			mult *= 128
			i += 1
			if b & 0x80 == 0:
				break
		if _rx.size() < i + length:
			return                             # packet not complete yet
		var header := _rx[0]
		var body := _rx.slice(i, i + length)
		_rx = _rx.slice(i + length)
		_handle(header, body)


func _handle(header: int, body: PackedByteArray) -> void:
	match header >> 4:
		2:                                     # CONNACK
			if body.size() >= 2 and body[1] == 0:
				online = true
				_ping_timer = 0.0
				for t in _subs:
					_send_subscribe(t)
				connected.emit()
			else:
				push_warning("mqtt: connection refused (code %d)" % (body[1] if body.size() > 1 else -1))
				_ws.close()
		3:                                     # PUBLISH
			var qos := (header >> 1) & 0x03
			var tlen := (body[0] << 8) | body[1]
			var topic := body.slice(2, 2 + tlen).get_string_from_utf8()
			var p := 2 + tlen
			if qos > 0:
				var pid := body.slice(p, p + 2)
				p += 2
				if qos == 1:
					_send(0x40, pid)           # PUBACK
			msgs_in += 1
			bytes_in += body.size()
			message.emit(topic, body.slice(p))


func _send(header: int, body: PackedByteArray) -> void:
	var pkt := PackedByteArray([header])
	var n := body.size()
	while true:                                # remaining length, varint
		var b := n % 128
		n /= 128
		pkt.append(b | (0x80 if n > 0 else 0))
		if n == 0:
			break
	pkt.append_array(body)
	if header >> 4 == 3:
		msgs_out += 1
		bytes_out += pkt.size()
	_ws.send(pkt, WebSocketPeer.WRITE_MODE_BINARY)


func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray([b.size() >> 8, b.size() & 0xFF])
	out.append_array(b)
	return out
