class_name ShieldIcon
extends Control
## Shield badge: protected player (question too hard for their age).


@export var color := Color(0.3, 0.75, 1.0):
	set(c):
		color = c
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var w := size.x
	var h := size.y
	var pts := PackedVector2Array([
		Vector2(w * 0.5, h * 0.04), Vector2(w * 0.92, h * 0.18), Vector2(w * 0.86, h * 0.58),
		Vector2(w * 0.5, h * 0.96), Vector2(w * 0.14, h * 0.58), Vector2(w * 0.08, h * 0.18)])
	draw_colored_polygon(pts, color)
	var inner := PackedVector2Array()
	for p in pts:
		inner.append(p.lerp(Vector2(w * 0.5, h * 0.45), 0.35))
	inner.append(inner[0])
	draw_polyline(inner, Color(1, 1, 1, 0.85), maxf(2.0, w * 0.07), true)
