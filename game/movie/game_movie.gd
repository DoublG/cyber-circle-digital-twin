extends Node
## A whole game, every screen on its own (tools/media/make_game_movies.py): the real
## game, connected to MQTT and the control server, is played from outside -
## the gamemaster app registers the visitors, the web interface starts it -
## and this records every screen's picture, frame by frame, on the game's own
## clock (--fixed-fps 30: game time, however slow the PC renders):
##   DIR/overzicht, DIR/scherm_1 .. 5, DIR/mobiel_1 .. 2: %06d.jpg
##   DIR/frame.txt   the frame number now (the browser recorders follow it)
##   DIR/stop        (written by the driver) -> quit
## In the game: a registered visitor walks to their tile and presses the 4
## icons after a few seconds; bots play for every player (DemoBots, joining nobody).
##   godot-4 --path . --resolution 960x540 --fixed-fps 30 --write-movie DIR/main.avi \
##     res://movie/game_movie.tscn -- --rec=DIR --mqtt=... --control=... --sim-tiles

const ARENA := preload("res://scenes/arena.tscn")

var arena: Node3D
var game: GameManager
var _dir := ""
var _panes: Array[SubViewport] = []
var _names: Array[String] = []
var _frame := 0
var _activating := {}            # tile_id -> true: walking to the tile / pressing


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rec="):
			_dir = a.trim_prefix("--rec=")
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	var bots := DemoBots.new()
	bots.players = 0                              # (nobody joins by itself: the app registers the visitors)
	bots.arena = arena
	add_child(bots)
	await get_tree().process_frame
	game.auto_start_delay = 0.0                   # (the web interface starts the game)
	_compose()
	_record()


func _process(_delta: float) -> void:
	for id in arena.tiles.size():
		var t: int = id + 1
		if arena.is_pending(t) and not _activating.has(t):
			_activating[t] = true
			_activate(t)


## The visitor walks to their tile (or their drone's station) and presses the 4 icons.
func _activate(tile_id: int) -> void:
	await get_tree().create_timer(randf_range(4.0, 7.0)).timeout
	for b in CyberTile.BUTTONS:
		if not arena.is_pending(tile_id):
			break
		arena.tiles[tile_id - 1].press_button(b)
		await get_tree().create_timer(randf_range(0.5, 1.0)).timeout
	_activating.erase(tile_id)


## Every screen rendered at full HD although the window only shows the overview.
func _compose() -> void:
	var wall: ScreenWall = arena.screen_wall
	_panes = [wall._observer_screen.get_viewport()]
	_names = ["overzicht"]
	for k in wall._screens.size():
		_panes.append(wall._screens[k].get_viewport())
		_names.append("scherm_%d" % (k + 1) if k < wall.screen_groups.size() else "mobiel_%d" % (k + 1 - wall.screen_groups.size()))
	wall.visible = false
	for vp in _panes:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_viewport().disable_3d = true
	var layer := CanvasLayer.new()
	add_child(layer)
	var view := TextureRect.new()                 # the window (and main.avi: its sound): the overview
	view.texture = _panes[0].get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(view)


func _record() -> void:
	for n in _names:
		DirAccess.make_dir_recursive_absolute(_dir.path_join(n))
	while true:
		await RenderingServer.frame_post_draw
		for k in _panes.size():
			_panes[k].get_texture().get_image().save_jpg(_dir.path_join(_names[k]).path_join("%06d.jpg" % _frame), 0.9)
		_frame += 1
		var f := FileAccess.open(_dir.path_join("frame.txt"), FileAccess.WRITE)
		f.store_string(str(_frame))
		f.close()
		if FileAccess.file_exists(_dir.path_join("stop")):
			print("[movie] stop at frame %d" % _frame)
			get_tree().quit()
			return
