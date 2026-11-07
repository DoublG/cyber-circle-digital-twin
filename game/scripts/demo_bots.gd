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
var answer_quiz := true            # false: the quiz answers are given by someone else (a movie script)
var protected_wrong := false       # shielded players answer wrong: the shield blocks the robot's shot (the movies)
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
			if answer_quiz and round._phase == "question" and not round._answers.has(id) and randf() < delta * 0.5:
				var right := int(round._questions[round._index].correct)
				var answer := right if randf() < SKILL else randi() % 4
				if protected_wrong and round.is_protected(id):
					answer = (right + 1 + randi() % 3) % 4
				arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[answer])
		elif round is ZwartePietRound:
			if round.holder == id and round._clock - round._got_at > randf_range(0.3, 1.5):
				arena.tiles[id - 1].press_button(CyberTile.BUTTONS.pick_random())
		elif round is RhythmRound:
			_rhythm(round, id)
		elif randf() < delta * 1.6:          # tile games: press now and then
			arena.tiles[id - 1].press_button(CyberTile.BUTTONS.pick_random())


## Rhythm: every bot has its own timing per symbol (from a hash, so it is
## stable): mostly in the band, often on the line, sometimes not at all.
func _rhythm(round: RhythmRound, id: int) -> void:
	var st: Dictionary = round.state.get(id, {})
	if st.is_empty():
		return
	for i in range(round._first, round.notes.size()):
		var n: Dictionary = round.notes[i]
		if n.t - round.clock > n.fall * round.band:
			break
		if st.judged.has(i):
			continue
		var h := absi(hash([id, i]))
		if float(h % 1000) / 1000.0 > SKILL:
			continue                         # this one the bot misses
		var off: float = (float((h / 1000) % 1000) / 1000.0 - 0.5) * 1.6 * round.band * n.fall
		if round.clock >= n.t + off:
			arena.tiles[id - 1].press_button(CyberTile.BUTTONS[n.lane])


func _join() -> void:
	var free: Array = arena.tiles.filter(func(t): return t.idle and not arena.is_pending(t.tile_id) and arena.is_enabled(t.tile_id) and not t is DroneTile)
	if free.is_empty():
		return
	var used: Array = arena.player_ids().map(func(id): return arena.player_name(id))
	var name: String = NAMES.filter(func(n): return n not in used).pick_random()
	arena.join(free.pick_random().tile_id, name, randi_range(7, 14))
