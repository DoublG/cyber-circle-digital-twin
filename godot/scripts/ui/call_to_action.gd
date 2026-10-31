class_name CallToAction
extends Label
## Big rotating slogan (Retro.CALLS_TO_ACTION): types itself out, pulses,
## and is replaced by the next one every `interval` seconds.

var interval := 5.0
var _index := 0
var _t := 0.0


func _init(font_size := 72) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_theme_font_override("font", Retro.FONT)
	add_theme_font_size_override("font_size", font_size)
	add_theme_color_override("font_color", Retro.AMBER)
	add_theme_color_override("font_outline_color", Color(Retro.ORANGE, 0.6))
	add_theme_constant_override("outline_size", 10)
	_index = randi() % Retro.CALLS_TO_ACTION.size()
	text = Retro.CALLS_TO_ACTION[_index]


func _process(delta: float) -> void:
	_t += delta
	if _t >= interval:
		_t = 0.0
		_index = (_index + 1) % Retro.CALLS_TO_ACTION.size()
		text = Retro.CALLS_TO_ACTION[_index]
	visible_ratio = clampf(_t / 0.8, 0.0, 1.0)            # typewriter
	modulate.a = 0.75 + 0.25 * sin(_t * 6.0)              # glow pulse
