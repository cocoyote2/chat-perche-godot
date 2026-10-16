extends SceneTree
## Scripted parkour scenarios, run headless:
##   godot --headless --fixed-fps 120 -s res://tests/parkour_test.gd
## Each scenario drives the Player with fake input and checks where it ends up.

var world: World
var p: Player
var failures := 0
var max_v := 0.0


func _initialize() -> void:
	world = World.new()
	root.add_child(world)
	world.generate()
	world.build_collision()
	p = Player.new()
	p.world = world
	p.sim = true
	world.add_child(p)
	_run.call_deferred()


func _run() -> void:
	for i in 3:
		await physics_frame

	# An outer building of ~4 m and a clear stretch of street in front of its +X face.
	var rec: Dictionary = world.buildings[0]
	var part: Array = rec.parts[0]
	for q in rec.parts:
		if q[1] >= part[1]:
			part = q
	var face: float = part[1]
	var top: float = part[4]
	var z := _clear_z(face, part[2] + 1.5, part[3] - 1.5)
	print("building +X face x=%.2f top=%.2f lane z=%.2f" % [face, top, z])

	# 1. run at the wall, jump: wall climb, but no grab without a second Space press
	p.set_pos(Vector3(face + 4.5, 0, z), PI / 2)
	var log := await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "jump": true, "t": 1.4}])
	_check("grimpe sans Espace : pas de hissage", "climb" in log and not "mantle" in log and p.position.y < top - 0.5, log)

	# 1b. Space again near the top: grab the ledge and pull up onto the roof
	p.set_pos(Vector3(face + 4.5, 0, z), PI / 2)
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "jump": true, "t": 0.2}, {"ax": Vector2(0, 1), "jump": true, "t": 1.0}])
	_check("Espace au rebord : escalade d'un mur de %.1f m" % top, p.position.y >= top - 0.05 and "mantle" in log, log)

	# 2. slide: starts at the running speed, no boost
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)   # outer street, facing +X
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.6}])
	var before := p.hspeed()
	log += await _sim([{"ax": Vector2(0, 1), "slide": true, "slide_press": true, "t": 0.1}])
	_check("glissade à la vitesse de course (%.1f -> %.1f m/s)" % [before, p.hspeed()], absf(p.hspeed() - before) < 0.3 and p.st == "slide", log)

	# 3. wall run along the +X face
	p.set_pos(Vector3(face + 0.5, 0, part[3] + 0.5), 0.0)   # facing -Z, wall on the left
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.5}, {"ax": Vector2(-1, 1), "jump": true, "t": 0.12}, {"ax": Vector2(0, 1), "t": 0.6}])
	_check("course murale", "wall" in log, log)
	log = await _sim([{"ax": Vector2(0, 1), "jump": true, "t": 0.3}])
	_check("saut depuis la course murale", p.st == "move" and not p.grounded and p.velocity.y > 0.0, log)

	# 4. high fall with a roll, then without
	var tall := _tallest_building()
	var tz: float = (tall.z0 + tall.z1) / 2.0
	p.set_pos(Vector3(tall.x1 - 1.0, tall.h, tz), -PI / 2)   # facing +X, off the edge
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.6}, {"ax": Vector2(0, 0), "t": 0.75, "slide_at": 0.55}, {"ax": Vector2(0, 0), "t": 0.6}])
	_check("roulade après %.0f m de chute" % tall.h, "roll" in log, log)
	p.set_pos(Vector3(tall.x1 - 1.0, tall.h, tz), -PI / 2)
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.6}, {"ax": Vector2(0, 0), "t": 1.4}])
	_check("mauvaise réception sans roulade", "stun" in log, log)

	# 5. falling back down past the ledge without pushing forward: Space still grabs it
	p.set_pos(Vector3(face + 4.5, 0, z), PI / 2)
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "jump": true, "t": 0.2}, {"ax": Vector2(0, 0), "t": 0.85}, {"ax": Vector2(0, 0), "jump": true, "t": 0.6}])
	_check("en retombant, Espace pour s'agripper et se hisser", "mantle" in log and p.position.y >= top - 0.05, log)

	# 6. slide down a ramp: gravity adds speed
	var r: World.Ramp = world.ramps[0]
	var mid_x := (r.x0 + r.x1) / 2.0
	p.set_pos(Vector3(mid_x, r.hi + 0.05, r.z1 + 0.6), 0.0)   # on the roof, facing -Z down the ramp
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.45}, {"ax": Vector2(0, 1), "slide": true, "slide_press": true, "t": 1.0}])
	_check("glissade sur rampe (pointe à %.1f m/s)" % max_v, max_v > 11.0 and "slide" in log, log)

	# 7. sprint on the ground with Shift, drains stamina
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)
	p.stamina = 1.0
	log = await _sim([{"ax": Vector2(0, 1), "sprint": true, "t": 0.8}])
	_check("sprint au sol (%.1f m/s, endurance %.0f %%)" % [p.hspeed(), p.stamina * 100.0], p.hspeed() > 10.0 and p.stamina < 0.9, log)

	# 8. no stamina used in the air, even with Shift held
	var before_air := p.stamina
	log = await _sim([{"ax": Vector2(0, 1), "sprint": true, "jump": true, "t": 0.5}])
	_check("pas de sprint en l'air (endurance %.2f -> %.2f)" % [before_air, p.stamina], p.stamina >= before_air - 0.005, log)

	# 9. an empty bar locks the sprint until it recovers
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)
	p.stamina = 0.03
	log = await _sim([{"ax": Vector2(0, 1), "sprint": true, "t": 1.0}])
	_check("endurance vide : sprint bloqué (%.1f m/s)" % p.hspeed(), p.exhausted and p.hspeed() <= Player.RUN_RUNNER + 0.6, log)
	log = await _sim([{"ax": Vector2(0, 0), "t": 2.2}])
	_check("endurance qui remonte (%.0f %%)" % (p.stamina * 100.0), not p.exhausted and p.stamina >= Player.STAMINA_RECOVER, log)

	# 10. jumping during a wall climb no longer turns the runner around
	p.set_pos(Vector3(face + 4.5, 0, z), PI / 2)
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "jump": true, "t": 0.2}])
	var yaw_before := p.yaw
	var was_climbing := p.st == "climb"
	log += await _sim([{"ax": Vector2(0, 0), "jump": true, "t": 0.4}])
	_check("plus de demi-tour mural", was_climbing and is_equal_approx(p.yaw, yaw_before), log)

	# 11. spamming slide-jumps with Ctrl held bleeds the speed down to running pace
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)
	p.stamina = 1.0
	log = await _sim([{"ax": Vector2(0, 1), "sprint": true, "t": 0.8}])
	before = p.hspeed()
	var jumps := [0]
	var count := func(label: String) -> void:
		if label == "Saut glissé":
			jumps[0] += 1
	p.move_done.connect(count)
	log += await _sim([{"ax": Vector2(0, 1), "slide": true, "slide_press": true, "spam_jump": true, "t": 2.4}])
	p.move_done.disconnect(count)
	_check("spam du saut glissé : %d sauts, %.1f -> %.1f m/s (pointe %.1f)" % [jumps[0], before, p.hspeed(), max_v],
		jumps[0] >= 3 and max_v <= before + 0.9 and p.hspeed() <= Player.RUN_RUNNER + 0.3, log)

	print("\n%s" % ("TOUS LES TESTS PASSENT" if failures == 0 else "%d ÉCHEC(S)" % failures))
	quit(1 if failures > 0 else 0)


func _sim(steps: Array) -> String:
	var out := ""
	var last := ""
	var t := 0.0
	max_v = 0.0
	for s in steps:
		p.sim_axes = s.get("ax", Vector2.ZERO)
		p.sim_slide = s.get("slide", false)
		p.sim_sprint = s.get("sprint", false)
		if s.get("jump", false):
			p.jump_buf = 0.15
		if s.get("slide_press", false):
			p.slide_buf = 0.0
		var n := int(round(float(s.t) * 120.0))
		var slide_at: float = s.get("slide_at", -1.0)
		for i in n:
			if slide_at >= 0.0 and absf(i / 120.0 - slide_at) < 0.004:
				p.slide_buf = 0.0
			if s.get("spam_jump", false) and p.st == "slide":
				p.jump_buf = 0.15
			await physics_frame
			t += 1.0 / 120.0
			max_v = maxf(max_v, p.hspeed())
			var st := p.st + ("/g" if p.grounded else "/a")
			if st != last:
				out += "  %.2fs %-9s y=%5.2f v=%4.1f\n" % [t, st, p.position.y, p.hspeed()]
				last = st
	return out


func _check(name: String, ok: bool, log: String) -> void:
	print("%s  %s" % ["OK   " if ok else "ÉCHEC", name])
	if not ok:
		failures += 1
		print(log)
		print("  fin : pos=%s st=%s v=%.1f" % [p.position, p.st, p.hspeed()])


func _clear_z(face: float, z0: float, z1: float) -> float:
	var z := (z0 + z1) / 2.0
	for k in 20:
		var cand := lerpf(z0, z1, k / 19.0)
		if world.box_hit(face + 0.05, 0.05, cand - 0.6, face + 5.0, 1.8, cand + 0.6) == null:
			return cand
	return z


func _tallest_building() -> Dictionary:
	var best: Dictionary = {}
	for rec in world.buildings:
		if rec != null and rec.parts.size() == 1 and (best.is_empty() or rec.h > best.h):
			best = rec
	return best

