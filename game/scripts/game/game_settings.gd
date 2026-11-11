class_name GameSettings
extends RefCounted
## The settings the operator can change (GameManager.settings; the web
## interface's "Instellingen", --settings=FILE): per group - the game, every
## round type (GameRound.tunables), the randomizer, the questions, sound,
## light and the read-aloud voice. The game ones apply at once, a round
## type's from its next round.

## Round settings that are network / hardware delays, not game times: the tempo leaves them alone.
const NETWORK_TIMES := ["latency_ms", "late_grace"]
## The game's own settings. tempo > 1: every time shorter.
const GAME_TUNABLES := [
	{"key": "tempo", "label": "Tempo (x, alle tijden)", "min": 0.5, "max": 2.0, "step": 0.05, "unit": ""},
	{"key": "intro_time", "label": "Uitleg voor een ronde", "min": 2, "max": 30, "step": 1, "unit": "s"},
	{"key": "result_time", "label": "Uitslag (plaatsen, levens)", "min": 0, "max": 30, "step": 1, "unit": "s"},
	{"key": "scoreboard_time", "label": "Scorebord", "min": 2, "max": 30, "step": 1, "unit": "s"},
	{"key": "clip_time", "label": "Doodsfilmpje op eigen scherm (min.)", "min": 2, "max": 60, "step": 1, "unit": "s"},
	{"key": "clip_wait", "label": "Doodsfilmpje wacht op eigen scherm max.", "min": 0, "max": 120, "step": 5, "unit": "s"},
	{"key": "auto_start_delay", "label": "Start na eerste speler", "min": 0, "max": 120, "step": 5, "unit": "s"},
	{"key": "lives", "label": "Levens (leeftijd onbekend)", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_8", "label": "Levens t/m 8 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_10", "label": "Levens 9 - 10 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_99", "label": "Levens vanaf 11 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "streak_bonus", "label": "Juist op rij voor +1 leven", "min": 2, "max": 50, "step": 1, "unit": ""},
	{"key": "personal_min_players", "label": "Spelers nodig voor eigen spellen", "min": 1, "max": 13,
		"step": 1, "unit": ""},
	{"key": "queue_length", "label": "Rondes vooruit gepland", "min": 1, "max": 10, "step": 1, "unit": ""},
]
const ARENA_KEYS := ["clip_wait", "clip_time"]                 # game settings kept by the arena
const PICKER_KEYS := ["personal_min_players", "queue_length"]  # ... and by the round picker

var game: GameManager
var values := {}                   # the operator's values: {"game": {key: v}, "<round type>": {key: v}, ...}
var _defaults := {}                # group -> {key: the value before the operator changed anything}


func _init(game_node: GameManager) -> void:
	game = game_node


## Once the arena is known: the values now are the defaults.
func remember_defaults() -> void:
	for g in _live_groups():
		var d := {}
		for t in g.items:
			d[t.key] = g.read.call(t.key)
		_defaults[g.group] = d


## The operator's values for one round type ({key: value}).
func of_round(type_name: String) -> Dictionary:
	return values.get(type_name, {})


## A new round's settings: the operator's for its type, then this round's in
## the round plan (web interface), e.g. {"categories": ["Computers"],
## "duration": 60, "question_count": 5}: every key that is a property of the
## round is set. Future special rounds and difficulty steering hook in here.
func configure(r: GameRound, type_name: String, options: Dictionary) -> void:
	for given in [of_round(type_name), options]:
		for key in given:
			if key in r:
				r.set(key, given[key])
			else:
				push_warning("%s: no setting %s" % [r.title, key])


## Every setting with its range, default and current value, per group ("game"
## and each round type, ...) - for the web interface:
## [{group, title, items: [{key, label, min, max, step, unit, default, value}]}].
func schema() -> Array:
	var live := {}
	for g in _live_groups():
		live[g.group] = {"group": g.group, "title": g.title, "items": g.items.map(func(t):
			return t.merged({"default": _default(g.group, t.key), "value": g.read.call(t.key)}))}
	var groups := [live.game]
	for type in RoundPicker.ROUND_TYPES:
		var r: GameRound = type.new()
		var own := of_round(RoundPicker.type_name(type))
		groups.append({"group": RoundPicker.type_name(type), "title": r.title, "items": r.tunables().map(func(t):
			return t.merged({"default": r.get(t.key), "value": own.get(t.key, r.get(t.key))}))})
	for name in ["randomizer", "questions", "sound", "light", "voice"]:
		groups.append(live[name])
	return groups


## The operator's settings (all groups at once; missing keys: the default).
## The game ones apply at once, the round ones from the next round.
func apply(given_values: Dictionary) -> void:
	var clean := {}
	for g in schema():
		var given: Dictionary = given_values.get(g.group, {}) if given_values.get(g.group) is Dictionary else {}
		var out := {}
		for t in g.items:
			if given.has(t.key) and (given[t.key] is float or given[t.key] is int):
				var v := clampf(float(given[t.key]), t.min, t.max)
				out[t.key] = roundi(v) if t.default is int else v
		clean[g.group] = out
	values = clean
	game.questions.category_weights.clear()
	for g in _live_groups():
		for t in g.items:
			g.write.call(t.key, clean[g.group].get(t.key, _default(g.group, t.key)))
	game.arena.lights.refresh()
	game.picker.plan()
	game.settings_changed.emit()


## The groups that apply at once: where their settings are read and written.
func _live_groups() -> Array:
	var a := game.arena
	return [
		{"group": "game", "title": "Spel", "items": GAME_TUNABLES, "read": get_game, "write": set_game},
		{"group": "randomizer", "title": "Randomizer", "items": game.picker.tunables(),
			"read": game.picker.get_setting, "write": game.picker.set_setting},
		{"group": "questions", "title": "Vragen", "items": game.questions.tunables(),
			"read": game.questions.get_setting, "write": game.questions.set_setting},
		{"group": "sound", "title": "Geluid", "items": a.sound.tunables(), "read": a.sound.get, "write": a.sound.set},
		{"group": "light", "title": "Licht", "items": a.lights.tunables(), "read": a.lights.get, "write": a.lights.set},
		{"group": "voice", "title": "Voorlezen", "items": a.narrator.tunables(), "read": a.narrator.get,
			"write": a.narrator.set},
	]


## (A question category that came later has no default of its own: weight 1.)
func _default(group: String, key: String) -> Variant:
	return _defaults.get(group, {}).get(key, 1.0 if key.begins_with("cat:") else null)


## A game setting, wherever it is kept (GAME_TUNABLES).
func get_game(key: String) -> Variant:
	if key.begins_with("lives_age_"):
		return game.lives_by_age.get(int(key.trim_prefix("lives_age_")), game.lives)
	return _owner_of(key).get(key)


func set_game(key: String, value: Variant) -> void:
	if key.begins_with("lives_age_"):
		game.lives_by_age[int(key.trim_prefix("lives_age_"))] = int(value)
		return
	var owner := _owner_of(key)
	owner.set(key, int(value) if owner.get(key) is int else float(value))


func _owner_of(key: String) -> Object:
	if key in ARENA_KEYS:
		return game.arena
	if key in PICKER_KEYS:
		return game.picker
	return game
