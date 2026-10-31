class_name ControlApi
extends Node
## The game master's data source in the installation: the control server's
## HTTP API (control/server.py owns the database). Same methods as GameDb, so
## the game doesn't care which one it has:
##   questions(), leaderboard()    cached here, fetched at the start and kept fresh
##   fetch_player(id)              await it: asks the server
##   start_game(), save_round(), save_result(), end_game()
##                                 queued and sent in order, retried while the
##                                 server can't be reached - nothing gets lost
## start_game() returns a temporary (negative) id at once; the queued requests
## use the server's real id as soon as it is known.

signal changed                    # the ranking was refreshed

const REFRESH_TIME := 60.0        # s between fetching questions and ranking
const RETRY_TIME := 3.0

var base_url := ""                # e.g. http://192.168.1.10:8080
var _questions: Array = []
var _ranking: Array = []
var _queue: Array = []            # [{method, path (may hold "{game}"), body, game}]
var _busy := false
var _game_ids := {}               # temporary id -> the server's id
var _next_temp := -1
var _refresh := 0.0


func open(url: String) -> bool:
	base_url = url.trim_suffix("/")
	refresh()
	return true


func is_open() -> bool:
	return base_url != ""


func questions() -> Array:
	return _questions


func leaderboard() -> Array:
	return _ranking


func refresh() -> void:
	var q = await _http_get("/api/questions")
	if q is Array:
		_questions = q
	var r = await _http_get("/api/ranking")
	if r is Array:
		_ranking = r
		changed.emit()


func fetch_player(id: int) -> Dictionary:
	var p = await _http_get("/api/players/%d" % id)
	return p if p is Dictionary else {}


func start_game() -> int:
	var temp := _next_temp
	_next_temp -= 1
	_queue.append({"method": HTTPClient.METHOD_POST, "path": "/api/games", "body": {}, "start": temp})
	_pump()
	return temp


func end_game(game_id: int) -> void:
	_enqueue("/api/games/{game}/end", {}, game_id)


func save_round(game_id: int, round: int, round_type: String, rows: Array) -> void:
	_enqueue("/api/games/{game}/rounds", {"round": round, "type": round_type, "rows": rows}, game_id)


func save_result(game_id: int, r: Dictionary) -> void:
	_enqueue("/api/games/{game}/results", {"rows": [r]}, game_id)
	_queue.append({"refresh": true})      # the ranking changed
	_pump()


func _process(delta: float) -> void:
	_refresh -= delta
	if _refresh <= 0.0 and is_open():
		_refresh = REFRESH_TIME
		refresh()                         # questions edited in the web interface, ranking


func _enqueue(path: String, body: Dictionary, game_id: int) -> void:
	_queue.append({"method": HTTPClient.METHOD_POST, "path": path, "body": body, "game": game_id})
	_pump()


## Send the queued requests one by one, in order; retry while the server is away.
func _pump() -> void:
	if _busy:
		return
	_busy = true
	while not _queue.is_empty():
		var item: Dictionary = _queue[0]
		if item.has("refresh"):
			_queue.pop_front()
			refresh()
			continue
		var path: String = item.path
		if item.has("game"):
			var id: int = item.game
			if id < 0:
				if not _game_ids.has(id):        # the game itself is not on the server yet
					break
				id = _game_ids[id]
			path = path.replace("{game}", str(id))
		var result = await _request(item.method, path, item.body)
		if result == null:                      # server not reachable: try again later
			await get_tree().create_timer(RETRY_TIME).timeout
			continue
		if item.has("start"):
			_game_ids[item.start] = int(result.get("id", 0))
		_queue.pop_front()
	_busy = false


func _http_get(path: String):
	return await _request(HTTPClient.METHOD_GET, path, null)


## One request; returns the parsed JSON, or null when it failed.
func _request(method: int, path: String, body):
	if not is_inside_tree():
		return null
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	var data := "" if body == null else JSON.stringify(body)
	var err := http.request(base_url + path, ["Content-Type: application/json"], method, data)
	if err != OK:
		http.queue_free()
		return null
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] >= 400:
		if res[1] != 404:
			push_warning("control server: %s %s -> %s/%s" % [method, path, res[0], res[1]])
		return null
	return JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
