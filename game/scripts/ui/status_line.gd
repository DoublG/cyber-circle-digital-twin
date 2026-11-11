class_name StatusLine
extends Label
## One small line of round info at the bottom of a player view (rounds on the
## tile: the tile itself shows the game, this only adds what it can't show).

const SCENE := "res://scenes/ui/status_line.tscn"

var source := Callable()          # () -> String; empty hides the line


static func create() -> StatusLine:
	return load(SCENE).instantiate()


func _process(_delta: float) -> void:
	text = str(source.call()) if source.is_valid() else ""
	visible = text != ""
