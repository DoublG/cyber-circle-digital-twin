class_name QuizAnswerCard
extends PanelContainer
## One answer on the quiz screen: the icon's key (solid, like the lit icon on
## the tile's glass) and the answer's text. It takes the colours of its button
## (CyberTile.BUTTON_COLORS: one place for the 4 colours).

@export var button: StringName = &"Square"

@onready var answer: Label = %Answer          # (QuizView sets the text and fits the font)


func _ready() -> void:
	var col: Color = CyberTile.BUTTON_COLORS[button]
	add_theme_stylebox_override("panel", Retro.panel(col.darkened(0.82), col, 4, 18, 10))
	var key: PanelContainer = %Key
	key.add_theme_stylebox_override("panel", Retro.panel(col, col.lightened(0.4), 3, 14, 6))
	var icon: ButtonIcon = %Icon
	icon.button = button
	var tag: Label = %Tag
	tag.text = Retro.BUTTON_NAMES[button]
	tag.add_theme_color_override("font_color", col)
