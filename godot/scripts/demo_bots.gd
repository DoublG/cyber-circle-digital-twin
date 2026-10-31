class_name DemoBots
extends Node
## --demo: bot players keep the game going by themselves (showing the
## installation without visitors). `players` bots join (--demo=13: a full
## circle), after --demo-idle s of an empty, idling game; they press icons at random,
## answer quiz questions (often right), kick Zwarte Piet on after a moment, and
## an exterminated bot is replaced by a new one after a while.

const NAMES := ["Anna", "Bram", "Cleo", "Daan", "Eva", "Fien", "Gijs", "Hanne", "Ilse", "Jop",
		"Kai", "Lotte", "Mats", "Noor", "Otto", "Pien"]
const SKILL := 0.7                 # chance a bot answers / reacts right

var players := 6                   # 0: nobody plays, the game idles
var join_interval := 4.0
var arena: Node3D
var _t := 0.0
var _next_join := 0.0


func _ready() -> void:
	var game: GameManager = arena.game
	game.auto_start_delay = 5.0
	if game.mode != GameManager.Mode.OPEN:
		game.set_mode(GameManager.Mode.OPEN)


func _process(delta: float) -> void:
	_t += delta
	var game: GameManager = arena.game
	if arena.player_ids().size() < players and _t >= _next_join:
		_next_join = _t + join_interval
		_join()
	if game.state != GameManager.State.PLAYING or game.current == null:
		return
	var round = game.current
	for id in round.players:
		if not arena.is_playing(id) or arena.tiles[id - 1].is_dead:
			continue
		if round is QuizRound:
			if round._phase == "question" and not round._answers.has(id) and randf() < delta * 0.5:
				var right := int(round._questions[round._index].correct)
				var answer := right if randf() < SKILL else randi() % 4
				arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[answer])
		elif round is ZwartePietRound:
			if round.holder == id and round._clock - round._got_at > randf_range(0.3, 1.5):
				arena.tiles[id - 1].press_button(CyberTile.BUTTONS.pick_random())
		elif randf() < delta * 1.6:          # tile games: press now and then
			arena.tiles[id - 1].press_button(CyberTile.BUTTONS.pick_random())


func _join() -> void:
	var free: Array = arena.tiles.filter(func(t): return t.idle and not arena.is_pending(t.tile_id) and arena.is_enabled(t.tile_id))
	if free.is_empty():
		return
	var used: Array = arena.player_ids().map(func(id): return arena.player_name(id))
	var name: String = NAMES.filter(func(n): return n not in used).pick_random()
	arena.join(free.pick_random().tile_id, name, randi_range(7, 14))
