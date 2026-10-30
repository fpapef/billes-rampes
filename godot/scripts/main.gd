extends Node3D
## Billes & Rampes — version native Meta Quest (Godot + OpenXR, passthrough).
## Sans casque, le jeu se lance en mode bureau (souris). Avec « -- --test-levels », il vérifie les niveaux et quitte.

const Defs = preload("res://scripts/defs.gd")
const Sfx = preload("res://scripts/sfx.gd")
const Toolbox = preload("res://scripts/toolbox.gd")

const LAYER_WORLD := 1
const LAYER_PIECES := 2
const LAYER_UI := 4

const SNAP_DIST := 0.07
const SNAP_ANGLE := 0.698     # 40°
const SNAP_DROP := 0.008      # la pièce suivante est un peu plus basse
const SNAP_OVERLAP := 0.012   # et passe un peu sous la précédente
const BIN_RADIUS := 0.16
const MAX_MARBLES := 80
const PHYS_DT := 1.0 / 120.0

const BUTTONS := {
	"free": [
		[["marble", "Lâcher une bille", "#2f7de1"]],
		[["rain", "Pluie de billes", "#7a4ce0"]],
		[["mode", "Mode : Libre", "#c9741c"]],
		[["undo", "Annuler", "#4f5970"]],
		[["clear", "Tout effacer", "#b8413a"]],
	],
	"challenge": [
		[["launch", "Lancer !", "#2f9e44"]],
		[["retry", "Recommencer", "#4f5970"]],
		[["prev", "‹ Préc.", "#3b4a66"], ["next", "Suiv. ›", "#3b4a66"]],
		[["mode", "Mode : Défis", "#c9741c"]],
		[["undo", "Annuler", "#4f5970"]],
	],
}

# Objets (comparés par identité, contrairement aux dictionnaires)
class Piece:
	var type: String
	var def: Dictionary
	var body: StaticBody3D
	var mats: Dictionary
	var locked := false
	var lit := false


class Marble:
	var body: RigidBody3D
	var born := 0.0
	var sleep_since := -1.0
	var counted := false
	var prev_speed := 0.0


class Pointer:
	var kind: String          # "controller", "hand" ou "mouse"
	var side: String
	var ctrl: XRController3D
	var xf := Transform3D()   # rayon : origine, -Z vers l'avant
	var active := false
	var held = null           # {target, obj, offset | local_pos + basis}
	var hover = null          # résultat du dernier lancer de rayon
	var grab_btn := ""
	var events: Array = []
	var yaw_latch := false
	var pinching := false
	var visual: Node3D
	var line: MeshInstance3D
	var cursor: MeshInstance3D


var PIECES: Dictionary
var xr_interface: OpenXRInterface
var xr_active := false
var test_mode := false

var env: Environment
var sun: DirectionalLight3D
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var desk_camera: Camera3D
var room: Node3D
var table_body: StaticBody3D
var toolbox: Toolbox
var level_frame: Node3D
var snap_marker: MeshInstance3D
var sfx: Sfx

var pieces: Array[Piece] = []
var marbles: Array[Marble] = []
var pointers: Array[Pointer] = []   # manettes, mains, souris
var stars: Array = []       # {node, got}
var confetti: Array = []

var mode := "free"
var inventory := {}
var level_index := 0
var run = null              # tentative en cours (mode Défis)
var last_result = null
var progress := {}
var score := 0
var rain_left := 0
var rain_timer := 0.0
var rain_ptr = null
var sim_time := 0.0
var toast_text := ""
var toast_until := 0.0
var flashes := {}
var panel_dirty := true
var xr_frames := 0
var hover_ids := {}

var _mesh_cache := {}
var _shape_cache := {}
var _marble_mesh: SphereMesh
var _marble_shape: SphereShape3D
var _marble_pm: PhysicsMaterial
var _star_mesh: ArrayMesh
var _star_mat: StandardMaterial3D


func _ready() -> void:
	test_mode = OS.get_cmdline_user_args().has("--test-levels")
	PIECES = Defs.make_pieces()
	for type in PIECES:
		PIECES[type]["aabb"] = Toolbox._visual_aabb(PIECES[type])
	_load_progress()
	_build_world()
	_build_pointers()
	xr_active = (not test_mode) and _setup_xr()
	if not xr_active:
		desk_camera.current = true
		room.visible = not test_mode
		if test_mode:
			table_body.queue_free()
	else:
		xr_camera.current = true
		room.visible = false
		table_body.queue_free()
	_place_toolbox_desktop()
	_rebuild_buttons()
	build_starter()
	if test_mode:
		_run_tests.call_deferred()


# ------------------------------------------------------------------ Monde
func _build_world() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#20242c")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.88, 0.95)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4.0
	add_child(sun)

	var ground := StaticBody3D.new()
	ground.collision_layer = LAYER_WORLD
	ground.collision_mask = 0
	var gshape := CollisionShape3D.new()
	gshape.shape = WorldBoundaryShape3D.new()
	ground.add_child(gshape)
	var gpm := PhysicsMaterial.new()
	gpm.friction = 0.3
	gpm.bounce = 0.1
	ground.physics_material_override = gpm
	add_child(ground)

	xr_origin = XROrigin3D.new()
	add_child(xr_origin)
	xr_origin.current = true
	xr_camera = XRCamera3D.new()
	xr_camera.near = 0.02
	xr_origin.add_child(xr_camera)

	desk_camera = Camera3D.new()
	desk_camera.fov = 60
	desk_camera.near = 0.02
	add_child(desk_camera)
	desk_camera.look_at_from_position(Vector3(0.1, 1.5, 1.15), Vector3(0.1, 1.0, -0.05))

	_build_room()

	toolbox = Toolbox.new()
	add_child(toolbox)
	_star_mesh = _make_star_mesh(0.026, 0.011, 0.008)
	toolbox.build(PIECES, _build_visual, _star_mesh)

	level_frame = Node3D.new()
	add_child(level_frame)

	snap_marker = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.018
	torus.outer_radius = 0.026
	snap_marker.mesh = torus
	snap_marker.material_override = _unshaded(Color(0.37, 0.88, 1.0, 0.9))
	snap_marker.visible = false
	add_child(snap_marker)

	sfx = Sfx.new()
	add_child(sfx)

	_marble_mesh = SphereMesh.new()
	_marble_mesh.radius = Defs.MR
	_marble_mesh.height = Defs.MR * 2
	_marble_mesh.radial_segments = 24
	_marble_mesh.rings = 12
	_marble_shape = SphereShape3D.new()
	_marble_shape.radius = Defs.MR
	_marble_pm = PhysicsMaterial.new()
	_marble_pm.friction = 0.25
	_marble_pm.bounce = 0.1

	_star_mat = StandardMaterial3D.new()
	_star_mat.albedo_color = Color("#ffd23f")
	_star_mat.metallic = 0.4
	_star_mat.roughness = 0.3
	_star_mat.emission_enabled = true
	_star_mat.emission = Color("#7a5a00")
	_star_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


# Pièce de bureau (sans casque) : sol et table
func _build_room() -> void:
	room = Node3D.new()
	add_child(room)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	floor_mesh.mesh = plane
	floor_mesh.material_override = _lit(Color("#3a404c"), 0.9)
	room.add_child(floor_mesh)
	var wood := _lit(Color("#9a6b45"), 0.7)
	var top := MeshInstance3D.new()
	top.mesh = _box_mesh(Vector3(1.3, 0.04, 0.75))
	top.material_override = wood
	top.position = Vector3(0.15, 0.72, -0.35)
	room.add_child(top)
	for xz in [Vector2(-0.45, -0.67), Vector2(0.75, -0.67), Vector2(-0.45, -0.03), Vector2(0.75, -0.03)]:
		var leg := MeshInstance3D.new()
		leg.mesh = _box_mesh(Vector3(0.05, 0.7, 0.05))
		leg.material_override = wood
		leg.position = Vector3(xz.x, 0.35, xz.y)
		room.add_child(leg)
	table_body = StaticBody3D.new()
	table_body.collision_layer = LAYER_WORLD
	var ts := CollisionShape3D.new()
	ts.shape = _box_shape(Vector3(1.3, 0.04, 0.75))
	table_body.add_child(ts)
	table_body.position = Vector3(0.15, 0.72, -0.35)
	add_child(table_body)


# ------------------------------------------------------------------ Réalité mixte
func _setup_xr() -> bool:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface == null or not xr_interface.is_initialized():
		return false
	var vp := get_viewport()
	vp.use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	xr_interface.session_begun.connect(_on_session_begun)
	# Recentrage (bouton Meta maintenu) : la boîte à outils revient devant le joueur
	xr_interface.pose_recentered.connect(place_toolbox_in_front)
	_apply_passthrough()
	return true


func _apply_passthrough() -> void:
	if xr_interface == null:
		return
	if xr_interface.get_supported_environment_blend_modes().has(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
		get_viewport().transparent_bg = true
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0, 0, 0, 0)
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND


func _on_session_begun() -> void:
	_apply_passthrough()
	# Fréquence d'affichage la plus haute proposée (90 ou 120 Hz sur Quest 3)
	var rates: Array = xr_interface.get_available_display_refresh_rates()
	if rates.size() > 0:
		var best: float = rates.max()
		xr_interface.display_refresh_rate = minf(best, 90.0)
	xr_frames = 0


# ------------------------------------------------------------------ Pièces
func _box_mesh(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var m := BoxMesh.new()
		m.size = size
		_mesh_cache[size] = m
	return _mesh_cache[size]


func _box_shape(size: Vector3) -> BoxShape3D:
	if not _shape_cache.has(size):
		var s := BoxShape3D.new()
		s.size = size
		_shape_cache[size] = s
	return _shape_cache[size]


func _lit(color: Color, roughness := 0.45, metallic := 0.05) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	m.emission_enabled = true
	m.emission = Color.BLACK
	return m


func _unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _make_materials(def: Dictionary, locked := false) -> Dictionary:
	var base: Color = def.color
	var accent: Color = def.get("accent", base.lightened(0.25))
	if locked and def.name != "Départ" and def.name != "Panier":
		base = base.darkened(0.2)
		accent = accent.darkened(0.2)
	var metal: bool = def.get("metal", false)
	return {
		"a": _lit(base, 0.3 if metal else 0.45, 0.55 if metal else 0.05),
		"b": _lit(accent, 0.3 if metal else 0.45, 0.55 if metal else 0.05),
	}


func _build_visual(def: Dictionary, parent: Node3D, mats = null) -> void:
	if mats == null:
		mats = _make_materials(def)
	for b in def.boxes:
		var mi := MeshInstance3D.new()
		mi.mesh = _box_mesh(b.s)
		mi.material_override = mats[b.c]
		mi.position = b.p
		mi.quaternion = b.q
		parent.add_child(mi)


func create_piece(type: String, locked := false) -> Piece:
	var def: Dictionary = PIECES[type]
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD | LAYER_PIECES
	body.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.friction = 0.25
	pm.bounce = 0.85 if def.get("bouncy", false) else 0.1
	body.physics_material_override = pm
	var mats := _make_materials(def, locked)
	_build_visual(def, body, mats)
	for b in def.boxes:
		var cs := CollisionShape3D.new()
		cs.shape = _box_shape(b.s)
		cs.position = b.p
		cs.quaternion = b.q
		body.add_child(cs)
	add_child(body)
	var piece := Piece.new()
	piece.type = type
	piece.def = def
	piece.body = body
	piece.mats = mats
	piece.locked = locked
	body.set_meta("piece", piece)
	pieces.append(piece)
	return piece


func set_piece_transform(piece: Piece, t: Transform3D) -> void:
	piece.body.global_transform = t
	wake_marbles()


func delete_piece(piece: Piece, with_sound := true) -> void:
	if not pieces.has(piece):
		return
	pieces.erase(piece)
	if mode == "challenge" and not piece.locked:
		inventory[piece.type] = inventory.get(piece.type, 0) + 1
	for ptr in pointers:
		if ptr.held != null and ptr.held.target.get("piece") == piece:
			ptr.held = null
	piece.body.queue_free()
	wake_marbles()
	panel_dirty = true
	if with_sound:
		sfx.play("del", piece.body.global_position, 0.8)


func clear_all() -> void:
	while pieces.size() > 0:
		delete_piece(pieces[pieces.size() - 1], false)
	while marbles.size() > 0:
		remove_marble(marbles[0])
	score = 0
	panel_dirty = true


func set_lit(piece: Piece, on: bool) -> void:
	if piece.lit == on:
		return
	piece.lit = on
	var e := Color(0.16, 0.16, 0.16) if on else Color.BLACK
	piece.mats.a.emission = e
	piece.mats.b.emission = e


func is_held(piece: Piece) -> bool:
	for ptr in pointers:
		if ptr.held != null and ptr.held.target.get("piece") == piece:
			return true
	return false


## Supprime le roulis (« level ») ou garde la pièce debout (« upright »).
func constrain(b: Basis, mode_c: String) -> Basis:
	var x := b.x.normalized()
	if mode_c == "upright":
		if absf(x.y) > 0.98:
			x = (b * Vector3(0, 0, -1)).cross(Vector3.UP)
		return Basis(Vector3.UP, atan2(-x.z, x.x))
	if mode_c == "level":
		if absf(x.y) > 0.97:
			return b.orthonormalized()
		var y := (Vector3.UP - x * Vector3.UP.dot(x)).normalized()
		return Basis(x, y, x.cross(y))
	return b.orthonormalized()


func yaw_of(node: Node3D) -> float:
	var x := node.global_transform.basis.x
	return atan2(-x.z, x.x)


# ------------------------------------------------------------------ Aimantation
func port_world(piece: Piece, kind: String):
	var ports: Dictionary = Defs.PORTS.get(piece.type, {})
	if not ports.has(kind):
		return null
	var t: Transform3D = piece.body.global_transform
	var dir: Vector3 = t.basis * ports[kind][1]
	dir.y = 0
	if dir.length_squared() < 1e-6:
		return null
	return {"pos": t * ports[kind][0], "dir": dir.normalized()}


## Meilleure connexion : l'entrée de la pièce sous une sortie, ou sa sortie au-dessus d'une entrée.
func find_snap(piece: Piece):
	if not Defs.PORTS.has(piece.type):
		return null
	var best = null
	for other in pieces:
		if other == piece or is_held(other):
			continue
		for pair in [["in", "out", -1.0], ["out", "in", 1.0]]:
			var a = port_world(piece, pair[0])
			var b = port_world(other, pair[1])
			if a == null or b == null:
				continue
			var d: float = a.pos.distance_to(b.pos)
			if d > SNAP_DIST or a.dir.angle_to(b.dir) > SNAP_ANGLE:
				continue
			if best == null or d < best.d:
				var sgn: float = pair[2]
				var target: Vector3 = b.pos + b.dir * SNAP_OVERLAP * sgn + Vector3(0, SNAP_DROP * sgn, 0)
				best = {"d": d, "mine": pair[0], "a": a, "b": b, "target": target}
	return best


func apply_snap(piece: Piece, s: Dictionary) -> void:
	var yaw := atan2(s.a.dir.cross(s.b.dir).y, s.a.dir.dot(s.b.dir))
	var t: Transform3D = piece.body.global_transform
	t.basis = Basis(Vector3.UP, yaw) * t.basis
	piece.body.global_transform = t
	var a = port_world(piece, s.mine)
	t.origin += s.target - a.pos
	set_piece_transform(piece, t)


# ------------------------------------------------------------------ Billes
func spawn_marble(pos: Vector3) -> void:
	var rb := RigidBody3D.new()
	rb.mass = 0.02
	rb.collision_layer = LAYER_WORLD
	rb.collision_mask = LAYER_WORLD
	rb.continuous_cd = true
	rb.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rb.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rb.linear_damp = 0.04
	rb.angular_damp = 0.05
	rb.physics_material_override = _marble_pm
	rb.contact_monitor = true
	rb.max_contacts_reported = 4
	var cs := CollisionShape3D.new()
	cs.shape = _marble_shape
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _marble_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(randf(), 0.75, 0.95)
	mat.roughness = 0.12
	mat.metallic = 0.3
	mi.material_override = mat
	rb.add_child(mi)
	add_child(rb)
	rb.global_position = pos
	var m := Marble.new()
	m.body = rb
	m.born = sim_time
	rb.body_entered.connect(func(_other): _on_marble_hit(m))
	marbles.append(m)
	if marbles.size() > MAX_MARBLES:
		remove_marble(marbles[0])
	panel_dirty = true


func _on_marble_hit(m: Marble) -> void:
	if m.prev_speed > 0.25 and not test_mode:
		sfx.tick(m.body.global_position, minf(1.0, m.prev_speed / 3.0))


func remove_marble(m: Marble) -> void:
	if not marbles.has(m):
		return
	marbles.erase(m)
	m.body.queue_free()
	panel_dirty = true


func wake_marbles() -> void:
	for m in marbles:
		m.body.sleeping = false


func spawn_from_starts() -> bool:
	var found := false
	# En mode Défis, pas d'aléa : un circuit qui a marché marchera toujours
	var j := 0.0 if mode == "challenge" else 0.006
	for p in pieces:
		if p.type != "start" or is_held(p):
			continue
		var jitter := Vector3(randf_range(-j, j) / 2, 0, randf_range(-j, j) / 2)
		spawn_marble(p.body.global_transform * Vector3(0, Defs.START_H - 0.02, 0) + jitter)
		found = true
	return found


func drop_marbles(ptr) -> void:
	if mode == "challenge":
		launch_run()
		return
	if spawn_from_starts():
		return
	if ptr != null and ptr.kind != "mouse":
		spawn_marble(ptr.xf.origin - ptr.xf.basis.z * 0.12)
	else:
		spawn_marble(toolbox.global_transform * Vector3(0.6, 0.35, -0.1))
	toast("Astuce : placez un « Départ », les billes en sortiront.")


# ------------------------------------------------------------------ Repère des circuits et niveaux
func anchor_frame() -> void:
	level_frame.global_transform = Transform3D(Basis(Vector3.UP, yaw_of(toolbox)), toolbox.global_position)


func place_in_frame(type: String, x: float, y: float, z: float, yaw := 0.0, pitch := 0.0, locked := false) -> Piece:
	var p := create_piece(type, locked)
	var local := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3(0, 0, 1), deg_to_rad(pitch)), Vector3(x, y, z))
	set_piece_transform(p, level_frame.global_transform * local)
	return p


func build_starter() -> void:
	anchor_frame()
	place_in_frame("start", 0.40, 0.30, -0.10)
	place_in_frame("ramp", 0.58, 0.24, -0.10, 0, -10)
	place_in_frame("goal", 0.82, 0.10, -0.10)


func _spec(arr: Array, locked: bool) -> Piece:
	var yaw := float(arr[4]) if arr.size() > 4 else 0.0
	var pitch := float(arr[5]) if arr.size() > 5 else 0.0
	return place_in_frame(arr[0], float(arr[1]), float(arr[2]), float(arr[3]), yaw, pitch, locked)


func load_level(i: int) -> void:
	level_index = clampi(i, 0, Defs.LEVELS.size() - 1)
	var level: Dictionary = Defs.LEVELS[level_index]
	run = null
	last_result = null
	clear_all()
	_clear_stars()
	anchor_frame()
	for f in level.fixed:
		_spec(f, true)
	inventory = level.inv.duplicate()
	for s in level.stars:
		var node := MeshInstance3D.new()
		node.mesh = _star_mesh
		node.material_override = _star_mat
		add_child(node)
		node.global_position = level_frame.global_transform * Vector3(s[0], s[1], s[2])
		stars.append({"node": node, "got": false})
	panel_dirty = true
	toast("Niveau %d : %s. Construisez puis « Lancer ! »" % [level_index + 1, level.name], 5.0)


func solve(i: int) -> void:
	for f in Defs.LEVELS[i].solution:
		_spec(f, false)


func _clear_stars() -> void:
	for s in stars:
		s.node.queue_free()
	stars.clear()


func is_unlocked(i: int) -> bool:
	return i == 0 or progress.has(i - 1)


func set_mode(m: String) -> void:
	mode = m
	run = null
	_rebuild_buttons()
	if mode == "challenge":
		var first := 0
		for k in Defs.LEVELS.size():
			if not progress.has(k):
				first = k
				break
		load_level(first)
	else:
		_clear_stars()
		inventory = {}
		clear_all()
		build_starter()
		toast("Mode libre : construisez ce que vous voulez !")


func launch_run() -> void:
	var level: Dictionary = Defs.LEVELS[level_index]
	while marbles.size() > 0:
		remove_marble(marbles[0])
	for s in stars:
		s.got = false
		s.node.visible = true
	run = {"to_spawn": level.get("marbles", 1), "timer": 0.0, "t": 0.0}
	last_result = null
	panel_dirty = true


func _update_run(dt: float) -> void:
	if run == null:
		return
	run.t += dt
	if run.to_spawn > 0:
		run.timer -= dt
		if run.timer <= 0.0:
			spawn_from_starts()
			run.to_spawn -= 1
			run.timer = 0.6
		return
	# Échec quand plus aucune bille ne bouge au-dessus du circuit (ou au bout de 15 s)
	var inv := level_frame.global_transform.affine_inverse()
	var moving := false
	for m in marbles:
		if not m.body.sleeping and (inv * m.body.global_position).y > -0.4:
			moving = true
	if not moving or run.t > 15.0:
		_finish_run(false)


func _finish_run(ok: bool) -> void:
	if run == null:
		return
	run = null
	if ok:
		var got := 0
		for s in stars:
			if s.got:
				got += 1
		last_result = {"stars": got}
		progress[level_index] = maxi(progress.get(level_index, 0), got)
		_save_progress()
		sfx.play("win")
		for ptr in pointers:
			_haptic(ptr, 0.6, 0.12)
		var last := level_index == Defs.LEVELS.size() - 1
		if got == 3:
			toast("Parfait ! Tous les niveaux sont terminés !" if last else "Parfait, 3 étoiles ! Niveau suivant débloqué.", 6.0)
		else:
			toast("Réussi avec %d étoile%s sur 3. Visez les étoiles !" % [got, "s" if got > 1 else ""], 6.0)
	else:
		sfx.play("fail")
		toast("Raté… Ajustez votre circuit et relancez !", 4.0)
	panel_dirty = true


func _check_stars_and_goals() -> void:
	if run != null:
		for s in stars:
			if s.got:
				continue
			for m in marbles:
				if m.body.global_position.distance_to(s.node.global_position) < 0.045:
					s.got = true
					s.node.visible = false
					burst(s.node.global_position)
					sfx.play("star", s.node.global_position)
					panel_dirty = true
					break
	for g in pieces:
		if g.type != "goal":
			continue
		var inv: Transform3D = g.body.global_transform.affine_inverse()
		for m in marbles:
			if m.counted:
				continue
			var l: Vector3 = inv * m.body.global_position
			if absf(l.x) < Defs.GOAL_IN / 2 and absf(l.z) < Defs.GOAL_IN / 2 and l.y > 0.0 and l.y < Defs.GOAL_H:
				m.counted = true
				score += 1
				panel_dirty = true
				burst(m.body.global_position)
				sfx.play("chime", m.body.global_position)
				for ptr in pointers:
					_haptic(ptr, 0.3, 0.04)
				if run != null:
					_finish_run(true)


func _load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://progression.cfg") != OK or not cfg.has_section("niveaux"):
		return
	for k in cfg.get_section_keys("niveaux"):
		progress[int(k)] = int(cfg.get_value("niveaux", k))


func _save_progress() -> void:
	if test_mode:
		return
	var cfg := ConfigFile.new()
	for k in progress:
		cfg.set_value("niveaux", str(k), progress[k])
	cfg.save("user://progression.cfg")


# ------------------------------------------------------------------ Confettis
func burst(pos: Vector3) -> void:
	if test_mode:
		return
	for i in 30:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.012, 0.008)
		q.mesh = qm
		q.material_override = _unshaded(Color.from_hsv(randf(), 0.8, 1.0))
		add_child(q)
		q.global_position = pos
		var a := randf() * TAU
		var v := Vector3(cos(a) * 0.5, 1.0 + randf() * 0.8, sin(a) * 0.5) * randf_range(0.7, 1.3)
		confetti.append({"node": q, "v": v, "spin": Vector3(randf() * 10, randf() * 10, 0), "life": 1.3})


func _update_confetti(dt: float) -> void:
	for i in range(confetti.size() - 1, -1, -1):
		var c: Dictionary = confetti[i]
		c.life -= dt
		c.v.y -= 2.5 * dt
		c.v *= 1.0 - 1.5 * dt
		c.node.position += c.v * dt
		c.node.rotation += c.spin * dt
		c.node.scale = Vector3.ONE * clampf(c.life * 2.0, 0.01, 1.0)
		if c.life <= 0.0:
			c.node.queue_free()
			confetti.remove_at(i)


# ------------------------------------------------------------------ Pointeurs
func _build_pointers() -> void:
	for side in ["left", "right"]:
		var ctrl := XRController3D.new()
		ctrl.tracker = side + "_hand"
		ctrl.pose = "aim"
		xr_origin.add_child(ctrl)
		var cptr := _new_pointer("controller", side)
		cptr.ctrl = ctrl
		ctrl.button_pressed.connect(func(n: String): cptr.events.append(["down", n]))
		ctrl.button_released.connect(func(n: String): cptr.events.append(["up", n]))
		pointers.append(cptr)
		pointers.append(_new_pointer("hand", side))
	pointers.append(_new_pointer("mouse", ""))


func _new_pointer(kind: String, side: String) -> Pointer:
	var visual := Node3D.new()
	add_child(visual)
	var line := MeshInstance3D.new()
	line.mesh = _box_mesh(Vector3(0.002, 0.002, 1.0))
	line.material_override = _unshaded(Color(1, 1, 1, 0.5))
	visual.add_child(line)
	var cursor := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.006
	sm.height = 0.012
	cursor.mesh = sm
	cursor.material_override = _unshaded(Color.WHITE)
	visual.add_child(cursor)
	visual.visible = false
	var ptr := Pointer.new()
	ptr.kind = kind
	ptr.side = side
	ptr.visual = visual
	ptr.line = line
	ptr.cursor = cursor
	return ptr


func _hand_tracker(side: String) -> XRHandTracker:
	return XRServer.get_tracker("/user/hand_tracker/" + side) as XRHandTracker


## Met à jour la position des pointeurs et transforme pincements / boutons en événements.
func _update_pointers() -> void:
	var head := xr_camera.global_transform
	for ptr in pointers:
		match ptr.kind:
			"controller":
				var hand := _hand_tracker(ptr.side)
				var hand_on := hand != null and hand.has_tracking_data
				ptr.active = xr_active and not hand_on and ptr.ctrl.get_has_tracking_data()
				if ptr.active:
					ptr.xf = ptr.ctrl.global_transform
			"hand":
				var hand := _hand_tracker(ptr.side)
				ptr.active = xr_active and hand != null and hand.has_tracking_data
				if ptr.active:
					var o := xr_origin.global_transform
					var thumb: Vector3 = o * hand.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
					var index: Vector3 = o * hand.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
					var pinch := (thumb + index) / 2
					# Rayon partant de l'épaule (comme le système du Quest)
					var shoulder := head.origin + head.basis.x * (-0.18 if ptr.side == "left" else 0.18) - Vector3(0, 0.25, 0)
					var dir := (pinch - shoulder).normalized()
					ptr.xf = Transform3D(Basis.looking_at(dir, Vector3.UP), pinch)
					var d := thumb.distance_to(index)
					if not ptr.pinching and d < 0.018:
						ptr.pinching = true
						ptr.events.append(["down", "pinch"])
					elif ptr.pinching and d > 0.035:
						ptr.pinching = false
						ptr.events.append(["up", "pinch"])
				elif ptr.pinching:
					ptr.pinching = false
					ptr.events.append(["up", "pinch"])
			"mouse":
				ptr.active = not xr_active and not test_mode
				if ptr.active:
					var mp := get_viewport().get_mouse_position()
					var o := desk_camera.project_ray_origin(mp)
					var dir := desk_camera.project_ray_normal(mp)
					ptr.xf = Transform3D(Basis.looking_at(dir, Vector3.UP), o)
		if not ptr.active and ptr.held != null:
			_release(ptr, "")


func _ray_pick(ptr: Pointer, allow_near: bool):
	var origin: Vector3 = ptr.xf.origin
	var dir: Vector3 = -ptr.xf.basis.z
	if allow_near:
		for i in range(pieces.size() - 1, -1, -1):
			var p := pieces[i]
			if p.locked or is_held(p):
				continue
			var local: Vector3 = p.body.global_transform.affine_inverse() * origin
			if p.def.aabb.grow(0.025).has_point(local):
				return {"grab": {"kind": "piece", "piece": p}, "dist": 0.0}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 8.0, LAYER_PIECES | LAYER_UI)
	var exclude: Array[RID] = []
	for p in pieces:
		if is_held(p):
			exclude.append(p.body.get_rid())
	q.exclude = exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var col: Object = hit.collider
	var dist := origin.distance_to(hit.position)
	if col.has_meta("ui"):
		return {"ui": col.get_meta("ui"), "dist": dist}
	if col.has_meta("handle"):
		return {"grab": {"kind": "toolbox"}, "dist": dist}
	if col.has_meta("piece"):
		var piece: Piece = col.get_meta("piece")
		if piece.locked:
			return {"locked": true, "dist": dist}
		return {"grab": {"kind": "piece", "piece": piece}, "dist": dist}
	return null


func _haptic(ptr: Pointer, amplitude: float, duration: float) -> void:
	if ptr.kind == "controller" and ptr.active:
		ptr.ctrl.trigger_haptic_pulse("haptic", 0.0, amplitude, duration, 0.0)


func _press(ptr: Pointer, btn: String) -> void:
	if ptr.held != null:
		return
	var res = _ray_pick(ptr, ptr.kind != "mouse")
	if res == null:
		return
	if res.has("locked"):
		toast("Cette pièce fait partie du niveau : elle ne bouge pas.")
		return
	if res.has("ui"):
		_handle_ui(res.ui, ptr, res.dist, btn)
		return
	_start_grab(ptr, res.grab, btn)


func _start_grab(ptr: Pointer, target: Dictionary, btn: String) -> void:
	var obj: Node3D = target.piece.body if target.kind == "piece" else toolbox
	for other in pointers:
		if other != ptr and other.held != null and other.held.obj == obj:
			other.held = null
	var h := {"target": target, "obj": obj}
	if ptr.kind == "mouse":
		h.local_pos = ptr.xf.affine_inverse() * obj.global_position
		h.basis = obj.global_transform.basis
	else:
		h.offset = ptr.xf.affine_inverse() * obj.global_transform
	ptr.held = h
	ptr.grab_btn = btn
	_haptic(ptr, 0.5, 0.035)
	sfx.play("pick", obj.global_position)


func _release(ptr: Pointer, btn: String) -> void:
	var h = ptr.held
	if h == null or (btn != "" and ptr.grab_btn != "" and btn != ptr.grab_btn):
		return
	ptr.held = null
	if h.target.kind != "piece":
		sfx.play("place", toolbox.global_position)
		return
	var piece: Piece = h.target.piece
	if piece.body.global_position.distance_to(toolbox.bin_position()) < BIN_RADIUS:
		delete_piece(piece)
		_haptic(ptr, 0.8, 0.06)
		return
	var snap = find_snap(piece)
	if snap != null:
		apply_snap(piece, snap)
		sfx.play("snap", snap.target)
		burst(snap.target)
	sfx.play("place", piece.body.global_position)
	_haptic(ptr, 0.6 if snap != null else 0.3, 0.04 if snap != null else 0.02)
	wake_marbles()


func _update_held(ptr: Pointer) -> void:
	var h = ptr.held
	if h == null:
		return
	var t: Transform3D
	if h.has("local_pos"):
		t = Transform3D(h.basis, ptr.xf * h.local_pos)
	else:
		t = ptr.xf * h.offset
	var piece = h.target.get("piece")
	t.basis = constrain(t.basis.orthonormalized(), piece.def.constraint if piece != null else "upright")
	if piece != null:
		set_piece_transform(piece, t)
	else:
		toolbox.global_transform = t


## Rotation de l'objet tenu autour d'un axe vertical passant par son centre.
func _rotate_held(ptr: Pointer, angle: float) -> void:
	var h = ptr.held
	var obj: Node3D = h.obj
	var p := obj.global_position
	var r := Basis(Vector3.UP, angle)
	var world := Transform3D(r, p - r * p) * obj.global_transform
	if h.has("basis"):
		h.basis = r * h.basis
	else:
		h.offset = ptr.xf.affine_inverse() * world


func _spawn_in_hand(type: String, ptr: Pointer, dist: float, btn: String) -> void:
	var def: Dictionary = PIECES[type]
	if mode == "challenge":
		if inventory.get(type, 0) <= 0:
			toast("Plus de « %s » disponible dans ce niveau." % def.name)
			return
		inventory[type] -= 1
		panel_dirty = true
	var p := create_piece(type)
	var dir: Vector3 = -ptr.xf.basis.z
	var f := Vector3(dir.x, 0, dir.z)
	if f.length_squared() < 1e-4:
		f = Vector3(0, 0, -1)
	f = f.normalized()
	var right := f.cross(Vector3.UP)
	var yaw := atan2(-right.z, right.x)
	var d := dist * 0.8 if ptr.kind == "mouse" else 0.12
	var t := Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3(0, 0, 1), deg_to_rad(def.pitch)), ptr.xf.origin + dir * d)
	set_piece_transform(p, t)
	_start_grab(ptr, {"kind": "piece", "piece": p}, btn)


func _handle_ui(id: String, ptr: Pointer, dist: float, btn: String) -> void:
	panel_dirty = true
	if _is_disabled(id) and not id.begins_with("slot:"):
		return
	flashes[id] = sim_time + 0.16
	_haptic(ptr, 0.25, 0.02)
	if id.begins_with("slot:"):
		_spawn_in_hand(id.substr(5), ptr, dist, btn)
		return
	sfx.play("click")
	match id.substr(4):
		"marble":
			drop_marbles(ptr)
		"rain":
			rain_left += 10
			rain_ptr = ptr
		"undo":
			for i in range(pieces.size() - 1, -1, -1):
				if not pieces[i].locked:
					delete_piece(pieces[i])
					break
		"clear":
			clear_all()
			sfx.play("del")
		"mode":
			set_mode("challenge" if mode == "free" else "free")
		"launch":
			launch_run()
		"retry":
			load_level(level_index)
		"prev":
			load_level(level_index - 1)
		"next":
			load_level(level_index + 1)


func _is_disabled(id: String) -> bool:
	if mode != "challenge":
		return false
	if id.begins_with("slot:"):
		return inventory.get(id.substr(5), 0) <= 0
	if id == "btn:prev":
		return level_index == 0
	if id == "btn:next":
		return level_index >= Defs.LEVELS.size() - 1 or not is_unlocked(level_index + 1)
	return false


## Boutons des manettes : gâchette/grip = prendre, A/X = supprimer ou bille, B/Y = bille,
## clic du joystick = rappeler la boîte, joystick = tourner / éloigner la pièce tenue.
func _process_events(ptr: Pointer, dt: float) -> void:
	for ev in ptr.events:
		var btn: String = ev[1]
		if ev[0] == "down":
			match btn:
				"trigger_click", "grip_click", "pinch":
					_press(ptr, btn)
				"ax_button":
					if ptr.held != null and ptr.held.target.kind == "piece":
						delete_piece(ptr.held.target.piece)
						_haptic(ptr, 0.8, 0.06)
					else:
						drop_marbles(ptr)
				"by_button":
					drop_marbles(ptr)
				"primary_click":
					if ptr.held == null:
						place_toolbox_in_front()
						sfx.play("click")
		else:
			if btn in ["trigger_click", "grip_click", "pinch"]:
				_release(ptr, btn)
	ptr.events.clear()
	if ptr.kind != "controller" or not ptr.active or ptr.held == null:
		return
	var stick: Vector2 = ptr.ctrl.get_vector2("primary")
	var h: Dictionary = ptr.held
	if h.has("offset") and absf(stick.y) > 0.2:
		h.offset = Transform3D(Basis(), Vector3(0, 0, -stick.y * 0.8 * dt)) * h.offset
		if h.offset.origin.length() < 0.05:
			h.offset.origin = h.offset.origin.normalized() * 0.05
	if absf(stick.x) > 0.7 and not ptr.yaw_latch:
		ptr.yaw_latch = true
		_rotate_held(ptr, deg_to_rad(-15.0 if stick.x > 0 else 15.0))
		_haptic(ptr, 0.2, 0.015)
	if absf(stick.x) < 0.4:
		ptr.yaw_latch = false


func _unhandled_input(event: InputEvent) -> void:
	if xr_active or test_mode:
		return
	var mouse := pointers[pointers.size() - 1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			mouse.events.append(["down" if mb.pressed else "up", "trigger_click"])
		elif mouse.held != null and mb.pressed and mouse.held.has("local_pos"):
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				mouse.held.local_pos.z = minf(-0.2, mouse.held.local_pos.z - 0.03)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				mouse.held.local_pos.z = minf(-0.2, mouse.held.local_pos.z + 0.03)
	elif event is InputEventKey and event.is_pressed() and not event.is_echo():
		var h = mouse.held
		match (event as InputEventKey).keycode:
			KEY_SPACE:
				drop_marbles(mouse)
			KEY_Q:
				if h != null: _rotate_held(mouse, deg_to_rad(15))
			KEY_E:
				if h != null: _rotate_held(mouse, deg_to_rad(-15))
			KEY_R:
				if h != null and h.has("basis"): h.basis = h.basis * Basis(Vector3(0, 0, 1), deg_to_rad(5))
			KEY_F:
				if h != null and h.has("basis"): h.basis = h.basis * Basis(Vector3(0, 0, 1), deg_to_rad(-5))
			KEY_DELETE, KEY_BACKSPACE:
				if h != null and h.target.kind == "piece": delete_piece(h.target.piece)


# ------------------------------------------------------------------ Boîte à outils
func _place_toolbox_desktop() -> void:
	var p := Vector3(-0.42, 0.98, 0.22)
	var cam := desk_camera.global_position
	toolbox.global_transform = Transform3D(Basis(Vector3.UP, atan2(cam.x - p.x, cam.z - p.z)), p)


func place_toolbox_in_front() -> void:
	var head := xr_camera.global_transform
	var f := -head.basis.z
	f.y = 0
	if f.length_squared() < 1e-4:
		f = Vector3(0, 0, -1)
	f = f.normalized()
	var right := f.cross(Vector3.UP)
	var p := head.origin + f * 0.45 - right * 0.15
	p.y = maxf(0.5, head.origin.y - 0.5)
	toolbox.global_transform = Transform3D(Basis(Vector3.UP, atan2(-f.x, -f.z)), p)


func _rebuild_buttons() -> void:
	toolbox.set_buttons(BUTTONS[mode])
	panel_dirty = true


func toast(text: String, seconds := 3.5) -> void:
	toast_text = text
	toast_until = sim_time + seconds
	panel_dirty = true


func _refresh_panel() -> void:
	if mode == "challenge":
		var level: Dictionary = Defs.LEVELS[level_index]
		var shown := -1
		var status := ""
		if run != null:
			shown = 0
			for s in stars:
				if s.got:
					shown += 1
			status = "en cours"
		elif last_result != null:
			shown = last_result.stars
			status = "réussi !"
		elif progress.has(level_index):
			shown = progress[level_index]
			status = "record"
		toolbox.set_header("Niveau %d/%d" % [level_index + 1, Defs.LEVELS.size()], level.name, status, shown)
	else:
		toolbox.set_header("Billes & Rampes", "", "Panier : %d · Billes : %d" % [score, marbles.size()], -1)
	for type in Defs.SLOT_TYPES:
		toolbox.set_badge(type, inventory.get(type, 0), mode == "challenge")
	var toast_on := sim_time < toast_until
	toolbox.set_footer(toast_text if toast_on else "Gâchette ou pincement : prendre · Joystick : tourner, éloigner · A/X : supprimer · B/Y : bille", toast_on)


func _update_panel_states() -> void:
	for id in toolbox.elements:
		toolbox.set_state(id, hover_ids.has(id), _is_disabled(id), flashes.get(id, 0.0) > sim_time)


# ------------------------------------------------------------------ Boucles
func _physics_process(delta: float) -> void:
	sim_time += delta
	if xr_active:
		xr_frames += 1
		if xr_frames == 10:
			place_toolbox_in_front()
			if mode == "challenge":
				load_level(level_index)
			else:
				clear_all()
				build_starter()
	_update_pointers()
	for ptr in pointers:
		_process_events(ptr, delta)
		if ptr.active:
			_update_held(ptr)
		# Survol calculé ici : l'espace physique n'est sûr à interroger que dans la boucle physique
		ptr.hover = _ray_pick(ptr, ptr.kind != "mouse") if ptr.active and ptr.held == null else null

	if rain_left > 0:
		rain_timer -= delta
		if rain_timer <= 0.0:
			drop_marbles(rain_ptr)
			rain_left -= 1
			rain_timer = 0.22

	_check_stars_and_goals()
	_update_run(delta)

	# Billes : vitesse (pour les sons) et nettoyage
	var speed_sum := 0.0
	var speed_max := 0.0
	for i in range(marbles.size() - 1, -1, -1):
		var m := marbles[i]
		var rb := m.body
		var v := rb.linear_velocity.length()
		m.prev_speed = v
		if rb.get_contact_count() > 0:
			speed_sum += v
			speed_max = maxf(speed_max, v)
		if rb.sleeping:
			if m.sleep_since < 0.0:
				m.sleep_since = sim_time
		else:
			m.sleep_since = -1.0
		if rb.global_position.y < -1.0 or (m.sleep_since >= 0.0 and sim_time - m.sleep_since > 10.0) or sim_time - m.born > 120.0:
			remove_marble(m)
	if not test_mode:
		sfx.set_rolling(speed_sum, speed_max)


func _process(delta: float) -> void:
	# Rayons, curseurs et surbrillances
	var new_hover := {}
	var lit := {}
	var handle_hot := false
	snap_marker.visible = false
	var near_bin := false
	for ptr in pointers:
		ptr.visual.visible = ptr.active and ptr.kind != "mouse"
		if not ptr.active:
			continue
		var h = ptr.held
		var res = ptr.hover
		if h != null:
			if h.target.kind == "piece":
				lit[h.target.piece] = true
				var snap = find_snap(h.target.piece)
				if snap != null:
					snap_marker.global_position = snap.target
					snap_marker.scale = Vector3.ONE * (1.0 + 0.15 * sin(sim_time * 8.0))
					snap_marker.visible = true
				if h.target.piece.body.global_position.distance_to(toolbox.bin_position()) < BIN_RADIUS:
					near_bin = true
			else:
				handle_hot = true
		if res != null:
			if res.has("ui"):
				new_hover[res.ui] = true
			elif res.has("grab"):
				if res.grab.kind == "piece":
					lit[res.grab.piece] = true
				else:
					handle_hot = true
		var d: float = res.dist if res != null else (0.06 if h != null else 1.2)
		ptr.visual.global_transform = ptr.xf
		ptr.line.scale = Vector3(1, 1, maxf(0.01, d))
		ptr.line.position = Vector3(0, 0, -maxf(0.01, d) / 2)
		ptr.cursor.visible = res != null and res.dist > 0.0
		ptr.cursor.position = Vector3(0, 0, -d)
	for p in pieces:
		set_lit(p, lit.has(p))
	toolbox.set_handle_hot(handle_hot)
	toolbox.set_bin_hot(near_bin)
	if new_hover.keys() != hover_ids.keys():
		hover_ids = new_hover
	_update_panel_states()
	if panel_dirty or (toast_until > 0.0 and sim_time >= toast_until):
		if sim_time >= toast_until:
			toast_until = 0.0
		_refresh_panel()
		panel_dirty = false

	for s in stars:
		s.node.rotation.y = sim_time * 1.6
	_update_confetti(delta)

	# Lumière : l'ombre suit le joueur
	if xr_active:
		var head := xr_camera.global_position
		sun.global_position = Vector3(head.x, 0, head.z)


# ------------------------------------------------------------------ Étoiles (maillage)
func _make_star_mesh(ro: float, ri: float, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Vector2] = []
	for i in 10:
		var r := ro if i % 2 == 0 else ri
		var a := PI / 2 + float(i) / 10.0 * TAU
		pts.append(Vector2(cos(a), sin(a)) * r)
	var hz := depth / 2
	for i in 10:
		var a2 := pts[i]
		var b2 := pts[(i + 1) % 10]
		for zs in [hz, -hz]:
			st.set_normal(Vector3(0, 0, signf(zs)))
			st.add_vertex(Vector3(0, 0, zs))
			st.add_vertex(Vector3(a2.x, a2.y, zs))
			st.add_vertex(Vector3(b2.x, b2.y, zs))
		var n := Vector3(b2.y - a2.y, a2.x - b2.x, 0).normalized()
		st.set_normal(n)
		st.add_vertex(Vector3(a2.x, a2.y, hz))
		st.add_vertex(Vector3(a2.x, a2.y, -hz))
		st.add_vertex(Vector3(b2.x, b2.y, hz))
		st.add_vertex(Vector3(b2.x, b2.y, hz))
		st.add_vertex(Vector3(a2.x, a2.y, -hz))
		st.add_vertex(Vector3(b2.x, b2.y, -hz))
	return st.commit()


# ------------------------------------------------------------------ Tests automatiques (CI)
func _sim(seconds: float) -> void:
	for k in int(seconds * 120.0):
		await get_tree().physics_frame


func _sim_trace(seconds: float) -> Array:
	var pts := []
	var inv := level_frame.global_transform.affine_inverse()
	for k in int(seconds * 120.0):
		await get_tree().physics_frame
		if k % 12 == 0 and marbles.size() > 0:
			var l: Vector3 = inv * marbles[0].body.global_position
			pts.append("(%.3f, %.3f, %.3f)" % [l.x, l.y, l.z])
	return pts


func _run_tests() -> void:
	await _sim(0.2)
	var failures := 0
	# Circuit de démonstration (mode libre)
	drop_marbles(null)
	await _sim(4.0)
	print("DEMO : billes dans le panier = %d" % score)
	if score < 1:
		failures += 1
	set_mode("challenge")
	for i in Defs.LEVELS.size():
		load_level(i)
		launch_run()
		await _sim(7.0)
		var empty = last_result
		load_level(i)
		solve(i)
		launch_run()
		var tr: Array = await _sim_trace(7.0)
		var sol = last_result
		var ok: bool = empty == null and sol != null and sol.stars == 3
		if not ok:
			failures += 1
		print("NIVEAU %d %s : %s | vide=%s solution=%s" % [i + 1, Defs.LEVELS[i].name, "OK" if ok else "ECHEC", str(empty), str(sol)])
		print("  trajectoire : " + " ".join(PackedStringArray(tr)))
	print("RESULTAT : %d test(s) en échec" % failures)
	get_tree().quit(1 if failures > 0 else 0)
