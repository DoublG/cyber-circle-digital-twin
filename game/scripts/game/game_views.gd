class_name GameViews
extends RefCounted
## What the screens show during the game (GameManager.views), as data - so a
## display node (Replica) builds the very same views itself. Kinds:
##   players  every player's own view [overlay: the round's, look_down]
##   message  a round's intro
##   power    the robot's boot / shutdown show
##   round    a shared round's view
##   ranking  this round's places (UITSLAG)
##   scores   the scoreboard

var game: GameManager
var shown := {}                   # the view on the screens now: {kind, seq, ...}
var lives_shown := false          # the scoreboard shows the lives after the change
var _seq := 0


func _init(game_node: GameManager) -> void:
	game = game_node


func show(v: Dictionary) -> void:
	_seq += 1
	shown = v.merged({"seq": _seq}, true)
	build()


## The view on the screens is of this kind.
func is_kind(kind: String) -> bool:
	return shown.get("kind", "") == kind


## A display node: the master's view (full: a snapshot, built again anyway).
func apply_replica(f: Dictionary, full: bool) -> void:
	if f.has("lives_shown"):
		lives_shown = bool(f.lives_shown)
	if f.has("view") and (full or int(f.view.get("seq", -1)) != int(shown.get("seq", -2))):
		shown = f.view
		build()


## The scoreboard shows the lives changing (here and on the display nodes).
func reveal_lives() -> void:
	Replica.relay("views", &"reveal_lives", [])
	lives_shown = true
	game.lives_revealed.emit()


func build() -> void:
	var v := shown
	var wall := game.screen_wall
	match str(v.get("kind", "players")):
		"players":
			var f := Callable()
			if v.get("overlay", false) and game.current:
				f = func(id): return game.current.make_player_overlay(id) if game.in_round(id) else waiting_overlay(id)
			wall.show_players(f, bool(v.get("look_down", false)))
		"message":
			wall.show_shared(func(): return MessageView.create())
		"power":
			var kind := str(v.get("show", "boot"))
			var at := float(v.get("at", 0.0))
			wall.show_shared(func(): return PowerView.create(kind, at))
		"round":
			if game.current:
				wall.show_shared(game.current.make_shared_view)
		"ranking":
			wall.show_shared(func():
				var r := RankingView.create()
				r.show_ranking(str(v.title), str(v.label), v.rows)
				return r)
		"scores":
			wall.show_shared(_scoreboard.bind(str(v.title), str(v.subtitle), v.rows))


## Not in this round: joined during it (they play from the next one) - or
## exterminated: that is the end, no next round for them (their view keeps the
## death clip, then GEËXTERMINEERD; the line stays empty).
func waiting_overlay(id: int) -> Control:
	var line := StatusLine.create()
	line.source = func(): return "" if game.arena.tiles[id - 1].is_dead else "WACHT OP DE VOLGENDE RONDE"
	return line


## One screen's scoreboard (also rebuilt when a player joins / leaves: new
## players come in here, at the bottom).
func _scoreboard(title: String, subtitle: String, rows: Array) -> Control:
	var arena := game.arena
	var board := ScoreboardView.create()
	var all := rows.duplicate()
	var listed := rows.map(func(r): return r.tile)
	for id in arena.players.player_ids():
		if id not in listed and not arena.tiles[id - 1].is_dead:
			var h: int = arena.tiles[id - 1].health
			all.append({"name": arena.players.player_name(id), "tile": id, "survived": 0, "lives": h,
				"lives_before": h, "change": 0, "score": 0, "delta": 0, "out": false, "was_out": false,
				"record": game.standings.record(id), "rank": game.standings.rank(id), "new": true})
	board.show_scores(title, subtitle, all, lives_shown)
	game.lives_revealed.connect(board.reveal_lives)
	return board
