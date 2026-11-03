class_name ZwartePietRound
extends GameRound
## Personal, competitive round: "Zwarte Piet". A random player's tile lights
## up with a light running around its ring, and a hidden random countdown
## starts. The player who has the light kicks it to a neighbour:
##   left  (Square / Cross)     -> the next player clockwise (seen from above)
##   right (Triangle / Circle)  -> the previous player
## (empty tiles and tiles out of service are skipped). The faster the kicks,
## the faster the light spins. When the countdown ends, whoever has the light
## loses 1 point and the robot fires at them (a show: lives only change at the
## end of the round); a new countdown starts at a random tile. Until the round
## time is up. Places by points: 1st +1 life, last -1 (GameRound.life_changes).
##
## The game runs this one (the light goes from tile to tile); the tile only
## shows it: {"piet": {"on": true, "speed": LEDs/s, "color": "#ff2a00"}} /
## {"piet": {"on": false}} and reports its presses as usual.

const LEFT: Array[StringName] = [&"Square", &"Cross"]
const PIET_COLOR := Color(1.0, 0.16, 0.0)

var countdown_min := 6.0             # s: hidden, random per burst
var countdown_max := 14.0
var penalty := 1                     # points lost by whoever has the light
var base_speed := 14.0               # LEDs/s around the ring
var max_speed := 60.0
var pause_time := 2.5                # s between a burst and the next

var holder := 0                      # tile with the light (0 = none: between bursts)
var speed := 0.0
var _left := 0.0                     # s until the current burst ends (hidden)
var _got_at := 0.0                   # round clock when the holder got the light
var _clock := 0.0
var _wait := 0.0                     # pause between bursts
var bursts := 0


func _init() -> void:
	title = "Zwarte Piet"
	mode = "personal"
	on_tile = true
	duration = 60.0
	rules = "Een lampje draait rond op een tegel. Heb jij het? Schop het snel weg!\nLinks (vierkant of kruis) of rechts (driehoek of cirkel) naar je buur.\nNiemand weet wanneer de tijd om is: wie het lampje dan heeft verliest een punt.\nNa de ronde: meeste punten +1 leven, minste punten -1 leven."


func tunables() -> Array:
	return super() + [
		setting("countdown_min", "Geheime tijd min", 2, 60, 1, "s"),
		setting("countdown_max", "Geheime tijd max", 2, 60, 1, "s"),
		setting("pause_time", "Pauze tussen beurten", 0.5, 10, 0.5, "s"),
		setting("base_speed", "Startsnelheid lichtje", 4, 60, 1),
		setting("max_speed", "Maximale snelheid", 10, 120, 5),
		setting("penalty", "Strafpunten", 0, 10, 1),
	]


func _start() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"piet": {"on": false}})
	_new_burst()


func _update(delta: float) -> void:
	_clock += delta
	if holder == 0:
		_wait -= delta
		if _wait <= 0.0 and time_left > 3.0:
			_new_burst()
		return
	if not _alive(holder):               # left or exterminated: pass it on
		_give(_neighbour(holder, 1))
		return
	_left -= delta
	if _left <= 0.0:
		_burst()


## A new hidden countdown at a random player.
func _new_burst() -> void:
	var alive := players.filter(func(id): return _alive(id))
	if alive.size() < 2:
		return
	bursts += 1
	speed = base_speed
	_left = randf_range(countdown_min, maxf(countdown_min, countdown_max))
	_give(alive.pick_random())


func button(id: int, b: StringName) -> void:
	if id != holder or holder == 0:
		return
	var reaction := _clock - _got_at
	# the faster the kick, the faster the light spins from now on
	speed = minf(max_speed, speed * (1.0 + 0.35 * clampf(1.0 - reaction / 1.5, 0.0, 1.0)) + 1.0)
	var to := _neighbour(id, 1 if b in LEFT else -1)
	game.arena.send_packet(id, PIET_COLOR, Callable())   # the light runs off down the cable
	_give(to)


## The next player in that direction (1 = clockwise from above = to the left of
## a player facing the robot), skipping empty and out-of-service tiles.
func _neighbour(id: int, dir: int) -> int:
	var n: int = game.arena.tiles.size()
	for step in range(1, n + 1):
		var other := posmod(id - 1 + dir * step, n) + 1
		if other != id and _alive(other):
			return other
	return id


func _give(id: int) -> void:
	if holder != 0 and holder != id:
		game.arena.send_to_tile(holder, {"piet": {"on": false}})
	holder = id
	_got_at = _clock
	game.arena.send_to_tile(id, {"piet": {"on": true, "speed": speed, "color": "#" + PIET_COLOR.to_html(false)}})


## Time is up: whoever has the light loses a point; the robot fires at them.
func _burst() -> void:
	var loser := holder
	game.arena.send_to_tile(loser, {"piet": {"on": false}})
	holder = 0
	_wait = pause_time
	add_points(loser, -penalty)
	game.screen_wall.popup(loser, "-%d ZWARTE PIET!" % penalty, Retro.BAD)
	game.arena.robot_attack([loser], PIET_COLOR, [], false)


func _alive(id: int) -> bool:
	return id in players and game.arena.is_playing(id) and not tile(id).is_dead


func finish() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"piet": {"on": false}})
	holder = 0


## Places: most points (the fewest times caught).
func progress(id: int) -> int:
	return points[id]


func replica_keys() -> Array:              # (what its overlay reads: Replica)
	return ["holder", "speed"]


func make_player_overlay(id: int) -> Control:
	var line := StatusLine.new()
	line.source = func():
		if holder == id:
			return "JIJ HEBT HET LICHT!  < LINKS  |  RECHTS >"
		return "%+d PUNTEN" % points.get(id, 0)
	return line
