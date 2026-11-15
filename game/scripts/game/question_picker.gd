class_name QuestionPicker
extends RefCounted
## The quiz's questions (GameManager.questions): where they come from and
## which category is asked next - the same style as the round randomizer:
## a weight per category (missing = 1, 0 = never) and an extra chance per
## question a category was not asked. Remembers what was asked over all quiz
## rounds, so a question only comes back when nothing new is left.
## The players' ages steer it too (AgeFit, `age_steer`; 0 = off): a question
## whose min_age .. max_age suits them comes more often, and so does a
## category with such questions.

var game: GameManager
var category_weights := {}
var category_drought := 0.5
var age_steer := 1.0
## What was asked (over all quiz rounds): {count: questions asked, since:
## {category: questions since it was last asked}, asked: {question id: count when}}.
var memory := {"count": 0, "since": {}, "asked": {}}


func _init(game_node: GameManager) -> void:
	game = game_node


## All questions: from the database (or control server), else the JSON file.
func all() -> Array:
	var list: Array = game.db.questions() if game.db else []
	if list.is_empty():
		var data = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
		list = data if data is Array else []
	return list


## The chance of each category for the next question (the categories in `pool`):
## its weight x (1 + category_drought x questions since it was last asked;
## never asked: as long as there have been questions, max 10); a category
## whose questions were all asked is skipped while other ones have new ones
## (repeats only when nothing new is left); x the average age fit of its
## questions that can come (the new ones, else all) for `ages`.
## {category: chance}.
func category_chances(pool: Array, ages := []) -> Dictionary:
	var w := {}
	var fresh := {}                                 # category -> it still has unasked questions
	var fits := {}                                  # category -> [age fit of its new questions, of all]
	for q in pool:
		var c := str(q.get("category", ""))
		var is_new: bool = not memory.asked.has(str(q.get("id", q.get("question", ""))))
		if is_new:
			fresh[c] = true
		var f := age_factor(q, ages)
		if not fits.has(c):
			fits[c] = [[], []]
		fits[c][1].append(f)
		if is_new:
			fits[c][0].append(f)
		if w.has(c):
			continue
		var since: int = memory.since.get(c, mini(memory.count + 1, 10))
		w[c] = float(category_weights.get(c, 1.0)) * (1.0 + category_drought * mini(since, 10))
	for c in w:
		var f: Array = fits[c][0] if not fits[c][0].is_empty() else fits[c][1]
		w[c] *= f.reduce(func(a, b): return a + b, 0.0) / f.size()
	if not fresh.is_empty():
		for c in w:
			if not fresh.has(c):
				w[c] = 0.0                          # every question asked already: not while others have new ones
	var total: float = w.values().reduce(func(a, b): return a + b, 0.0)
	if total <= 0.0:
		return {}                                   # every category weight 0
	for c in w.keys():
		if w[c] <= 0.0:
			w.erase(c)
		else:
			w[c] /= total
	return w


## x weight of one question from how well its min_age .. max_age suits `ages`.
func age_factor(q: Dictionary, ages: Array) -> float:
	return AgeFit.factor(ages, int(q.get("min_age", 0)), int(q.get("max_age", 99)), age_steer)


## One of these questions (from one category), weighted by their age fit:
## only those asked longest ago (never asked first) can come.
func pick_question(qs: Array, ages: Array) -> Dictionary:
	var when := func(q): return int(memory.asked.get(str(q.get("id", q.get("question", ""))), -1))
	var oldest: int = qs.map(when).min()
	var can := qs.filter(func(q): return when.call(q) == oldest)
	var total := 0.0
	for q in can:
		total += age_factor(q, ages)
	var r := randf() * total
	for q in can:
		r -= age_factor(q, ages)
		if r <= 0.0:
			return q
	return can.back()


## A question was asked (for the drought protection and no early repeats).
func note(category: String, id: String) -> void:
	memory.count += 1
	for c in memory.since:
		memory.since[c] += 1
	memory.since[category] = 0
	memory.asked[id] = memory.count


# ---------------------------------------------------------------- settings (GameSettings, "Vragen")

## The drought, and a weight for each category of the questions there are now.
func tunables() -> Array:
	var items := [GameRound.setting("category_drought",
		"Extra kans per vraag categorie niet gevraagd (x gewicht)", 0, 3, 0.1),
		GameRound.setting("age_steer", "Sturing door leeftijd (0 = uit)", 0, 3, 0.1)]
	var cats := {}
	for q in all():
		cats[str(q.get("category", ""))] = true
	var names := cats.keys()
	names.sort()
	for c in names:
		items.append(GameRound.setting("cat:" + c, "Gewicht " + (c if c != "" else "(geen categorie)"), 0, 10, 0.5))
	return items


func get_setting(key: String) -> Variant:
	if key.begins_with("cat:"):
		return float(category_weights.get(key.trim_prefix("cat:"), 1.0))
	return get(key)


func set_setting(key: String, value: Variant) -> void:
	if key.begins_with("cat:"):
		category_weights[key.trim_prefix("cat:")] = float(value)
	else:
		set(key, float(value))
