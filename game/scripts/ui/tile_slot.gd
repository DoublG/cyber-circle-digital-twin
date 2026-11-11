class_name TileSlot
extends Control
## A tile's place on its screen when there is no player on it - the same size
## as a player view, so the layout never changes when players come and go:
##   free tile:    tile number, "VRIJ", a rotating call to action and how to join
##   out of service: "BUITEN GEBRUIK" (taken out of the game by the operator)
##   invited tile: (registered in the app, not activated yet) the player's name
##                 and a bar pulsing in the colour they picked, "DRUK OP DE 4 ICONEN"
##                 with the tile drawn from above: its ring in their colour, the 4
##                 quarters with their icons (the robot side up); a pressed quarter
##                 greys out, and a count (2/4)
## Plain 2D (no 3D view): cheap to draw.


const SCENE := "res://scenes/ui/tile_slot.tscn"

var tile_id := 0
var player := ""                  # "" = free tile
var out_of_service := false
var mode := "open"                # the game's mode: "setup" shows the tile number big, "closed" GESLOTEN
var color := Color.WHITE
var tile: CyberTile                # invited: the tile (which icons are pressed)
var _t := 0.0

@onready var _badge: Label = %Badge
@onready var _setup: Label = %Setup
@onready var _player_name: Label = %PlayerName
@onready var _diagram: TileDiagram = %Diagram
@onready var _cta: CallToAction = %Cta
@onready var _join: Label = %Join


static func create() -> TileSlot:
	return load(SCENE).instantiate()


## Shows the part of the scene for the slot's state (the caller set tile_id,
## player, ... before adding it to the tree).
func _ready() -> void:
	var invited := player != ""
	var state := _state()
	_badge.text = Retro.tile_label(tile_id)
	(_badge.get_theme_stylebox("normal") as StyleBoxFlat).bg_color.a = 1.0 if invited else 0.45
	if state == &"setup":                  # physical setup: which slot is which tile?
		_badge.add_theme_font_size_override("font_size", 180)
		_setup.text = "SETUP" + ("  -  BUITEN GEBRUIK" if out_of_service else "")
	_setup.visible = state == &"setup"
	%OutOfService.visible = state == &"out_of_service"
	%Closed.visible = state == &"closed"
	%Invited.visible = state == &"invited"
	%Free.visible = state == &"free"
	_player_name.text = player.to_upper()
	_player_name.add_theme_color_override("font_color", color.lightened(0.25))
	_diagram.tile = tile
	_diagram.color = color
	_cta.offset = tile_id
	_join.text = Texts.join_text()
	set_process(invited)


func _state() -> StringName:
	if mode == "setup":
		return &"setup"
	if out_of_service:
		return &"out_of_service"
	if mode == "closed":
		return &"closed"
	return &"invited" if player != "" else &"free"


func _process(_delta: float) -> void:
	_t = fmod(Retro.game_clock, 3600.0)   # (the game's clock: in step on every node, at the game's pace)
	queue_redraw()
	_diagram.t = _t
	_diagram.queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(Retro.PANEL, 0.95))
	if player == "":
		return
	var pulse := 0.55 + 0.45 * sin(_t * 4.0)        # the colour the player looks for
	draw_rect(Rect2(40, 40, size.x - 80, 22), Color(color, pulse))
	draw_rect(Rect2(40, size.y - 62, size.x - 80, 22), Color(color, pulse))
