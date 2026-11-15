class_name AgeFit
extends RefCounted
## How well something (a round type, a question) suits the players' ages: its
## age range (min_age .. max_age) against the ages of the players there are.
## The randomizer and the question picker multiply their weights by it, so
## what suits the players comes more often - never never: just less.
##   fit       1 inside the range; outside it drops per year to LOWEST (at SPAN years)
##   group     the average over the players whose age is known (none known: 1)
##   steer     how strongly: weight x group ^ steer (0 = off, 1 = as is, 2 = stronger)

const SPAN := 4.0           # years outside the range where the fit is lowest
const LOWEST := 0.15        # the fit far outside the range


## One player: 1 inside lo..hi, less the further outside (age <= 0: unknown, 1).
static func fit(age: int, lo: int, hi: int) -> float:
	if age <= 0:
		return 1.0
	var off := 0
	if age < lo:
		off = lo - age
	elif hi > 0 and age > hi:
		off = age - hi
	return lerpf(1.0, LOWEST, clampf(off / SPAN, 0.0, 1.0))


## All players (their ages, 0 = unknown): the average fit of those known.
static func group(ages: Array, lo: int, hi: int) -> float:
	var known := ages.filter(func(a): return a > 0)
	if known.is_empty():
		return 1.0
	return known.map(func(a): return fit(a, lo, hi)).reduce(func(a, b): return a + b, 0.0) / known.size()


## The factor for a weight: group ^ steer.
static func factor(ages: Array, lo: int, hi: int, steer: float) -> float:
	if steer <= 0.0:
		return 1.0
	return pow(group(ages, lo, hi), steer)
