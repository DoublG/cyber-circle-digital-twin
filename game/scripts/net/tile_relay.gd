class_name TileRelay
extends RefCounted
## A tile's visual actions as the game calls them (arena.rt(id).play_hit(...)):
## the call runs here and goes to every display node (Replica.relay; its LED
## ring is a target of its own: "ring:3"). The
## tile's own calls (its animations, TileFirmware's LEDs) don't go through
## here: the displays run those themselves.

var tile: CyberTile
var target := ""
var ring_target := ""


func _init(t: CyberTile) -> void:
	tile = t
	target = "tile:%d" % t.tile_id
	ring_target = "ring:%d" % t.tile_id


func _r(method: StringName, args: Array) -> void:
	Replica.relay(target, method, args)


func start_activation(color := Color.WHITE) -> void:
	_r(&"start_activation", [color])
	tile.start_activation(color)


func cancel_activation() -> void:
	_r(&"cancel_activation", [])
	tile.cancel_activation()


func set_ring_led(index: int, color: Color) -> void:
	Replica.relay(ring_target, &"set_led", [index, color])
	tile.ring.set_led(index, color)


func set_ring(colors: Array) -> void:
	Replica.relay(ring_target, &"set_all", [colors])
	tile.ring.set_all(colors)


func fill_ring(color: Color) -> void:
	Replica.relay(ring_target, &"fill", [color])
	tile.ring.fill(color)


func clear_ring() -> void:
	Replica.relay(ring_target, &"clear", [])
	tile.ring.clear()


func blink_doomed() -> void:
	_r(&"blink_doomed", [])
	tile.blink_doomed()


func play_death() -> void:
	_r(&"play_death", [])
	await tile.play_death()


func play_attack(color := Color(0.2, 1.0, 0.3)) -> void:
	_r(&"play_attack", [color])
	tile.play_attack(color)


func play_hit(color := Color(1.0, 0.1, 0.05)) -> void:
	_r(&"play_hit", [color])
	tile.play_hit(color)


func play_block(color := Color(1.0, 0.1, 0.05)) -> void:
	_r(&"play_block", [color])
	tile.play_block(color)


func revive(lives := -1) -> void:
	_r(&"revive", [lives])
	tile.revive(lives)


func set_button_led(button: StringName, color: Color) -> void:
	_r(&"set_button_led", [button, color])
	tile.set_button_led(button, color)


func press_button(button: StringName, hold := 0.15) -> void:
	_r(&"press_button", [button, hold])
	tile.press_button(button, hold)


func hold_button(button: StringName) -> void:
	_r(&"hold_button", [button])
	tile.hold_button(button)


func release_button(button: StringName) -> void:
	_r(&"release_button", [button])
	tile.release_button(button)
