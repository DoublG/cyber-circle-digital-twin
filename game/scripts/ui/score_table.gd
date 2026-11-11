class_name ScoreTable
extends Control
## The table under the title of the scoreboard / UITSLAG (score_table.tscn):
## one column of rows, or two side by side from TWO_COLUMNS rows on (mobile
## tiles: more players than tiles; the first half left). Too tall for its
## room: scaled down as a whole, centred.

const TWO_COLUMNS := 17

var font_size := 44
var gap := 30                    # between the cells of a row (tighter in two columns)
var _count := 0


func _ready() -> void:
	resized.connect(_fit)
	%Columns.minimum_size_changed.connect(_fit)


## An empty table for `count` rows.
func setup(count: int) -> void:
	_count = count
	font_size = 44 if count <= 8 else 30
	gap = 30 if count < TWO_COLUMNS else 16
	%Right.visible = count >= TWO_COLUMNS
	for column: VBoxContainer in %Columns.get_children():
		column.add_theme_constant_override("separation", 10 if count <= 8 else 5)
		for row in column.get_children():
			column.remove_child(row)
			row.queue_free()


func new_row(scene: PackedScene, color: Color, texts: Array, style: StyleBox = null) -> ScoreRow:
	var row: ScoreRow = scene.instantiate()
	row.fill(font_size, gap, color, texts, style)
	return row


## The same header row on top of every column.
func add_header(scene: PackedScene, texts: Array) -> void:
	for column in _columns():
		column.add_child(new_row(scene, Retro.DIM, texts))


## Row i of the rows the table was set up for.
func add_row(i: int, row: ScoreRow) -> void:
	var columns := _columns()
	columns[i / ceili(float(_count) / columns.size())].add_child(row)


func _columns() -> Array:
	return %Columns.get_children().filter(func(c: Control) -> bool: return c.visible)


func _fit() -> void:
	var columns: HBoxContainer = %Columns
	var need := columns.get_combined_minimum_size().y
	var k := minf(1.0, size.y / need) if need > 0.0 else 1.0
	columns.scale = Vector2(k, k)
	columns.size = Vector2(size.x / k, need)
	columns.position = Vector2(0, floorf(maxf(size.y - need * k, 0.0) / 2.0))
