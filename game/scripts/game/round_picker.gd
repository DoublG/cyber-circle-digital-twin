class_name RoundPicker
extends RefCounted
## Which round comes next (GameManager.picker). The next rounds are planned
## ahead (`upcoming`, shown in the web interface, which can set them: a chosen
## round is always played). Round types are picked at random (the other games
## never twice in a row; quiz after quiz can); with fewer than
## `personal_min_players` players only shared rounds (the quiz) are played:
## personal rounds always have a loser, in the quiz everyone can stay alive.
##
## The randomizer (game style: weighted random with drought protection and a
## "director", see round_chances): weight per round type (0 = never), the
## extra chance per round a type was not played, and how strongly the
## players' lives steer it.

const ROUND_TYPES := [preload("res://scripts/game/cyclone_round.gd"),
	preload("res://scripts/game/quiz_round.gd"), preload("res://scripts/game/reaction_round.gd"),
	preload("res://scripts/game/rhythm_round.gd"), preload("res://scripts/game/simon_round.gd"),
	preload("res://scripts/game/zwarte_piet_round.gd"), preload("res://scripts/game/code_round.gd")]
const HISTORY := 20                        # round types remembered

var game: GameManager
var round_types: Array = ROUND_TYPES: set = set_round_types   # the round types to pick from
var random_rounds := true                  # false: play round_types in order (tests)
var personal_min_players := 4              # fewer players: no personal rounds (they always have a loser)
var queue_length := 3                      # rounds planned ahead
var randomizer_off := {}                   # type name -> true: never drawn (the operator can still plan it)
var round_weights := {"code": 1.0, "cyclone": 1.0, "quiz": 5.0, "reaction": 1.0, "rhythm": 1.0, "simon": 1.0,
	"zwarte_piet": 1.0}
var drought := 0.5
var mercy := 1.0
var history: Array[Script] = []            # the round types played, last at the end
var upcoming: Array = []                   # [{type: Script, forced: bool, options: {}}]: the next rounds
var planned := 0                           # rounds planned so far (fixed order: the index)
var last_type: Script                      # the round type played last


func _init(game_node: GameManager) -> void:
	game = game_node


## The name of a round type in settings, commands and the database: "quiz", "zwarte_piet", ...
static func type_name(t: Script) -> String:
	return t.resource_path.get_file().get_basename().trim_suffix("_round")


## The round type with that name, or null.
static func type_named(name: String) -> Script:
	for t in ROUND_TYPES:
		if type_name(t) == name:
			return t
	return null


func set_round_types(types: Array) -> void:
	round_types = types
	upcoming.clear()                     # plan again with the new types
	planned = 0
	if game and game.arena:
		plan()


## A new game in the fixed order (tests): from the first type.
func restart() -> void:
	if not random_rounds:
		upcoming.clear()
		planned = 0


## The round to play now: the first of the plan ({type, forced, options}); the
## plan is filled up again.
func take_next() -> Dictionary:
	plan()
	var entry: Dictionary = upcoming.pop_front()
	last_type = entry.type
	history.append(last_type)
	if history.size() > HISTORY:
		history.pop_front()
	plan()
	return entry


## Random round type after `after`: personal rounds only with enough players,
## and not the same type twice in a row (when there is a choice). n: the
## round's index, for the fixed order (random_rounds = false).
func pick_type(after: Script, n: int) -> Script:
	return _pick(after, n).type


## {type, chance}: the pick and how likely it was.
func _pick(after: Script, n: int) -> Dictionary:
	if not random_rounds:
		return {"type": round_types[n % round_types.size()], "chance": 1.0}
	var chances := round_chances(after)
	var r := randf()
	var pick: Script = chances.keys().back()
	for t in chances:
		r -= chances[t]
		if r <= 0.0:
			pick = t
			break
	return {"type": pick, "chance": chances[pick]}


## The chance of each round type for the round after `after` - a weighted
## random, steered the way games steer their dice:
##   in / out   per type (settings "Randomizer", the web interface's Spel tab):
##              out = never drawn - planning it (set_planned) still plays it:
##              a new game for a chosen audience
##   weight     per type (settings "Randomizer"; 0 = never)
##   no repeat  never the same type twice in a row (when there is a choice;
##              the quiz can: it is the backbone, the other games come in between)
##   drought    (pity / bad-luck protection) every round a type was not
##              played - played or already planned - adds `drought` x its
##              weight: nothing stays away for long
##   director   the players' lives: when they are low, the rounds that can
##              win a life (the personal ones) come more often and the quiz
##              (it only takes lives) less; everyone healthy: more quiz
##              (more pressure). `mercy` = how strongly (0 = off)
## Personal rounds only with enough players. Returns {Script: chance}.
func round_chances(after: Script) -> Dictionary:
	var options := round_types.filter(func(t): return allowed(t) and not randomizer_off.has(type_name(t)))
	if options.is_empty():                       # (everything out, or not allowed: then any allowed type)
		options = round_types.filter(func(t): return allowed(t))
	if options.is_empty():
		options = round_types.duplicate()
	if options.size() > 1:
		options = options.filter(func(t): return t != after or t.new().can_repeat)
	var seq: Array = Array(history) + upcoming.map(func(e): return e.type)
	var lives_factor := _director()
	var w := {}
	for t in options:
		var since := seq.size() - 1 - seq.rfind(t) if t in seq else mini(seq.size() + 1, 10)
		var weight: float = round_weights.get(type_name(t), 1.0)
		weight *= 1.0 + drought * maxi(since - 1, 0)
		if not t.new().gives_lives:
			weight *= lives_factor
		w[t] = weight
	var total: float = w.values().reduce(func(a, b): return a + b, 0.0)
	for t in w:
		w[t] = w[t] / total if total > 0.0 else 1.0 / w.size()
	return w


## The director: x weight of the rounds that cannot win a life, from the
## players' lives (average share of their own full hearts - age): low -> fewer, full -> more.
func _director() -> float:
	var alive := _alive_tiles()
	if alive.is_empty() or mercy <= 0.0:
		return 1.0
	var f: float = alive.map(func(t): return float(t.health) / maxi(t.max_health, 1)) \
		.reduce(func(a, b): return a + b, 0.0) / alive.size()
	var tension := clampf((0.7 - f) / 0.45, 0.0, 1.0)    # lives running out (full effect at 1/4)
	var ease := clampf((f - 0.8) / 0.2, 0.0, 1.0)        # (almost) all hearts full
	return maxf(0.1, 1.0 - mercy * tension) * (1.0 + mercy * ease)


## The tiles of the players who are still alive.
func _alive_tiles() -> Array:
	var arena := game.arena
	return arena.players.player_ids().map(func(id): return arena.tiles[id - 1]).filter(func(t): return not t.is_dead)


## This round type can be played with the players there are now.
func allowed(t: Script) -> bool:
	return _personal_allowed() or t.new().mode != "personal"


func _personal_allowed() -> bool:
	return _alive_tiles().size() >= personal_min_players


## The type the next planned round comes after.
func _last_planned() -> Script:
	return upcoming.back().type if not upcoming.is_empty() else last_type


## Keep `queue_length` rounds planned: planned (not chosen) rounds that are no
## longer allowed (too few players) are planned again.
func plan() -> void:
	var keep := []
	var personal_ok := _personal_allowed()
	for e in upcoming:
		if not random_rounds or e.forced:                         # (fixed order: every type)
			keep.append(e)
		elif allowed(e.type) and (e.get("personal_ok", true) or not personal_ok) \
				and not randomizer_off.has(type_name(e.type)):
			keep.append(e)
		# else: not allowed any more, or only chosen because personal rounds were not
		# allowed then (too few players): pick again, now from every type
	upcoming = keep
	while upcoming.size() < queue_length:
		var pick := _pick(_last_planned(), planned)
		upcoming.append({"type": pick.type, "forced": false, "personal_ok": personal_ok, "chance": pick.chance})
		planned += 1
	while upcoming.size() > queue_length and not upcoming.back().forced:   # (shorter queue setting)
		upcoming.pop_back()


## Operator: play `name` (code, cyclone, quiz, reaction, rhythm, simon, zwarte_piet) as the round in
## slot `slot` of the plan (0 = the next round). "" = random again from there.
func set_planned(slot: int, name: String, options := {}) -> void:
	plan()
	slot = clampi(slot, 0, upcoming.size() - 1)
	if name == "":
		upcoming.resize(slot)
	else:
		var t := type_named(name)
		if t == null:
			push_warning("unknown round type %s" % name)
			return
		upcoming[slot] = {"type": t, "forced": true, "options": options}
	plan()
	_checkpoint()


## Operator: every planned round random again.
func clear_planned() -> void:
	upcoming.clear()
	plan()
	_checkpoint()


## The plan changed: it is what comes back after a crash (Recovery).
func _checkpoint() -> void:
	if game.recovery:
		game.recovery.mark()


## The plan for the web interface: [{type, title, forced, options, chance}].
func planned_rounds() -> Array:
	return upcoming.map(func(e): return {"type": type_name(e.type), "title": e.type.new().title,
		"forced": e.forced, "options": e.get("options", {}), "chance": e.get("chance", 1.0)})


## Every round type for the web interface: in the randomizer or not, its
## weight, its chance now (for a random round after the planned ones).
func types_status() -> Array:
	var chances := round_chances(_last_planned()) if random_rounds else {}
	return ROUND_TYPES.map(func(t): return {"type": type_name(t), "title": t.new().title,
		"random": not randomizer_off.has(type_name(t)), "weight": round_weights.get(type_name(t), 1.0),
		"allowed": allowed(t), "min_players": personal_min_players if t.new().mode == "personal" else 0,
		"chance": snappedf(chances.get(t, 0.0), 0.001)})


# ---------------------------------------------------------------- settings (GameSettings, "Randomizer")

func tunables() -> Array:
	var items := ROUND_TYPES.map(func(t): return GameRound.setting(
		"use_" + type_name(t), "In de randomizer: " + t.new().title + " (1 aan, 0 uit)", 0, 1, 1))
	items.append_array(ROUND_TYPES.map(func(t): return GameRound.setting(
		"weight_" + type_name(t), "Gewicht " + t.new().title, 0, 10, 0.5)))
	items.append(GameRound.setting("drought", "Extra kans per ronde niet gespeeld (x gewicht)", 0, 3, 0.1))
	items.append(GameRound.setting("mercy", "Sturing door levens (0 = uit)", 0, 2, 0.1))
	return items


func get_setting(key: String) -> Variant:
	if key.begins_with("weight_"):
		return round_weights.get(key.trim_prefix("weight_"), 1.0)
	if key.begins_with("use_"):
		return 0 if randomizer_off.has(key.trim_prefix("use_")) else 1
	return get(key)


func set_setting(key: String, value: Variant) -> void:
	if key.begins_with("weight_"):
		round_weights[key.trim_prefix("weight_")] = float(value)
	elif key.begins_with("use_"):
		if int(value) == 0:
			randomizer_off[key.trim_prefix("use_")] = true
		else:
			randomizer_off.erase(key.trim_prefix("use_"))
	elif get(key) is int:
		set(key, int(value))
	else:
		set(key, float(value))
