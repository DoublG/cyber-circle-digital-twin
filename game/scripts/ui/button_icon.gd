class_name ButtonIcon
extends Control
## The etched icon of a tile button, as a glowing line drawing.


@export var button: StringName = &"Square"
@export var color := Color.WHITE:
	set(c):
		color = c
		queue_redraw()
@export var glow := true


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	Retro.draw_icon(self, button, size / 2, minf(size.x, size.y) * 0.4, color, glow)
