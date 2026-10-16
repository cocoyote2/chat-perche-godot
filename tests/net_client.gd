extends SceneTree
## Network smoke test: a bot client that joins a server, starts a round, and tags
## the other bot when it is the hunter. Start a dedicated server and two bots:
##   godot --headless res://scenes/main.tscn -- --server
##   godot --headless -s res://tests/net_client.gd -- --name=A
##   godot --headless -s res://tests/net_client.gd -- --name=B

var net: Node
var bot_name := "Bot"
var t := 0.0
var started := false
var tagged := false
var caught_seen := false
var result := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			bot_name = a.substr(7)
	_connect.call_deferred()


func _connect() -> void:
	await process_frame
	net = root.get_node("Net")   # the autoload, also loaded when running a script
	net.my_name = bot_name
	net.caught_event.connect(func(target, hunter): if target == net.me(): caught_seen = true)
	var err: int = net.start_client("127.0.0.1")
	print("[%s] connexion : %s" % [bot_name, error_string(err)])


func _process(delta: float) -> bool:
	t += delta
	if net == null:
		return false
	if net.mode == "client" and net.me() != 0:
		# stand next to each other near the plaza so the server accepts the tag
		var x := 4.0 if bot_name == "A" else 5.5
		net.send_state(PackedFloat32Array([x, 0, 12, 0, 0, 0, 0, 0, 0, 1.8]))
	var g: Dictionary = net.g
	if not started and bot_name == "A" and net.players.size() >= 2 and t > 1.5:
		started = true
		net.request_start()
		print("[A] demande de lancement, joueurs : ", net.players.values().map(func(p): return p.name))
	if g.ph == "run" and int(g.h) == net.me() and not tagged:
		for id in net.players:
			if id != net.me():
				tagged = true
				print("[%s] chasseur : touche %s" % [bot_name, net.players[id].name])
				net.request_tag(id)
	if g.ph == "end" and result == "":
		result = "fin de manche : vainqueur=%s attrapés=%s scores=%s" % [g.w, g.c, g.sc]
		print("[%s] %s%s" % [bot_name, result, " (j'ai été attrapé)" if caught_seen else ""])
		quit(0 if g.w == "hunter" else 1)
	if t > 25.0:
		print("[%s] délai dépassé, phase=%s joueurs=%d" % [bot_name, g.ph, net.players.size()])
		quit(2)
	return false
