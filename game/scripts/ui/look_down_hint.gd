class_name LookDownHint
extends Control
## "Look at your tile": bouncing arrows pointing down, shown while the player
## camera tilts from the robot down to the player's own tile. Fades out by
## itself after `lifetime` seconds.

const SCENE := "res://scenes/ui/look_down_hint.tscn"

var lifetime := 4.0
var _t := 0.0


static func create() -> LookDownHint:
	return load(SCENE).instantiate()


func _process(delta: float) -> void:
	_t += delta
	modulate.a = clampf((lifetime - _t) / 0.6, 0.0, 1.0)
	if _t >= lifetime:
		queue_free()
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var bob := absf(sin(_t * 5.0)) * 30.0
	var top := 280.0 + bob
	for k in 3:                       # three chevrons, the lowest the brightest
		var y := top + k * 55.0
		var a := 0.35 + 0.3 * k
		_chevron(Vector2(w * 0.5, y), 90.0, Color(Retro.AMBER, a))
	for side in [-1, 1]:              # and an arrow at each side, pointing down
		var x: float = w * 0.5 + side * w * 0.36
		_chevron(Vector2(x, top + 70.0), 70.0, Color(Retro.ORANGE, 0.8))


func _chevron(tip_top: Vector2, half: float, color: Color) -> void:
	var h := half * 0.55
	var t := half * 0.32               # thickness
	draw_colored_polygon(PackedVector2Array([
		tip_top + Vector2(-half, 0), tip_top + Vector2(0, h), tip_top + Vector2(half, 0),
		tip_top + Vector2(half, t), tip_top + Vector2(0, h + t), tip_top + Vector2(-half, t)]), color)
