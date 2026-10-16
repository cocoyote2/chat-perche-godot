extends SceneTree
## Scripted parkour scenarios, run headless:
##   godot --headless --fixed-fps 120 -s res://tests/parkour_test.gd
## Each scenario drives the Player with fake input and checks where it ends up.

var world: World
var p: Player
var failures := 0
var max_v := 0.0
var max_y := 0.0


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
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "jump": true, "t": 0.2}, {"ax": Vector2(0, 1), "t": 0.15}, {"ax": Vector2(0, 1), "jump": true, "t": 1.0}])
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
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.6}, {"ax": Vector2(0, 0), "slide": true, "t": 0.9}, {"ax": Vector2(0, 0), "t": 0.6}])
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
	var dh := r.downhill()
	var top_pt := Vector3((r.x0 + r.x1) / 2.0, 0, (r.z0 + r.z1) / 2.0)
	if r.ax == "x":
		top_pt.x = (r.x1 if r.up > 0 else r.x0) + dh.x * 1.0   # 1 m in from the high end
	else:
		top_pt.z = (r.z1 if r.up > 0 else r.z0) + dh.z * 1.0
	top_pt.y = r.y_at(top_pt.x, top_pt.z) + 0.05
	p.set_pos(top_pt, atan2(-dh.x, -dh.z))   # facing down the slope
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

	# 12. bonus "Ressort": higher jumps
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)
	log = await _sim([{"ax": Vector2(0, 0), "t": 0.2}, {"ax": Vector2(0, 0), "jump": true, "t": 0.9}])
	var plain := max_y
	p.jump_mul = 1.4
	log += await _sim([{"ax": Vector2(0, 0), "jump": true, "t": 1.1}])
	p.jump_mul = 1.0
	_check("Ressort : saut de %.2f m au lieu de %.2f m" % [max_y, plain], max_y > plain * 1.7, log)

	# 13. bonus "Second souffle": sprint without using stamina, even while exhausted
	p.set_pos(Vector3(-52.0, 0, (rec.z0 + -58.0) / 2.0), -PI / 2)
	p.stamina = 0.5
	p.exhausted = true
	p.free_sprint = true
	log = await _sim([{"ax": Vector2(0, 1), "sprint": true, "t": 0.8}])
	p.free_sprint = false
	_check("Second souffle : sprint gratuit (%.1f m/s, endurance %.0f %%)" % [p.hspeed(), p.stamina * 100.0], p.hspeed() > 10.0 and p.stamina >= 0.5, log)

	# ---- the map: getting onto the roofs, and chaining for speed

	# 14. a side ramp takes a runner from the street onto the roof
	var sr: World.Ramp = null
	for q in world.ramps:
		if q.thick < 0.0 and q.hi > 4.0 and maxf(q.x1 - q.x0, q.z1 - q.z0) > 10.0:
			sr = q
			break
	var sdn := sr.downhill()
	var along := sr.x1 - sr.x0 if sr.ax == "x" else sr.z1 - sr.z0
	var lowp := Vector3((sr.x0 + sr.x1) / 2.0, 0, (sr.z0 + sr.z1) / 2.0)
	if sr.ax == "x":
		lowp.x = (sr.x0 if sr.up > 0 else sr.x1) + sdn.x * 1.5
	else:
		lowp.z = (sr.z0 if sr.up > 0 else sr.z1) + sdn.z * 1.5
	var ryaw := atan2(sdn.x, sdn.z)   # facing uphill
	var rright := Vector3(cos(ryaw), 0, -sin(ryaw))
	var side_n := Vector3(0, 0, 1) if sr.ax == "x" else Vector3(1, 0, 0)
	var top_end := lowp - sdn * (along + 2.8)   # middle of the flat landing at the top
	var roof_side := 1.0 if world.support_top(top_end.x + side_n.x * 2.0, sr.hi + 0.5, top_end.z + side_n.z * 2.0, 1.0) >= sr.hi - 0.05 else -1.0
	var sgn := signf(rright.dot(side_n * roof_side))
	p.set_pos(lowp, ryaw)
	log = await _sim([{"ax": Vector2(0, 1), "t": (along + 2.8) / 8.0 + 0.15}, {"ax": Vector2(0, 0), "t": 0.2}, {"ax": Vector2(sgn, 0), "t": 0.7}])
	_check("rampe d'accès : de la rue au toit de %.1f m en marchant, sans franchissement (y=%.2f)" % [sr.hi, p.position.y],
		p.position.y >= sr.hi - 0.1 and world.ramp_at(p.position.x, p.position.z, p.position.y) == null and not "mantle" in log, log)

	# 14b. from the street, jump at the side of that ramp and get onto it: a vault
	# where it is low, a grab with Space higher up
	var street_side := -roof_side
	for ylevel in [2.2, 3.2]:
		var gp: Vector3 = lowp - sdn * (1.5 + along * float(ylevel) / sr.hi)   # where the slope is that high
		var gstart: Vector3 = gp + side_n * street_side * (1.3 + 2.0)   # 2 m out from the ramp's street side
		p.set_pos(gstart, atan2(side_n.x * street_side, side_n.z * street_side))   # facing the ramp
		var steps := [{"ax": Vector2(0, 1), "t": 0.25}, {"ax": Vector2(0, 1), "jump": true, "t": 0.15}]
		if ylevel > 3.0:
			steps.append({"ax": Vector2(0, 1), "t": 0.1})
			steps.append({"ax": Vector2(0, 1), "jump": true, "t": 0.15})
		steps.append({"ax": Vector2(0, 0), "t": 0.6})
		log = await _sim(steps)
		var on_ramp := world.ramp_at(p.position.x, p.position.z, p.position.y) == sr
		_check("côté d'une rampe à %.1f m : %s puis sur la rampe" % [ylevel, "franchissement" if ylevel < 3.0 else "Espace pour se hisser"], "mantle" in log and on_ramp, log)

	# 15. crate steps: vault, vault, jump into a wall climb, Space at the top
	var climbed := false
	var tried := 0
	for cs in world.crate_steps:
		var n: Vector2i = cs.n
		var start: Vector3 = cs.p + Vector3(n.x, 0, n.y) * 2.5
		if cs.top > 7.0 or not world.is_free(start.x, 0.0, start.z, World.HS):
			continue
		tried += 1
		p.set_pos(start, atan2(n.x, n.y))
		log = await _sim([{"ax": Vector2(0, 1), "t": 1.0}, {"ax": Vector2(0, 1), "jump": true, "t": 0.25}, {"ax": Vector2(0, 1), "t": 0.15}, {"ax": Vector2(0, 1), "jump": true, "t": 1.2}])
		if p.position.y >= float(cs.top) - 0.05:
			climbed = true
			_check("escalier de caisses : de la rue au toit de %.1f m (%d essai)" % [cs.top, tried], true, log)
			break
		if tried >= 3:
			break
	if not climbed:
		_check("escalier de caisses : de la rue au toit", false, log)

	# 16. a bridge slopes down to the next roof: slide it for speed
	var br: World.Ramp = null
	for q in world.ramps:
		if q.thick > 0.0:
			br = q
			break
	var bdn := br.downhill()
	var bstart := Vector3((br.x0 + br.x1) / 2.0, br.hi, (br.z0 + br.z1) / 2.0)
	if br.ax == "x":
		bstart.x = (br.x1 if br.up > 0 else br.x0) - bdn.x * 2.0
	else:
		bstart.z = (br.z1 if br.up > 0 else br.z0) - bdn.z * 2.0
	p.set_pos(bstart, atan2(-bdn.x, -bdn.z))
	log = await _sim([{"ax": Vector2(0, 1), "t": 0.35}, {"ax": Vector2(0, 1), "slide": true, "slide_press": true, "t": 1.0}])
	_check("toboggan de %.1f à %.1f m : pointe à %.1f m/s, arrivée sur le toit (y=%.2f)" % [br.hi, br.lo, max_v, p.position.y],
		max_v > 9.5 and p.position.y > br.lo - 0.3, log)

	# 17. jump across a street onto a roof 1 to 1.5 m higher: it ends in a vault
	var hop := _find_hop()
	if hop.is_empty():
		_check("saut vers un toit plus haut : aucune paire trouvée", false, "")
	else:
		p.set_pos(hop.start, hop.yaw)
		p.velocity = Vector3(-sin(hop.yaw), 0, -cos(hop.yaw)) * 8.0
		log = await _sim([{"ax": Vector2(0, 1), "t": 0.1}, {"ax": Vector2(0, 1), "jump": true, "t": 1.2}])
		_check("saut par-dessus la rue vers un toit %.1f m plus haut (y=%.2f)" % [hop.up, p.position.y], p.position.y >= float(hop.top) - 0.05, log)

	# 18. every bridge can be walked up from its low end
	var blocked := []
	var bridges := 0
	for q: World.Ramp in world.ramps:
		if q.thick <= 0.0:
			continue
		bridges += 1
		var qdn := q.downhill()
		var qlen := (q.x1 - q.x0) if q.ax == "x" else (q.z1 - q.z0)
		var qs := Vector3((q.x0 + q.x1) / 2.0, q.lo + 0.02, (q.z0 + q.z1) / 2.0) + qdn * (qlen / 2.0 + 1.2)
		p.set_pos(qs, atan2(qdn.x, qdn.z))
		var qlog := await _sim([{"ax": Vector2(0, 1), "t": qlen / 8.0 + 0.6}])
		if max_y < q.hi - 0.15:
			blocked.append("%.1f→%.1f m en %s" % [q.lo, q.hi, qs])
		elif "mantle" in qlog:
			blocked.append("franchissement en haut de %.1f→%.1f m" % [q.lo, q.hi])
	_check("les %d toboggans se montent en marchant%s" % [bridges, "" if blocked.is_empty() else " (%s)" % ", ".join(blocked)], blocked.is_empty(), "")

	print("\n%s" % ("TOUS LES TESTS PASSENT" if failures == 0 else "%d ÉCHEC(S)" % failures))
	quit(1 if failures > 0 else 0)


func _sim(steps: Array) -> String:
	var out := ""
	var last := ""
	var t := 0.0
	max_v = 0.0
	max_y = -INF
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
			max_y = maxf(max_y, p.position.y)
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


## Two neighbouring roofs with the far one 0.9 to 1.6 m higher and a clear street
## in between. Returns {start, yaw, top, up} or {}.
func _find_hop() -> Dictionary:
	for j in 5:
		for i in 4:
			var a = world.buildings[j * 5 + i]
			var c = world.buildings[j * 5 + i + 1]
			if a == null or c == null or a.parts.size() > 1 or c.parts.size() > 1:
				continue
			for pair in [[a, c, 1.0], [c, a, -1.0]]:
				var lo: Dictionary = pair[0]
				var hi: Dictionary = pair[1]
				var dirx: float = pair[2]
				var dh: float = hi.h - lo.h
				if dh < 0.9 or dh > 1.6:
					continue
				var edge: float = lo.x1 if dirx > 0 else lo.x0
				var far_edge: float = hi.x0 if dirx > 0 else hi.x1
				for k in 7:
					var z: float = lerpf(maxf(lo.z0, hi.z0) + 2.0, minf(lo.z1, hi.z1) - 2.0, k / 6.0)
					# clear above our roof and over the street, then above the far roof
					var ax0 := minf(edge - dirx * 2.0, far_edge - dirx * 0.01)
					var ax1 := maxf(edge - dirx * 2.0, far_edge - dirx * 0.01)
					var bx0 := minf(far_edge, far_edge + dirx * 3.0)
					var bx1 := maxf(far_edge, far_edge + dirx * 3.0)
					if world.box_hit(ax0, lo.h + 0.05, z - 0.6, ax1, hi.h + 2.2, z + 0.6) != null:
						continue
					if world.box_hit(bx0, hi.h + 0.05, z - 0.6, bx1, hi.h + 2.2, z + 0.6) != null:
						continue
					if world.ramp_at(edge + dirx * 2.0, z) != null:
						continue
					return {"start": Vector3(edge - dirx * 1.2, lo.h, z), "yaw": -PI / 2 if dirx > 0 else PI / 2, "top": hi.h, "up": dh}
	return {}


func _tallest_building() -> Dictionary:
	var best: Dictionary = {}
	for rec in world.buildings:
		if rec != null and rec.parts.size() == 1 and (best.is_empty() or rec.h > best.h):
			best = rec
	return best

