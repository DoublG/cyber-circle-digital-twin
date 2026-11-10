class_name RoundState
extends RefCounted
## One player's state in a round. Every round type that keeps one has its own
## class with typed fields (CycloneRound.PlayerState, ...) instead of a
## Dictionary: a wrong field name or type is an error when the script loads,
## not a surprise in the middle of a game.
## The display nodes (Replica) only get plain data: pack() on the master,
## unpack() there builds the same objects again (GameRound.state_fields).
## Fields are plain values, Arrays and Dictionaries (no typed arrays, no objects).

static var _names := {}            # Script -> the names of its fields


## {tile_id: RoundState} as plain data: {tile_id: {field: value}}.
static func pack(states: Dictionary) -> Dictionary:
	var out := {}
	for id in states:
		out[id] = states[id].to_dict()
	return out


## The other way: fills `states` with objects of `type` from pack()'s data.
static func unpack(states: Dictionary, data: Dictionary, type: GDScript) -> void:
	states.clear()
	for id in data:
		var st: RoundState = type.new()
		st.apply_dict(data[id])
		states[id] = st


## The fields as plain data: {name: value}.
func to_dict() -> Dictionary:
	var d := {}
	for f in _fields():
		d[f] = get(f)
	return d


func apply_dict(d: Dictionary) -> void:
	for f in _fields():
		if d.has(f):
			set(f, d[f])


func _fields() -> Array:
	var type: Script = get_script()
	if not _names.has(type):
		_names[type] = get_property_list() \
			.filter(func(p): return p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) \
			.map(func(p): return p.name)
	return _names[type]
