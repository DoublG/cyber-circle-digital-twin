class_name TileFirmware
extends Node
## Simulation of the logic that runs on the real tile's own controller.
## The game sends a complete program up front (during the round intro) and a
## "start" when the round begins; from then on the tile runs on its own: it
## shows every step, measures the reaction time locally (no network delay)
## and reports one result per step. The game only scores and animates results.
## With the real installation connected (arena.simulate_firmware = false) the
## same messages go to the tiles and their results come back via apply_command.
##
## Clock ("game": "clock", Ritme): nothing on the ring, only the round's time;
## the real tile stamps every press with it ({"press": .., "t": ms since the
## start, "program": id}) and the game scores the press at that moment.
##
## Messages to the tile (arena.send_to_tile):
##   {"program": {"game": "reaction", "id": "...", "length": ms,
##       "windows": [1400, 1300, ..., 700],   # ms to react; every success one step
##                                             # faster, a mistake back to the first
##       "steps": [{"at": ms after start, "button": "Triangle", "color": "#33ff66",
##                  "nogo": false}, ...]}}
##   {"start": "<program id>"}
##   {"stop": true}
##   {"pause": true} / {"pause": false}   game paused: freeze the program's clock
##   {"piet": {"on": true, "speed": 20, "color": "#ff2a00"}} / {"piet": {"on": false}}
##       Zwarte Piet (run by the game): a light with a tail runs around the
##       ring at `speed` LEDs/s while this tile has it; presses are reported
##       as usual ({"press": ...}).
## Results from the tile (as apply_command input):
##   {"tile": 3, "result": {"program": id, "step": 4, "outcome": "hit",
##                          "button": "Triangle", "ms": 412, "window": 1100, "streak": 4}}
##     window = ms the player had for this step, streak = successes in a row now
##     outcome: "hit"       right button pressed (ms = reaction time)
##              "wrong"     another button pressed
##              "miss"      nothing pressed in time
##              "nogo_ok"   red step: waited or pressed another button
##              "nogo_fail" red step: pressed the red button
##   {"tile": 3, "result": {"program": id, "done": true}}
##
## Simon ("game": "simon"): the tile shows a sequence of icons, each in its own
## colour; the player repeats it by pressing the icons. Every level is one step
## longer; a mistake starts again at start_level, until the time runs out.
## Program:
##   {"program": {"game": "simon", "id": "...", "length": ms,
##       "sequence": [{"button": "Cross", "color": "#4d80ff"}, ...],
##       "start_level": 3,
##       "show_on": 700, "show_off": 300,      # ms per shown step (level start_level)
##       "speedup": 0.93, "min_on": 300,       # show_on *= speedup every level
##       "input_ms": 4000,                     # max ms between two presses
##       "pause_ms": 1200}}                    # between levels
## Results (every one carries "n", a counter per start, to drop duplicates):
##   {"program": id, "n": 7, "level": 4, "outcome": "watch"}   showing the sequence
##   ... "outcome": "repeat"                                   player's turn
##   ... "outcome": "press", "index": 2, "button": "Cross"     correct press
##   ... "outcome": "ok", "ms": 3120                           level repeated correctly
##   ... "outcome": "fail", "index": 2, "button": "Square",    wrong icon ("" = too slow):
##       "expected": "Cross", "restart": 3                     back to level 3
##   {"program": id, "n": 9, "done": true, "reason": "time" | "complete", "best": 5}
##
## Cyclone ("game": "cyclone"): a green light runs around the ring; press any
## icon when it is on the red LED. The yellow bands next to the red LED also
## count; every success the tile moves to the next level (narrower bands,
## faster light), a miss back to the first level. The tile judges the press
## itself, to the exact LED.
##   {"program": {"game": "cyclone", "id": "...", "length": ms,
##       "levels": [{"yellow": 4, "speed": 14}, ...],   # LEDs per side, LEDs/s
##       "targets": [{"led": 17, "dir": 1}, ...],        # red LED per turn (cycled)
##       "result_ms": 900}}                              # result shown on the ring
## Results (with "n" like Simon):
##   {"program": id, "n": 3, "outcome": "red" | "yellow" | "miss", "level": 2,
##    "offset": -1, "yellow": 2}   offset = LEDs from the red one (+ = too late)
##   {"program": id, "n": 12, "done": true, "reason": "time", "best": 4}

signal step_started(tile_id: int, index: int, step: Dictionary)
## Simon: the player's turn starts (for test bots and debugging).
signal simon_turn(tile_id: int, level: int, sequence: Array)

const REPEAT_ICON := Color(0.35, 0.35, 0.35)   # dim white: where to press, no colour hint

const FLASH_TIME := 0.15

var tile: CyberTile
var report := Callable()          # Dictionary -> void, e.g. arena.apply_command
var _program := {}
var _running := false
var _clock := 0.0                 # ms since start (tile-local)
var _piet := {}                   # Zwarte Piet: {"speed", "color"} while this tile has the light
var _piet_pos := 0.0
var _paused := false
var _next := 0                    # next step to show
var _open := -1                   # step currently shown, -1 = none
var _opened_at := 0.0
var _window := 0.0                # reaction: ms for the step that is open
var _streak := 0                  # reaction: successes in a row (sets the window)
# simon
var _phase := ""                  # pause / watch / repeat
var _level := 0
var _index := 0                   # step being shown / pressed
var _lit := false
var _due := 0.0                   # tile clock (ms) of the next change
var _turn_start := 0.0
var _n := 0
# cyclone
var _target := 0
var _dir := 1
var _pos := 0.0                   # green light, LED index (float)
var _turn_count := 0
var _best := 0


func _ready() -> void:
	tile.button_pressed.connect(_on_press)


func receive(msg: Dictionary) -> void:
	if msg.has("program"):
		_program = msg.program
		_running = false
		if _program.get("game", "") != "clock":       # (clock - Ritme: only the time, nothing shown)
			tile.fill_ring(Color(0.15, 0.15, 0.15))  # armed: dim white ring
			_icons(&"")
	if msg.has("start") and str(msg.start) == str(_program.get("id", "")):
		_running = true
		_clock = 0.0
		_next = 0
		_open = -1
		_n = 0
		_streak = 0
		if _program.get("game", "") != "clock":
			tile.clear_ring()
		match _program.get("game", ""):
			"simon":
				_level = int(_program.start_level)
				_best = 0
				_pause()
			"cyclone":
				_level = 0
				_best = 0
				_turn_count = 0
				_icons(&"")
				_cyclone_turn()
	if msg.get("piet") is Dictionary:
		if msg.piet.get("on", false):
			_piet = {"speed": float(msg.piet.get("speed", 15.0)), "color": Color(msg.piet.get("color", "#ff2a00"))}
			for b in CyberTile.BUTTONS:                     # kick it: every icon works
				tile.set_button_led(b, CyberTile.BUTTON_COLORS[b])
		else:
			_piet = {}
			tile.clear_ring()
			_icons(&"")
	if msg.has("pause"):
		_paused = bool(msg.pause)
	if msg.has("stop"):
		var shown: bool = _program.get("game", "") != "clock"   # (the clock showed nothing: leave the tile as it is)
		_running = false
		_open = -1
		if not shown:
			return
		tile.clear_ring()
		for b in CyberTile.BUTTONS:
			tile.set_button_led(b, CyberTile.BUTTON_COLORS[b])


func _process(delta: float) -> void:
	if not _piet.is_empty() and not _paused:
		_piet_pos = fposmod(_piet_pos + delta * _piet.speed, CyberTile.LED_COUNT)
		var colors := []
		for i in CyberTile.LED_COUNT:              # the light with a fading tail
			var behind := posmod(int(_piet_pos) - i, CyberTile.LED_COUNT)
			colors.append(_piet.color * (1.0 - behind / 6.0) if behind < 6 else Color.BLACK)
		tile.set_ring(colors)
	if not _running or _paused:
		return
	_clock += delta * 1000.0
	match _program.get("game", ""):
		"clock":
			return
		"simon":
			_simon_process()
			return
		"cyclone":
			_cyclone_process(delta)
			return
	var steps: Array = _program.steps
	if _open >= 0:
		if _clock - _opened_at >= _window:
			_close(&"")
	elif _next < steps.size():
		if _clock >= float(steps[_next].at):
			_show(_next)
			_next += 1
	else:
		_running = false
		_send({"program": _program.id, "done": true})


func _show(index: int) -> void:
	var step: Dictionary = _program.steps[index]
	_open = index
	_opened_at = _clock
	var windows: Array = _program.windows
	_window = float(windows[mini(_streak, windows.size() - 1)])
	tile.fill_ring(Color(step.color))
	_icons(StringName(step.button))
	step_started.emit(tile.tile_id, index, step)


func _on_press(_id: int, button: StringName) -> void:
	if not _running or _program.get("game", "") == "clock":
		return
	if _is_simon():
		_simon_press(button)
	elif _program.game == "cyclone":
		_cyclone_press()
	elif _running and _open >= 0:
		_close(button)


## button = &"" when the window ran out.
func _close(button: StringName) -> void:
	var step: Dictionary = _program.steps[_open]
	var target := StringName(step.button)
	var outcome := "miss"
	if step.get("nogo", false):
		outcome = "nogo_fail" if button == target else "nogo_ok"
	elif button == target:
		outcome = "hit"
	elif button != &"":
		outcome = "wrong"
	var ms := roundi(_clock - _opened_at) if button != &"" else roundi(_window)
	_streak = _streak + 1 if outcome in ["hit", "nogo_ok"] else 0    # a mistake: slow again
	_send({"program": _program.id, "step": _open, "outcome": outcome, "button": str(button), "ms": ms,
		"window": roundi(_window), "streak": _streak})
	_open = -1
	_icons(&"")
	_flash(outcome)


func _flash(outcome: String) -> void:
	var c: Color = {"hit": Color(0.1, 1.0, 0.3), "nogo_ok": CyberTile.SHIELD_COLOR,
		"wrong": Color.RED, "nogo_fail": Color.RED}.get(outcome, Color.BLACK)
	tile.fill_ring(c)
	await get_tree().create_timer(FLASH_TIME).timeout
	if _open < 0:
		tile.clear_ring()


## Only the step's icon lit (in its own colour); &"" = all off.
func _icons(lit: StringName) -> void:
	for b in CyberTile.BUTTONS:
		tile.set_button_led(b, CyberTile.BUTTON_COLORS[b] if b == lit else Color.BLACK)


func _send(result: Dictionary) -> void:
	if report.is_valid():
		report.call({"tile": tile.tile_id, "result": result})


# ------------------------------------------------------------------ simon

func _is_simon() -> bool:
	return _program.get("game", "") == "simon"


func _simon_process() -> void:
	if _clock >= float(_program.length):
		_simon_end("time")
		return
	if _clock < _due:
		return
	match _phase:
		"pause":
			_phase = "watch"
			_index = 0
			_lit = false
			tile.clear_ring()
			_send_n({"level": _level, "outcome": "watch"})
		"watch":
			if not _lit:
				var step: Dictionary = _program.sequence[_index]
				tile.fill_ring(Color(step.color))
				_icons(&"")
				tile.set_button_led(StringName(step.button), Color(step.color))
				_lit = true
				_due = _clock + _show_on()
			else:
				tile.clear_ring()
				_icons(&"")
				_lit = false
				_index += 1
				_due = _clock + float(_program.show_off)
				if _index >= _level:
					_turn()
		"repeat":
			_simon_fail(&"")              # too slow


func _show_on() -> float:
	var p := _program
	return maxf(float(p.min_on), float(p.show_on) * pow(float(p.speedup), _level - int(p.start_level)))


func _turn() -> void:
	_phase = "repeat"
	_index = 0
	_turn_start = _clock
	_due = _clock + float(_program.input_ms)
	for b in CyberTile.BUTTONS:
		tile.set_button_led(b, REPEAT_ICON)
	_progress()
	_send_n({"level": _level, "outcome": "repeat"})
	simon_turn.emit(tile.tile_id, _level, _program.sequence.slice(0, _level))


func _simon_press(button: StringName) -> void:
	if _phase != "repeat":
		return
	var step: Dictionary = _program.sequence[_index]
	if button != StringName(step.button):
		_simon_fail(button)
		return
	_blink(button, Color(step.color))
	_send_n({"level": _level, "outcome": "press", "index": _index, "button": str(button)})
	_index += 1
	_due = _clock + float(_program.input_ms)
	_progress()
	if _index < _level:
		return
	_send_n({"level": _level, "outcome": "ok", "ms": roundi(_clock - _turn_start)})
	_best = maxi(_best, _level)
	_level += 1
	if _level > _program.sequence.size():
		_simon_end("complete")
		return
	_flash("hit")
	_pause()


## Wrong icon or too slow: back to the shortest sequence (no game over).
func _simon_fail(button: StringName) -> void:
	var restart := int(_program.start_level)
	_send_n({"level": _level, "outcome": "fail", "index": _index, "button": str(button),
		"expected": str(_program.sequence[_index].button), "restart": restart})
	_level = restart
	_flash("wrong")
	_pause()


func _pause() -> void:
	_phase = "pause"
	_icons(&"")
	_due = _clock + float(_program.pause_ms)


func _simon_end(reason: String) -> void:
	_running = false
	_phase = ""
	_icons(&"")
	_send_n({"done": true, "reason": reason, "best": _best})


## Ring as a progress bar while repeating: one part per step, done = white.
func _progress() -> void:
	var colors := []
	for i in CyberTile.LED_COUNT:
		colors.append(Color(0.9, 0.9, 0.9) if i < CyberTile.LED_COUNT * _index / _level else Color(0.06, 0.06, 0.06))
	tile.set_ring(colors)


func _blink(button: StringName, color: Color) -> void:
	tile.set_button_led(button, color)
	await get_tree().create_timer(0.2).timeout
	if _phase == "repeat":
		tile.set_button_led(button, REPEAT_ICON)


# ---------------------------------------------------------------- cyclone

func _cyclone_turn() -> void:
	var t: Dictionary = _program.targets[_turn_count % _program.targets.size()]
	_turn_count += 1
	_target = int(t.led)
	_dir = int(t.dir)
	_pos = float((_target + CyberTile.LED_COUNT / 2) % CyberTile.LED_COUNT)   # start opposite the red LED
	_phase = "run"
	_cyclone_draw()


func _cyclone_process(delta: float) -> void:
	if _clock >= float(_program.length):
		_running = false
		_phase = ""
		tile.clear_ring()
		_send_n({"done": true, "reason": "time", "best": _best})
		return
	if _phase == "hold":
		if _clock >= _due:
			_cyclone_turn()
		return
	var lv: Dictionary = _program.levels[_level]
	_pos = fposmod(_pos + delta * float(lv.speed) * _dir, CyberTile.LED_COUNT)
	_cyclone_draw()


## Signed distance in LEDs from the red LED to the green one (+ = past it).
func _offset() -> int:
	var d := posmod(int(_pos) % CyberTile.LED_COUNT - _target, CyberTile.LED_COUNT)
	if d > CyberTile.LED_COUNT / 2:
		d -= CyberTile.LED_COUNT
	return d * _dir


func _cyclone_draw() -> void:
	var yellow := int(_program.levels[_level].yellow)
	var colors := []
	for i in CyberTile.LED_COUNT:
		var d := absi(posmod(i - _target + CyberTile.LED_COUNT / 2, CyberTile.LED_COUNT) - CyberTile.LED_COUNT / 2)
		colors.append(Color.RED if d == 0 else (Color(1.0, 0.8, 0.0) if d <= yellow else Color.BLACK))
	colors[int(_pos) % CyberTile.LED_COUNT] = Color(0.1, 1.0, 0.25)   # (float rounding can give 48.0)
	tile.set_ring(colors)


func _cyclone_press() -> void:
	if _phase != "run":
		return
	var yellow := int(_program.levels[_level].yellow)
	var off := _offset()
	var outcome := "red" if off == 0 else ("yellow" if absi(off) <= yellow else "miss")
	_send_n({"outcome": outcome, "level": _level, "offset": off, "yellow": yellow})
	if outcome != "miss":
		_level = mini(_level + 1, _program.levels.size() - 1)
		_best = maxi(_best, _level)
	else:
		_level = 0                        # a miss: back to the first level
	tile.fill_ring({"red": Color(0.1, 1.0, 0.25), "yellow": Color(1.0, 0.8, 0.0)}.get(outcome, Color.RED))
	_phase = "hold"
	_due = _clock + float(_program.result_ms)


func _send_n(result: Dictionary) -> void:
	_n += 1
	result["program"] = _program.id
	result["n"] = _n
	_send(result)
