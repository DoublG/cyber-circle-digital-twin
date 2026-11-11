class_name ScoreRow
extends PanelContainer
## One row of the scoreboard / UITSLAG table (scoreboard_row.tscn,
## ranking_row.tscn): a plate with its cells side by side - 0 the place, 1 the
## name (takes the rest), 2 the tile, ... The cells have fixed widths, so the
## columns line up without a grid.

const NAME_PAD := "  "            # every name starts with this room: "▶ " on this screen's players (mark_own)
const CHAR_WIDTH := 0.62         # of the font size: the room one character takes

## Per cell, in characters; 0 = takes the rest.
@export var widths: PackedInt32Array


## sign: "+" (green) after a gained heart, "-" (red) after a lost one; without
## it the same room stays empty, so the hearts of every row line up.
static func hearts(bbcode: String, sign := "") -> String:
	var col: String = {"+": Retro.GOOD.to_html(false), "-": Retro.BAD.to_html(false)}.get(sign, "00000000")
	return "[right]%s[color=#%s]%s[/color][/right]" % [bbcode, col, sign if sign != "" else "+"]


func cell(k: int) -> Control:
	return get_child(0).get_child(k)


## The row's texts in one size and colour on a plate (none: the header row).
func fill(font_size: int, gap: int, color: Color, texts: Array, style: StyleBox = null) -> void:
	add_theme_stylebox_override("panel", style if style else StyleBoxEmpty.new())
	get_child(0).add_theme_constant_override("separation", gap)
	for k in texts.size():
		var c := cell(k)
		if c is RichTextLabel:                # the hearts: more than one colour (the new one green)
			c.add_theme_font_size_override("normal_font_size", font_size)
			c.text = hearts(texts[k])
		else:
			c.add_theme_font_size_override("font_size", font_size)
			c.text = texts[k]
		tint(k, color)
		if widths[k] > 0:
			c.custom_minimum_size.x = widths[k] * font_size * CHAR_WIDTH


func tint(k: int, color: Color) -> void:
	var c := cell(k)
	c.add_theme_color_override("default_color" if c is RichTextLabel else "font_color", color)


## The players at the tiles in front of this screen (ScreenWall: the tiles
## this screen shows) find their row at once: a thick teal frame with a bar
## on the left, ▶ before their name, their tile number in teal.
func mark_own() -> void:
	var style := get_theme_stylebox("panel") as StyleBoxFlat
	style = style.duplicate() if style else Retro.panel(Retro.PANEL, Retro.TEAL, 2, 14, 20)
	style.border_color = Retro.TEAL
	style.set_border_width_all(5)
	style.border_width_left = 18
	add_theme_stylebox_override("panel", style)
	var name_label := cell(1) as Label
	if not name_label.text.begins_with("▶"):        # (into the room every name keeps for it: the names line up)
		name_label.text = "▶ " + name_label.text.trim_prefix(NAME_PAD)
	if style.bg_color.v < 0.5:                     # (not on the 1st place's amber: unreadable)
		tint(2, Retro.TEAL)
