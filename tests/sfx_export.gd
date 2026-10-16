extends SceneTree
## Synthesises every sound effect and saves them as WAV files to listen to:
##   godot --headless -s res://tests/sfx_export.gd -- --out=/tmp/sons

var out_dir := "user://sons"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var sfx := Sfx.new()
	root.add_child(sfx)   # synthesis runs in _ready
	print("synthèse : %d ms" % (Time.get_ticks_msec() - t0))
	for k in sfx._streams:
		var list: Array = sfx._streams[k]
		for i in list.size():
			var path := out_dir.path_join("%s%s.wav" % [k, "" if list.size() == 1 else "_%d" % (i + 1)])
			(list[i] as AudioStreamWAV).save_to_wav(path)
	sfx._slide.stream.save_to_wav(out_dir.path_join("slide_boucle.wav"))
	print("sons enregistrés dans ", ProjectSettings.globalize_path(out_dir))
	quit()
