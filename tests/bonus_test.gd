extends SceneTree
## Bonus rules on the server, without a network: one runner (us) and a fake hunter.
##   godot --headless -s res://tests/bonus_test.gd

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
	net.start_solo()
	net.beacon_spots = world.beacon_spots
	net.players[2] = {"name": "Chasseur", "color": 1}
	net._new_round()
	var g: Dictionary = net.g
	g.h = 2
	var me: int = net.me()
	var far := Vector3(500, 0, 500)
	net.local_pos = far

	_check("%d bonus au début de la manche" % (g.pu as Array).size(), (g.pu as Array).size() == net.BONUS_START)
	_check("écartés d'au moins %d m" % int(net.BONUS_GAP), _spread_ok(g.pu))
	g.ph = "run"
	g.t = net.ROUND_T
	g.bn = 999.0   # no beacons in the way
	_tick(net.BONUS_EVERY * 4.0)
	_check("puis un de plus toutes les %d s, %d au plus" % [int(net.BONUS_EVERY), net.BONUS_MAX], (g.pu as Array).size() == net.BONUS_MAX and _spread_ok(g.pu))

	# walk onto a bonus: it disappears and its effect lasts its duration
	var bonus: Dictionary = g.pu[0]
	bonus.k = "speed"
	net.local_pos = bonus.p + Vector3(1.0, 0, 0)
	_tick(0.2)
	var fx: Dictionary = g.fx.get(me, {})
	_check("ramassé : effet Turbo, bonus retiré", str(fx.get("k", "")) == "speed" and not (g.pu as Array).has(bonus))
	net.local_pos = far
	_tick(net.BONUS_DUR["speed"] + 0.3)
	_check("l'effet s'arrête après %d s" % int(net.BONUS_DUR["speed"]), not g.fx.has(me))

	# the hunter picking a shield gets a sonar recharge instead
	net.states[2] = [{"t": 0, "d": PackedFloat32Array([far.x + 30.0, far.y, far.z, 0, 0, 0, 0, 0, 0, 1.8])}]
	(g.pu as Array).append({"p": Vector3(far.x + 30.0, far.y, far.z), "k": "shield", "id": 1000})
	_tick(0.2)
	_check("le chasseur ramasse un bouclier : sonar rechargé", str(g.fx.get(2, {}).get("k", "")) == "sonar")

	# a shield blocks one tag, then the next tag catches (the round ends there)
	g.fx[me] = {"k": "shield", "t": 10.0, "n": 99}
	var blocked := [0]
	net.shield_event.connect(func(_t, _h): blocked[0] += 1)
	net.states[2] = [{"t": 0, "d": PackedFloat32Array([far.x + 1.0, far.y, far.z, 0, 0, 0, 0, 0, 0, 1.8])}]
	net._srv_tag_from(2, me)
	_check("bouclier : la touche est bloquée et le bouclier consommé", blocked[0] == 1 and not (g.c as Array).has(me) and not g.fx.has(me))
	net._srv_tag_from(2, me)
	_check("sans bouclier, la touche suivante attrape", (g.c as Array).has(me))

	world.free()
	_done()


func _spread_ok(list: Array) -> bool:
	for a in list:
		for b in list:
			if a != b and (a.p as Vector3).distance_to(b.p) < net.BONUS_GAP:
				return false
	return true


func _tick(seconds: float) -> void:
	var dt := 0.1
	for i in int(round(seconds / dt)):
		net._host_tick(dt)


func _check(name: String, ok: bool) -> void:
	print("%s  %s" % ["OK   " if ok else "ÉCHEC", name])
	if not ok:
		failures += 1


func _done() -> void:
	print("\n%s" % ("TOUS LES TESTS PASSENT" if failures == 0 else "%d ÉCHEC(S)" % failures))
	quit(1 if failures > 0 else 0)
