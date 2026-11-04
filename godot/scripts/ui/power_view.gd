class_name PowerView
extends Control
## Every screen during the robot's shows (GameManager._power):
##   boot      dark, a cursor; the robot's system starting line by line with a
##             progress bar; then SYSTEEM ONLINE - it sees you.
##   shutdown  the players' attack, the system glitching, the errors, the power
##             failing - GEWONNEN: the robot is shut down.
## On the game's clock from `at` (Retro.game_clock: the same moment on every
## screen of every node, and in the movies).

const BOOT_LINES := [
	[2.0, "CYBER CIRCLE OS  v4.7"],
	[3.2, "GEHEUGEN ............ OK"],
	[4.4, "STROOM .............. OK"],
	[5.6, "13 SENSOREN ......... OK"],
	[6.8, "KOPMOTOR ............ OK"],
	[8.0, "WAPENSYSTEEM ........ OK"],
	[9.6, "ROOKMACHINE ......... OK"],
	[11.2, "SPELERS ZOEKEN ......"],
]
const FAIL_LINES := [
	[9.0, "KOPMOTOR ............ FOUT"],
	[9.8, "13 SENSOREN ......... FOUT"],
	[10.6, "WAPENSYSTEEM ........ FOUT"],
	[11.4, "GEHEUGEN ............ FOUT"],
	[12.2, "STROOM .............. 12 %"],
]
const GLITCH := "#@%&$*!?<>/\\|=+~^01"

var kind := "boot"
var at := 0.0
var _bg: ColorRect
var _lines: Label
var _big: Label
var _sub: Label
var _bar: ProgressBar
var _glitch_frame := -1


func _init(show_kind := "boot", start_at := 0.0) -> void:
	kind = show_kind
	at = start_at
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg = ColorRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.color = Color.BLACK
	add_child(_bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 120
	box.offset_right = -120
	box.offset_top = 80
	box.offset_bottom = -80
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 36)
	add_child(box)
	_lines = Retro.label(44, Retro.GOOD)
	_lines.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(_lines)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 34)
	_bar.show_percentage = false
	_bar.max_value = 1.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = Retro.GOOD
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.1, 0.1, 0.1)
	back.border_color = Color(Retro.GOOD, 0.5)
	back.set_border_width_all(3)
	_bar.add_theme_stylebox_override("fill", fill)
	_bar.add_theme_stylebox_override("background", back)
	box.add_child(_bar)
	_big = Retro.label(130, Retro.AMBER)
	_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_big)
	_sub = Retro.label(60, Retro.CREAM)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_sub)
	_process(0.0)


func _process(_delta: float) -> void:
	var t := Retro.game_clock - at
	if kind == "boot":
		_boot(t)
	else:
		_shutdown(t)


func _typed(lines: Array, t: float) -> String:
	var out := []
	for l in lines:
		if t >= l[0]:
			var chars := int((t - l[0]) * 40.0)            # typing, 40 characters a second
			out.append(str(l[1]).left(chars))
	return "\n".join(out)


func _cursor(t: float) -> String:
	return "_" if fmod(t, 0.8) < 0.4 else " "


func _boot(t: float) -> void:
	_bg.color = Color.BLACK
	if t < 2.0:                                            # dark, a blinking cursor
		_lines.text = _cursor(t)
		_bar.visible = false
		_big.text = ""
		_sub.text = ""
		return
	_lines.text = _typed(BOOT_LINES, t) + _cursor(t)
	_lines.add_theme_color_override("font_color", Retro.GOOD)
	_bar.visible = true
	_bar.value = clampf((t - 3.0) / 10.5, 0.0, 1.0)
	if t >= 14.0:                                          # awake
		_lines.text = _typed(BOOT_LINES, t) + "  GEVONDEN"
		_big.text = "SYSTEEM ONLINE"
		_big.add_theme_color_override("font_color", Retro.AMBER)
		_sub.text = "Ik zie jullie..." if t >= 15.0 else ""
	else:
		_big.text = ""
		_sub.text = ""


func _shutdown(t: float) -> void:
	_bar.visible = false
	if t < 1.6:                                            # the players' attack (no full-screen flashing:
		_bg.color = Color(0.0, 0.12, 0.03)                 #  photosensitive viewers - children - see it)
		_lines.text = ""
		_big.text = "AANVAL!"
		_big.add_theme_color_override("font_color", Retro.GOOD)
		_sub.text = "Alle spelers vallen tegelijk aan"
	elif t < 8.6:                                          # electrocuted: the system glitches
		_bg.color = Color.BLACK
		if int(t * 8.0) == _glitch_frame:                  # the glitch text changes 8x a second (text only)
			return
		_glitch_frame = int(t * 8.0)
		var rows := []
		for r in 7:
			var row := ""
			for c in randi_range(10, 28):
				row += GLITCH[randi() % GLITCH.length()]
			rows.append(row)
		_lines.text = "\n".join(rows)
		_lines.add_theme_color_override("font_color", Color.from_hsv(randf(), 0.7, 1.0))
		_lines.position.x = randf_range(-12.0, 12.0)
		_big.text = "STROOMSTOORING" if randf() < 0.8 else "ST#OOMST&RING"
		_big.add_theme_color_override("font_color", Retro.BAD)
		_sub.text = ""
	elif t < 18.0:                                         # the errors, the power failing
		_bg.color = Color.BLACK
		_lines.position.x = 0.0
		_lines.text = _typed(FAIL_LINES, t)
		_lines.add_theme_color_override("font_color", Retro.BAD)
		_big.text = "SYSTEEMFOUT" if t < 13.0 else "STROOM VALT WEG"
		var fade := clampf(1.0 - (t - 13.0) / 5.0, 0.15, 1.0)
		_big.add_theme_color_override("font_color", Color(Retro.BAD, fade))
		_sub.text = ""
	else:                                                  # won
		_bg.color = Color.BLACK
		_lines.text = ""
		_big.text = "GEWONNEN!"
		_big.add_theme_color_override("font_color", Retro.GOOD)
		_sub.text = "De robot is uitgeschakeld.\nTot de volgende keer..." if t >= 19.0 else ""
