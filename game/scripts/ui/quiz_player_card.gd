class_name QuizPlayerCard
extends PanelContainer
## A player's card on the quiz's players slide: the name and the icon they
## chose. In the reveal the card's frame shows the result (no ✔ / ✘): right =
## thick glowing green border; wrong = thin red border, the card dimmed; wrong
## but shielded (question above their age) = blue, with the shield badge.

const SCENE := "res://scenes/ui/quiz_player_card.tscn"

@onready var name_label: Label = %NameLabel
@onready var icon: ButtonIcon = %Icon
@onready var shield: ShieldIcon = %Shield
@onready var mark: Label = %Mark              # "GEEN": no answer


static func create() -> QuizPlayerCard:
	return load(SCENE).instantiate()


## p: the player's state (QuizView.show_question); revealed: the card shows
## right / wrong (its turn in the reveal has come).
func show_player(p: Dictionary, revealed: bool) -> void:
	name_label.text = "%02d %s" % [p.id, p.name.to_upper()]
	var answered: bool = p.answer >= 0
	var col: Color = CyberTile.BUTTON_COLORS[QuizRound.ANSWER_BUTTONS[p.answer]] if answered else Retro.DIM
	icon.visible = answered
	if answered:
		icon.button = QuizRound.ANSWER_BUTTONS[p.answer]
		icon.color = col
	mark.visible = not answered
	var wrong: bool = revealed and p.ok != true
	shield.visible = wrong and p.protected
	modulate = Color(1, 1, 1, 0.5) if wrong and not p.protected else Color.WHITE
	if not revealed:
		_frame(col.darkened(0.7), col, 5, 0.0)
	elif not wrong:                               # right: thick bright border, glowing
		_frame(Retro.GOOD.darkened(0.45), Retro.GOOD, 12, 0.7)
	elif p.protected:                             # wrong but shielded: blue, keeps its life
		_frame(Retro.SHIELD.darkened(0.6), Retro.SHIELD, 9, 0.4)
	else:                                         # wrong: thin red border, the card dimmed
		_frame(Retro.BAD.darkened(0.75), Retro.BAD, 4, 0.0)


## The card's frame: a border wider than the usual 5 grows outwards (the card's
## content and size stay put), glow > 0: a halo in the border's colour.
func _frame(fill: Color, border: Color, width: int, glow: float) -> void:
	var st := Retro.panel(fill, border, width, 20, 22)
	var out := maxf(width - 5, 0.0)
	st.expand_margin_left = out
	st.expand_margin_right = out
	st.expand_margin_top = out
	st.expand_margin_bottom = out
	if glow > 0.0:
		st.shadow_color = Color(border, glow)
		st.shadow_size = 26
	add_theme_stylebox_override("panel", st)
