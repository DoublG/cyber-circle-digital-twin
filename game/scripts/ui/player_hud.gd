class_name PlayerHud
extends Control
## Everything drawn over one player's view (player_hud.tscn), scaled with its
## cell: the name plate in the top-left corner - [T03] NAME ♥♥♥ 3 RONDES (no
## overall place: the countdown is in the top-right corner; the place is on
## the scoreboard) - and GEËXTERMINEERD! in the middle. The wall adds the
## round's overlay, the look-down hint and floating texts to it.

const SCENE := "res://scenes/ui/player_hud.tscn"

var clip_playing := false         # a movie over the view says it all: no GEËXTERMINEERD! label


static func create() -> PlayerHud:
	return load(SCENE).instantiate()


func show_player(tile: String, player: String, lives: String, score: String, dead: bool) -> void:
	%Tile.text = tile
	%PlayerName.text = player
	%Lives.text = lives
	%Score.text = score
	%Dead.visible = dead and not clip_playing


## Scale with the cell: 1 at a full screen, smaller in a split.
func fit(cell: Control, full: Vector2, min_scale: float) -> void:
	var s := clampf(sqrt(cell.size.x * cell.size.y / (full.x * full.y)), min_scale, 1.0)
	scale = Vector2(s, s)
	size = cell.size / s
