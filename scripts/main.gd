extends Node
## Ties everything together: world, local player, other players, HUD, sounds, and
## the per-frame reading of the game state that Net keeps in sync.
##
## Run with `-- --server` for a headless dedicated server (no window, no player).

const COLORS := Hud.COLORS
const TAG_RANGE := 3.0
const PULSE_CD := 20.0
const PULSE_T := 3.0

var world: World
var player: Player
var hud: Hud
var sfx: Sfx
var avatars := {}          # peer id -> Avatar
var playing := false
var paused := false
var my_round := -1
var caught := false
var tag_cd := 0.0
var pulse_cd := 0.0
var pulse_t := 0.0
var send_acc := 0.0
var hud_acc := 0.0
var last_phase := ""
var last_count := -1
var heart_t := 0.0
var beacon: Beacon
var last_beacon_p = null   # Vector3 of the beacon already announced, or null
var beacon_done := false
var reveal_seen := false
var board_held := false
var settings := ConfigFile.new()


func _ready() -> void:
	_setup_input()
	if "--server" in OS.get_cmdline_user_args():
		_run_dedicated()
		return
	world = World.new()
	add_child(world)
	world.generate()
	world.build_collision()
	world.build_visuals()
	Net.beacon_spots = world.beacon_spots
	beacon = Beacon.new()
	world.add_child(beacon)
	_setup_environment()

	sfx = Sfx.new()
	add_child(sfx)
	player = Player.new()
	player.world = world
	world.add_child(player)
	player.camera.current = true
	player.move_done.connect(func(label: String): hud.flash_move(label))
	player.sfx.connect(func(s: String, v: float): sfx.play(s, v))
	player.notice.connect(func(t: String): hud.message(t))

	hud = Hud.new()
	add_child(hud)
	hud.solo_pressed.connect(_on_solo)
	hud.host_pressed.connect(_on_host)
	hud.join_pressed.connect(_on_join)
	hud.resume_pressed.connect(_resume)
	hud.leave_pressed.connect(_on_leave)
	hud.start_pressed.connect(func(): Net.request_start())
	hud.fullscreen_toggled.connect(_set_fullscreen)
	hud.key_chosen.connect(_on_key_chosen)
	hud.keys_reset.connect(_on_keys_reset)

	Net.joined.connect(_on_joined)
	Net.session_ended.connect(_on_session_ended)
	Net.caught_event.connect(_on_caught_event)

	hud.name_edit.text = str(settings.get_value("player", "name", ""))
	hud._pick_color(int(settings.get_value("player", "color", randi() % COLORS.size())))
	hud.sens_slider.value = float(settings.get_value("player", "sensitivity", 1.0))
	hud.ip_edit.text = str(settings.get_value("player", "last_ip", "127.0.0.1"))
	_set_fullscreen(bool(settings.get_value("display", "fullscreen", false)))
	hud.show_main_menu()

	# view behind the menu
	var s: Vector3 = world.spawns_runner[0] if not world.spawns_runner.is_empty() else Vector3(30, 8, 30)
	player.set_pos(s, atan2(s.x, s.z))
	player.pitch = -0.12


func _run_dedicated() -> void:
	Engine.max_fps = 60
	# the server places the beacons, so it needs the city layout (no visuals)
	var w := World.new()
	w.generate()
	Net.beacon_spots = w.beacon_spots
	w.free()
	var err := Net.start_host(true)
	if err != OK:
		printerr("Impossible d'ouvrir le port %d (erreur %d)" % [Net.PORT, err])
		get_tree().quit(1)
		return
	print("Serveur dédié Chat Perché prêt sur le port UDP %d" % Net.PORT)
	Net.roster_changed.connect(func(): print("Joueurs : ", Net.players.values().map(func(p): return p.name)))


## Bindings by physical key position (ZQSD on AZERTY, WASD on QWERTY), with the
## player's own choices saved in settings.cfg on top of the defaults.
func _setup_input() -> void:
	settings.load("user://settings.cfg")
	Keys.load_from(settings)


func _setup_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#3f86d8")
	sky_mat.sky_horizon_color = Color("#d6e8f5")
	sky_mat.ground_horizon_color = Color("#d6e8f5")
	sky_mat.ground_bottom_color = Color("#9aa7b4")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#c9d3dc")
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ssao_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color("#b4c3d0")
	env.fog_density = 0.0025
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(-35), 0)
	sun.light_color = Color("#fff0d8")
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)


# ------------------------------------------------------------------ session flow

func _save_profile() -> void:
	var n := hud.name_edit.text.strip_edges().left(16)
	if n == "":
		n = "Coureur %d" % (randi() % 90 + 10)
		hud.name_edit.text = n
	Net.my_name = n
	Net.my_color = hud.color_idx
	player.sensitivity = hud.sens_slider.value
	settings.set_value("player", "name", n)
	settings.set_value("player", "color", hud.color_idx)
	settings.set_value("player", "sensitivity", hud.sens_slider.value)
	settings.set_value("player", "last_ip", hud.ip_edit.text.strip_edges())
	settings.save("user://settings.cfg")


func _on_solo() -> void:
	_save_profile()
	Net.start_solo()
	_enter_game()


func _on_host() -> void:
	_save_profile()
	var err := Net.start_host()
	if err != OK:
		hud.set_status("Impossible d'ouvrir le port %d. Une autre partie tourne peut-être déjà sur cette machine." % Net.PORT)
		return
	_enter_game()
	hud.message("Partie hébergée. Tes amis rejoignent avec ton adresse IP, port %d." % Net.PORT)


func _on_join(address: String) -> void:
	_save_profile()
	if address == "":
		hud.set_status("Entre l'adresse de l'hôte.")
		return
	var err := Net.start_client(address)
	if err != OK:
		hud.set_status("Adresse invalide.")
		return
	hud.set_status("Connexion à %s…" % address)


func _on_joined() -> void:
	_enter_game()


func _on_session_ended(reason: String) -> void:
	_exit_game()
	hud.show_main_menu(reason)


func _on_leave() -> void:
	Net.leave()
	_exit_game()
	hud.show_main_menu()


func _enter_game() -> void:
	playing = true
	my_round = -1
	caught = false
	_respawn_free()
	_resume()


func _exit_game() -> void:
	playing = false
	paused = false
	player.input_enabled = false
	player.frozen = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for id in avatars:
		avatars[id].queue_free()
	avatars.clear()
	sfx.play("slide_off")
	beacon.visible = false
	hud.set_beacon("", Hud.INK)
	hud.set_beacon_marker(false)
	last_beacon_p = null


func _set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	hud.fullscreen_check.set_pressed_no_signal(on)
	if bool(settings.get_value("display", "fullscreen", false)) != on:
		settings.set_value("display", "fullscreen", on)
		settings.save("user://settings.cfg")


func _on_key_chosen(action: String, e: InputEvent) -> void:
	if Keys.rebind(action, e):
		Keys.save_to(settings)
		settings.save("user://settings.cfg")
	hud.refresh_keys()


func _on_keys_reset() -> void:
	Keys.reset()
	Keys.save_to(settings)
	settings.save("user://settings.cfg")
	hud.refresh_keys()


func _resume() -> void:
	paused = false
	player.sensitivity = hud.sens_slider.value
	hud.show_game()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.input_enabled = true


func _pause() -> void:
	paused = true
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_pause(Net.g.ph == "lobby" and Net.players.size() >= 2)


func _unhandled_input(e: InputEvent) -> void:
	if player == null:
		return
	if e.is_action_pressed("fullscreen"):   # works in the menus too
		_set_fullscreen(DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if not playing:
		return
	if e.is_action_pressed("pause"):
		if paused:
			_resume()
		else:
			_pause()
		return
	if paused:
		return
	if e.is_action_pressed("tag"):
		_try_tag()
	elif e.is_action_pressed("pulse"):
		_try_pulse()
	elif e.is_action_pressed("start_round"):
		Net.request_start()
	elif e.is_action_pressed("scores"):
		board_held = true
	elif e.is_action_released("scores"):
		board_held = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and playing and not paused and player != null:
		_pause()


# ------------------------------------------------------------------ hunter tools

func _aim_target() -> int:
	var o := player.camera.global_position
	var d := -player.camera.global_transform.basis.z
	var best := 0
	var bt := TAG_RANGE
	for id in avatars:
		var av: Avatar = avatars[id]
		if not av.visible or not av.get_meta("runner", false) or av.cur.is_empty():
			continue
		var c := av.position
		var hh: float = av.cur.h
		var t := World.ray_box(o, d, Vector3(c.x - 0.65, c.y - 0.1, c.z - 0.65), Vector3(c.x + 0.65, c.y + hh + 0.2, c.z + 0.65))
		if t >= 0.0 and t < bt and not world.ray_blocked(o, d, t):
			bt = t
			best = id
	return best


func _try_tag() -> void:
	var g := Net.g
	if g.ph != "run" or int(g.h) != Net.me() or tag_cd > 0.0 or player.st == "spec":
		return
	var target := _aim_target()
	if target != 0:
		Net.request_tag(target)
		avatars[target].set_meta("tagged_round", int(g.r))
		sfx.play("tag")
		hud.message("Touché : " + Net.player_name(target))
		hud.flash_screen(0.35)
		tag_cd = 0.3
	else:
		tag_cd = 0.45
		sfx.play("miss")


func _try_pulse() -> void:
	var g := Net.g
	if g.ph != "run" or int(g.h) != Net.me() or pulse_cd > 0.0:
		return
	pulse_cd = PULSE_CD
	pulse_t = PULSE_T
	sfx.play("sonar")
	hud.message("Sonar")


func _on_caught_event(target: int, hunter: int) -> void:
	if target == Net.me() and not caught:
		caught = true
		sfx.play("caught")
		player.start_spectating()
		hud.flash_screen(0.6)
		hud.message("Attrapé par %s. Tu regardes la suite en vol libre." % Net.player_name(hunter))


# ------------------------------------------------------------------ spawning

func _respawn_free() -> void:
	if world.spawns_runner.is_empty():
		player.set_pos(Vector3(0, 3, 20), 0.0)
		return
	var s: Vector3 = world.spawns_runner[randi() % world.spawns_runner.size()]
	player.set_pos(s, atan2(s.x, s.z))


func _spawn_for_round(g: Dictionary) -> void:
	if int(g.h) == Net.me():
		player.set_pos(world.hunter_spawn, 0.0)
		return
	var idx: int = (g.pl as Array).find(Net.me())
	var n := world.spawns_runner.size()
	var s: Vector3 = world.spawns_runner[(absi(hash("r%d" % int(g.r))) + idx * 7) % n]
	player.set_pos(s + Vector3((idx % 3 - 1) * 1.2, 0, 0), atan2(s.x, s.z))


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	if player == null:
		return
	if not playing:
		return
	var g := Net.g
	var me := Net.me()
	var round_live: bool = g.ph == "hide" or g.ph == "run"
	var in_round: bool = round_live and (g.pl as Array).has(me)

	if in_round and int(g.r) != my_round:
		my_round = int(g.r)
		caught = false
		pulse_cd = 0.0
		pulse_t = 0.0
		_spawn_for_round(g)
		hud.message("Tu es le chasseur" if int(g.h) == me else "Le chasseur est " + Net.player_name(int(g.h)))
	if in_round and g.ph == "run" and not caught and int(g.h) != me and (g.c as Array).has(me):
		_on_caught_event(me, int(g.h))

	var role := "free"
	if round_live:
		if not in_round:
			role = "spectator"
		elif int(g.h) == me:
			role = "hunter"
		elif caught:
			role = "caught"
		else:
			role = "runner"
	if (role == "spectator" or role == "caught") and player.st != "spec":
		player.start_spectating()
	if (role == "free" or role == "runner" or role == "hunter") and player.st == "spec":
		_respawn_free()
	player.frozen = role == "hunter" and g.ph == "hide"
	if player.frozen:
		player.position = world.hunter_spawn
	player.run_speed = Player.RUN_HUNTER if role == "hunter" else Player.RUN_RUNNER
	player.sprint_speed = Player.SPRINT_HUNTER if role == "hunter" else Player.SPRINT_RUNNER

	if g.ph != last_phase:
		if g.ph == "run":
			sfx.play("beep_hi")
			if role == "hunter":
				hud.message("Trouve-les et touche-les")
		elif g.ph == "end":
			sfx.play("beep")
		last_phase = g.ph
	if g.ph == "hide":
		var c := ceili(float(g.t))
		if c != last_count and c <= 3:
			sfx.play("beep")
		last_count = c
	tag_cd -= delta
	pulse_cd -= delta
	pulse_t -= delta

	# ---- other players
	var now := Time.get_ticks_msec()
	var hunter_dist := INF
	for id in Net.players:
		if id == me:
			continue
		if not avatars.has(id):
			var av := Avatar.new()
			world.add_child(av)
			avatars[id] = av
	for id in avatars.keys():
		if not Net.players.has(id):
			avatars[id].queue_free()
			avatars.erase(id)
			continue
		var av: Avatar = avatars[id]
		var s := av.sample(Net.states.get(id, []), now)
		var is_hunter: bool = round_live and int(g.h) == id
		var out: bool = s.is_empty() or int(s.s) == 9 or (round_live and (not (g.pl as Array).has(id) or (g.c as Array).has(id) or int(av.get_meta("tagged_round", -1)) == int(g.r)))
		av.visible = not out
		av.set_meta("runner", not out and g.ph == "run" and not is_hunter)
		if out:
			continue
		var p: Dictionary = Net.players[id]
		av.style(COLORS[clampi(int(p.color), 0, COLORS.size() - 1)], is_hunter, str(p.name))
		av.show_sample(s, delta, now / 1000.0)
		# the sonar, or a beacon the runner missed, shows them through walls
		av.set_xray(role == "hunter" and not is_hunter and (pulse_t > 0.0 or (g.rv as Array).has(id)))
		if is_hunter:
			hunter_dist = av.position.distance_to(player.position)

	_update_beacon(g, role)

	# ---- feedback
	var danger := clampf((24.0 - hunter_dist) / 20.0, 0.0, 1.0) if role == "runner" and g.ph == "run" else 0.0
	hud.set_danger(danger)
	if danger > 0.0:
		heart_t -= delta
		if heart_t <= 0.0:
			sfx.play("heart", danger)
			heart_t = lerpf(1.0, 0.35, danger)
	var aim := _aim_target() if role == "hunter" and g.ph == "run" else 0
	hud.set_cross("lock" if aim != 0 else ("cross" if role == "hunter" else "dot"))
	hud.set_blind(role == "hunter" and g.ph == "hide", ceili(float(g.t)))
	var hs := player.hspeed()
	hud.set_speed(hs, player.run_speed, Player.VMAX, player.combo)
	hud.set_stamina(player.stamina, player.exhausted, player.sprinting, player.st != "spec")

	hud_acc += delta
	if hud_acc >= 0.1:
		hud_acc = 0.0
		_update_hud(g, role)

	# ---- broadcast my runner
	send_acc += delta
	if send_acc >= 1.0 / 30.0:
		send_acc = 0.0
		Net.send_state(PackedFloat32Array([
			player.position.x, player.position.y, player.position.z, player.yaw,
			player.velocity.x, player.velocity.y, player.velocity.z,
			player.state_code(), -player.wall_side if player.st == "wall" else 0, player.h,
		]))


## Beacon in the world, its HUD line and marker, and the messages when one
## appears, is reached, or closes on runners who missed it.
func _update_beacon(g: Dictionary, role: String) -> void:
	var me := Net.me()
	var b: Dictionary = g.b
	var active: bool = not b.is_empty() and g.ph == "run" and role != "free"
	if not active:
		last_beacon_p = null
	else:
		var bp: Vector3 = b.p
		if last_beacon_p == null or (last_beacon_p as Vector3) != bp:
			last_beacon_p = bp
			beacon_done = false
			sfx.play("beacon")
			if role == "runner":
				hud.message("Nouvelle balise : rejoins-la en %d s" % ceili(float(b.t)))
			elif role == "hunter":
				hud.message("Nouvelle balise : les chassés doivent s'y rendre")
	var done: bool = active and (b.ok as Array).has(me)
	if done and not beacon_done:
		beacon_done = true
		sfx.play("beacon_ok")
		hud.flash_move("Balise +%d" % roundi(Net.BEACON_PTS))

	var rv: Array = g.rv
	var reveal_on: bool = g.ph == "run" and not rv.is_empty() and float(g.rvt) > 0.0
	if reveal_on and not reveal_seen:
		reveal_seen = true
		if rv.has(me) and role == "runner":
			sfx.play("reveal")
			hud.message("Balise ratée : le chasseur te voit à travers les murs")
			hud.flash_screen(0.25)
		elif role == "hunter":
			sfx.play("reveal")
			hud.message("%d chassé%s repéré%s" % [rv.size(), "s" if rv.size() > 1 else "", "s" if rv.size() > 1 else ""])
	elif not reveal_on:
		reveal_seen = false

	if active:
		var bp: Vector3 = b.p
		beacon.show_at(bp, done)
		var col := Beacon.DONE if done else Beacon.TODO
		var secs := ceili(float(b.t))
		var dist := roundi(player.position.distance_to(bp))
		if role == "runner":
			hud.set_beacon("Balise validée" if done else "Balise · %d s · %d m" % [secs, dist], col)
		else:
			hud.set_beacon("Balise · %d s" % secs, col)
		if done:
			hud.set_beacon_marker(false)
		else:
			hud.set_beacon_marker(true, _screen_point(bp + Vector3(0, 1.5, 0)), "%d m" % dist, col)
		return
	beacon.visible = false
	hud.set_beacon_marker(false)
	if reveal_on and rv.has(me) and role == "runner":
		hud.set_beacon("Repéré · %d s" % ceili(float(g.rvt)), Hud.RED)
	elif reveal_on and role == "hunter":
		hud.set_beacon("%d repéré%s · %d s" % [rv.size(), "s" if rv.size() > 1 else "", ceili(float(g.rvt))], Hud.RED)
	else:
		hud.set_beacon("", Hud.INK)


## Where a world point lands on screen, pinned to the screen edge when it is
## off to the side or behind the camera.
func _screen_point(p: Vector3) -> Vector2:
	var cam := player.camera
	var vp := get_viewport().get_visible_rect().size
	var margin := Vector2(60, 70)
	var sp: Vector2
	if cam.is_position_behind(p):
		var local := cam.global_transform.affine_inverse() * p
		sp = Vector2(margin.x if local.x < 0.0 else vp.x - margin.x, vp.y * 0.5)
	else:
		sp = cam.unproject_position(p)
	return sp.clamp(margin, vp - margin)


static func _fmt_time(t: float) -> String:
	var s := maxi(0, ceili(t))
	return "%d:%02d" % [s / 60, s % 60]


func _update_hud(g: Dictionary, role: String) -> void:
	var me := Net.me()
	var n := Net.players.size()
	var pl: Array = g.pl
	var caught_l: Array = g.c
	var hunter := int(g.h)
	match g.ph:
		"lobby":
			hud.set_top("%d joueur%s" % [n, "s" if n > 1 else ""], "Entraînement libre" if Net.mode == "solo" else "Salle d'attente")
		"hide":
			hud.set_top(_fmt_time(g.t), "Dispersion")
		"run":
			var alive := 0
			for u in pl:
				if u != hunter and not caught_l.has(u):
					alive += 1
			hud.set_top(_fmt_time(g.t), "%d chassé%s en fuite" % [alive, "s" if alive > 1 else ""])
		_:
			hud.set_top(_fmt_time(g.t), "Fin de manche")

	var role_text := {"free": "Échauffement" if g.ph == "lobby" else "Libre", "runner": "Chassé", "hunter": "Chasseur", "caught": "Attrapé", "spectator": "Spectateur"}
	var fly := "Vol libre : %s, %s, %s" % [Keys.move_names(), Keys.name_of("jump"), Keys.name_of("slide")]
	var role_hint := {"runner": "Ne te fais pas toucher", "hunter": "Touche-les tous", "caught": fly, "spectator": fly}
	var kind := "hunter" if role == "hunter" else ("spec" if role == "caught" or role == "spectator" else "normal")
	hud.set_role(role_text[role], kind, role_hint.get(role, ""))

	var ids := Net.players.keys()
	ids.sort_custom(func(a, b): return float(g.sc.get(a, 0)) > float(g.sc.get(b, 0)))
	var rows := []
	var board_rows := []
	for id in ids:
		var p: Dictionary = Net.players[id]
		var is_h: bool = g.ph != "lobby" and hunter == id
		var is_c: bool = caught_l.has(id)
		var score := roundi(float(g.sc.get(id, 0)))
		var nm := str(p.name) + (" (toi)" if id == me else "")
		var col: Color = COLORS[clampi(int(p.color), 0, COLORS.size() - 1)]
		rows.append({"name": nm, "color": col, "hunter": is_h, "out": is_c or ((g.ph == "hide" or g.ph == "run") and not pl.has(id)), "status": "chasseur" if is_h else ("attrapé" if is_c else str(score))})
		board_rows.append({"name": nm, "color": col, "tag": "chasseur" if is_h else ("attrapé" if is_c else ""), "score": score})
	hud.set_players(rows)

	var hint := ""
	if g.ph == "lobby":
		if n < 2:
			hint = "Entraîne-toi au parkour." if Net.mode == "solo" else "En attente d'autres joueurs (2 minimum)."
		else:
			hint = "[%s] pour lancer la manche" % Keys.name_of("start_round")
	elif role == "hunter" and g.ph == "run":
		hint = "[%s] pour toucher · [%s] sonar" % [Keys.name_of("tag"), Keys.name_of("pulse")]
	hud.set_hint(hint)
	hud.set_pulse(role == "hunter" and g.ph == "run", "ACTIF" if pulse_t > 0.0 else ("%d s" % ceili(pulse_cd) if pulse_cd > 0.0 else "PRÊT"))

	var big := ""
	if g.ph == "hide" and role == "runner":
		big = "Fuis ! %d" % ceili(float(g.t))
	elif g.ph == "run" and float(g.t) > Net.ROUND_T - 1.5:
		big = "Chasse !" if role == "hunter" else "Il arrive"
	elif role == "caught" and g.ph == "run":
		big = "Attrapé"
	hud.set_center(big)

	if g.ph == "end" or board_held:
		var hunter_name := Net.player_name(hunter)
		var title := "Scores"
		var sub := "Manche %d" % int(g.r)
		if g.ph == "end":
			title = "Victoire de " + hunter_name if g.w == "hunter" else ("Les chassés s'en sortent" if g.w == "runners" else "Manche annulée")
			sub = "Prochaine manche dans %d s" % ceili(float(g.t)) + ("" if n >= 2 else " (en attente de joueurs)")
		hud.set_board(true, title, sub, board_rows)
	else:
		hud.set_board(false)
