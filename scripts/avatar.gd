extends Node3D
class_name Avatar
## Another player as seen by this client: a blocky runner posed from the state the
## owner broadcasts, drawn ~110 ms in the past and interpolated between updates.

const INTERP_MS := 110

var body: Node3D
var leg_l: Node3D
var leg_r: Node3D
var arm_l: Node3D
var arm_r: Node3D
var suit := StandardMaterial3D.new()
var dark := StandardMaterial3D.new()
var skin := StandardMaterial3D.new()
var marker_mat := StandardMaterial3D.new()
var marker: MeshInstance3D
var label: Label3D
var shield: MeshInstance3D
var phase := 0.0
var styled := ""
var xray := false
var cur := {}      # last sample drawn: {x, y, z, yaw, vx, vz, s, w, h}


func _init() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	suit.roughness = 0.55
	dark.roughness = 0.7
	dark.albedo_color = Color("#1f232a")
	skin.albedo_color = Color("#e6c2a4")
	skin.roughness = 0.8
	marker_mat.albedo_color = Color("#e5382d")
	marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body = Node3D.new()
	body.position.y = 0.95
	add_child(body)
	_part(body, Vector3(0.46, 0.62, 0.26), suit, Vector3(0, 0.36, 0))
	_part(body, Vector3(0.28, 0.3, 0.28), skin, Vector3(0, 0.86, 0))
	_part(body, Vector3(0.3, 0.1, 0.3), dark, Vector3(0, 1.03, 0))
	_part(body, Vector3(0.24, 0.07, 0.04), dark, Vector3(0, 0.9, -0.15))   # visor: the front is -Z
	leg_l = _limb(Vector3(-0.12, 0, 0), 0.18, 0.92, dark)
	leg_r = _limb(Vector3(0.12, 0, 0), 0.18, 0.92, dark)
	arm_l = _limb(Vector3(-0.31, 0.62, 0), 0.13, 0.68, suit)
	arm_r = _limb(Vector3(0.31, 0.62, 0), 0.13, 0.68, suit)
	marker = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.2
	cone.bottom_radius = 0.0
	cone.height = 0.36
	cone.radial_segments = 4
	marker.mesh = cone
	marker.material_override = marker_mat
	marker.position.y = 2.55
	marker.visible = false
	add_child(marker)
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 2.2
	label.font_size = 44
	label.outline_size = 10
	label.pixel_size = 0.006
	add_child(label)
	shield = MeshInstance3D.new()   # bubble while the "Bouclier" bonus is held
	var bubble := SphereMesh.new()
	bubble.radius = 1.0
	bubble.height = 2.2
	shield.mesh = bubble
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.albedo_color = Color(Bonus.color_of("shield"), 0.22)
	shield.material_override = sm
	shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shield.position.y = 1.0
	shield.visible = false
	add_child(shield)


func _part(parent: Node3D, size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _limb(pivot_pos: Vector3, w: float, length: float, mat: Material) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	body.add_child(pivot)
	_part(pivot, Vector3(w, length, w), mat, Vector3(0, -length / 2.0, 0))
	return pivot


## samples: Array of {"t": msec, "d": PackedFloat32Array[x,y,z,yaw,vx,vy,vz,state,wall,h]}
func sample(samples: Array, now_ms: int) -> Dictionary:
	if samples.is_empty():
		return {}
	var t := now_ms - INTERP_MS
	var first: Dictionary = samples[0]
	if t <= int(first.t):
		return _unpack(first.d)
	for i in range(samples.size() - 1, -1, -1):
		var a: Dictionary = samples[i]
		if int(a.t) > t:
			continue
		var da := _unpack(a.d)
		if i == samples.size() - 1:
			var ex := minf((t - int(a.t)) / 1000.0, 0.2)
			da.x += da.vx * ex
			da.z += da.vz * ex
			return da
		var b: Dictionary = samples[i + 1]
		var db := _unpack(b.d)
		var k := float(t - int(a.t)) / maxf(float(int(b.t) - int(a.t)), 1.0)
		db.x = lerpf(da.x, db.x, k)
		db.y = lerpf(da.y, db.y, k)
		db.z = lerpf(da.z, db.z, k)
		db.yaw = lerp_angle(da.yaw, db.yaw, k)
		db.vx = lerpf(da.vx, db.vx, k)
		db.vz = lerpf(da.vz, db.vz, k)
		db.h = lerpf(da.h, db.h, k)
		if k < 0.5:
			db.s = da.s
		return db
	return _unpack(first.d)


static func _unpack(d: PackedFloat32Array) -> Dictionary:
	return {"x": d[0], "y": d[1], "z": d[2], "yaw": d[3], "vx": d[4], "vy": d[5], "vz": d[6], "s": int(d[7]), "w": d[8], "h": d[9]}


func show_sample(s: Dictionary, dt: float, now_s: float) -> void:
	cur = s
	position = Vector3(s.x, s.y, s.z)
	rotation.y = s.yaw
	_pose(s.s, Vector2(s.vx, s.vz).length(), dt, s.w, now_s)


func style(color: Color, hunter: bool, player_name: String) -> void:
	var key := "%s|%s|%s" % [color.to_html(), hunter, player_name]
	if key == styled:
		return
	styled = key
	suit.albedo_color = Color("#22252b") if hunter else color
	dark.albedo_color = Color("#c62c22") if hunter else Color("#1f232a")
	marker.visible = hunter
	label.text = player_name + ("  ·  chasseur" if hunter else "")
	label.modulate = Color("#ffb3ad") if hunter else Color.WHITE


func set_shield(on: bool) -> void:
	shield.visible = on


func set_xray(on: bool) -> void:
	if on == xray:
		return
	xray = on
	for m: StandardMaterial3D in [suit, dark, skin]:
		m.no_depth_test = on
		m.render_priority = 10 if on else 0
		m.emission_enabled = on
		m.emission = Color("#8a1008")


func _pose(s: int, speed: float, dt: float, w: float, t: float) -> void:
	body.rotation = Vector3.ZERO
	body.position.y = 0.95
	phase += dt * (2.0 + speed * 1.25)
	var sw := sin(phase)
	var amp := minf(speed / 8.0, 1.0)
	var ll := sw * amp * 0.95
	var lr := -sw * amp * 0.95
	var al := -sw * amp * 0.8
	var ar := sw * amp * 0.8
	match s:
		0:
			body.rotation.x = -0.18 * amp
		1:
			ll = 0.7
			lr = -0.35
			al = -2.2
			ar = -0.6
		2:
			body.rotation.x = 1.05
			body.position.y = 0.42
			ll = 0.1
			lr = -0.25
			al = -0.8
			ar = 0.4
		3:
			body.rotation.z = w * 0.45
			ll *= 1.2
			lr *= 1.2
		4:
			al = -2.9 + sw * 0.3
			ar = -2.9 - sw * 0.3
		6:
			al = -1.5
			ar = -1.5
			ll = 1.2
			lr = 0.3
			body.rotation.x = -0.4
		7:
			body.position.y = 0.5
			body.rotation.x = -fmod(t * 2.0, 1.0) * TAU
			ll = 1.4
			lr = 1.4
			al = -1.2
			ar = -1.2
		8:
			body.rotation.x = -0.5
			al = 0.3
			ar = 0.3
	leg_l.rotation.x = ll
	leg_r.rotation.x = lr
	arm_l.rotation.x = al
	arm_r.rotation.x = ar
