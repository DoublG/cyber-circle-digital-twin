class_name MessageView
extends Control
## Full-screen message on all screens: round intro with rules and countdown.

const SCENE := "res://scenes/ui/message_view.tscn"

@onready var _title: Label = %Title
@onready var _body: Label = %Body
@onready var _footer: Label = %Footer


static func create() -> MessageView:
	return load(SCENE).instantiate()


func show_message(title: String, body: String, footer := "") -> void:
	_title.text = title.to_upper()
	_body.text = body
	_footer.text = footer.to_upper()
