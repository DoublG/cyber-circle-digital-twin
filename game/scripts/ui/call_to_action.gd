class_name CallToAction
extends Label
## Big rotating slogan (Texts.calls(): the operator's, else Retro.CALLS_TO_ACTION): types itself out, pulses,
## and is replaced by the next one every `interval` seconds. On the game's clock
## (Retro.game_clock: the master's on every display node), so every screen of
## every node shows the same at the same time, at the game's pace;
## offset: another slogan than its neighbours (e.g. the tile number).

const SCENE := "res://scenes/ui/call_to_action.tscn"

var interval := 10.0                # s per slogan (time to read it on a split view)
var offset := 0:
	set(v):
		offset = v
		if is_inside_tree():            # (set after it went on screen: pick again, now)
			_process(0.0)
var _index := -1
var _t := 0.0


static func create() -> CallToAction:
	return load(SCENE).instantiate()


## The first slogan when it goes on screen (with the caller's offset: a slogan
## picked before that - offset 0, the same on every tile - flashed for one
## frame each time a tile's view was rebuilt).
func _ready() -> void:
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
