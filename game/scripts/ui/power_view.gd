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
	[2.0, "CYBER CIRCLE CHALLENGE  OS v4.7"],
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
const SCENE := "res://scenes/ui/power_view.tscn"
const GLITCH := "#@%&$*!?<>/\\|=+~^01"

var kind := "boot"
var at := 0.0
var _glitch_frame := -1

@onready var _bg: ColorRect = %Bg
@onready var _lines: Label = %Lines
@onready var _big: Label = %Big
@onready var _sub: Label = %Sub
@onready var _bar: ProgressBar = %Bar


## The show `show_kind` ("boot" / "shutdown"), started at `start_at` on the game's clock.
static func create(show_kind := "boot", start_at := 0.0) -> PowerView:
	var v: PowerView = load(SCENE).instantiate()
	v.kind = show_kind
	v.at = start_at
	return v


func _ready() -> void:
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
