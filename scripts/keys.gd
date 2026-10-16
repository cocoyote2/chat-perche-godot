class_name Keys
## Key bindings: defaults, the player's choices, and their names for display.
##
## Each action has one main binding the player can change (a key, by physical
## position, or a mouse button) plus a few fixed extras (arrow keys, F to tag...).
## Escape is reserved for the menu and cannot be bound.

## Actions the player can rebind, in the order of the settings screen.
const ACTIONS: Array[Array] = [
	["move_forward", "Avancer"], ["move_back", "Reculer"], ["move_left", "Aller à gauche"], ["move_right", "Aller à droite"],
	["jump", "Sauter, grimper"], ["slide", "Glisser, roulade"], ["sprint", "Sprinter"],
	["tag", "Toucher (chasseur)"], ["pulse", "Sonar (chasseur)"],
	["scores", "Scores"], ["start_round", "Lancer la manche"], ["fullscreen", "Plein écran"],
]

# "k:<physical keycode>" or "m:<mouse button>"
const DEFAULTS := {
	"move_forward": "k:%d" % KEY_W, "move_back": "k:%d" % KEY_S, "move_left": "k:%d" % KEY_A, "move_right": "k:%d" % KEY_D,
	"jump": "k:%d" % KEY_SPACE, "slide": "k:%d" % KEY_CTRL, "sprint": "k:%d" % KEY_SHIFT,
	"tag": "m:%d" % MOUSE_BUTTON_LEFT, "pulse": "k:%d" % KEY_E,
	"scores": "k:%d" % KEY_TAB, "start_round": "k:%d" % KEY_ENTER, "fullscreen": "k:%d" % KEY_F11,
}

const EXTRAS := {
	"move_forward": ["k:%d" % KEY_UP], "move_back": ["k:%d" % KEY_DOWN],
	"move_left": ["k:%d" % KEY_LEFT], "move_right": ["k:%d" % KEY_RIGHT],
	"tag": ["k:%d" % KEY_F], "start_round": ["k:%d" % KEY_KP_ENTER],
}

const NAMES := {
	"Space": "Espace", "Shift": "Maj", "Ctrl": "Ctrl", "Alt": "Alt", "Enter": "Entrée", "Kp Enter": "Entrée (pavé)",
	"Tab": "Tab", "Backspace": "Retour", "CapsLock": "Verr. Maj", "Up": "Haut", "Down": "Bas", "Left": "Gauche",
	"Right": "Droite", "Delete": "Suppr", "Insert": "Inser", "Home": "Début", "End": "Fin",
	"PageUp": "Page préc.", "PageDown": "Page suiv.",
}

static var bound := {}   # action -> binding string


## Applies the saved choices on top of the defaults (call once at startup).
static func load_from(cfg: ConfigFile) -> void:
	bound = DEFAULTS.duplicate()
	for a in DEFAULTS:
		var s := str(cfg.get_value("keys", a, ""))
		if _event(s) != null:
			bound[a] = s
	apply()


static func save_to(cfg: ConfigFile) -> void:
	for a in bound:
		cfg.set_value("keys", a, bound[a])


static func reset() -> void:
	bound = DEFAULTS.duplicate()
	apply()


## Binds an action to an input event. Returns false for events that cannot be
## bound. If another action had that binding, the two swap.
static func rebind(action: String, e: InputEvent) -> bool:
	var s := _encode(e)
	if s == "" or not bound.has(action):
		return false
	for a in bound:
		if a != action and bound[a] == s:
			bound[a] = bound[action]
	bound[action] = s
	apply()
	return true


## Rebuilds the InputMap. "pause" (Escape) stays fixed.
static func apply() -> void:
	var taken := bound.values()
	for a in bound:
		if InputMap.has_action(a):
			InputMap.erase_action(a)
		InputMap.add_action(a)
		InputMap.action_add_event(a, _event(bound[a]))
		for x in EXTRAS.get(a, []):
			if not taken.has(x):   # a main binding wins over a fixed extra
				InputMap.action_add_event(a, _event(x))
	if not InputMap.has_action("pause"):
		InputMap.add_action("pause")
		var esc := InputEventKey.new()
		esc.physical_keycode = KEY_ESCAPE
		InputMap.action_add_event("pause", esc)


## Display name of an action's main binding, for the current keyboard layout.
static func name_of(action: String) -> String:
	return describe(str(bound.get(action, DEFAULTS.get(action, ""))))


## The four movement keys, e.g. "ZQSD" (or "Z/Q/S/D" when names are long).
static func move_names() -> String:
	var n := [name_of("move_forward"), name_of("move_left"), name_of("move_back"), name_of("move_right")]
	for x in n:
		if x.length() > 1:
			return "/".join(n)
	return "".join(n)


static func describe(s: String) -> String:
	if s.begins_with("m:"):
		match int(s.substr(2)):
			MOUSE_BUTTON_LEFT:
				return "Clic gauche"
			MOUSE_BUTTON_RIGHT:
				return "Clic droit"
			MOUSE_BUTTON_MIDDLE:
				return "Clic molette"
			MOUSE_BUTTON_XBUTTON1:
				return "Souris 4"
			MOUSE_BUTTON_XBUTTON2:
				return "Souris 5"
		return "Souris %d" % int(s.substr(2))
	if s.begins_with("k:"):
		var phys := int(s.substr(2)) as Key
		var code := DisplayServer.keyboard_get_keycode_from_physical(phys)
		var n := OS.get_keycode_string(code if code != KEY_NONE else phys)
		return NAMES.get(n, n)
	return "?"


static func _encode(e: InputEvent) -> String:
	var k := e as InputEventKey
	if k != null:
		var phys := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if phys == KEY_NONE or phys == KEY_ESCAPE:
			return ""
		return "k:%d" % phys
	var m := e as InputEventMouseButton
	if m != null and m.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		return "m:%d" % m.button_index
	return ""


static func _event(s: String) -> InputEvent:
	if s.begins_with("k:") and s.substr(2).is_valid_int():
		var e := InputEventKey.new()
		e.physical_keycode = int(s.substr(2)) as Key
		return e
	if s.begins_with("m:") and s.substr(2).is_valid_int():
		var m := InputEventMouseButton.new()
		m.button_index = int(s.substr(2)) as MouseButton
		return m
	return null
