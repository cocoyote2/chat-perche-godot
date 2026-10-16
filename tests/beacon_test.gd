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
	net.local_pos = Vector3(500, 0, 500)   # far from every spot

	_tick(net.BEACON_FIRST - 1.0)
	_check("pas de balise avant %d s de chasse" % int(net.BEACON_FIRST), g.b.is_empty())
	_tick(1.5)
	_check("une balise apparaît ensuite", not g.b.is_empty() and spots.has(g.b.p))
	if g.b.is_empty():
		return _done()

	var first: Vector3 = g.b.p
	var score_before := float(g.sc.get(me, 0.0))
	net.local_pos = first + Vector3(1.5, 0, 0)
	_tick(0.2)
	var gained := float(g.sc.get(me, 0.0)) - score_before
	_check("atteindre la balise : validée et +%d (gagné %.0f)" % [int(net.BEACON_PTS), gained],
		(g.b.ok as Array).has(me) and gained >= net.BEACON_PTS)
	net.local_pos = Vector3(500, 0, 500)
	_tick(net.BEACON_T)
	_check("balise validée : pas repéré à la fermeture", g.b.is_empty() and (g.rv as Array).is_empty())

	_tick(net.BEACON_GAP + 0.5)
	_check("nouvelle balise à %.0f m de la précédente" % (g.b.p.distance_to(first) if not g.b.is_empty() else 0.0),
		not g.b.is_empty() and g.b.p.distance_to(first) >= net.BEACON_MIN_MOVE)
	_tick_until(func() -> bool: return g.b.is_empty(), net.BEACON_T + 1.0)
	_check("balise ratée : repéré %.1f s" % float(g.rvt), (g.rv as Array) == [me] and float(g.rvt) > net.REVEAL_T - 0.5)
	_tick(net.REVEAL_T + 0.5)
	_check("le repérage s'arrête ensuite", (g.rv as Array).is_empty())

	world.free()
	_done()


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
