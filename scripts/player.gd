extends CharacterBody3D
class_name Player
## First-person parkour controller for the local player.
##
## States: move (run / air), slide, wall (lateral wall-run), climb (vertical wall
## run), hang (holding a ledge), mantle (pulling up / vaulting), roll, stun, spec
## (free-flying spectator). Godot's move_and_slide() does the collisions; the World
## probes answer the parkour questions (wall beside me, ledge in front of me).

signal move_done(label: String)
signal sfx(sound: String, volume: float)
signal notice(text: String)

const R := 0.35
const HS := 1.8
const HL := 0.95
const GRAV := 22.0
const JUMP := 7.2
const VMAX := 16.0
const RUN_RUNNER := 8.0
const RUN_HUNTER := 8.5
const SPRINT_RUNNER := 10.5
const SPRINT_HUNTER := 11.0
const STAMINA_DRAIN := 0.22      # per second of sprint: ~4.5 s from full
const STAMINA_REGEN := 0.25      # per second once recovering: 4 s to refill
const STAMINA_REGEN_DELAY := 0.8 # pause after sprinting before it refills
const STAMINA_RECOVER := 0.3     # once empty, sprint is locked until this level
const AXES: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var world: World
var head: Node3D
var camera: Camera3D
var shape: CollisionShape3D
var capsule: CapsuleShape3D

var yaw := 0.0
var pitch := 0.0
var h := HS
var eye := 1.62
var st := "move"
var st_t := 0.0
var grounded := false
var coyote := 0.0
var jump_buf := 0.0
var slide_buf := 9.0
var air_t := 0.0
var wall_n := Vector2i.ZERO
var wall_side := 0
var wr_speed := 0.0
var climb_v := 0.0
var last_wall_key := ""
var climb_used := false
var ledge_cd := 0.0
var slide_boost_cd := 0.0
var recent := 0.0          # recent top horizontal speed, survives a wall impact
var mantle := {}
var hang := {}
var combo := 0
var combo_t := 0.0
var stun_t := 0.0
var dip := 0.0
var shake := 0.0
var bob := 0.0
var cam_roll := 0.0
var step_acc := 0.0
var run_speed := RUN_RUNNER
var sprint_speed := SPRINT_RUNNER
var stamina := 1.0
var exhausted := false
var sprinting := false
var _regen_wait := 0.0
var frozen := false
var input_enabled := false
var sensitivity := 1.0

# Scripted input for the headless tests.
var sim := false
var sim_axes := Vector2.ZERO
var sim_slide := false
var sim_sprint := false


func _ready() -> void:
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(46.0)
	shape = CollisionShape3D.new()
	capsule = CapsuleShape3D.new()
	capsule.radius = R
	capsule.height = HS
	shape.shape = capsule
	shape.position.y = HS / 2.0
	add_child(shape)
	head = Node3D.new()
	head.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(head)
	camera = Camera3D.new()
	camera.fov = 78.0
	camera.near = 0.05
	camera.far = 1500.0
	head.add_child(camera)


func _unhandled_input(e: InputEvent) -> void:
	if not input_enabled:
		return
	var mm := e as InputEventMouseMotion
	if mm != null:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var k := 0.0022 * sensitivity
			yaw -= mm.relative.x * k
			pitch = clampf(pitch - mm.relative.y * k, -1.52, 1.52)
		return
	if e.is_action_pressed("jump"):
		jump_buf = 0.15
	elif e.is_action_pressed("slide"):
		slide_buf = 0.0


func _axes() -> Vector2:
	if sim:
		return sim_axes
	if not input_enabled:
		return Vector2.ZERO
	return Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_back", "move_forward"))


func slide_held() -> bool:
	if sim:
		return sim_slide
	return input_enabled and Input.is_action_pressed("slide")


func sprint_held() -> bool:
	if sim:
		return sim_sprint
	return input_enabled and Input.is_action_pressed("sprint")


func hspeed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func set_height(nh: float) -> void:
	if is_equal_approx(h, nh):
		return
	h = nh
	capsule.height = nh
	shape.position.y = nh / 2.0


func set_pos(p: Vector3, new_yaw := NAN) -> void:
	position = p
	velocity = Vector3.ZERO
	st = "move"
	grounded = false
	set_height(HS)
	mantle = {}
	hang = {}
	last_wall_key = ""
	climb_used = false
	stun_t = 0.0
	shape.disabled = false
	if not is_nan(new_yaw):
		yaw = new_yaw
		pitch = 0.0
	reset_physics_interpolation()


func start_spectating() -> void:
	st = "spec"
	shape.disabled = true
	velocity = Vector3.ZERO
	position.y += 3.0
	sfx.emit("slide_off", 0.0)


func state_code() -> int:
	match st:
		"move":
			return 0 if grounded else 1
		"slide":
			return 2
		"wall":
			return 3
		"climb":
			return 4
		"hang":
			return 5
		"mantle":
			return 6
		"roll":
			return 7
		"stun":
			return 8
		"spec":
			return 9
	return 0


func _combo(label: String) -> void:
	combo = combo + 1 if combo_t > 0.0 else 1
	combo_t = 2.4
	move_done.emit(label)
	sfx.emit("whoosh", 0.4)


static func _front_normal(f: Vector3, minv: float) -> Vector2i:
	if absf(f.x) > absf(f.z):
		return Vector2i.ZERO if absf(f.x) < minv else Vector2i(-int(signf(f.x)), 0)
	return Vector2i.ZERO if absf(f.z) < minv else Vector2i(0, -int(signf(f.z)))


static func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


# ------------------------------------------------------------------ simulation

func _physics_process(dt: float) -> void:
	step(dt)


func step(dt: float) -> void:
	jump_buf -= dt
	slide_buf += dt
	ledge_cd -= dt
	slide_boost_cd -= dt
	combo_t -= dt
	if combo_t <= 0.0:
		combo = 0
	var hs0 := hspeed()
	recent = maxf(hs0, recent - 7.0 * dt)

	var ax := _axes()
	var f := ax.y
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var wish := fwd * f + right * ax.x
	var has := wish.length() > 0.01
	if has:
		wish = wish.normalized()

	if st == "spec":
		_step_spec(dt, ax, fwd, right)
		return
	if frozen:
		velocity = Vector3.ZERO
		return
	if st == "mantle":
		_step_mantle(dt, f, fwd)
		return
	if st == "hang":
		_step_hang(f)
		return

	_update_stamina(dt, has)
	var run := 3.5 if (h < HS - 0.01 and st == "move") else (sprint_speed if sprinting else run_speed)
	var hs := hs0

	# ---- velocity update for the current state
	match st:
		"move":
			if grounded:
				_ground_move(dt, has, wish, hs, run)
			else:
				_air_move(dt, has, wish, hs)
		"slide":
			_slide_move(dt, has, wish)
		"wall":
			st_t += dt
			var n := Vector3(wall_n.x, 0, wall_n.y)
			var along := Vector3(-n.z, 0, n.x)
			if along.dot(velocity) < 0.0:
				along = -along
			wr_speed = maxf(wr_speed - 0.5 * dt, 0.0)
			var hv := along * wr_speed - n * 0.8
			velocity = Vector3(hv.x, maxf(velocity.y - GRAV * 0.36 * dt, -4.0), hv.z)
		"climb":
			st_t += dt
			velocity.y -= GRAV * 0.55 * dt
			var touching := world.wall_probe(position, wall_n, 0.06, 0.3, 1.8) != null
			var v := 1.0 if touching else climb_v
			velocity.x = -wall_n.x * v
			velocity.z = -wall_n.y * v
		"roll":
			st_t += dt
			_scale_h(maxf(hs - 1.2 * dt, 0.0), hs)
			velocity.y = -1.0 if grounded else velocity.y - GRAV * dt
			if st_t > 0.5:
				st = "move"
		"stun":
			stun_t -= dt
			_scale_h(maxf(hs - 20.0 * dt, 0.0), hs)
			velocity.y = -1.0 if grounded else velocity.y - GRAV * dt
			if stun_t <= 0.0:
				st = "move"
	var sp := hspeed()
	if sp > VMAX:
		_scale_h(VMAX, sp)

	# ---- grounded actions
	if grounded and (st == "move" or st == "slide"):
		if jump_buf > 0.0:
			var fn := _front_normal(fwd, 0.72)
			var wb: World.Box = null
			if fn != Vector2i.ZERO and f > 0.0 and not climb_used:
				wb = world.wall_probe(position, fn, 1.2, 0.5, 1.7)
			if wb != null and wb.y1 - position.y > 1.4 and st == "move":
				jump_buf = 0.0
				_start_climb(fn, wb)
			else:
				jump_buf = 0.0
				velocity.y = JUMP
				grounded = false
				coyote = 0.0
				if st == "slide":
					var hh := hspeed()
					_scale_h(minf(hh + 0.8, VMAX), hh)
					_combo("Saut glissé")
					sfx.emit("slide_off", 0.0)
				st = "move"
				sfx.emit("jump", 1.0)
		elif st == "move" and slide_buf < 0.12 and hs > 4.5:
			slide_buf = 9.0
			_start_slide(false)
	elif not grounded and st == "move" and coyote > 0.0 and jump_buf > 0.0:
		jump_buf = 0.0
		velocity.y = JUMP
		coyote = 0.0
		sfx.emit("jump", 1.0)

	# ---- move
	var was_g := grounded
	var pre_vy := velocity.y
	move_and_slide()
	var g := is_on_floor() and st != "climb"
	if g and not was_g:
		_on_land(-pre_vy, fwd)
	grounded = g
	if g:
		coyote = 0.1
		climb_used = false
		last_wall_key = ""
		air_t = 0.0
	else:
		coyote -= dt
		air_t += dt
		if st == "slide":
			st = "move"
			sfx.emit("slide_off", 0.0)
		if st == "roll":
			st = "move"

	# ---- crouch / stand
	if st == "slide" or st == "roll":
		set_height(HL)
	elif h < HS and world.is_free(position.x, position.y, position.z, HS):
		set_height(HS)

	# ---- ledges and vaults
	hs = hspeed()
	if ledge_cd <= 0.0 and (st == "move" or st == "climb"):
		var fn := _front_normal(fwd, 0.6)
		if fn != Vector2i.ZERO:
			var reach := maxf(hs, recent)
			if grounded and f > 0.0 and reach > 2.5:
				var l := world.find_ledge(position, h, fn, 0.25, 1.4, 0.3 + reach * 0.05)
				if not l.is_empty():
					_start_mantle(l, "vault", f)
					return
			elif not grounded and (f > 0.0 or (velocity.y < 0.0 and st == "move")):
				var l := world.find_ledge(position, h, fn, 0.3, 2.4, 0.5)
				if not l.is_empty():
					var rel: float = l.top - position.y
					if rel <= 1.45 and f > 0.0:
						_start_mantle(l, "vault", f)
						return
					if f > 0.0:
						_start_mantle(l, "climb", f)
						return
					if rel > 1.45:
						_start_hang(l, fn)
						return

	# ---- walls while airborne
	if not grounded and st == "move":
		var fn := _front_normal(fwd, 0.72)
		var fb: World.Box = world.wall_probe(position, fn, 0.45, 0.4, 1.7) if fn != Vector2i.ZERO else null
		# running into a tall wall just after a jump turns into a wall climb
		if fb != null and f > 0.0 and not climb_used and velocity.y > 0.0 and air_t < 0.5 and fb.y1 - position.y > 1.4 \
				and world.wall_probe(position, fn, 0.08, 0.4, 1.7) != null:
			_start_climb(fn, fb)
			return
		if jump_buf > 0.0:
			if fb != null and fb.y1 - position.y > 1.4 and not climb_used and air_t < 0.45 and velocity.y > -3.0:
				jump_buf = 0.0
				_start_climb(fn, fb)
				return
			for n in AXES:
				if n == fn:
					continue   # a wall straight ahead gives no wall jump
				var b := world.wall_probe(position, n, 0.3, 0.4, 1.6)
				if b != null and World.wall_key(n, b) != last_wall_key:
					jump_buf = 0.0
					last_wall_key = World.wall_key(n, b)
					velocity.x += n.x * 5.5
					velocity.z += n.y * 5.5
					velocity.y = JUMP * 0.95
					_combo("Saut mural")
					sfx.emit("jump", 1.0)
					return
		if f > 0.0 and hs >= 5.0 and velocity.y > -6.0:
			var vd := Vector2(velocity.x, velocity.z) / hs
			for n in AXES:
				if absf(vd.x * n.x + vd.y * n.y) > 0.7:
					continue
				var b := world.wall_probe(position, n, 0.3, 0.3, 1.6)
				if b != null and b.y1 > position.y + 1.5 and World.wall_key(n, b) != last_wall_key:
					_start_wallrun(n, b, hs, right)
					break
	elif st == "wall":
		var n := Vector3(wall_n.x, 0, wall_n.y)
		var b := world.wall_probe(position, wall_n, 0.3, 0.3, 1.6)
		var along := Vector3(-n.z, 0, n.x)
		if along.dot(velocity) < 0.0:
			along = -along
		if jump_buf > 0.0:
			jump_buf = 0.0
			var s := minf(wr_speed + 1.0, VMAX)
			var hv := along * s + n * 5.5
			velocity = Vector3(hv.x, JUMP * 0.95, hv.z)
			st = "move"
			_combo("Saut mural")
			sfx.emit("jump", 1.0)
		elif b == null or st_t > 1.5 or f <= 0.0 or slide_buf < 0.05 or grounded:
			st = "move"
			velocity.x += n.x * 1.2
			velocity.z += n.z * 1.2
	elif st == "climb":
		var b := world.wall_probe(position, wall_n, 1.3 if st_t < 0.3 else 0.45, 0.3, 1.8)
		if b == null or velocity.y < -1.5:
			st = "move"
			velocity.x = wall_n.x * 0.6
			velocity.z = wall_n.y * 0.6


## Sprint only counts on the ground while running upright. Leaving the ground
## keeps the speed already gained but stops draining the bar.
func _update_stamina(dt: float, moving: bool) -> void:
	sprinting = grounded and st == "move" and moving and h >= HS - 0.01 and not exhausted and sprint_held()
	if sprinting:
		stamina -= STAMINA_DRAIN * dt
		_regen_wait = STAMINA_REGEN_DELAY
		if stamina <= 0.0:
			stamina = 0.0
			exhausted = true
			sprinting = false
	else:
		_regen_wait -= dt
		if _regen_wait <= 0.0:
			stamina = minf(stamina + STAMINA_REGEN * dt, 1.0)
		if exhausted and stamina >= STAMINA_RECOVER:
			exhausted = false


func _scale_h(new_speed: float, cur: float) -> void:
	if cur <= 0.0001:
		return
	velocity.x *= new_speed / cur
	velocity.z *= new_speed / cur


func _ground_move(dt: float, has: bool, wish: Vector3, hs: float, run: float) -> void:
	if has:
		if hs <= run + 0.05:
			var target := Vector2(wish.x, wish.z) * run
			var cur := Vector2(velocity.x, velocity.z).move_toward(target, 32.0 * dt)
			velocity.x = cur.x
			velocity.z = cur.y
		else:
			# above running speed: keep the momentum, steer, bleed speed slowly
			var cur_a := atan2(velocity.x, velocity.z)
			var d := angle_difference(cur_a, atan2(wish.x, wish.z))
			var sp := hs
			var ang := cur_a
			if absf(d) > 2.2:
				sp = maxf(hs - 26.0 * dt, 0.0)
			else:
				var rot := clampf(d, -5.0 * dt, 5.0 * dt)
				ang = cur_a + rot
				sp = maxf(hs - absf(rot) * 2.0 - 1.7 * dt, run)
			velocity.x = sin(ang) * sp
			velocity.z = cos(ang) * sp
	else:
		_scale_h(maxf(hs - 30.0 * dt, 0.0), hs)
	velocity.y = -1.0


func _air_move(dt: float, has: bool, wish: Vector3, hs: float) -> void:
	velocity.y -= GRAV * dt
	if not has:
		return
	if hs < 5.0:
		velocity.x += wish.x * 14.0 * dt
		velocity.z += wish.z * 14.0 * dt
		var n := hspeed()
		var cap := maxf(hs, 5.0)
		if n > cap:
			_scale_h(cap, n)
	else:
		var cur_a := atan2(velocity.x, velocity.z)
		var d := angle_difference(cur_a, atan2(wish.x, wish.z))
		if absf(d) < 1.9:
			var ang := cur_a + clampf(d, -2.2 * dt, 2.2 * dt)
			velocity.x = sin(ang) * hs
			velocity.z = cos(ang) * hs
		else:
			_scale_h(hs - 5.0 * dt, hs)


func _slide_move(dt: float, has: bool, wish: Vector3) -> void:
	st_t += dt
	var friction := 2.0
	var r := world.ramp_at(position.x, position.z) if grounded else null
	if r != null:   # gravity pulls along the slope
		var gr := r.grade()
		var acc := GRAV * gr / sqrt(1.0 + gr * gr) * 0.9
		var dh := r.downhill()
		velocity.x += dh.x * acc * dt
		velocity.z += dh.z * acc * dt
		friction = 0.6
	var hs := hspeed()
	if hs > 0.0:
		var ang := atan2(velocity.x, velocity.z)
		if has:
			ang += clampf(angle_difference(ang, atan2(wish.x, wish.z)), -1.3 * dt, 1.3 * dt)
		var ns := maxf(hs - friction * dt, 0.0)
		velocity.x = sin(ang) * ns
		velocity.z = cos(ang) * ns
	velocity.y = -1.0
	var blocked := not world.is_free(position.x, position.y, position.z, HS)
	var slow := hspeed() < 2.8
	if (slow or (not slide_held() and st_t > 0.3)) and not blocked:
		st = "move"
		sfx.emit("slide_off", 0.0)
	elif slow and blocked:
		st = "move"
		sfx.emit("slide_off", 0.0)


func _start_slide(from_landing: bool) -> void:
	st = "slide"
	st_t = 0.0
	set_height(HL)
	var hs := hspeed()
	if slide_boost_cd <= 0.0 and hs > 0.1:
		_scale_h(minf(hs + 2.2, VMAX), hs)
		slide_boost_cd = 1.2
	_combo("Réception glissée" if from_landing else "Glissade")
	sfx.emit("slide_on", 0.0)


func _start_roll(hs: float, fwd: Vector3) -> void:
	var d := Vector2(velocity.x, velocity.z)
	d = Vector2(fwd.x, fwd.z) if d.length() < 1.0 else d.normalized()
	var s := maxf(hs, 6.5)
	st = "roll"
	st_t = 0.0
	velocity.x = d.x * s
	velocity.z = d.y * s
	set_height(HL)
	_combo("Roulade")
	sfx.emit("land", 0.5)


func _on_land(impact: float, fwd: Vector3) -> void:
	var hs := hspeed()
	if st == "climb" or st == "wall":
		st = "move"
	dip = minf(impact * 0.012, 0.28)
	if impact > 13.5:
		if slide_buf < 0.45 or slide_held():
			_start_roll(hs, fwd)
			return
		st = "stun"
		if impact > 18.0:
			stun_t = 0.7
			_scale_h(hs * 0.12, hs)
			shake = 0.5
			notice.emit("Mauvaise réception")
		else:
			stun_t = 0.25
			_scale_h(hs * 0.5, hs)
			shake = 0.25
		sfx.emit("land", 1.0)
		return
	sfx.emit("land", minf(impact / 12.0, 0.8))
	if slide_held() and hs > 4.5 and st == "move":
		_start_slide(true)


func _start_mantle(l: Dictionary, kind: String, f: float) -> void:
	var hs := maxf(recent, hspeed())
	var exit := hs + (0.7 if hs > 5.0 else 0.0) if kind == "vault" else maxf(hs, 6.5) + 1.6
	mantle = {"from": position, "to": Vector3(l.tx, l.top, l.tz), "t": 0.0, "dur": 0.17 if kind == "vault" else 0.3, "exit": clampf(exit, 0.0, VMAX), "n": l.n}
	st = "mantle"
	velocity = Vector3.ZERO
	set_height(HL)
	hang = {}
	_combo("Franchissement" if kind == "vault" else "Escalade")
	sfx.emit("grab", 1.0)


func _step_mantle(dt: float, f: float, fwd: Vector3) -> void:
	mantle.t += dt
	var u := minf(float(mantle.t) / float(mantle.dur), 1.0)
	var a: Vector3 = mantle.from
	var b: Vector3 = mantle.to
	var k := _ease(clampf((u - 0.3) / 0.7, 0.0, 1.0))
	var y := lerpf(a.y, b.y, 1.0 - pow(1.0 - minf(u / 0.6, 1.0), 3.0))
	position = Vector3(lerpf(a.x, b.x, k), y, lerpf(a.z, b.z, k))
	if u >= 1.0:
		var n: Vector2i = mantle.n
		var dir := Vector3(-n.x, 0, -n.y)
		if fwd.dot(dir) > 0.4:
			dir = fwd
		var sp: float = mantle.exit if f > 0.0 else minf(mantle.exit, 2.0)
		velocity = Vector3(dir.x * sp, -1.0, dir.z * sp)
		st = "move"
		grounded = true
		mantle = {}
		ledge_cd = 0.2


func _start_hang(l: Dictionary, fn: Vector2i) -> void:
	st = "hang"
	hang = l
	var face: float = l.face
	var p := position
	p.y = float(l.top) - 1.95
	if fn.x != 0:
		p.x = face + fn.x * (R + 0.01)
	if fn.y != 0:
		p.z = face + fn.y * (R + 0.01)
	position = p
	velocity = Vector3.ZERO
	sfx.emit("grab", 1.0)
	notice.emit("Accroché : avance pour grimper, Ctrl pour lâcher")


func _step_hang(f: float) -> void:
	velocity = Vector3.ZERO
	if f > 0.0 or jump_buf > 0.0:
		jump_buf = 0.0
		_start_mantle(hang, "climb", 1.0)
	elif slide_buf < 0.05:
		hang = {}
		st = "move"
		ledge_cd = 0.5


func _start_wallrun(n: Vector2i, b: World.Box, hs: float, right: Vector3) -> void:
	st = "wall"
	st_t = 0.0
	wall_n = n
	wr_speed = minf(maxf(hs, 7.5) + 0.6, VMAX)
	velocity.y = maxf(velocity.y, 3.0)
	last_wall_key = World.wall_key(n, b)
	var sgn := signf(n.x * right.x + n.y * right.z)
	wall_side = int(sgn) if sgn != 0.0 else 1
	_combo("Course murale")


func _start_climb(n: Vector2i, b: World.Box) -> void:
	st = "climb"
	st_t = 0.0
	wall_n = n
	climb_used = true
	grounded = false
	climb_v = maxf(absf(velocity.x * n.x + velocity.z * n.y), 4.0)
	velocity = Vector3(-n.x * climb_v, 7.4, -n.y * climb_v)
	last_wall_key = World.wall_key(n, b)
	_combo("Grimpe")


func _step_spec(dt: float, ax: Vector2, fwd: Vector3, right: Vector3) -> void:
	var cp := cos(pitch)
	var v := fwd * cp * ax.y + right * ax.x + Vector3.UP * sin(pitch) * ax.y
	if input_enabled and Input.is_action_pressed("jump"):
		v.y += 1.0
	if slide_held():
		v.y -= 1.0
	position += v * 16.0 * dt
	position.y = maxf(position.y, 0.5)
	velocity = Vector3.ZERO


# ------------------------------------------------------------------ camera

func _process(dt: float) -> void:
	var hs := hspeed()
	eye = lerpf(eye, h - 0.18, 1.0 - exp(-dt * 14.0))
	dip = maxf(0.0, dip - dt * 0.9)
	var bob_y := 0.0
	if st == "move" and grounded and hs > 1.0:
		bob += hs * dt * 1.3
		bob_y = sin(bob * 2.0) * 0.035 * minf(hs / 8.0, 1.0)
		step_acc += hs * dt
		if step_acc > 2.2:
			step_acc = 0.0
			sfx.emit("step", 0.6)
	var roll_target := 0.0
	var pitch_fx := 0.0
	if st == "wall":
		roll_target = -wall_side * 0.2
	elif st == "roll":
		pitch_fx = -_ease(clampf(st_t / 0.5, 0.0, 1.0)) * TAU
	elif st == "mantle" and not mantle.is_empty():
		pitch_fx = -sin(float(mantle.t) / float(mantle.dur) * PI) * 0.18
	cam_roll = lerpf(cam_roll, roll_target, 1.0 - exp(-dt * 10.0))
	var sh := Vector2.ZERO
	if shake > 0.0:
		shake -= dt
		sh = Vector2(randf() - 0.5, randf() - 0.5) * shake * 0.2
	head.position = Vector3(sh.x, (1.6 if st == "spec" else eye) + bob_y - dip + sh.y, 0)
	head.rotation = Vector3(0, yaw, 0)
	camera.rotation = Vector3(pitch + pitch_fx, 0, cam_roll)
	camera.fov = lerpf(camera.fov, 78.0 + clampf((hs - 7.0) * 1.8, 0.0, 18.0), 1.0 - exp(-dt * 6.0))
