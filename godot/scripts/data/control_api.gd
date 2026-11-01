class_name ControlApi
extends Node
## The game master's data source in the installation: the control server's
## HTTP API (control/server.py owns the database). Same methods as GameDb, so
## the game doesn't care which one it has:
##   questions(), leaderboard()    cached here, fetched at the start and kept fresh
##   fetch_player(id)              await it: asks the server
##   start_game(), save_round(), save_result(), end_game()
##                                 queued and sent in order, retried while the
##                                 server can't be reached - nothing gets lost:
##                                 the queue is kept on disk (queue_file(), one
##                                 per control server) and sent after a restart too
## save_checkpoint() / fetch_checkpoint(): the game's state for after a crash
## (Recovery) - the control server keeps it; only the newest one waits.
## refresh() at once when the control server says the database changed
## (<prefix>/db over MQTT: a question edited, a player renamed, the ranking),
## else every REFRESH_TIME.
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
var _refreshing := false
var _db_id := ""                  # the control server's database (its checkpoints belong to it)
var _refresh_again := false


func open(url: String) -> bool:
	base_url = url.trim_suffix("/")
	_load_queue()
	refresh()
	_pump()
	return true


## Writes not on the server yet (0 = in sync).
func pending() -> int:
	return _queue.filter(func(i): return not i.has("refresh") and not i.has("checkpoint")).size()


func db_id() -> String:
	return _db_id


## The game state for after a crash: the newest replaces one still waiting
## (not the one being sent right now).
func save_checkpoint(data: Dictionary) -> void:
	var keep := []
	for i in _queue.size():
		if not _queue[i].has("checkpoint") or (i == 0 and _busy):
			keep.append(_queue[i])
	_queue = keep
	_queue.append({"method": HTTPClient.METHOD_PUT, "path": "/api/checkpoint", "body": {"checkpoint": data},
		"checkpoint": true})
	_save_queue()
	_pump()


## {db, checkpoint}: what the control server keeps; null when it can't be reached.
func fetch_checkpoint():
	var r = await _http_get("/api/checkpoint")
	if r is Dictionary:
		_db_id = str(r.get("db", ""))
		_save_queue()
	return r


## The server's id for a game started while it was away (a temporary id until then).
func server_game_id(id: int) -> int:
	return _game_ids.get(id, id)


## The game is (or will be) in the database: a real id, or one still to be sent.
func knows_game(id: int) -> bool:
	return id > 0 or _game_ids.has(id) or _queue.any(func(i): return i.get("start") == id)


func is_open() -> bool:
	return base_url != ""


func questions() -> Array:
	return _questions


func leaderboard() -> Array:
	return _ranking


func refresh() -> void:
	if _refreshing:                       # (one at a time; a change during it: once more after)
		_refresh_again = true
		return
	_refreshing = true
	_refresh = REFRESH_TIME
	var q = await _http_get("/api/questions")
	if q is Array:
		_questions = q
	var r = await _http_get("/api/ranking")
	if r is Array:
		_ranking = r
		changed.emit()
	_refreshing = false
	if _refresh_again:
		_refresh_again = false
		refresh()


func fetch_player(id: int) -> Dictionary:
	var p = await _http_get("/api/players/%d" % id)
	return p if p is Dictionary else {}


func start_game() -> int:
	var temp := _next_temp
	_next_temp -= 1
	_queue.append({"method": HTTPClient.METHOD_POST, "path": "/api/games", "body": {}, "start": temp})
	_save_queue()
	_pump()
	return temp


func end_game(game_id: int) -> void:
	_enqueue("/api/games/{game}/end", {}, game_id)


func save_round(game_id: int, round: int, round_type: String, rows: Array) -> void:
	_enqueue("/api/games/{game}/rounds", {"round": round, "type": round_type, "rows": rows}, game_id)


func save_result(game_id: int, r: Dictionary) -> void:
	_enqueue("/api/games/{game}/results", {"rows": [r]}, game_id)
	_queue.append({"refresh": true})      # the ranking changed
	_save_queue()
	_pump()


func _process(delta: float) -> void:
	_refresh -= delta
	if _refresh <= 0.0 and is_open():
		refresh()                         # (a fallback: normally <prefix>/db says when)


func _enqueue(path: String, body: Dictionary, game_id: int) -> void:
	_queue.append({"method": HTTPClient.METHOD_POST, "path": path, "body": body, "game": game_id})
	_save_queue()
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
		_save_queue()
	_busy = false


## The queue on disk: what the server hasn't got yet survives a restart. One
## file per server (a test server's writes never go to the installation's).
func queue_file() -> String:
	return "user://control_queue_%s.json" % base_url.md5_text().left(12)


func _save_queue() -> void:
	var f := FileAccess.open(queue_file(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"queue": _queue.filter(func(i): return not i.has("refresh")),
			"game_ids": _game_ids, "next_temp": _next_temp, "db_id": _db_id}))


func _load_queue() -> void:
	if not FileAccess.file_exists(queue_file()):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(queue_file()))
	if not d is Dictionary:
		return
	for item in d.get("queue", []):        # (JSON numbers come back as floats)
		for k in ["method", "game", "start"]:
			if item.has(k):
				item[k] = int(item[k])
		_queue.append(item)
	for k in d.get("game_ids", {}):
		_game_ids[int(k)] = int(d.game_ids[k])
	_next_temp = mini(_next_temp, int(d.get("next_temp", -1)))
	_db_id = str(d.get("db_id", ""))
	if not _queue.is_empty():
		print("control server: %d writes from before the restart still to send" % pending())


func _http_get(path: String):
	return await _request(HTTPClient.METHOD_GET, path, null)


## One request; returns the parsed JSON, or null when it failed.
func _request(method: int, path: String, body):
	if not is_inside_tree():
		return null
	var http := HTTPRequest.new()
	http.timeout = 5.0
	if TlsTrust.options and base_url.begins_with("https"):
		http.set_tls_options(TlsTrust.options)
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
