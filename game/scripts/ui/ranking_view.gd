class_name RankingView
extends Control
## UITSLAG: shown on all screens at the end of a round with places, before the
## scoreboard. This round's places (1, 2, 3 ..., shared when equal), what
## decided them (points, level, ...) and the life each player will gain or
## lose there: +♥ green, -♥ red, ☠ the last life (exterminated on the
## scoreboard). The rows come in from the last place up to the 1st (gold),
## then the lives badges stamp in.
## rows: [{name, tile, place, score, change (-1 / 0 / +1), doomed}] best first.

const ROWS_TIME := 2.4           # s: all rows in, last place first
const BADGE_DELAY := 0.4         # s after the rows: the lives badges

const SCENE := "res://scenes/ui/ranking_view.tscn"
const ROW := preload("res://scenes/ui/ranking_row.tscn")
const BADGE_CELL := 4

var _badges: Array[Label] = []
var _row_panels := []              # [{tile, panel}]


static func create() -> RankingView:
	return load(SCENE).instantiate()


## The players at this screen's tiles: their row marked (ScoreRow.mark_own).
func highlight_tiles(tiles: Array) -> void:
	for e in _row_panels:
		if e.tile in tiles:
			e.panel.mark_own()


## (Also before the view is in the tree.)
func show_ranking(title: String, label: String, rows: Array) -> void:
	_row_panels.clear()
	_badges.clear()
	%Subtitle.text = title.to_upper()
	var n := rows.size()                          # (any number: mobile tiles too)
	var table: ScoreTable = %Table
	table.setup(n)
	table.add_header(ROW, ["#", ScoreRow.NAME_PAD + "SPELER", "TEGEL", label, "LEVEN"])
	var ranked := rows.any(func(r): return r.place > 1)   # (all equal: nobody in gold)
	var step := ROWS_TIME / maxf(n, 1)
	for i in n:
		var r: Dictionary = rows[i]
		var first: bool = ranked and r.place == 1
		var style := Retro.panel(Retro.AMBER, Retro.CREAM, 3, 14, 20) if first \
			else Retro.panel(Retro.PANEL, Retro.ORANGE.darkened(0.35), 2, 14, 20)
		var row := table.new_row(ROW, Retro.BG if first else Retro.CREAM, [str(r.place),
			ScoreRow.NAME_PAD + r.name.to_upper(), Retro.tile_label(r.tile), str(r.score), _badge_text(r)], style)
		if not first:
			row.tint(3, Retro.AMBER)
		row.tint(BADGE_CELL, Retro.GOOD if r.change > 0 else (Retro.BAD if r.change < 0 else Retro.DIM))
		if first and r.change > 0:
			row.tint(BADGE_CELL, Retro.BG)
		var badge: Label = row.cell(BADGE_CELL)
		badge.modulate.a = 0.0
		_badges.append(badge)
		table.add_row(i, row)
		_row_panels.append({"tile": r.tile, "panel": row})
		row.modulate.a = 0.0                       # in from the last place up to the 1st
		var tw := row.create_tween()
		tw.tween_interval(step * (n - 1 - i))
		tw.tween_property(row, "modulate:a", 1.0, 0.25)
		if first:
			tw.tween_property(row, "modulate", Color(1.4, 1.4, 1.4), 0.15)
			tw.tween_property(row, "modulate", Color.WHITE, 0.3)
	for i in _badges.size():                       # then the lives: stamped in
		var b := _badges[i]
		var tw := b.create_tween()
		tw.tween_interval(ROWS_TIME + BADGE_DELAY + 0.08 * i)
		tw.tween_callback(func():
			b.pivot_offset = b.size / 2.0
			b.scale = Vector2(2.2, 2.2))
		tw.tween_property(b, "modulate:a", 1.0, 0.12)
		tw.parallel().tween_property(b, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		if rows[i].doomed:                         # the last life: blinks
			var blink := b.create_tween().set_loops()
			blink.tween_interval(ROWS_TIME + BADGE_DELAY + 0.5)
			blink.tween_property(b, "modulate:a", 0.3, 0.25)
			blink.tween_property(b, "modulate:a", 1.0, 0.25)


func _badge_text(r: Dictionary) -> String:
	if r.change > 0:
		return "+♥"
	if r.change < 0:
		return "-♥ ☠" if r.doomed else "-♥"
	return ""
