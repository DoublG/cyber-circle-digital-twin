class_name Texts
## The texts the operator can change (web interface › Teksten), over the
## defaults in the code: the calls to action (rotating slogans), how to join
## (the overview's steps), the line on a free tile, and per game its name and
## rules. They come over MQTT (<prefix>/texts, retained) or --texts=FILE;
## values {} = every default. An empty or missing text: the default.
##   cta          the slogans, one per line
##   join_steps   "HOE DOE JE MEE?" on the overview
##   join_text    on the screen of a free tile
##   title.<type> / rules.<type>   a game (type: quiz, cyclone, reaction,
##                rhythm, simon, zwarte_piet, code); the default rules include the
##                current settings (points, times) - a changed text does not

const JOIN_STEPS := ("1. Haal een QR-codekaart.\n"
	+ "2. Registreer je met je gsm.\n"
	+ "3. Ga naar een gamemaster: die laat je toe tot het spel.\n"
	+ "4. Zoek de tegel in jouw kleur en druk op de 4 iconen.\n"
	+ "5. Blijf zo lang mogelijk in het spel!")
const JOIN_TEXT := "HAAL EEN QR-KAART EN MELD JE BIJ DE GAMEMASTER"

static var values := {}
static var version := 0           # +1 on every change (the screens notice it)


static func apply(new_values: Dictionary) -> void:
	values = {}
	for k in new_values:
		if new_values[k] is String and str(new_values[k]).strip_edges() != "":
			values[k] = str(new_values[k])
	version += 1


static func text(key: String, fallback: String) -> String:
	return values.get(key, fallback)


static func calls() -> Array:
	var lines := Array(text("cta", "").split("\n")).map(func(l): return l.strip_edges()).filter(func(l): return l != "")
	return lines if not lines.is_empty() else Retro.CALLS_TO_ACTION


static func join_steps() -> String:
	return text("join_steps", JOIN_STEPS)


static func join_text() -> String:
	return text("join_text", JOIN_TEXT)


## A round's name and rules with the operator's texts.
static func dress(round: GameRound, type: String) -> void:
	round.title = text("title." + type, round.title)
	round.rules = text("rules." + type, round.rules)


## The defaults (for the web interface: shown when a text is empty).
static func defaults(game: GameManager) -> Dictionary:
	var out := {"cta": "\n".join(Retro.CALLS_TO_ACTION), "join_steps": JOIN_STEPS, "join_text": JOIN_TEXT}
	for t in RoundPicker.ROUND_TYPES:
		var r: GameRound = t.new()
		r.prepare(game, [])
		var type := RoundPicker.type_name(t)
		out["title." + type] = r.title
		out["rules." + type] = r.rules
	return out
