class_name Narrator
extends Node
## Read-aloud: the question, its answers and the screen texts as speech, on a
## channel of its own (for players who find reading hard). Prebaked audio
## files only - no speech engine in the game:
##   data/voice/<name>.ogg (.wav, .mp3)  or the folder of --voice=DIR (no import needed)
## Every line has a fixed file name (lines(): the list to record or generate;
## `--voice-export=FILE` writes them as CSV and quits):
##   question_<text>_<hash>           the question     ("<question>")
##   question_<text>_<hash>_answer_<n> its answers     ("Vierkant: <answer 1>", ...)
##   round_<type>             a round's intro          ("<name>. <rules>")
##   time_up                  "Tijd om!"
##   invite_tile_03 / invite_m1   an invited player     ("Ga naar tegel 3 en druk op de 4 iconen.")
## Personal lines (say_to): for one player only ("tile"), e.g. "Je koos
## Driehoek." - for the accessible page of a blind or partially sighted player
## (control server /a11y/<token>); without a file they are only sent out.
## Settings (web interface, group "Voorlezen"): on / off (enabled), the output:
## stereo (mixed with the sound effects) / the CENTRE channel of a 5.1 or 7.1
## sound card (its own jack: a separate speaker or headphones), the volume.
## Its own audio bus, "Voice". Off: nothing is played anywhere - the lines
## still go out on MQTT (the accessible companion pages show their text).
## With display nodes (Replica) a line plays on the Pi(s) showing its screens
## (a question on every Pi, an invite only where that tile is), where the
## sound plays (SoundBoard.where_to).
## Every line is linked to the screens that show its text ("screens": the
## screen numbers, as --screens counts them: all of them for a question or a
## round's intro, the one with the player's tile for an invite) and goes out
## on MQTT (<prefix>/voice: {name, text, kind, screens, tile?, file}) - so a
## speaker / headphones / a Pi per screen can play the lines of its own screen.

signal line_said(line: Dictionary)

const VOICE_DIR := "res://data/voice/"
const EXTENSIONS := ["ogg", "wav", "mp3"]
const BUS := "Voice"
const ICON_NAMES := ["Vierkant", "Driehoek", "Kruis", "Cirkel"]   # QuizRound.ANSWER_BUTTONS order

var enabled := 0                       # 1: read aloud (0: off - the lines still go out on MQTT)
var output := 1                        # 1 stereo, 2 the centre channel (5.1 / 7.1); (0: off, as before)
var volume := 100                      # %
var extra_dir := ""                    # --voice=DIR

var _player: AudioStreamPlayer
var _queue: Array[AudioStream] = []
var _missing := {}                     # name -> true: reported once
var _cache := {}                       # name -> AudioStream (or null: no file)
var wall: ScreenWall                   # (which screen shows which tile)


func _ready() -> void:
	if AudioServer.get_bus_index(BUS) < 0:              # its own bus: its own volume / effects / routing
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, BUS)
		AudioServer.set_bus_send(i, "Master")
	_player = AudioStreamPlayer.new()
	_player.bus = BUS
	add_child(_player)
	_player.finished.connect(_play_next)


## The settings for the web interface (as GameRound.tunables).
func tunables() -> Array:
	return [
		GameRound.setting("enabled", "Voorlezen aan (1) of uit (0)", 0, 1, 1),
		GameRound.setting("output", "Voorlezen: 1 stereo, 2 middenkanaal (5.1/7.1)", 1, 2, 1),
		GameRound.setting("volume", "Voorlezen: volume (%)", 0, 100, 5),
	]


## Say a line: plays data/voice/<name>.* (when there is one and the output is
## on) and sends it out (MQTT). interrupt: stop what is being said (a new
## question). data: extra fields for the message, e.g. {"tile": 3}.
func say(name: String, text: String, kind: String, data := {}, interrupt := false) -> void:
	var stream := _stream(name)
	var line := data.duplicate()
	if not line.has("screens"):
		line["screens"] = screens_of(int(data.get("tile", 0)))
	line.merge({"name": name, "text": text, "kind": kind, "file": name if stream else ""})
	line_said.emit(line)
	if stream == null:
		if not _missing.has(name):
			_missing[name] = true
			print("voice: no file for %s (\"%s\")" % [name, text.left(60)])
		return
	if not is_on():
		return
	var sound: SoundBoard = get_parent().get("sound") if get_parent() else null
	if sound == null or SoundBoard.plays_on_displays(sound.where_to):
		Replica.relay_to_screens(line.get("screens", []), "narrator", &"play_line", [name, interrupt])
	if sound and not sound.plays_here():
		return
	play_line(name, interrupt)


func is_on() -> bool:
	return enabled == 1 and output > 0 and volume > 0


## Play one line's file (here; a display node: as the master sends it).
func play_line(name: String, interrupt := false) -> void:
	var stream := _stream(name)
	if stream == null or not is_on():
		return
	if interrupt:
		_queue.clear()
		_player.stop()
	_queue.append(stream)
	if not _player.playing:
		_play_next()


## The screens (1, 2, ...) showing a tile's place; tile 0: every screen.
func screens_of(tile_id: int) -> Array:
	var groups: Array = wall.groups() if wall else []
	if tile_id <= 0:
		return range(1, groups.size() + 1)
	var out := []
	for i in groups.size():
		if tile_id in groups[i]:
			out.append(i + 1)
	return out


func stop() -> void:
	_queue.clear()
	_player.stop()


func _play_next() -> void:
	if _queue.is_empty():
		return
	_player.stream = _queue.pop_front()
	_player.volume_db = linear_to_db(volume / 100.0)
	_player.mix_target = AudioStreamPlayer.MIX_TARGET_CENTER if output == 2 else AudioStreamPlayer.MIX_TARGET_STEREO
	_player.play()


func _stream(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var stream: AudioStream = null
	for ext in EXTENSIONS:
		var path: String = VOICE_DIR + name + "." + ext
		if ResourceLoader.exists(path):
			stream = load(path)
			break
		if extra_dir != "":
			var file: String = extra_dir.path_join(name + "." + ext)
			if FileAccess.file_exists(file):
				match ext:
					"ogg": stream = AudioStreamOggVorbis.load_from_file(file)
					"wav": stream = AudioStreamWAV.load_from_file(file)
					"mp3": stream = AudioStreamMP3.load_from_file(file)
				break
	_cache[name] = stream
	return stream


# ---------------------------------------------------------------- the lines

## A line for one player only (kind "personal"): their answer, right or
## wrong, hit, a life, their place. name: a fixed file name (personal_<what>).
func say_to(tile_id: int, what: String, text: String) -> void:
	say("personal_" + what, text, "personal", {"tile": tile_id})


## A question's file name, from its text: readable and a short hash, e.g.
## question_wat-is-phishing_32c557. A changed text gets a new name, so an old
## recording never plays with a different question.
static func question_name(q: Dictionary) -> String:
	var text := str(q.get("question", ""))
	var slug := ""
	for ch in text.to_lower():
		if ch in "abcdefghijklmnopqrstuvwxyz0123456789":
			slug += ch
		elif not slug.ends_with("-"):
			slug += "-"
	slug = slug.trim_prefix("-").trim_suffix("-").left(32).trim_suffix("-")
	return "question_%s_%s" % [slug, text.sha1_text().left(6)]


static func answer_line(q: Dictionary, n: int) -> String:
	return "%s: %s" % [ICON_NAMES[n], q.answers[n]]


static func invite_name(tile_id: int) -> String:
	return "invite_tile_%02d" % tile_id if tile_id <= Retro.FLOOR_TILES else "invite_m%d" % (tile_id - Retro.FLOOR_TILES)


static func invite_line(tile_id: int) -> String:
	if tile_id <= Retro.FLOOR_TILES:
		return "Ga naar tegel %d en druk op de 4 iconen." % tile_id
	return "Ga naar mobiele plaats M%d en druk op de 4 iconen." % (tile_id - Retro.FLOOR_TILES)


## Every line the game can say: [{name, text, kind}] (the questions as they are
## in the database now, the rounds with the operator's names and rules).
static func lines(game: GameManager) -> Array:
	var out := []
	for q in game.all_questions():
		var qn := question_name(q)
		out.append({"name": qn, "text": str(q.question), "kind": "question"})
		for n in mini(q.answers.size(), 4):
			out.append({"name": "%s_answer_%d" % [qn, n + 1], "text": answer_line(q, n), "kind": "answer"})
	for t in GameManager.ROUND_TYPES:
		var r: GameRound = t.new()
		var type := game.round_type_name(t)
		Texts.dress(r, type)
		out.append({"name": "round_" + type, "text": "%s. %s" % [r.title, r.rules], "kind": "round"})
	out.append({"name": "time_up", "text": "Tijd om!", "kind": "time_up"})
	for id in range(1, Retro.FLOOR_TILES + 6):
		out.append({"name": invite_name(id), "text": invite_line(id), "kind": "invite"})
	return out


## --voice-export=FILE: the lines as CSV (name;text;kind), for recording.
static func export_csv(game: GameManager, path: String) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("voice: cannot write %s" % path)
		return 0
	f.store_line("file;text;kind")
	var all := lines(game)
	for l in all:
		var text := str(l.text).replace("\n", " ").replace('"', '""')
		f.store_line('%s;"%s";%s' % [l.name, text, l.kind])
	return all.size()
