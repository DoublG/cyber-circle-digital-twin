class_name SoundBoard
extends Node
## Sound effects for game events: play(&"attack") plays a random sound from
## data/sounds/attack/ (.ogg / .wav / .mp3), so sounds are added or replaced
## by dropping files in those folders (tools/make_sounds.py made the first
## ones). An extra folder with the same layout can be given with --sounds=DIR
## (no re-export needed). Events:
##   charge      the robot charges its gun        attack     the shot
##   hit         a tile is hit                     shield     a shield blocks the shot
##   death       a player is exterminated          zap        the tile's electrocution
##   explosion   the tile explodes                 life       +1 life
##   round_start a round begins                    scoreboard the scoreboard
##   join        a player activates their tile     random     now and then, between the action
## Settings (web interface, group "Geluid"): volume, the random sounds' interval.
##
## Any other folder is an event too, e.g. data/sounds/announce/ or DIR/gong/:
## external systems play sounds through the command {"sound": "gong"}
## (Arena.apply_command, see play_external), and the web interface lists them
## (catalog(), published retained on MQTT <prefix>/sounds).

signal sounds_changed                  # after reload(): the catalog may be different

const SOUND_DIR := "res://data/sounds/"
const EXTENSIONS := ["ogg", "wav", "mp3"]
const VOICES := 8                      # sounds at the same time

var enabled := true                    # --no-sound: false
var volume := 80                       # %
var random_min := 20.0                 # s between random sounds (when the game is open)
var random_max := 60.0
var extra_dir := ""                    # --sounds=DIR

var _sounds := {}                      # event -> [AudioStream]
var _files := {}                       # event -> [file name], in the same order as _sounds
var _players: Array[AudioStreamPlayer] = []
var _next_random := 0.0
var _clock := 0.0
var _last := {}                        # event -> msec it last started (no stacking)


func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	reload()
	_next_random = randf_range(random_min, random_max)


## The settings for the web interface (as GameRound.tunables).
func tunables() -> Array:
	return [
		GameRound.setting("volume", "Volume (%)", 0, 100, 5),
		GameRound.setting("random_min", "Willekeurig geluid na min.", 5, 600, 5, "s"),
		GameRound.setting("random_max", "Willekeurig geluid na max.", 5, 600, 5, "s"),
	]


## Plays a random sound of `event` (nothing if there is none). Not the same
## event twice within `min_gap` s (e.g. 13 hits at once: one sound).
func play(event: StringName, min_gap := 0.08) -> void:
	if not enabled or volume <= 0 or not _sounds.has(event):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(event, -100000)) < min_gap * 1000.0:
		return
	_last[event] = now
	var p := _free_player()
	p.stream = _sounds[event].pick_random()
	p.volume_db = linear_to_db(volume / 100.0)
	p.play()


## A sound asked for from outside (web interface, an external system):
## `file` = one file of the event (else a random one), `vol` = volume in %
## for this sound only (-1: the setting). Plays whatever the game is doing.
## Returns false when there is no such sound.
func play_external(event: StringName, file := "", vol := -1) -> bool:
	if not _sounds.has(event):
		return false
	var stream: AudioStream = _sounds[event].pick_random()
	if file != "":
		var i: int = _files[event].find(file)
		if i < 0:
			return false
		stream = _sounds[event][i]
	if not enabled:
		return true
	var v := float(volume if vol < 0 else clampi(vol, 0, 100))
	if v <= 0.0:
		return true
	var p := _free_player()
	p.stream = stream
	p.volume_db = linear_to_db(v / 100.0)
	p.play()
	return true


## Stops every sound that is playing now.
func stop_all() -> void:
	for p in _players:
		p.stop()


## Every event with its files: {"attack": ["laser1.ogg", ...], ...}.
func catalog() -> Dictionary:
	var out := {}
	for e in _files:
		out[String(e)] = _files[e].duplicate()
	return out


## Scans the sound folders again (new files in --sounds=DIR count at once;
## new files in the project's own data/sounds/ need an import first).
func reload() -> void:
	_sounds.clear()
	_files.clear()
	_load_dir(SOUND_DIR, true)
	if extra_dir != "":
		_load_dir(extra_dir.path_join(""), false)
	sounds_changed.emit()


func has_sounds(event: StringName) -> bool:
	return _sounds.has(event)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < _next_random:
		return
	_next_random = _clock + randf_range(random_min, maxf(random_min, random_max))
	var game: GameManager = get_parent().game
	if game.mode == GameManager.Mode.OPEN and game.state != GameManager.State.SCOREBOARD:
		play(&"random")


func _free_player() -> AudioStreamPlayer:
	for p in _players:
		if not p.playing:
			return p
	return _players[0]                 # all busy: cut the oldest-started one


func _load_dir(dir: String, packed: bool) -> void:
	var events: PackedStringArray = ResourceLoader.list_directory(dir) if packed else DirAccess.get_directories_at(dir)
	for e in events:
		var event := e.trim_suffix("/")
		if packed and not e.ends_with("/"):
			continue
		var files: PackedStringArray = ResourceLoader.list_directory(dir + event) if packed \
			else DirAccess.get_files_at(dir.path_join(event))
		for f in files:
			if f.get_extension().to_lower() not in EXTENSIONS:
				continue
			var path := dir.path_join(event).path_join(f)
			var stream: AudioStream = load(path) if packed else _load_file(path)
			if stream:
				if not _sounds.has(StringName(event)):
					_sounds[StringName(event)] = []
					_files[StringName(event)] = []
				_sounds[StringName(event)].append(stream)
				_files[StringName(event)].append(f.trim_suffix(".import").trim_suffix(".remap"))


## A sound file outside the project (--sounds=DIR).
func _load_file(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null
