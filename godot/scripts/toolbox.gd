extends Node3D
## Boîte à outils : pupitre incliné avec les pièces, les boutons, la poignée et la poubelle.
## Les éléments cliquables sont des StaticBody3D (couche UI) avec la méta "ui" = identifiant.

const Defs = preload("res://scripts/defs.gd")

const PW := 0.5          # largeur du pupitre (m)
const PH := 0.3125       # hauteur du pupitre (m)
const PX_W := 1024.0     # repère « pixels » utilisé pour la mise en page
const PX_H := 640.0
const LAYER_UI := 4

var panel: Node3D
var bin: Node3D
var bin_mat: StandardMaterial3D
var handle_mat: StandardMaterial3D
var title_label: Label3D
var subtitle_label: Label3D
var stats_label: Label3D
var footer_label: Label3D
var header_stars: Array[MeshInstance3D] = []
var elements := {}       # id -> {kind, body, mat, base, label, badge}
var minis := {}          # type -> Node3D qui tourne
var _button_ids: Array[String] = []
var _star_on: StandardMaterial3D
var _star_off: StandardMaterial3D


func build(pieces_def: Dictionary, make_visual: Callable, star_mesh: Mesh) -> void:
	panel = Node3D.new()
	panel.rotation_degrees = Vector3(-40, 0, 0)
	add_child(panel)

	var back := MeshInstance3D.new()
	var back_mesh := BoxMesh.new()
	back_mesh.size = Vector3(PW + 0.01, PH + 0.01, 0.012)
	back.mesh = back_mesh
	back.material_override = _mat(Color("#151a22"), 0.6)
	back.position = Vector3(0, 0, -0.0065)
	panel.add_child(back)

	# Poignée pour déplacer la boîte
	handle_mat = _mat(Color("#9aa6b8"), 0.35, 0.4)
	handle_mat.emission_enabled = true
	handle_mat.emission = Color.BLACK
	var handle := StaticBody3D.new()
	handle.collision_layer = LAYER_UI
	handle.collision_mask = 0
	handle.set_meta("handle", true)
	handle.position = Vector3(0, PH / 2 + 0.035, -0.01)
	var hmesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.014
	cyl.bottom_radius = 0.014
	cyl.height = 0.3
	hmesh.mesh = cyl
	hmesh.rotation_degrees = Vector3(0, 0, 90)
	hmesh.material_override = handle_mat
	handle.add_child(hmesh)
	var hshape := CollisionShape3D.new()
	var hbox := BoxShape3D.new()
	hbox.size = Vector3(0.3, 0.035, 0.035)
	hshape.shape = hbox
	handle.add_child(hshape)
	panel.add_child(handle)
	for sx in [-0.13, 0.13]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.012, 0.04, 0.012)
		post.mesh = pm
		post.material_override = handle_mat
		post.position = Vector3(sx, PH / 2 + 0.015, -0.01)
		panel.add_child(post)

	# Poubelle : relâcher une pièce dedans la supprime
	bin = Node3D.new()
	bin.position = Vector3(PW / 2 + 0.11, -0.06, 0.06)
	bin_mat = _mat(Color("#d8463c"), 0.5)
	bin_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	bin_mat.emission_enabled = true
	bin_mat.emission = Color.BLACK
	var bin_mesh := MeshInstance3D.new()
	var bcyl := CylinderMesh.new()
	bcyl.top_radius = 0.075
	bcyl.bottom_radius = 0.06
	bcyl.height = 0.13
	bcyl.cap_top = false
	bin_mesh.mesh = bcyl
	bin_mesh.material_override = bin_mat
	bin.add_child(bin_mesh)
	add_child(bin)

	# En-tête et pied de page
	title_label = _label("", 44, Vector2(34, 40), HORIZONTAL_ALIGNMENT_LEFT)
	subtitle_label = _label("", 26, Vector2(34, 76), HORIZONTAL_ALIGNMENT_LEFT, Color("#b8c2d3"))
	stats_label = _label("", 26, Vector2(990, 52), HORIZONTAL_ALIGNMENT_RIGHT, Color("#ffd25e"))
	footer_label = _label("", 22, Vector2(512, 606), HORIZONTAL_ALIGNMENT_CENTER, Color("#8c97aa"))
	_star_on = _mat(Color("#ffd23f"), 0.3, 0.4)
	_star_on.emission_enabled = true
	_star_on.emission = Color("#7a5a00")
	_star_off = _mat(Color("#3a4252"), 0.6)
	for k in 3:
		var s := MeshInstance3D.new()
		s.mesh = star_mesh
		s.material_override = _star_off
		var p := _px(820 + k * 62, 52)
		s.position = Vector3(p.x, p.y, 0.008)
		s.scale = Vector3.ONE * 0.8
		panel.add_child(s)
		header_stars.append(s)

	# Cases des pièces (2 rangées de 4)
	for i in Defs.SLOT_TYPES.size():
		var type: String = Defs.SLOT_TYPES[i]
		var def: Dictionary = pieces_def[type]
		var col := i % 4
		var row := i / 4
		var rect := Rect2(24 + col * 160, 96 + row * 240, 150, 228)
		var el := _element("slot:" + type, "slot", rect, Color("#222a38"), def.name, 25, true)
		# Liseré de la couleur de la pièce
		var border := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(rect.size.x / PX_W * PW + 0.004, rect.size.y / PX_H * PH + 0.004, 0.003)
		border.mesh = bm
		border.material_override = _mat(def.color, 0.5)
		border.position = Vector3(0, 0, -0.001)
		el.body.add_child(border)
		el.label.position.y = -rect.size.y / PX_H * PH / 2 + 0.018
		# Badge du nombre de pièces restantes (mode Défis)
		var badge := Label3D.new()
		badge.font_size = 24
		badge.pixel_size = 0.0004
		badge.modulate = Color("#ffd25e")
		badge.outline_size = 0
		badge.position = Vector3(rect.size.x / PX_W * PW / 2 - 0.016, rect.size.y / PX_H * PH / 2 - 0.014, 0.004)
		badge.visible = false
		el.body.add_child(badge)
		el["badge"] = badge
		# Miniature qui tourne
		var holder := Node3D.new()
		var mini := Node3D.new()
		make_visual.call(def, mini)
		var aabb := _visual_aabb(def)
		var sc := 0.07 / maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		mini.scale = Vector3.ONE * sc
		mini.position = -aabb.get_center() * sc
		holder.add_child(mini)
		holder.position = Vector3(0, 0.012, 0.04)
		el.body.add_child(holder)
		minis[type] = holder


func _process(_delta: float) -> void:
	# Les miniatures restent droites dans le monde malgré l'inclinaison du pupitre
	var t := Time.get_ticks_msec() / 1000.0
	var i := 0
	for type in minis:
		var h: Node3D = minis[type]
		h.basis = Basis(Vector3(1, 0, 0), deg_to_rad(40)) * Basis(Vector3.UP, t * 0.6 + i)
		i += 1


## rows : [[[action, libellé, couleur], ...], ...] — une rangée peut contenir deux boutons.
func set_buttons(rows: Array) -> void:
	for id in _button_ids:
		elements[id].body.queue_free()
		elements.erase(id)
	_button_ids.clear()
	for r in rows.size():
		var row: Array = rows[r]
		var w := (312.0 - (row.size() - 1) * 10.0) / row.size()
		for j in row.size():
			var spec: Array = row[j]
			var rect := Rect2(688 + j * (w + 10), 96 + r * 96, w, 84)
			var id := "btn:" + str(spec[0])
			_element(id, "button", rect, Color(spec[2]), spec[1], 28 if w > 200 else 25, false)
			_button_ids.append(id)


func set_label(id: String, text: String) -> void:
	if elements.has(id):
		elements[id].label.text = text


func set_state(id: String, hot: bool, disabled: bool, flash: bool) -> void:
	if not elements.has(id):
		return
	var el: Dictionary = elements[id]
	var c: Color = el.base
	if disabled:
		c = c.darkened(0.55)
	elif flash:
		c = c.lightened(0.35)
	elif hot:
		c = c.lightened(0.18)
	el.mat.albedo_color = c
	el.label.modulate = Color(1, 1, 1, 0.35) if disabled else Color.WHITE
	if el.has("badge"):
		el.badge.modulate = Color("#55607a") if disabled else Color("#ffd25e")


func set_badge(type: String, count: int, visible_badge: bool) -> void:
	var el: Dictionary = elements.get("slot:" + type, {})
	if el.is_empty():
		return
	el.badge.visible = visible_badge
	el.badge.text = "×%d" % count
	minis[type].visible = not visible_badge or count > 0


func set_header(title: String, subtitle: String, stats: String, stars_shown: int) -> void:
	title_label.text = title
	title_label.font_size = 44 if subtitle == "" else 38
	title_label.position.y = _px(0, 52 if subtitle == "" else 40).y
	subtitle_label.text = subtitle
	stats_label.text = stats
	for k in 3:
		header_stars[k].visible = stars_shown >= 0
		header_stars[k].material_override = _star_on if k < stars_shown else _star_off


func set_footer(text: String, highlight: bool) -> void:
	footer_label.text = text
	footer_label.modulate = Color("#ffd25e") if highlight else Color("#8c97aa")


func set_handle_hot(on: bool) -> void:
	handle_mat.emission = Color(0.2, 0.2, 0.2) if on else Color.BLACK


func set_bin_hot(on: bool) -> void:
	bin_mat.emission = Color(0.4, 0.05, 0.05) if on else Color.BLACK


func bin_position() -> Vector3:
	return bin.global_position


func _element(id: String, kind: String, rect: Rect2, color: Color, text: String, font: int, dark_text: bool) -> Dictionary:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_UI
	body.collision_mask = 0
	body.set_meta("ui", id)
	var center := _px(rect.position.x + rect.size.x / 2, rect.position.y + rect.size.y / 2)
	body.position = Vector3(center.x, center.y, 0.004)
	var size := Vector3(rect.size.x / PX_W * PW, rect.size.y / PX_H * PH, 0.004)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := _mat(color, 0.6)
	mesh.material_override = mat
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(size.x, size.y, 0.02)
	shape.shape = bs
	body.add_child(shape)
	var label := Label3D.new()
	label.text = text
	label.font_size = font
	label.pixel_size = 0.0004
	label.outline_size = 0
	label.modulate = Color.WHITE
	label.position = Vector3(0, 0, size.z / 2 + 0.001)
	body.add_child(label)
	panel.add_child(body)
	var el := {"kind": kind, "body": body, "mat": mat, "base": color, "label": label}
	elements[id] = el
	return el


func _label(text: String, font: int, at: Vector2, align: HorizontalAlignment, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font
	l.pixel_size = 0.0004
	l.outline_size = 0
	l.modulate = color
	l.horizontal_alignment = align
	var p := _px(at.x, at.y)
	l.position = Vector3(p.x, p.y, 0.002)
	panel.add_child(l)
	return l


func _px(x: float, y: float) -> Vector2:
	return Vector2((x / PX_W - 0.5) * PW, (0.5 - y / PX_H) * PH)


func _mat(color: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


static func _visual_aabb(def: Dictionary) -> AABB:
	var aabb := AABB()
	var first := true
	for b in def.boxes:
		var half: Vector3 = b.s / 2
		for sx in [-1, 1]:
			for sy in [-1, 1]:
				for sz in [-1, 1]:
					var corner: Vector3 = b.q * Vector3(half.x * sx, half.y * sy, half.z * sz) + b.p
					if first:
						aabb = AABB(corner, Vector3.ZERO)
						first = false
					else:
						aabb = aabb.expand(corner)
	return aabb
