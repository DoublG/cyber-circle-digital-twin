class_name ScoreboardView
extends Control
## The game's standing on all screens after every round (after this round's
## places: RankingView): the players in the game by rounds survived, with
## lives, their record (most rounds survived ever) and overall place.
## rows: [{name, tile, survived, lives, out, record, rank}] sorted best first;
## with this round's lives change also {lives_before, change, was_out}: the
## rows first show the lives as they were, reveal_lives() shows the change
## (+1 green, -1 red, 0 lives: GEËXTERMINEERD).

const SCENE := "res://scenes/ui/scoreboard_view.tscn"
const ROW := preload("res://scenes/ui/scoreboard_row.tscn")
const LIVES_CELL := 3
const LIVES := Color(1.0, 0.2, 0.3)

var _rows := []                  # [{data, panel, name, lives}]
var _banner_tweens: Array[Tween] = []


static func create() -> ScoreboardView:
	return load(SCENE).instantiate()


## (Also before the view is in the tree; again after a change, e.g. a player joined.)
func show_scores(title: String, subtitle: String, rows: Array, revealed := true) -> void:
	_rows.clear()
	_hide_banner()
	%Title.text = title.to_upper()
	%Subtitle.text = subtitle.to_upper()
	%Subtitle.visible = subtitle != ""
	var table: ScoreTable = %Table
	table.setup(rows.size())                      # (any number: mobile tiles too)
	table.add_header(ROW, ["#", ScoreRow.NAME_PAD + "SPELER", "TEGEL", "LEVENS", "RONDES", "RECORD", "PLAATS"])
	for i in rows.size():
		var r: Dictionary = rows[i]
		var out: bool = r.out if revealed else r.get("was_out", r.out)
		var is_new: bool = r.get("new", false)
		var lives: int = r.get("lives", 0) if revealed else r.get("lives_before", r.get("lives", 0))
		var cells := ["+" if is_new else "%02d" % (i + 1),
			ScoreRow.NAME_PAD + r.name.to_upper() + ("  [UIT]" if out else ("  NIEUW!" if is_new else "")),
			Retro.tile_label(r.tile), "♥".repeat(lives), str(r.get("survived", 0)),
			str(r.get("record", 0)), "#%d" % r.rank if r.get("rank", 0) > 0 else "-"]
		var col := Retro.BG if i == 0 else (Retro.DIM if out else Retro.CREAM)
		var row := table.new_row(ROW, col, cells, _plate(i == 0, out, is_new))
		if i != 0 and not r.out:  # colour the lives, rounds and place
			row.tint(LIVES_CELL, LIVES)
			row.tint(4, Retro.AMBER)
			row.tint(6, Retro.TEAL)
		table.add_row(i, row)
		_rows.append({"data": r, "panel": row, "name": row.cell(1), "lives": row.cell(LIVES_CELL)})
		if revealed and r.get("out") and not r.get("was_out", true):
			_mark_exterminated(_rows.back())
		if is_new:                                 # welcome: slides in, teal glow
			row.tint(1, Retro.TEAL)
			row.modulate.a = 0.0
			var tw := row.create_tween()
			tw.tween_property(row, "modulate:a", 1.0, 0.6)
			tw.tween_property(row, "modulate", Color(1.4, 1.4, 1.4), 0.3)
			tw.tween_property(row, "modulate", Color.WHITE, 0.4)
	if revealed:
		_banner_if_exterminated()


## A row's plate: the leader's amber, grey when out, teal for a new player.
func _plate(leader: bool, out: bool, is_new: bool) -> StyleBoxFlat:
	if is_new:
		return Retro.panel(Color(0.02, 0.16, 0.15), Retro.TEAL, 3, 14, 20)
	if leader:
		return Retro.panel(Retro.AMBER, Retro.CREAM, 3, 14, 20)
	if out:
		return Retro.panel(Color(0.06, 0.06, 0.06), Color(0.2, 0.2, 0.2), 2, 14, 20)
	return Retro.panel(Retro.PANEL, Retro.ORANGE.darkened(0.35), 2, 14, 20)


## (rebuilt after the change, e.g. a player joined: the banner again)
func _banner_if_exterminated() -> void:
	var names := _rows.filter(func(e): return e.data.out and not e.data.get("was_out", true)) \
		.map(func(e): return e.data.name.to_upper())
	if not names.is_empty():
		_exterminate_banner(names)


## The lives change: hearts +1 (green) / -1 (red), 0 lives: GEËXTERMINEERD
## (the row turns red and blinks, a big banner over the board, a red flash).
func reveal_lives() -> void:
	var doomed := []
	for e in _rows:
		if e.data.get("change", 0) < 0 and e.data.lives == 0 and not e.data.get("was_out", false):
			doomed.append(e.data.name.to_upper())
	if not doomed.is_empty():
		_exterminate_banner(doomed)
	for e in _rows:
		var r: Dictionary = e.data
		var d: int = r.get("change", 0)
		if d == 0 or r.get("was_out", false):
			continue
		var lives: RichTextLabel = e.lives
		if d > 0:                                  # the hearts they had stay, only the new one (and the +) green
			var had: int = r.get("lives_before", r.lives - d)
			lives.text = ScoreRow.hearts("♥".repeat(had) + "[color=#%s]%s[/color]"
				% [Retro.GOOD.to_html(false), "♥".repeat(r.lives - had)], "+")
		else:                                      # the hearts left stay, the lost one greyed out, then "-"
			var had: int = r.get("lives_before", r.lives - d)
			lives.text = ScoreRow.hearts("♥".repeat(r.lives) + "[color=#%s]%s[/color]" % [Retro.DIM.to_html(false),
				"♥".repeat(maxi(had - r.lives, 0))], "-")
		var tw := lives.create_tween()
		lives.pivot_offset = lives.size / 2.0
		tw.tween_property(lives, "scale", Vector2(1.5, 1.5), 0.15)
		tw.tween_property(lives, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)
		if r.lives == 0:
			_mark_exterminated(e)


## The whole board flashes red; the banner takes the place of the title
## (never over the rows).
func _exterminate_banner(names: Array) -> void:
	_hide_banner()
	var flash: ColorRect = %Flash
	flash.color.a = 0.55
	flash.visible = true
	var ft := flash.create_tween()
	ft.tween_property(flash, "color:a", 0.0, 0.6)
	ft.tween_callback(flash.hide)
	%Who.text = "  ·  ".join(names)
	%Titles.visible = false                        # the title steps aside
	var banner: PanelContainer = %Banner
	var header: Control = %Header
	banner.visible = true
	banner.pivot_offset = header.size / 2.0 - Vector2(header.size.x * 0.04, 0)
	banner.scale = Vector2(1.12, 1.12)
	banner.modulate.a = 0.0
	var tw := banner.create_tween()
	tw.tween_property(banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(banner, "modulate:a", 1.0, 0.2)
	var pulse := banner.create_tween().set_loops()
	pulse.tween_property(banner, "self_modulate", Color(1.5, 0.6, 0.6), 0.3)
	pulse.tween_property(banner, "self_modulate", Color.WHITE, 0.3)
	_banner_tweens = [ft, tw, pulse]


func _hide_banner() -> void:
	for tw in _banner_tweens:
		tw.kill()
	_banner_tweens.clear()
	%Flash.visible = false
	%Banner.visible = false
	%Banner.self_modulate = Color.WHITE
	%Titles.visible = true


func _mark_exterminated(e: Dictionary) -> void:
	# (keeps ▶; the banner says GEËXTERMINEERD)
	e.name.text = e.name.text.left(ScoreRow.NAME_PAD.length()) + "☠ %s ☠" % e.data.name.to_upper()
	e.name.add_theme_color_override("font_color", Retro.BG)
	e.lives.text = ScoreRow.hearts("-")
	e.panel.add_theme_stylebox_override("panel", Retro.panel(Retro.BAD, Retro.CREAM, 3, 14, 20))
	var tw: Tween = e.panel.create_tween().set_loops(4)
	tw.tween_property(e.panel, "modulate:a", 0.35, 0.18)
	tw.tween_property(e.panel, "modulate:a", 1.0, 0.18)


## The players at the tiles in front of this screen find their row at once
## (ScoreRow.mark_own). The order stays the ranking.
func highlight_tiles(tiles: Array) -> void:
	for e in _rows:
		if e.data.tile in tiles:
			e.panel.mark_own()
