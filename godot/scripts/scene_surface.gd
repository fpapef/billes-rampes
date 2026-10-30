extends Node3D
## Surface réelle détectée par le Quest (table, mur, sol, canapé…), créée par OpenXRFbSceneManager.
## Elle arrête les billes et s'affiche brièvement en transparence pour montrer ce qui a été détecté.

const LAYER_WORLD := 1
const IGNORED := ["ceiling", "global_mesh"]
const SHOW_TIME := 6.0

var label := ""
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D
var _fade := 0.0


func setup_scene(entity) -> void:
	var labels: PackedStringArray = entity.get_semantic_labels()
	label = labels[0] if labels.size() > 0 else ""
	if label in IGNORED:
		return

	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.friction = 0.3
	pm.bounce = 0.15
	body.physics_material_override = pm
	var shape = entity.create_collision_shape()
	if shape:
		body.add_child(shape)
	add_child(body)

	_mesh = entity.create_mesh_instance()
	if _mesh:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat.albedo_color = Color(0.37, 0.88, 1.0, 0.0)
		_mesh.material_override = _mat
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh)
	add_to_group("real_surfaces")
	flash()


## Montre la surface quelques secondes.
func flash() -> void:
	if _mesh == null:
		return
	_mesh.visible = true
	_fade = SHOW_TIME


func _process(delta: float) -> void:
	if _mesh == null or _fade <= 0.0:
		return
	_fade -= delta
	_mat.albedo_color.a = clampf(_fade / SHOW_TIME, 0.0, 1.0) * 0.22
	if _fade <= 0.0:
		_mesh.visible = false
