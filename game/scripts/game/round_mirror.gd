class_name RoundMirror
extends RefCounted
## A round on the display nodes (Replica). A display node runs no round: it
## makes the same round type, with the master's data (GameRound.replica_init)
## and fields (fields(), sent on change; GameRound.replica_live, every frame),
## and its views read those as on the master.

## The fields every round's views read; a round type adds its own (GameRound.replica_keys).
const BASE := ["title", "rules", "mode", "on_tile", "players", "points", "duration", "progress_label", "ranked"]


## The master: the round's fields as plain data.
static func fields(r: GameRound) -> Dictionary:
	var d := {}
	for k in BASE + r.replica_keys:
		if k in r:
			d[k] = RoundState.pack(r.get(k)) if r.state_fields.has(k) else r.get(k)
	return d


## A display node: the master's fields (also its replica_init and replica_live).
static func apply(r: GameRound, d: Dictionary) -> void:
	for k in d:
		if not (k in r):
			continue
		var cur = r.get(k)
		if r.state_fields.has(k):
			RoundState.unpack(cur, d[k], r.state_fields[k])
		elif cur is Array and (cur as Array).is_typed():
			(cur as Array).assign(d[k])
		else:
			r.set(k, d[k])
