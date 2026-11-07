class_name NodeMetrics
extends Node
## Performance metrics of this Godot process, for the web interface's
## *Prestaties* tab: <prefix>/metrics/<node> every INTERVAL s (not retained).
## The engine's monitors (Performance), the frame times of the last interval
## (average, worst, how many over budget), the process's CPU and memory, the
## machine's load, memory and temperature (Linux / Raspberry Pi: /proc, /sys).
## extra: a Callable returning the role's own part (the mirror, the game).

const INTERVAL := 2.0
const BUDGET_MS := 1000.0 / 30.0              # a frame slower than this is a "slow frame"

var mqtt: MqttClient
var topic := ""
var node_id := ""
var role := ""
var extra := Callable()
var sink := Callable()                         # instead of MQTT: (metrics) -> send them (a display node: to the master)

var _t := 0.0
var _frames := 0
var _sum_ms := 0.0
var _worst_ms := 0.0
var _slow := 0
var _cpu_last := -1.0                          # process CPU ticks (utime + stime) at the last sample
var _cpu_wall := 0.0
var _mqtt_last := {}
var _started := Time.get_unix_time_from_system()
static var _tick_hz := 100.0                  # (USER_HZ: 100 on Linux, ARM included)


func _process(delta: float) -> void:
	var ms := delta * 1000.0
	_frames += 1
	_sum_ms += ms
	_worst_ms = maxf(_worst_ms, ms)
	if ms > BUDGET_MS:
		_slow += 1
	var now := Time.get_ticks_msec() / 1000.0           # (wall clock: also at --fixed-fps, recording movies)
	if _t <= 0.0:
		_t = now
	if now - _t < INTERVAL:
		return
	var span := now - _t
	_t = now
	if not sink.is_valid() and (mqtt == null or not mqtt.online or topic == ""):
		_reset()
		return
	var m := sample(span)
	if extra.is_valid():
		m.merge(extra.call(span), true)
	if sink.is_valid():
		sink.call(m)
	else:
		mqtt.publish_json(topic, m)
	_reset()


func _reset() -> void:
	_frames = 0
	_sum_ms = 0.0
	_worst_ms = 0.0
	_slow = 0


## One sample (span: the seconds it covers).
func sample(span: float) -> Dictionary:
	var m := {
		"id": node_id, "role": role, "t": Time.get_unix_time_from_system(),
		"uptime": int(Time.get_unix_time_from_system() - _started),
		"fps": Engine.get_frames_per_second(),
		"frame_ms": snappedf(_sum_ms / maxi(_frames, 1), 0.01),
		"worst_ms": snappedf(_worst_ms, 0.1),
		"slow_frames": _slow,                     # frames over BUDGET_MS in this span
		"process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
		"physics_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"mem_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"vram_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"audio_ms": snappedf(Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0, 0.1),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"gpu": RenderingServer.get_video_adapter_name(),
		"cpus": OS.get_processor_count(),
	}
	var cpu := _process_cpu()
	if cpu >= 0.0:
		m["cpu"] = cpu                            # % of one core (200 = two cores busy)
	var rss := _proc_status_kb("VmRSS")
	if rss > 0:
		m["rss_mb"] = snappedf(rss / 1024.0, 0.1)
	m.merge(machine(), true)
	if mqtt and (mqtt.online or not _mqtt_last.is_empty()):
		var now := {"in": mqtt.msgs_in, "out": mqtt.msgs_out, "bin": mqtt.bytes_in, "bout": mqtt.bytes_out}
		if not _mqtt_last.is_empty():
			m["mqtt"] = {"in_s": snappedf((now.in - _mqtt_last.in) / span, 0.1),
				"out_s": snappedf((now.out - _mqtt_last.out) / span, 0.1),
				"in_kbps": snappedf((now.bin - _mqtt_last.bin) * 8.0 / 1000.0 / span, 0.1),
				"out_kbps": snappedf((now.bout - _mqtt_last.bout) * 8.0 / 1000.0 / span, 0.1),
				"reconnects": mqtt.reconnects}
		_mqtt_last = now
	return m


## The machine: load, memory, temperature (Linux; empty elsewhere).
static func machine() -> Dictionary:
	var out := {}
	var load := _read("/proc/loadavg")
	if load != "":
		out["load"] = float(load.get_slice(" ", 0))
	var total := _meminfo_kb("MemTotal")
	var avail := _meminfo_kb("MemAvailable")
	if total > 0:
		out["sys_mem_mb"] = int(total / 1024)
		out["sys_mem_used"] = snappedf(100.0 * (total - avail) / total, 0.1)
	var temp := _read("/sys/class/thermal/thermal_zone0/temp")
	if temp != "":
		out["temp_c"] = snappedf(int(temp) / 1000.0, 0.1)    # (a Pi 5 throttles from 85 °C)
	var freq := _read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
	if freq != "":
		out["cpu_mhz"] = int(int(freq) / 1000)
	return out


func _process_cpu() -> float:
	var stat := _read("/proc/self/stat")
	if stat == "":
		return -1.0
	var rest := stat.substr(stat.rfind(")") + 2).split(" ")     # (the name may hold spaces)
	if rest.size() < 13:
		return -1.0
	var ticks := float(rest[11]) + float(rest[12])              # utime, stime
	var wall := Time.get_ticks_msec() / 1000.0
	var out := -1.0
	if _cpu_last >= 0.0 and wall > _cpu_wall:
		out = snappedf(100.0 * (ticks - _cpu_last) / _tick_hz / (wall - _cpu_wall), 0.1)
	_cpu_last = ticks
	_cpu_wall = wall
	return out


static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()                # (line by line: /proc and /sys files report no length)
	while true:
		var line := f.get_line()
		if f.eof_reached() and line == "":
			break
		lines.append(line)
		if f.eof_reached():
			break
	return "\n".join(lines).strip_edges()


static func _meminfo_kb(key: String) -> int:
	for line in _read("/proc/meminfo").split("\n"):
		if line.begins_with(key + ":"):
			return int(line.get_slice(":", 1).strip_edges().get_slice(" ", 0))
	return 0


static func _proc_status_kb(key: String) -> int:
	for line in _read("/proc/self/status").split("\n"):
		if line.begins_with(key + ":"):
			return int(line.get_slice(":", 1).strip_edges().get_slice(" ", 0))
	return 0
