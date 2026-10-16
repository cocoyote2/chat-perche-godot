extends Node
## Network session (autoload "Net") and the authoritative game state.
##
## Topology: one ENet server (a player's game, or a dedicated `--server` process)
## and clients. Each client simulates its own runner and broadcasts its state ~30
## times a second (relayed by the server). The server alone runs the round logic:
## phases, who hunts, who is caught, scores. It validates tags against the last
## positions it received and pushes the game state to everyone.
##
## Beacons: during the chase the server keeps putting up a few beacons at random
## spots. Each one reached scores; a runner who reaches none of them in time is
## revealed to the hunter.

signal roster_changed
signal joined
signal session_ended(reason: String)
signal caught_event(target: int, hunter: int)

const PORT := 7777
const MAX_CLIENTS := 15
const HIDE_T := 10.0
const ROUND_T := 150.0
const END_T := 9.0
const BEACON_COUNT := 3      # beacons up at the same time
const BEACON_FIRST := 15.0   # into the chase before the first wave
const BEACON_T := 25.0       # time runners get to reach one of them
const BEACON_GAP := 10.0     # pause between two waves
const BEACON_R := 3.0        # horizontal reach, in metres
const BEACON_SPREAD := 20.0  # beacons of one wave are at least this far apart
const BEACON_MIN_MOVE := 25.0  # ...and this far from those of the last wave
const BEACON_PTS := 50.0     # per beacon reached
const REVEAL_T := 6.0        # runners who missed it show through walls this long

var mode := "none"          # none, solo, host, client
var dedicated := false
var my_name := "Coureur"
var my_color := 0
var players := {}           # peer id -> {"name": String, "color": int}
var states := {}            # peer id -> Array of {"t": msec, "d": PackedFloat32Array}
var g := new_g()
var local_pos := Vector3.ZERO
var beacon_spots: Array[Vector3] = []   # filled from the World, also on a dedicated server
var _last_beacons: Array = []
var _g_acc := 0.0
var _g_seq := 0
var _ending := false


static func new_g() -> Dictionary:
	# b: current wave {p: [Vector3], t, ok: [[ids] per beacon]} or {}; bn: time to
	# the next wave; rv: runners revealed for missing it, rvt: how long they stay so
	return {"ph": "lobby", "r": 0, "h": 0, "t": 0.0, "pl": [], "c": [], "sc": {}, "hc": {}, "w": "",
		"b": {}, "bn": 0.0, "rv": [], "rvt": 0.0, "seq": 0}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _end("Connexion impossible. Vérifie l'adresse et que l'hôte a lancé la partie."))
	multiplayer.server_disconnected.connect(func(): _end("L'hôte a quitté la partie."))


func me() -> int:
	return multiplayer.get_unique_id()


func is_server() -> bool:
	return mode != "none" and multiplayer.is_server()


# ------------------------------------------------------------------ session

func start_solo() -> void:
	_reset()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = "solo"
	players[1] = {"name": my_name, "color": my_color}
	roster_changed.emit()


func start_host(as_dedicated := false) -> Error:
	_reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = "host"
	dedicated = as_dedicated
	if not dedicated:
		players[1] = {"name": my_name, "color": my_color}
	roster_changed.emit()
	return OK


func start_client(address: String) -> Error:
	_reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = "client"
	return OK


func leave() -> void:
	_ending = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = "none"
	_reset()
	_ending = false


func _end(reason: String) -> void:
	if _ending or mode == "none":
		return
	leave()
	session_ended.emit(reason)


func _reset() -> void:
	players.clear()
	states.clear()
	g = new_g()
	_g_seq = 0


func _on_connected() -> void:
	register.rpc_id(1, my_name, my_color)
	joined.emit()


func _on_peer_connected(_id: int) -> void:
	pass   # a client only counts once it has registered


func _on_peer_disconnected(id: int) -> void:
	states.erase(id)
	if multiplayer.is_server() and players.has(id):
		players.erase(id)
		_push_roster.call_deferred()   # after ENet has dropped the leaving peer


@rpc("any_peer", "call_remote", "reliable")
func register(player_name: String, color: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var n := player_name.strip_edges().left(16)
	players[id] = {"name": n if n != "" else "Joueur", "color": clampi(color, 0, 7)}
	_push_roster()
	_push_g(true)


func _push_roster() -> void:
	roster_update.rpc(players)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func roster_update(p: Dictionary) -> void:
	players = p
	roster_changed.emit()


func player_name(id: int) -> String:
	return str(players[id].name) if players.has(id) else "?"


# ------------------------------------------------------------------ runner states

func send_state(d: PackedFloat32Array) -> void:
	local_pos = Vector3(d[0], d[1], d[2])
	if (mode == "host" or mode == "client") and not multiplayer.get_peers().is_empty():
		pstate.rpc(d)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func pstate(d: PackedFloat32Array) -> void:
	if d.size() != 10:
		return
	var id := multiplayer.get_remote_sender_id()
	var buf: Array = states.get(id, [])
	buf.append({"t": Time.get_ticks_msec(), "d": d})
	if buf.size() > 24:
		buf.pop_front()
	states[id] = buf


func pos_of(id: int) -> Variant:
	if id == me() and not dedicated:
		return local_pos
	var buf: Array = states.get(id, [])
	if buf.is_empty():
		return null
	var d: PackedFloat32Array = buf.back().d
	return Vector3(d[0], d[1], d[2])


# ------------------------------------------------------------------ requests to the server

func request_start() -> void:
	_to_server("_srv_start", [])


func request_tag(target: int) -> void:
	_to_server("_srv_tag", [target])


func _to_server(method: String, args: Array) -> void:
	if mode == "none":
		return
	if multiplayer.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)


func _sender() -> int:
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else multiplayer.get_unique_id()


@rpc("any_peer", "call_remote", "reliable")
func _srv_start() -> void:
	if not multiplayer.is_server():
		return
	if g.ph == "lobby" and players.size() >= 2:
		_new_round()
		_push_g(true)


@rpc("any_peer", "call_remote", "reliable")
func _srv_tag(target: int) -> void:
	if not multiplayer.is_server():
		return
	var s := _sender()
	if g.ph != "run" or s != int(g.h) or not g.pl.has(target) or target == s or g.c.has(target):
		return
	var hp = pos_of(s)
	var tp = pos_of(target)
	if hp != null and tp != null and (hp as Vector3).distance_to(tp as Vector3) > 7.0:
		return
	g.c.append(target)
	g.sc[s] = float(g.sc.get(s, 0.0)) + 100.0
	_push_g(true)
	caught_fx.rpc(target, s)
	caught_event.emit(target, s)


@rpc("authority", "call_remote", "reliable")
func caught_fx(target: int, hunter: int) -> void:
	caught_event.emit(target, hunter)


# ------------------------------------------------------------------ game state

func _process(delta: float) -> void:
	if mode == "none":
		return
	if multiplayer.is_server():
		_host_tick(delta)
		_g_acc += delta
		if _g_acc >= 0.1:
			_g_acc = 0.0
			_push_g(false)
	else:
		g.t = maxf(0.0, float(g.t) - delta)


func _push_g(reliable: bool) -> void:
	if mode != "host":
		return
	_g_seq += 1
	g.seq = _g_seq
	var out: Dictionary = g.duplicate(true)
	for k in out.sc.keys():
		out.sc[k] = roundi(out.sc[k])
	if reliable:
		gstate_r.rpc(out)
	else:
		gstate_u.rpc(out)


@rpc("authority", "call_remote", "unreliable_ordered")
func gstate_u(ng: Dictionary) -> void:
	_apply_g(ng)


@rpc("authority", "call_remote", "reliable")
func gstate_r(ng: Dictionary) -> void:
	_apply_g(ng)


func _apply_g(ng: Dictionary) -> void:
	if int(ng.get("seq", 0)) < int(g.get("seq", 0)):
		return
	for k in ["ph", "r", "h", "t", "pl", "c", "sc", "hc", "w", "b", "rv", "rvt"]:
		if not ng.has(k):
			return
	g = ng


func _host_tick(dt: float) -> void:
	var present := players.keys()
	match g.ph:
		"hide":
			g.t -= dt
			if not present.has(g.h):
				g.ph = "lobby"
				_push_g(true)
			elif g.t <= 0.0:
				g.ph = "run"
				g.t = ROUND_T
				_push_g(true)
		"run":
			g.t -= dt
			var alive := []
			for u in g.pl:
				if u != g.h and not g.c.has(u) and present.has(u):
					alive.append(u)
			for u in alive:
				g.sc[u] = float(g.sc.get(u, 0.0)) + dt * 2.0
			_beacon_tick(dt, alive)
			if not present.has(g.h):
				_end_round("abort", alive)
			elif alive.is_empty():
				_end_round("hunter" if not g.c.is_empty() else "abort", alive)
			elif g.t <= 0.0:
				_end_round("runners", alive)
		"end":
			g.t -= dt
			if g.t <= 0.0:
				if present.size() >= 2:
					_new_round()
				else:
					g.ph = "lobby"
				_push_g(true)


func _new_round() -> void:
	g.r = int(g.r) + 1
	var pl := players.keys()
	pl.sort()
	g.pl = pl
	g.c = []
	g.w = ""
	var best = pl[0]
	var best_k := INF
	for u in pl:   # fewest turns as hunter goes next, ties broken per round
		var k := float(g.hc.get(u, 0)) * 1e6 + float(absi(hash(str(u) + ":" + str(g.r))) % 1000000)
		if k < best_k:
			best_k = k
			best = u
	g.h = best
	g.hc[best] = int(g.hc.get(best, 0)) + 1
	g.ph = "hide"
	g.t = HIDE_T
	_clear_beacons()
	g.bn = BEACON_FIRST


func _end_round(winner: String, alive: Array) -> void:
	g.ph = "end"
	g.t = END_T
	g.w = winner
	_clear_beacons()
	if winner == "hunter":
		g.sc[g.h] = float(g.sc.get(g.h, 0.0)) + 150.0
	elif winner == "runners":
		for u in alive:
			g.sc[u] = float(g.sc.get(u, 0.0)) + 100.0
	_push_g(true)


# ------------------------------------------------------------------ beacons

func _clear_beacons() -> void:
	g.b = {}
	g.rv = []
	g.rvt = 0.0
	_last_beacons = []


## True once runner u has reached any beacon of the wave b.
static func beacon_reached(b: Dictionary, u: int) -> bool:
	for ids in b.get("ok", []):
		if (ids as Array).has(u):
			return true
	return false


func _beacon_tick(dt: float, alive: Array) -> void:
	if float(g.rvt) > 0.0:
		g.rvt = float(g.rvt) - dt
		if g.rvt <= 0.0:
			g.rv = []
			g.rvt = 0.0
	if g.b.is_empty():
		g.bn = float(g.bn) - dt
		# no wave that could not close before the round ends
		if g.bn <= 0.0 and float(g.t) > BEACON_T + 3.0 and not beacon_spots.is_empty():
			_new_beacons()
			_push_g(true)
		return
	var b: Dictionary = g.b
	b.t = float(b.t) - dt
	var changed := false
	for i in (b.p as Array).size():
		var p: Vector3 = b.p[i]
		var ok: Array = b.ok[i]
		for u in alive:
			if ok.has(u):
				continue
			var up = pos_of(u)
			if up == null:
				continue
			var d: Vector3 = (up as Vector3) - p
			if Vector2(d.x, d.z).length() <= BEACON_R and absf(d.y) < 2.5:
				ok.append(u)
				g.sc[u] = float(g.sc.get(u, 0.0)) + BEACON_PTS
				changed = true
	if b.t <= 0.0:
		var missed := []
		for u in alive:
			if not beacon_reached(b, u):
				missed.append(u)
		g.rv = missed
		g.rvt = REVEAL_T if not missed.is_empty() else 0.0
		g.b = {}
		g.bn = BEACON_GAP
		changed = true
	if changed:
		_push_g(true)


## Picks a wave of spread-out spots, away from the previous wave.
func _new_beacons() -> void:
	var pool := beacon_spots.duplicate()
	pool.shuffle()
	var picked: Array = []
	for strict in [true, false]:   # relax the distances if the map runs out
		for s: Vector3 in pool:
			if picked.size() >= BEACON_COUNT:
				break
			if picked.has(s):
				continue
			var ok := true
			if strict:
				for q: Vector3 in picked:
					ok = ok and s.distance_to(q) >= BEACON_SPREAD
				for q: Vector3 in _last_beacons:
					ok = ok and s.distance_to(q) >= BEACON_MIN_MOVE
			if ok:
				picked.append(s)
	_last_beacons = picked
	var oks := []
	for p in picked:
		oks.append([])
	g.b = {"p": picked, "t": BEACON_T, "ok": oks}
