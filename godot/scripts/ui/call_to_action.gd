class_name CallToAction
extends Label
## Big rotating slogan (Texts.calls(): the operator's, else Retro.CALLS_TO_ACTION): types itself out, pulses,
## and is replaced by the next one every `interval` seconds. On the game's clock
## (Retro.game_clock: the master's on every display node), so every screen of
## every node shows the same at the same time, at the game's pace;
## offset: another slogan than its neighbours (e.g. the tile number).

var interval := 10.0                # s per slogan (time to read it on a split view)
var offset := 0
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
	_index = -1
	_process(0.0)


func _process(_delta: float) -> void:
	var now := Retro.game_clock
	_t = fmod(now, interval)
	var calls := Texts.calls()
	var i := (int(now / interval) + offset) % calls.size()
	if i != _index:
		_index = i
		text = calls[_index]
	visible_ratio = clampf(_t / 0.8, 0.0, 1.0)            # typewriter
	modulate.a = 0.75 + 0.25 * sin(_t * 6.0)              # glow pulse
