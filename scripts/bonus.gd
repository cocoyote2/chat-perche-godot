extends Node3D
class_name Bonus
## A pickup lying on the map: a glowing gem that spins and bobs, its name above
## it, and a thin beam so it can be spotted from a few rooftops away.

const INFO := {
	"speed": {"name": "Turbo", "color": Color("#ff9f1c")},
	"jump": {"name": "Ressort", "color": Color("#3ddc84")},
	"stamina": {"name": "Second souffle", "color": Color("#4cc9f0")},
	"shield": {"name": "Bouclier", "color": Color("#b388ff")},
	"sonar": {"name": "Sonar rechargé", "color": Color("#b388ff")},
}

var gem: MeshInstance3D
var _t := randf() * TAU


static func name_of(kind: String) -> String:
	return str(INFO.get(kind, {}).get("name", kind))


static func color_of(kind: String) -> Color:
	return INFO.get(kind, {}).get("color", Color.WHITE)


func _init(kind: String) -> void:
	var c := color_of(kind)
	gem = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.45, 0.45, 0.45)
	gem.mesh = box
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	gem.material_override = m
	gem.rotation = Vector3(PI / 4, 0, PI / 4)   # stands on a corner, like a gem
	gem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gem)

	var halo := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	halo.mesh = sphere
	halo.material_override = _glow(Color(c, 0.18))
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gem.add_child(halo)

	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.03
	cyl.bottom_radius = 0.08
	cyl.height = 7.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	beam.mesh = cyl
	beam.position.y = 1.5 + 3.5   # starts above the gem, so it reads as a beam, not a stick
	var bm := _glow(Color(c, 0.35))
	bm.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	bm.distance_fade_min_distance = 2.0
	bm.distance_fade_max_distance = 8.0
	beam.material_override = bm
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)

	var label := Label3D.new()
	label.text = name_of(kind)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = c
	label.outline_size = 8
	label.font_size = 40
	label.pixel_size = 0.006
	label.position.y = 1.75
	label.visibility_range_end = 30.0   # only once close enough to read
	add_child(label)


static func _glow(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.albedo_color = c
	return m


func _process(dt: float) -> void:
	_t += dt
	gem.position.y = 0.9 + 0.12 * sin(_t * 2.2)
	gem.rotate_y(dt * 1.8)
