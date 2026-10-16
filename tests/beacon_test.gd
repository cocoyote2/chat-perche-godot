extends SceneTree
## Beacon rules on the server, without a network: one runner (us) and a fake hunter.
##   godot --headless -s res://tests/beacon_test.gd

var net: Node
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	net = root.get_node("Net")
	net.set_process(false)   # the test drives the server clock itself
	var world := World.new()
	world.generate()
	var spots: Array[Vector3] = world.beacon_spots
	var all_free := true
	for s in spots:
		if not world.is_free(s.x, s.y, s.z, World.HS):
			all_free = false
	_check("%d emplacements de balise, tous dégagés" % spots.size(), spots.size() >= 20 and all_free)

	net.start_solo()
	net.beacon_spots = spots
	net.players[2] = {"name": "Chasseur", "color": 1}
	net._new_round()
	var g: Dictionary = net.g
	g.h = 2
	g.ph = "run"
	g.t = net.ROUND_T
	var me: int = net.me()
	var far := Vector3(500, 0, 500)   # away from every spot
	net.local_pos = far

	_tick(net.BEACON_FIRST - 1.0)
	_check("pas de balise avant %d s de chasse" % int(net.BEACON_FIRST), g.b.is_empty())
	_tick(1.5)
	var ps: Array = g.b.get("p", [])
	_check("%d balises apparaissent ensemble" % ps.size(), ps.size() == net.BEACON_COUNT and ps.all(func(p): return spots.has(p)))
	if ps.size() != net.BEACON_COUNT:
		return _done()
	_check("espacées d'au moins %d m (min %.0f m)" % [int(net.BEACON_SPREAD), _min_gap(ps, ps)], _min_gap(ps, ps) >= net.BEACON_SPREAD)

	var first: Array = ps.duplicate()
	var score_before := float(g.sc.get(me, 0.0))
	net.local_pos = ps[1] + Vector3(1.5, 0, 0)
	_tick(0.2)
	var gained := float(g.sc.get(me, 0.0)) - score_before
	_check("atteindre une balise : validée et +%d (gagné %.0f)" % [int(net.BEACON_PTS), gained],
		(g.b.ok[1] as Array).has(me) and not (g.b.ok[0] as Array).has(me) and gained >= net.BEACON_PTS)
	net.local_pos = ps[2] + Vector3(0, 0, 1.0)
	_tick(0.2)
	_check("une deuxième balise rapporte encore +%d" % int(net.BEACON_PTS), float(g.sc.get(me, 0.0)) - score_before >= 2.0 * net.BEACON_PTS)
	net.local_pos = far
	_tick_until(func() -> bool: return g.b.is_empty(), net.BEACON_T + 1.0)
	_check("une balise suffit : pas repéré à la fermeture", (g.rv as Array).is_empty())

	_tick(net.BEACON_GAP + 0.5)
	var second: Array = g.b.get("p", [])
	_check("nouvelle vague à %.0f m au moins de la précédente" % _min_gap(second, first),
		second.size() == net.BEACON_COUNT and _min_gap(second, first) >= net.BEACON_MIN_MOVE)
	_tick_until(func() -> bool: return g.b.is_empty(), net.BEACON_T + 1.0)
	_check("aucune balise atteinte : repéré %.1f s" % float(g.rvt), (g.rv as Array) == [me] and float(g.rvt) > net.REVEAL_T - 0.5)
	_tick(net.REVEAL_T + 0.5)
	_check("le repérage s'arrête ensuite", (g.rv as Array).is_empty())

	world.free()
	_done()


## Smallest distance between a point of a and a different point of b.
func _min_gap(a: Array, b: Array) -> float:
	var m := INF
	for p: Vector3 in a:
		for q: Vector3 in b:
			if p != q:
				m = minf(m, p.distance_to(q))
	return m


func _tick(seconds: float) -> void:
	var dt := 0.1
	for i in int(round(seconds / dt)):
		net._host_tick(dt)


func _tick_until(cond: Callable, max_seconds: float) -> void:
	var dt := 0.1
	for i in int(round(max_seconds / dt)):
		if cond.call():
			return
		net._host_tick(dt)


func _check(name: String, ok: bool) -> void:
	print("%s  %s" % ["OK   " if ok else "ÉCHEC", name])
	if not ok:
		failures += 1


func _done() -> void:
	print("\n%s" % ("TOUS LES TESTS PASSENT" if failures == 0 else "%d ÉCHEC(S)" % failures))
	quit(1 if failures > 0 else 0)
