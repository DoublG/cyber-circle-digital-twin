class_name ViewFrame
extends Control
## Frame around one split-screen view: chamfered corners (filled with the
## screen background) and an orange edge, so views next to each other read
## as a set of matching console monitors.


@export var cut := 22.0
@export var color := Retro.ORANGE


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	var c := cut
	for corner in [[Vector2(0, 0), Vector2(c, 0), Vector2(0, c)],
			[Vector2(w, 0), Vector2(w, c), Vector2(w - c, 0)],
			[Vector2(w, h), Vector2(w - c, h), Vector2(w, h - c)],
			[Vector2(0, h), Vector2(0, h - c), Vector2(c, h)]]:
		draw_colored_polygon(PackedVector2Array(corner), Retro.BG)
	var edge := PackedVector2Array([Vector2(c, 1.5), Vector2(w - c, 1.5), Vector2(w - 1.5, c),
		Vector2(w - 1.5, h - c), Vector2(w - c, h - 1.5), Vector2(c, h - 1.5),
		Vector2(1.5, h - c), Vector2(1.5, c), Vector2(c, 1.5)])
	draw_polyline(edge, color, 3.0, true)
