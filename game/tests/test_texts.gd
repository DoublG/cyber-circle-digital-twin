extends Node
## The operator's texts (Texts): a game's name and rules for its next round,
## the slogans, how to join, the line on a free tile; {} = the defaults again.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_texts.tscn

const ARENA := preload("res://scenes/arena.tscn")
var _fails := 0


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.picker.random_rounds = false
	game.picker.round_types = [QuizRound]
	game.intro_time = 0.5
	await get_tree().process_frame
	var d := Texts.defaults(game)
	check(d["title.quiz"] == "Quiz" and d["title.rhythm"] == "Ritme" and d["rules.quiz"].contains("leven"),
		"defaults: every game's name and rules")
	Texts.apply({"title.quiz": "De Grote Quiz", "rules.quiz": "Juist = blijven. Fout = een leven minder.",
		"cta": "KOM SPELEN!\nWIN VAN DE ROBOT!", "join_steps": "1. Scan.\n2. Speel.", "join_text": "SCAN JE KAART",
		"x": "  "})
	check(not Texts.values.has("x"), "an empty text: the default")
	check(Texts.calls() == ["KOM SPELEN!", "WIN VAN DE ROBOT!"], "the slogans, one per line")
	var cta := CallToAction.new()
	add_child(cta)                                  # (it picks its slogan when it goes on screen)
	check(cta.text in Texts.calls(), "a call to action shows one of them (%s)" % cta.text)
	cta.free()
	arena.players.join(1, "Anna", 12)
	game.start_game()
	while game.state != GameManager.State.INTRO:
		await get_tree().process_frame
	check(game.current.title == "De Grote Quiz" and game.current.rules.begins_with("Juist = blijven"),
		"the round: the new name and rules (%s)" % game.current.title)
	var slot := TileSlot.new()
	slot.tile_id = 5
	add_child(slot)
	await get_tree().process_frame
	check(slot.find_children("*", "Label", true, false).any(func(l): return l.text == "SCAN JE KAART"),
		"a free tile: the new line")
	slot.queue_free()
	Texts.apply({})
	check(Texts.calls() == Retro.CALLS_TO_ACTION and Texts.join_steps() == Texts.JOIN_STEPS, "{}: the defaults again")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		_fails += 1
