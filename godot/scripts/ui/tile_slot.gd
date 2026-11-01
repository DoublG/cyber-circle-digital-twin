class_name TileSlot
extends Control
## A tile's place on its screen when there is no player on it - the same size
## as a player view, so the layout never changes when players come and go:
##   free tile:    tile number, "VRIJ", a rotating call to action and how to join
##   out of service: "BUITEN GEBRUIK" (taken out of the game by the operator)
##   invited tile: (registered in the app, not activated yet) the player's name
##                 and a bar pulsing in the colour they picked, "DRUK OP DE 4 ICONEN"
## Plain 2D (no 3D view): cheap to draw.


var tile_id := 0
var player := ""                  # "" = free tile
var out_of_service := false
var mode := "open"                # the game's mode: "setup" shows the tile number big, "closed" GESLOTEN
var color := Color.WHITE
var _t := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true


func _ready() -> void:
	var invited := player != ""
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 40)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 28)
	add_child(box)
	var badge := Retro.label(56, Retro.BG, Retro.tile_label(tile_id))
	badge.add_theme_stylebox_override("normal", Retro.panel(Retro.TEAL if invited else Color(Retro.TEAL, 0.45),
		Retro.TEAL, 0, 10, 22))
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(badge)
	if mode == "setup":                    # physical setup: which slot is which tile?
		badge.add_theme_font_size_override("font_size", 180)
		box.add_child(_wrapped("SETUP" + ("  -  BUITEN GEBRUIK" if out_of_service else ""), 48, Retro.AMBER))
	elif out_of_service:
		box.add_child(_wrapped("BUITEN GEBRUIK", 64, Color(Retro.BAD, 0.8)))
	elif mode == "closed":
		box.add_child(_wrapped("GESLOTEN", 96, Color(Retro.DIM, 0.8)))
	elif invited:
		box.add_child(_wrapped(player.to_upper(), 84, color.lightened(0.25)))
		box.add_child(_wrapped("DRUK OP DE 4 ICONEN", 40, Retro.AMBER))
	else:
		box.add_child(_wrapped("VRIJ", 96, Color(Retro.DIM, 0.8)))
		var cta := CallToAction.new(52)
		cta.custom_minimum_size.y = 200
		box.add_child(cta)
		box.add_child(_wrapped(Texts.join_text(), 32, Retro.CREAM))
	add_child(Retro.ViewFrame.new())
	set_process(invited)


func _wrapped(text: String, font_size: int, col: Color) -> Label:
	var l := Retro.label(font_size, col, text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(Retro.PANEL, 0.95))
	if player == "":
		return
	var pulse := 0.55 + 0.45 * sin(_t * 4.0)        # the colour the player looks for
	draw_rect(Rect2(40, 40, size.x - 80, 22), Color(color, pulse))
	draw_rect(Rect2(40, size.y - 62, size.x - 80, 22), Color(color, pulse))
