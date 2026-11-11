class_name CompanionStream
extends Node
## A live video of ONE player's screen, for a partially sighted player who
## reads it close by on their own phone or tablet (the accessible page, control
## server /a11y/<token>). Only exists while such a player has their page open:
## the control server starts it with {"stream": {"tile": 3, "on": true, "url": ...}}
## on <prefix>/cmd, repeats that every few seconds (keep-alive) and stops it;
## without a keep-alive for TIMEOUT s, or when the player has left, it stops
## itself. Not used: nothing of this runs.
##
## The screen the player faces is already rendered (ScreenWall: one
## SubViewport per screen): each frame its picture is read back (no second
## render) and piped as raw RGBA to FFmpeg, which encodes H.264 (NVENC on an
## NVIDIA GPU, else libx264) and publishes it to the stream server (MediaMTX,
## RTSP); browsers play it over WebRTC. The pipe is written on a worker
## thread: a slow encoder drops frames, it never stalls the game.
## Hardware: docs/SETUP.md §14 (one stream ~ a few ms GPU read-back per frame;
## encoding on the GPU, or ~1 CPU core with libx264 at 1280x720 15 fps).

signal state_changed(tile_id: int, on: bool, info: Dictionary)

const TIMEOUT := 30.0               # s without a keep-alive: stop
const LEFT_TIMEOUT := 10.0          # s the player is gone (left the game): stop

var arena: Arena
var tile_id := 0
var url := ""                       # rtsp://user:pass@host:8554/<path> (MediaMTX)
var fps := 15
var out_size := Vector2i(1280, 720)
var encoder := "auto"               # auto / h264_nvenc / libx264 / h264_v4l2m2m
var ffmpeg := "ffmpeg"
var sink_file := ""                 # (tests: raw frames to this file instead of FFmpeg)

var _screen := -1
var _pipe: FileAccess
var _pid := -1
var _used_encoder := ""
var _acc := 0.0
var _alive := 0.0                   # s since the last keep-alive
var _gone := 0.0                    # s the player is not on their place
var _check := 0.0
var _frames := 0
var _mutex := Mutex.new()
var _busy := false
var _running := false
var _src := Vector2i.ZERO
var _remote := false                # the screen is a display node's: rendered here only for this


func configure(cfg: Dictionary) -> void:
	url = str(cfg.get("url", url))
	fps = clampi(int(cfg.get("fps", fps)), 1, 30)
	encoder = str(cfg.get("encoder", encoder))
	ffmpeg = str(cfg.get("ffmpeg", ffmpeg))
	sink_file = str(cfg.get("file", sink_file))
	if cfg.has("width") and cfg.has("height"):
		out_size = Vector2i(int(cfg.width), int(cfg.height))


func keep_alive() -> void:
	_alive = 0.0


func start() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("no picture: the game runs headless")
		return
	var screens: Array = arena.narrator.screens_of(tile_id)
	if screens.is_empty():
		_fail("no screen shows this place")
		return
	_screen = int(screens[0]) - 1
	var vp: Viewport = arena.screen_wall.screen_viewport(_screen)
	if vp == null:
		_fail("no screen viewport")
		return
	_src = vp.size
	if not _remote and arena.screen_wall.is_remote(_screen):
		_remote = true
		arena.screen_wall.render_remote(_screen, true)
	if sink_file != "":
		_pipe = FileAccess.open(sink_file, FileAccess.WRITE)
		_used_encoder = "file"
	else:
		_used_encoder = _pick_encoder()
		var p: Dictionary = OS.execute_with_pipe(ffmpeg, _args(_used_encoder), false)
		_pipe = p.get("stdio")
		_pid = int(p.get("pid", -1))
		if _pipe == null or _pid <= 0:
			_fail("cannot start %s" % ffmpeg)
			return
	_running = true
	print("stream: %s, screen %d (%dx%d -> %dx%d, %d fps, %s)" % [
		Retro.tile_label(tile_id), _screen + 1, _src.x, _src.y, out_size.x, out_size.y, fps, _used_encoder])
	state_changed.emit(tile_id, true, {"screen": _screen + 1, "encoder": _used_encoder})


func stop(reason := "") -> void:
	if not _running and _pid < 0:
		return
	_running = false
	_mutex.lock()                       # (let a write in flight finish)
	if _pipe:
		_pipe.close()
		_pipe = null
	_mutex.unlock()
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	if _remote:
		_remote = false
		arena.screen_wall.render_remote(_screen, false)
	print("stream: %s stopped%s (%d frames)" % [Retro.tile_label(tile_id), " - " + reason if reason else "", _frames])
	state_changed.emit(tile_id, false, {"reason": reason})


func _exit_tree() -> void:
	stop("closed")


func _process(delta: float) -> void:
	if not _running:
		return
	var why := _stop_reason(delta)
	if why != "":
		stop(why)
		queue_free()
		return
	_check += delta
	if _check > 1.0:
		_check = 0.0
		if _pid > 0 and not OS.is_process_running(_pid):
			_encoder_died()
			return
	_acc += delta
	if _acc >= 1.0 / fps:
		_acc = 0.0
		_capture()


## Why the stream ends now ("": it goes on): no keep-alive, or the player left.
func _stop_reason(delta: float) -> String:
	_alive += delta
	if _alive > TIMEOUT:
		return "no keep-alive"
	_gone = 0.0 if (arena.players.is_playing(tile_id) or arena.players.is_pending(tile_id)) else _gone + delta
	return "the player left" if _gone > LEFT_TIMEOUT else ""


## The encoder died (e.g. NVENC without an NVIDIA GPU): fall back once.
func _encoder_died() -> void:
	if _used_encoder != "libx264" and encoder == "auto":
		print("stream: %s failed, trying libx264" % _used_encoder)
		encoder = "libx264"
		_running = false
		_pid = -1
		if _pipe:
			_pipe.close()
			_pipe = null
		start()
	else:
		stop("the encoder stopped")
		queue_free()


## One frame of the player's screen to the encoder.
func _capture() -> void:
	_mutex.lock()
	var busy := _busy
	_mutex.unlock()
	if busy:
		return                          # (the encoder is behind: drop this frame)
	var vp: Viewport = arena.screen_wall.screen_viewport(_screen)
	var img := vp.get_texture().get_image() if vp else null
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_size() != _src:
		img.resize(_src.x, _src.y)
	_mutex.lock()
	_busy = true
	_mutex.unlock()
	WorkerThreadPool.add_task(_write.bind(img.get_data()))


func _write(data: PackedByteArray) -> void:
	_mutex.lock()
	if _pipe:
		_pipe.store_buffer(data)
		_frames += 1
	_busy = false
	_mutex.unlock()


func _fail(why: String) -> void:
	if _remote:
		_remote = false
		arena.screen_wall.render_remote(_screen, false)
	push_warning("stream %s: %s" % [Retro.tile_label(tile_id), why])
	state_changed.emit(tile_id, false, {"error": why})
	queue_free()


## auto: NVENC when FFmpeg has it (an NVIDIA GPU), else libx264 (the CPU).
func _pick_encoder() -> String:
	if encoder != "auto":
		return encoder
	var out := []
	OS.execute(ffmpeg, ["-hide_banner", "-encoders"], out, true)
	return "h264_nvenc" if "h264_nvenc" in "".join(out) else "libx264"


## FFmpeg: raw RGBA frames on stdin -> H.264 without B-frames (WebRTC) -> RTSP.
func _args(enc: String) -> PackedStringArray:
	var a := PackedStringArray(["-hide_banner", "-loglevel", "error",
		"-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % [_src.x, _src.y], "-r", str(fps), "-i", "-"])
	if out_size != _src:
		a.append_array(["-vf", "scale=%d:%d:flags=bilinear" % [out_size.x, out_size.y]])
	a.append_array(["-pix_fmt", "yuv420p", "-c:v", enc, "-g", str(fps * 2), "-bf", "0"])
	match enc:
		"h264_nvenc":
			a.append_array(["-preset", "p1", "-tune", "ll", "-zerolatency", "1", "-b:v", "2M"])
		"libx264":
			a.append_array(["-preset", "ultrafast", "-tune", "zerolatency", "-b:v", "2M", "-profile:v", "baseline"])
		_:
			a.append_array(["-b:v", "2M"])
	if url.ends_with(".mp4") or url.ends_with(".mkv"):     # (tests: into a file)
		a.append_array(["-y", url])
	else:
		a.append_array(["-f", "rtsp", "-rtsp_transport", "tcp", url])
	return a
