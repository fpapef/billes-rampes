extends RefCounted
## Données du jeu : géométrie des pièces, points d'aimantation et niveaux.
## Chaque pièce est une liste de boîtes ; la même liste sert au visuel et aux collisions.

const T := 0.015          # épaisseur du fond
const RH := 0.035         # hauteur des rebords
const RT := 0.008         # épaisseur des rebords
const CW := 0.07          # largeur intérieure du canal
const MR := 0.018         # rayon des billes

const START_H := 0.14
const START_IN := 0.05
const START_GAP := 0.058
const GOAL_IN := 0.14
const GOAL_H := 0.07

const SLOT_TYPES := ["ramp", "long", "turn", "kicker", "funnel", "tramp", "start", "goal"]


static func box(s: Vector3, p: Vector3, c := "a", q := Quaternion.IDENTITY) -> Dictionary:
	return {"s": s, "p": p, "c": c, "q": q}


static func channel(length: float, cx := 0.0, cy := 0.0, rot_z := 0.0) -> Array:
	var q := Quaternion(Vector3(0, 0, 1), rot_z)
	var parts := [
		box(Vector3(length, T, CW), Vector3(0, -T / 2, 0), "a"),
		box(Vector3(length, RH, RT), Vector3(0, RH / 2 - T, CW / 2 + RT / 2), "b"),
		box(Vector3(length, RH, RT), Vector3(0, RH / 2 - T, -(CW / 2 + RT / 2)), "b"),
	]
	for b in parts:
		b.p = q * b.p + Vector3(cx, cy, 0)
		b.q = q
	return parts


static func turn_boxes() -> Array:
	var s := 0.11
	# Fond légèrement incliné vers la sortie (+Z) : la contrainte « sans roulis » empêche de le pencher à la main
	var tilt := Quaternion(Vector3(1, 0, 0), deg_to_rad(8))
	return [
		box(Vector3(s, T, s), Vector3(0, -T / 2, 0), "a", tilt),
		box(Vector3(RT, RH, s + 2 * RT), Vector3(s / 2 + RT / 2, RH / 2 - T, 0), "b"),
		box(Vector3(s, RH, RT), Vector3(0, RH / 2 - T, -(s / 2 + RT / 2)), "b"),
		box(Vector3(0.07, RH, RT), Vector3(s / 2 - 0.025, RH / 2 - T, -s / 2 + 0.025), "b", Quaternion(Vector3.UP, deg_to_rad(-45))),
	]


static func kicker_boxes() -> Array:
	var a := deg_to_rad(25)
	var l2 := 0.09
	return channel(0.2, -0.1) + channel(l2, cos(a) * l2 / 2, sin(a) * l2 / 2, a)


static func funnel_boxes() -> Array:
	var r1 := 0.13
	var r0 := 0.032
	var h := 0.1
	var n := 16
	var width := 2 * r1 * tan(PI / n) * 1.05
	var slant := Vector2(r1 - r0, h).length()
	var out := []
	for i in n:
		var ang := float(i) / n * TAU
		var r := Vector3(cos(ang), 0, sin(ang))
		var t := Vector3(-sin(ang), 0, cos(ang))
		var s := (r * (r1 - r0) + Vector3.UP * h).normalized()
		var basis := Basis(t, s, t.cross(s))
		var p := r * (r1 + r0) / 2 + Vector3.UP * h / 2
		out.append(box(Vector3(width, slant, 0.006), p, "b" if i % 2 == 0 else "a", basis.get_rotation_quaternion()))
	return out


static func tramp_boxes() -> Array:
	var s := 0.15
	var f := 0.012
	return [
		box(Vector3(s, 0.02, s), Vector3(0, -0.01, 0), "a"),
		box(Vector3(s + 2 * f, f, f), Vector3(0, 0.002, s / 2 + f / 2), "b"),
		box(Vector3(s + 2 * f, f, f), Vector3(0, 0.002, -(s / 2 + f / 2)), "b"),
		box(Vector3(f, f, s), Vector3(s / 2 + f / 2, 0.002, 0), "b"),
		box(Vector3(f, f, s), Vector3(-(s / 2 + f / 2), 0.002, 0), "b"),
	]


static func start_boxes() -> Array:
	var h2 := START_IN / 2
	return [
		box(Vector3(RT, START_H, START_IN + 2 * RT), Vector3(-(h2 + RT / 2), START_H / 2, 0), "a"),
		box(Vector3(START_IN + 2 * RT, START_H, RT), Vector3(0, START_H / 2, h2 + RT / 2), "a"),
		box(Vector3(START_IN + 2 * RT, START_H, RT), Vector3(0, START_H / 2, -(h2 + RT / 2)), "a"),
		box(Vector3(RT, START_H - START_GAP, START_IN + 2 * RT), Vector3(h2 + RT / 2, START_GAP + (START_H - START_GAP) / 2, 0), "a"),
		box(Vector3(0.075, T, START_IN), Vector3(0.005, 0.016, 0), "b", Quaternion(Vector3(0, 0, 1), deg_to_rad(-25))),
	]


static func goal_boxes() -> Array:
	var g2 := GOAL_IN / 2
	return [
		box(Vector3(GOAL_IN + 2 * RT, T, GOAL_IN + 2 * RT), Vector3(0, -T / 2, 0), "b"),
		box(Vector3(RT, GOAL_H, GOAL_IN + 2 * RT), Vector3(g2 + RT / 2, GOAL_H / 2, 0), "a"),
		box(Vector3(RT, GOAL_H, GOAL_IN + 2 * RT), Vector3(-(g2 + RT / 2), GOAL_H / 2, 0), "a"),
		box(Vector3(GOAL_IN, GOAL_H, RT), Vector3(0, GOAL_H / 2, g2 + RT / 2), "a"),
		box(Vector3(GOAL_IN, GOAL_H, RT), Vector3(0, GOAL_H / 2, -(g2 + RT / 2)), "a"),
	]


# constraint : "level" = pas de roulis (les billes ne tombent pas sur le côté), "upright" = toujours debout
static func make_pieces() -> Dictionary:
	return {
		"ramp":   {"name": "Rampe",        "color": Color("#3a9bff"), "constraint": "level",   "pitch": -10.0, "boxes": channel(0.35)},
		"long":   {"name": "Rampe longue", "color": Color("#7c5cff"), "constraint": "level",   "pitch": -8.0,  "boxes": channel(0.6)},
		"turn":   {"name": "Virage",       "color": Color("#18c4a0"), "constraint": "level",   "pitch": -6.0,  "boxes": turn_boxes()},
		"kicker": {"name": "Tremplin",     "color": Color("#ff8a3d"), "constraint": "level",   "pitch": -15.0, "boxes": kicker_boxes()},
		"funnel": {"name": "Entonnoir",    "color": Color("#e0c341"), "constraint": "upright", "pitch": 0.0,   "boxes": funnel_boxes()},
		"tramp":  {"name": "Trampoline",   "color": Color("#ff4f8b"), "constraint": "level",   "pitch": 0.0,   "boxes": tramp_boxes(), "bouncy": true, "accent": Color("#2a2f3a")},
		"start":  {"name": "Départ",       "color": Color("#4cc35a"), "constraint": "upright", "pitch": 0.0,   "boxes": start_boxes(), "accent": Color("#dfe6ee")},
		"goal":   {"name": "Panier",       "color": Color("#f2b632"), "constraint": "upright", "pitch": 0.0,   "boxes": goal_boxes(), "metal": true, "accent": Color("#8a6418")},
		# Obstacle des niveaux, absent de la boîte à outils
		"wall":   {"name": "Mur",          "color": Color("#6b7385"), "constraint": "none",    "pitch": 0.0,   "boxes": [box(Vector3(0.02, 0.25, 0.25), Vector3(0, 0.125, 0))]},
	}


# Entrée/sortie de chaque pièce (repère local, sur le dessus du fond) et sens d'écoulement
const PORTS := {
	"ramp":   {"in": [Vector3(-0.175, 0, 0), Vector3(1, 0, 0)], "out": [Vector3(0.175, 0, 0), Vector3(1, 0, 0)]},
	"long":   {"in": [Vector3(-0.3, 0, 0), Vector3(1, 0, 0)], "out": [Vector3(0.3, 0, 0), Vector3(1, 0, 0)]},
	# La bille sort du virage en longeant le mur du fond : sortie décalée de ce côté
	"turn":   {"in": [Vector3(-0.055, 0, 0), Vector3(1, 0, 0)], "out": [Vector3(0.02, -0.008, 0.055), Vector3(0, 0, 1)]},
	"kicker": {"in": [Vector3(-0.2, 0, 0), Vector3(1, 0, 0)]},
	"start":  {"out": [Vector3(0.035, 0, 0), Vector3(1, 0, 0)]},
}


# Niveaux, dans le repère du circuit (posé sur la boîte à outils : X à droite, Y en haut, Z vers le joueur).
# fixed : pièces imposées [type, x, y, z, lacet°, inclinaison°] · inv : pièces disponibles
# stars : étoiles à faire traverser · solution : circuit qui réussit avec 3 étoiles (sert aux tests)
const LEVELS := [
	{
		"name": "Première descente",
		"fixed": [["start", 0.35, 0.30, -0.10], ["goal", 0.82, 0.05, -0.10]],
		"inv": {"ramp": 1},
		"stars": [[0.475, 0.27, -0.10], [0.65, 0.245, -0.10], [0.79, 0.175, -0.10]],
		"solution": [["ramp", 0.53, 0.24, -0.10, 0, -10]],
	},
	{
		"name": "Le virage",
		"fixed": [["start", 0.35, 0.35, -0.25], ["goal", 0.755, 0.0, 0.27]],
		"inv": {"ramp": 2, "turn": 1},
		"stars": [[0.49, 0.315, -0.25], [0.80, 0.25, -0.20], [0.76, 0.18, 0.04]],
		"solution": [["ramp", 0.53, 0.29, -0.25, 0, -10], ["turn", 0.765, 0.24, -0.25, 0, -6], ["ramp", 0.765, 0.17, -0.02, -90, -10]],
	},
	{
		"name": "L'entonnoir",
		"fixed": [["start", 0.35, 0.40, -0.15], ["goal", 0.83, -0.17, -0.15]],
		"inv": {"ramp": 1, "funnel": 1},
		"stars": [[0.54, 0.357, -0.15], [0.785, 0.274, -0.15], [0.825, 0.03, -0.15]],
		"solution": [["ramp", 0.53, 0.34, -0.15, 0, -10], ["funnel", 0.82, 0.05, -0.15]],
	},
	{
		"name": "Rebond",
		"fixed": [["start", 0.35, 0.40, -0.10], ["goal", 0.87, 0.0, -0.10]],
		"inv": {"tramp": 1},
		"stars": [[0.53, 0.07, -0.10], [0.69, 0.29, -0.10], [0.80, 0.235, -0.10]],
		"solution": [["tramp", 0.55, -0.15, -0.10, 0, 0]],
	},
	{
		"name": "Zigzag",
		"fixed": [["start", 0.50, 0.42, -0.30], ["goal", 0.38, -0.10, 0.20]],
		"inv": {"ramp": 3, "turn": 2, "funnel": 1},
		"stars": [[0.757, 0.37, -0.30], [0.945, 0.29, -0.16], [0.75, 0.155, 0.196]],
		"solution": [
			["ramp", 0.68, 0.36, -0.30, 0, -10], ["turn", 0.915, 0.31, -0.30, 0, -6], ["ramp", 0.915, 0.24, -0.07, -90, -10],
			["turn", 0.915, 0.18, 0.165, -90, -6], ["ramp", 0.68, 0.12, 0.19, 180, -10],
		],
	},
	{
		"name": "Le grand saut",
		"fixed": [["start", 0.0, 0.40, -0.35], ["wall", 0.75, -0.15, -0.35], ["goal", 0.87, 0.0, -0.35]],
		"inv": {"ramp": 1, "kicker": 1, "tramp": 1},
		"stars": [[0.26, 0.345, -0.35], [0.65, 0.255, -0.35], [0.80, 0.165, -0.35]],
		"solution": [["ramp", 0.18, 0.34, -0.35, 0, -10], ["kicker", 0.56, 0.22, -0.35, 0, -15]],
	},
	{
		"name": "Ricochet",
		"fixed": [["start", 0.55, 0.40, -0.30], ["goal", 0.60, 0.03, -0.30]],
		"inv": {"tramp": 1, "ramp": 1},
		"stars": [[0.651, 0.352, -0.30], [0.742, 0.096, -0.30], [0.67, 0.377, -0.30]],
		"solution": [["tramp", 0.75, -0.15, -0.30, 0, 9]],
	},
	{
		"name": "Cascade",
		"fixed": [["start", 0.30, 0.50, -0.30], ["goal", 0.80, -0.19, 0.23]],
		"inv": {"ramp": 2, "funnel": 1, "turn": 1, "tramp": 1},
		"stars": [[0.515, 0.452, -0.30], [0.767, 0.167, -0.30], [0.80, -0.023, 0.05]],
		"solution": [
			["ramp", 0.48, 0.44, -0.30, 0, -10], ["funnel", 0.76, 0.18, -0.30],
			["turn", 0.765, 0.05, -0.30, 0, -6], ["ramp", 0.785, -0.02, -0.07, -90, -10],
		],
	},
]
