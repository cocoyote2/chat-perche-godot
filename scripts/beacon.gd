extends Node3D
class_name Beacon
## The spot runners must reach: a column of light seen from across the city and
## a ring on the floor marking the reach radius. Turns green once validated.

const TODO := Color("#ffd23f")
const DONE := Color("#2bd17e")

var column: MeshInstance3D
var ring: MeshInstance3D
var mat: StandardMaterial3D
var ring_mat: StandardMaterial3D
var _t := 0.0


func _init() -> void:
	mat = _glow()
	# seen from inside or up close it would wash the whole screen: fade it out
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 3.0
	mat.distance_fade_max_distance = 12.0
	ring_mat = _glow()
	column = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.6
	cyl.height = 90.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	column.mesh = cyl
	column.position.y = 45.0
	column.material_override = mat
	column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(column)
	ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = Net.BEACON_R - 0.15
	torus.outer_radius = Net.BEACON_R
	ring.mesh = torus
	ring.position.y = 0.06
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	visible = false


static func _glow() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	return m


func show_at(p: Vector3, done: bool) -> void:
	position = p
	visible = true
	var c := DONE if done else TODO
	mat.albedo_color = Color(c, 0.25 if done else 0.45)
	ring_mat.albedo_color = Color(c, 0.9)


func _process(dt: float) -> void:
	if not visible:
		return
	_t += dt
	var k := 1.0 + 0.06 * sin(_t * 5.0)
	ring.scale = Vector3(k, 1.0, k)
	column.scale = Vector3(1.0 + 0.15 * sin(_t * 3.0), 1.0, 1.0 + 0.15 * sin(_t * 3.0))
