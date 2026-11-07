class_name TileRelay
extends RefCounted
## A tile's visual actions as the game calls them (arena.rt(id).play_hit(...)):
## the call runs here and goes to every display node (Replica.relay). The
## tile's own calls (its animations, TileFirmware's LEDs) don't go through
## here: the displays run those themselves.

var tile: CyberTile
var target := ""


func _init(t: CyberTile) -> void:
	tile = t
	target = "tile:%d" % t.tile_id


func _r(method: StringName, args: Array) -> void:
	Replica.relay(target, method, args)


func start_activation(color := Color.WHITE) -> void:
	_r(&"start_activation", [color])
	tile.start_activation(color)


func cancel_activation() -> void:
	_r(&"cancel_activation", [])
	tile.cancel_activation()


func set_ring_led(index: int, color: Color) -> void:
	_r(&"set_ring_led", [index, color])
	tile.set_ring_led(index, color)


func set_ring(colors: Array) -> void:
	_r(&"set_ring", [colors])
	tile.set_ring(colors)


func fill_ring(color: Color) -> void:
	_r(&"fill_ring", [color])
	tile.fill_ring(color)


func clear_ring() -> void:
	_r(&"clear_ring", [])
	tile.clear_ring()


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
