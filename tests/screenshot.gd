extends SceneTree
## Renders the menu and a few in-game views to PNG files, then quits.
##   godot -s res://tests/screenshot.gd -- --out=/tmp/shots

var out_dir := "user://shots"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _shot(name: String) -> void:
	for i in 20:
		await process_frame
		if current_scene.playing:   # losing focus pauses the game; keep the HUD in view
			current_scene.hud.show_game()
	root.get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))


func _run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var main: Node = current_scene
	await _shot("menu")
	var net: Node = root.get_node("Net")
	net.my_name = "Dimitri"
	net.start_solo()
	main.playing = true
	main.hud.show_game()
	var p: Player = main.player
	var w: World = main.world
	p.set_pos(Vector3(10, 0, 14), deg_to_rad(35))
	p.pitch = 0.12
	await _shot("plaza")
	var s: Vector3 = w.spawns_runner[3]
	p.set_pos(s, atan2(s.x, s.z))
	p.pitch = -0.05
	await _shot("roofs")
	# a fake second player to see an avatar
	var av := Avatar.new()
	w.add_child(av)
	av.style(Hud.COLORS[0], true, "Camille")
	av.show_sample({"x": s.x - sin(p.yaw) * 4.0, "y": s.y, "z": s.z - cos(p.yaw) * 4.0, "yaw": p.yaw + PI, "vx": 6.0, "vz": 0.0, "s": 0, "w": 0.0, "h": 1.8}, 0.016, 0.3)
	await _shot("avatar")
	quit()
