class_name MessageView
extends Control
## Full-screen message on all screens: round intro with rules and countdown.

var _title: Label
var _body: Label
var _footer: Label


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(Retro.background())
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 80
	box.offset_right = -80
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 40)
	add_child(box)
	_title = Retro.label(120, Retro.AMBER)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 30)
	bar.add_child(Retro.stripes(true))
	bar.add_child(_title)
	bar.add_child(Retro.stripes(false))
	box.add_child(bar)
	var plate := Retro.panel_container(Retro.PANEL, Retro.TEAL, 4, 30, 50)
	box.add_child(plate)
	_body = Retro.label(50, Retro.CREAM)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plate.add_child(_body)
	_footer = Retro.label(64, Retro.TEAL)
	box.add_child(_footer)


func show_message(title: String, body: String, footer := "") -> void:
	_title.text = title.to_upper()
	_body.text = body
	_footer.text = footer.to_upper()
