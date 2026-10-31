class_name StatusLine
extends Label
## One small line of round info at the bottom of a player view (rounds on the
## tile: the tile itself shows the game, this only adds what it can't show).

var source := Callable()          # () -> String; empty hides the line


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_override("font", Retro.FONT)
	add_theme_font_size_override("font_size", 40)
	add_theme_color_override("font_color", Retro.AMBER)
	add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.85), Retro.ORANGE, 3, 14, 24))
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_bottom = -24


func _process(_delta: float) -> void:
	text = str(source.call()) if source.is_valid() else ""
	visible = text != ""
