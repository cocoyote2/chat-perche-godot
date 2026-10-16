extends CanvasLayer
class_name Hud
## Menu, in-game HUD, overlays and scoreboard, all built in code.

signal solo_pressed
signal host_pressed
signal join_pressed(address: String)
signal resume_pressed
signal leave_pressed
signal start_pressed
signal fullscreen_toggled(on: bool)
signal key_chosen(action: String, event: InputEvent)
signal keys_reset

const RED := Color("#e5382d")
const INK := Color("#f3f5f7")
const MUTED := Color("#a7b1bc")
const PANEL := Color(0.05, 0.06, 0.08, 0.9)
const COLORS: Array[Color] = [Color("#2f7de1"), Color("#f2a516"), Color("#2bb673"), Color("#9b59d0"), Color("#ef6fa8"), Color("#1fb5c7"), Color("#f3f3f3"), Color("#f07a2a")]

const VIGNETTE_SHADER := """
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(1.0);
uniform float strength = 0.0;
uniform float inner = 0.5;
void fragment() {
	float d = distance(UV, vec2(0.5)) * 1.414;
	COLOR = vec4(tint.rgb, smoothstep(inner, 1.0, d) * strength);
}
"""

class Crosshair extends Control:
	var mode := "dot"

	func set_mode(m: String) -> void:
		if m != mode:
			mode = m
			queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var white := Color(1, 1, 1, 0.85)
		match mode:
			"dot":
				draw_circle(c, 2.5, white)
			"cross":
				draw_line(c - Vector2(0, 7), c + Vector2(0, 7), white, 2.0)
				draw_line(c - Vector2(7, 0), c + Vector2(7, 0), white, 2.0)
			"lock":
				draw_arc(c, 20.0, 0.0, TAU, 48, Color("#e5382d"), 3.0)
				draw_line(c - Vector2(0, 7), c + Vector2(0, 7), Color("#e5382d"), 2.0)
				draw_line(c - Vector2(7, 0), c + Vector2(7, 0), Color("#e5382d"), 2.0)


var f_display := SystemFont.new()
var f_display_it := SystemFont.new()
var f_body := SystemFont.new()

var game_root: Control
var timer_l: Label
var phase_l: Label
var role_l: Label
var role_hint_l: Label
var players_box: VBoxContainer
var speed_l: Label
var speed_fill: ColorRect
var combo_l: Label
var effect_l: Label
var stamina_box: HBoxContainer
var stamina_fill: ColorRect
var flash_l: Label
var center_big: Label
var center_sub: Label
var hint_l: Label
var pulse_l: Label
var beacon_l: Label
var beacon_marks: Array[Label] = []
var cross: Crosshair
var vig_speed: ColorRect
var vig_danger: ColorRect
var flash_rect: ColorRect
var blind: ColorRect
var blind_num: Label
var board: PanelContainer
var board_title: Label
var board_sub: Label
var board_rows: VBoxContainer

var menu: Control
var name_edit: LineEdit
var ip_edit: LineEdit
var sens_slider: HSlider
var fullscreen_check: CheckButton
var keys_panel: PanelContainer
var menu_panel: PanelContainer
var key_buttons := {}      # action -> Button
var help_grid: GridContainer
var _capture := ""         # action waiting for a key press, or ""
var color_buttons: Array[Button] = []
var status_l: Label
var start_btns: HBoxContainer
var pause_btns: HBoxContainer
var start_round_btn: Button

var color_idx := 0
var _msg_t := 0.0
var _flash_tween: Tween


func _ready() -> void:
	layer = 10
	f_display.font_names = PackedStringArray(["Barlow Condensed", "Roboto Condensed", "Arial Narrow", "DejaVu Sans Condensed", "Liberation Sans Narrow", "sans-serif"])
	f_display.font_weight = 700
	f_display_it.font_names = f_display.font_names
	f_display_it.font_weight = 800
	f_display_it.font_italic = true
	f_body.font_names = PackedStringArray(["Barlow", "Inter", "Segoe UI", "Roboto", "DejaVu Sans", "sans-serif"])
	_build_game()
	_build_menu()


# ------------------------------------------------------------------ helpers

func _label(text: String, size: int, font: Font, color := INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.35))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _place(c: Control, al: float, at: float, ar: float, ab: float, ol := 0.0, ot := 0.0, orr := 0.0, ob := 0.0) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob


func _box(vertical: bool, sep := 4) -> BoxContainer:
	var b: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


func _flat(color: Color, pad := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad * 0.5
	s.content_margin_bottom = pad * 0.5
	return s


func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", f_display)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	var base := RED if primary else Color(1, 1, 1, 0.08)
	b.add_theme_stylebox_override("normal", _flat(base, 24))
	b.add_theme_stylebox_override("hover", _flat(base.lightened(0.12), 24))
	b.add_theme_stylebox_override("pressed", _flat(base.darkened(0.15), 24))
	var focus := _flat(Color(0, 0, 0, 0), 24)
	focus.border_color = Color.WHITE
	focus.set_border_width_all(2)
	focus.draw_center = false
	b.add_theme_stylebox_override("focus", focus)
	return b


func _overlay(shader_tint: Color, inner: float) -> ColorRect:
	var r := ColorRect.new()
	_place(r, 0, 0, 1, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = VIGNETTE_SHADER
	m.shader = sh
	m.set_shader_parameter("tint", shader_tint)
	m.set_shader_parameter("inner", inner)
	r.material = m
	return r


# ------------------------------------------------------------------ build

func _build_game() -> void:
	game_root = Control.new()
	_place(game_root, 0, 0, 1, 1)
	game_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_root.visible = false
	add_child(game_root)

	vig_speed = _overlay(Color(1, 1, 1), 0.55)
	vig_danger = _overlay(Color(0.8, 0.08, 0.04), 0.45)
	game_root.add_child(vig_speed)
	game_root.add_child(vig_danger)
	flash_rect = ColorRect.new()
	flash_rect.color = Color(1, 1, 1, 0)
	_place(flash_rect, 0, 0, 1, 1)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_root.add_child(flash_rect)

	var top := _box(true, 2)
	_place(top, 0, 0, 1, 0, 0, 14, 0, 90)
	timer_l = _label("", 46, f_display)
	timer_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_l = _label("", 16, f_display, MUTED)
	phase_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_l.uppercase = true
	top.add_child(timer_l)
	top.add_child(phase_l)
	game_root.add_child(top)

	beacon_l = _label("", 18, f_display)
	beacon_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	beacon_l.uppercase = true
	beacon_l.add_theme_stylebox_override("normal", _flat(Color(0.04, 0.05, 0.06, 0.55), 8))
	_place(beacon_l, 0.5, 0, 0.5, 0, -200, 104, 200, 134)
	beacon_l.visible = false
	game_root.add_child(beacon_l)


	var role := _box(false, 10)
	_place(role, 0, 0, 0, 0, 16, 16, 600, 50)
	role_l = _label("", 19, f_display, Color("#111"))
	role_l.uppercase = true
	role_l.add_theme_stylebox_override("normal", _flat(INK, 12))
	role_l.add_theme_constant_override("shadow_offset_y", 0)
	role_hint_l = _label("", 14, f_body, MUTED)
	role.add_child(role_l)
	role.add_child(role_hint_l)
	game_root.add_child(role)

	players_box = _box(true, 3)
	_place(players_box, 1, 0, 1, 0, -260, 16, -16, 400)
	game_root.add_child(players_box)

	var speed := _box(true, 4)
	_place(speed, 0, 1, 0, 1, 18, -185, 320, -18)   # room for the bonus line
	speed.alignment = BoxContainer.ALIGNMENT_END
	speed_l = _label("0 km/h", 52, f_display_it)
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(1, 1, 1, 0.18)
	bar_bg.custom_minimum_size = Vector2(180, 5)
	bar_bg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speed_fill = ColorRect.new()
	speed_fill.color = INK
	speed_fill.size = Vector2(0, 5)
	speed_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(speed_fill)
	combo_l = _label("", 20, f_display, RED)
	effect_l = _label("", 20, f_display)
	effect_l.uppercase = true
	effect_l.visible = false
	stamina_box = _box(false, 8)
	var st_bg := ColorRect.new()
	st_bg.color = Color(1, 1, 1, 0.18)
	st_bg.custom_minimum_size = Vector2(180, 8)
	st_bg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	st_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamina_fill = ColorRect.new()
	stamina_fill.color = Color("#7fd0ff")
	stamina_fill.size = Vector2(180, 8)
	stamina_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	st_bg.add_child(stamina_fill)
	stamina_box.add_child(st_bg)
	stamina_box.add_child(_label("ENDURANCE", 13, f_display, MUTED))
	speed.add_child(effect_l)
	speed.add_child(speed_l)
	speed.add_child(bar_bg)
	speed.add_child(stamina_box)
	speed.add_child(combo_l)
	game_root.add_child(speed)

	pulse_l = _label("", 18, f_display)
	pulse_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_place(pulse_l, 1, 1, 1, 1, -300, -80, -18, -18)
	pulse_l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	game_root.add_child(pulse_l)

	cross = Crosshair.new()
	_place(cross, 0.5, 0.5, 0.5, 0.5, -30, -30, 30, 30)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_root.add_child(cross)

	var center := _box(true, 6)
	_place(center, 0, 0.27, 1, 0.27, 0, 0, 0, 160)
	center_big = _label("", 72, f_display)
	center_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_big.uppercase = true
	center_sub = _label("", 17, f_body)
	center_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(center_big)
	center.add_child(center_sub)
	game_root.add_child(center)

	flash_l = _label("", 30, f_display_it)
	flash_l.uppercase = true
	flash_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(flash_l, 0, 0.62, 1, 0.62, 0, 0, 0, 40)
	flash_l.modulate.a = 0.0
	game_root.add_child(flash_l)

	hint_l = _label("", 15, f_body)
	hint_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_l.add_theme_stylebox_override("normal", _flat(Color(0.04, 0.05, 0.06, 0.55), 12))
	_place(hint_l, 0.5, 1, 0.5, 1, -300, -60, 300, -24)
	hint_l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint_l.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	game_root.add_child(hint_l)

	blind = ColorRect.new()
	blind.color = Color("#07090c")
	_place(blind, 0, 0, 1, 1)
	blind.visible = false
	var bb := _box(true, 8)
	_place(bb, 0, 0.35, 1, 0.35, 0, 0, 0, 200)
	blind_num = _label("10", 140, f_display, RED)
	blind_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bs := _label("Tu es le chasseur · les chassés se dispersent", 22, f_display, MUTED)
	bs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bs.uppercase = true
	bb.add_child(blind_num)
	bb.add_child(bs)
	blind.add_child(bb)
	game_root.add_child(blind)

	board = PanelContainer.new()
	var bstyle := _flat(PANEL, 26)
	bstyle.border_color = RED
	bstyle.border_width_top = 4
	board.add_theme_stylebox_override("panel", bstyle)
	_place(board, 0.5, 0.5, 0.5, 0.5, -270, -200, 270, 200)
	board.grow_vertical = Control.GROW_DIRECTION_BOTH
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.visible = false
	var bv := _box(true, 6)
	board_title = _label("Scores", 34, f_display)
	board_title.uppercase = true
	board_sub = _label("", 15, f_body, MUTED)
	board_rows = _box(true, 2)
	bv.add_child(board_title)
	bv.add_child(board_sub)
	bv.add_child(board_rows)
	board.add_child(bv)
	game_root.add_child(board)


func _build_menu() -> void:
	menu = Control.new()
	_place(menu, 0, 0, 1, 1)
	add_child(menu)
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.05, 0.55)
	_place(bg, 0, 0, 1, 1)
	menu.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(PANEL, 36))
	_place(panel, 0, 0, 0, 1, 0, 0, 540, 0)
	menu.add_child(panel)
	menu_panel = panel
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var v := _box(true, 16)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(v)

	var spacer := Control.new()   # room for the accent of the big É
	spacer.custom_minimum_size.y = 14
	v.add_child(spacer)
	v.add_child(_label("CHAT PERCHÉ", 78, f_display))
	var tag := _label(" PARKOUR ", 34, f_display_it, Color.WHITE)
	tag.add_theme_stylebox_override("normal", _flat(RED, 10))
	tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(tag)
	var lede := _label("Un chasseur, des chassés, une ville de toits. Le chasseur doit toucher les autres. Les chassés fuient en glissant, en courant sur les murs et en grimpant aux rebords. Enchaîner les mouvements fait gagner de la vitesse.", 16, f_body, Color("#d5dbe1"))
	lede.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lede.custom_minimum_size.x = 440
	v.add_child(lede)

	v.add_child(_field_label("Pseudo"))
	name_edit = LineEdit.new()
	name_edit.max_length = 16
	name_edit.placeholder_text = "Ton pseudo"
	name_edit.add_theme_font_override("font", f_body)
	name_edit.add_theme_font_size_override("font_size", 20)
	v.add_child(name_edit)

	v.add_child(_field_label("Couleur"))
	var colors := _box(false, 8)
	colors.mouse_filter = Control.MOUSE_FILTER_PASS
	for i in COLORS.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(34, 34)
		b.toggle_mode = true
		var normal := _flat(COLORS[i])
		var on := _flat(COLORS[i])
		on.border_color = Color.WHITE
		on.set_border_width_all(3)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", normal)
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
		b.pressed.connect(_pick_color.bind(i))
		colors.add_child(b)
		color_buttons.append(b)
	v.add_child(colors)

	v.add_child(_field_label("Sensibilité souris"))
	sens_slider = HSlider.new()
	sens_slider.min_value = 0.3
	sens_slider.max_value = 2.5
	sens_slider.step = 0.05
	sens_slider.value = 1.0
	v.add_child(sens_slider)

	fullscreen_check = CheckButton.new()
	fullscreen_check.text = "Plein écran (F11)"
	fullscreen_check.add_theme_font_override("font", f_body)
	fullscreen_check.add_theme_font_size_override("font_size", 16)
	fullscreen_check.toggled.connect(func(on: bool): fullscreen_toggled.emit(on))
	v.add_child(fullscreen_check)

	var keys_b := _button("Touches", false)
	keys_b.add_theme_font_size_override("font_size", 18)
	keys_b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	keys_b.pressed.connect(func(): _show_keys(not keys_panel.visible))
	v.add_child(keys_b)

	v.add_child(_field_label("Adresse de l'hôte (pour rejoindre)"))
	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.add_theme_font_override("font", f_body)
	ip_edit.add_theme_font_size_override("font_size", 18)
	v.add_child(ip_edit)

	start_btns = _box(false, 10)
	start_btns.mouse_filter = Control.MOUSE_FILTER_PASS
	var host_b := _button("Héberger", true)
	var join_b := _button("Rejoindre", false)
	var solo_b := _button("Solo", false)
	host_b.pressed.connect(func(): host_pressed.emit())
	join_b.pressed.connect(func(): join_pressed.emit(ip_edit.text.strip_edges()))
	solo_b.pressed.connect(func(): solo_pressed.emit())
	start_btns.add_child(host_b)
	start_btns.add_child(join_b)
	start_btns.add_child(solo_b)
	v.add_child(start_btns)

	pause_btns = _box(false, 10)
	pause_btns.mouse_filter = Control.MOUSE_FILTER_PASS
	var resume_b := _button("Reprendre", true)
	start_round_btn = _button("Lancer la manche", false)
	var leave_b := _button("Quitter", false)
	resume_b.pressed.connect(func(): resume_pressed.emit())
	start_round_btn.pressed.connect(func(): start_pressed.emit())
	leave_b.pressed.connect(func(): leave_pressed.emit())
	pause_btns.add_child(resume_b)
	pause_btns.add_child(start_round_btn)
	pause_btns.add_child(leave_b)
	pause_btns.visible = false
	v.add_child(pause_btns)

	status_l = _label("", 15, f_body, MUTED)
	status_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_l.custom_minimum_size.x = 440
	v.add_child(status_l)

	help_grid = GridContainer.new()
	help_grid.columns = 2
	help_grid.add_theme_constant_override("h_separation", 14)
	help_grid.add_theme_constant_override("v_separation", 6)
	v.add_child(help_grid)
	_fill_help()
	var note := _label("Pour jouer en ligne, l'hôte doit ouvrir le port UDP 7777 (ou utilisez un réseau privé virtuel comme Tailscale). Voir le README.", 13, f_body, MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 440
	v.add_child(note)
	_build_keys_panel()


## Controls help, written with the player's current bindings.
func _fill_help() -> void:
	for c in help_grid.get_children():
		c.queue_free()
	var jump := Keys.name_of("jump")
	for pair in [
		[Keys.move_names(), "Courir"],
		[jump, "Sauter. Face à un mur : grimper. Contre un mur sur le côté, en l'air : saut mural."],
		[Keys.name_of("sprint"), "Sprinter (au sol). Consomme l'endurance, qui se recharge quand tu ne sprintes pas."],
		[Keys.name_of("slide"), "Glisser en courant. Juste avant d'atterrir d'une chute : roulade."],
		["Course murale", "Sauter le long d'un mur en avançant, puis %s pour rebondir." % jump],
		["Rebords", "En l'air face à un rebord : %s pour s'agripper et se hisser." % jump],
		[Keys.name_of("tag"), "Chasseur : toucher un chassé dans le viseur, de près."],
		[Keys.name_of("pulse"), "Chasseur : sonar, révèle les chassés à travers les murs."],
		["Bonus", "À ramasser sur la carte : Turbo (vitesse), Ressort (sauts), Second souffle (sprint gratuit), Bouclier (bloque un contact du chasseur ; pour le chasseur, recharge le sonar)."],
		["Balises", "Chassé : rejoins au moins une des balises (colonnes de lumière) avant la fin du compte à rebours, +50 par balise. Sinon, le chasseur te voit à travers les murs 6 s."],
		[Keys.name_of("start_round"), "Lancer la manche (2 joueurs minimum)."],
		["%s · Échap" % Keys.name_of("scores"), "Scores · menu"],
		[Keys.name_of("fullscreen"), "Plein écran"],
	]:
		var k := _label(pair[0], 16, f_display)
		k.custom_minimum_size.x = 110
		k.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		help_grid.add_child(k)
		var d := _label(pair[1], 14, f_body, Color("#cfd6dd"))
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size.x = 300
		help_grid.add_child(d)


## Settings screen next to the menu: one button per action; click it, then
## press the new key or mouse button.
func _build_keys_panel() -> void:
	keys_panel = PanelContainer.new()
	var style := _flat(Color(0.06, 0.07, 0.09, 0.96), 30)
	style.border_color = RED
	style.border_width_left = 3
	keys_panel.add_theme_stylebox_override("panel", style)
	_place(keys_panel, 0, 0, 0, 1, 540, 0, 1020, 0)
	keys_panel.visible = false
	menu.add_child(keys_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	keys_panel.add_child(scroll)
	var v := _box(true, 10)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(v)
	v.add_child(_label("TOUCHES", 40, f_display))
	var sub := _label("Clique sur une action, puis appuie sur la touche ou le bouton de souris voulu. Échap annule. Une touche déjà prise est échangée.", 14, f_body, MUTED)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size.x = 400
	v.add_child(sub)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 4)
	grid.mouse_filter = Control.MOUSE_FILTER_PASS
	for pair in Keys.ACTIONS:
		var l := _label(pair[1], 17, f_body)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(l)
		var b := _button("", false)
		b.add_theme_font_size_override("font_size", 18)
		b.custom_minimum_size.x = 170
		for st in ["normal", "hover", "pressed", "focus"]:   # compact rows
			var sb := b.get_theme_stylebox(st).duplicate() as StyleBoxFlat
			sb.content_margin_top = 4
			sb.content_margin_bottom = 4
			b.add_theme_stylebox_override(st, sb)
		b.pressed.connect(_start_capture.bind(pair[0]))
		grid.add_child(b)
		key_buttons[pair[0]] = b
	v.add_child(grid)
	var fixed := _label("Toujours actives : les flèches pour se déplacer, F pour toucher, Échap pour le menu.", 13, f_body, MUTED)
	fixed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fixed.custom_minimum_size.x = 400
	v.add_child(fixed)
	var row := _box(false, 10)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var reset_b := _button("Réinitialiser", false)
	var close_b := _button("Fermer", true)
	reset_b.pressed.connect(func(): keys_reset.emit())
	close_b.pressed.connect(func(): _show_keys(false))
	row.add_child(reset_b)
	row.add_child(close_b)
	v.add_child(row)
	refresh_keys()


func _show_keys(on: bool) -> void:
	_capture = ""
	keys_panel.visible = on
	# right against the menu, whose width follows its content
	keys_panel.offset_left = menu_panel.size.x
	keys_panel.offset_right = menu_panel.size.x + 480
	refresh_keys()


func _start_capture(action: String) -> void:
	refresh_keys()
	_capture = action
	key_buttons[action].text = "Appuie sur une touche…"


## While waiting for a binding, the next key or mouse press goes to it.
func _input(e: InputEvent) -> void:
	if _capture == "":
		return
	var key := e as InputEventKey
	var mouse := e as InputEventMouseButton
	if (key != null and key.pressed and not key.echo) or (mouse != null and mouse.pressed):
		get_viewport().set_input_as_handled()
		var action := _capture
		_capture = ""
		if key != null and key.physical_keycode == KEY_ESCAPE:
			refresh_keys()
			return
		key_chosen.emit(action, e)


## Updates every text that names a key, after a change of bindings.
func refresh_keys() -> void:
	for a in key_buttons:
		key_buttons[a].text = Keys.name_of(a)
	fullscreen_check.text = "Plein écran (%s)" % Keys.name_of("fullscreen")
	_fill_help()


func _field_label(text: String) -> Label:
	var l := _label(text, 14, f_display, MUTED)
	l.uppercase = true
	return l


func _pick_color(i: int) -> void:
	color_idx = i
	for k in color_buttons.size():
		color_buttons[k].set_pressed_no_signal(k == i)


# ------------------------------------------------------------------ menu state

func show_main_menu(status := "") -> void:
	menu.visible = true
	game_root.visible = false
	start_btns.visible = true
	pause_btns.visible = false
	status_l.text = status


func show_pause(can_start: bool) -> void:
	menu.visible = true
	start_btns.visible = false
	pause_btns.visible = true
	start_round_btn.visible = can_start


func show_game() -> void:
	_show_keys(false)
	menu.visible = false
	game_root.visible = true


func set_status(text: String) -> void:
	status_l.text = text


# ------------------------------------------------------------------ HUD updates

func set_speed(hs: float, run: float, vmax: float, combo: int) -> void:
	speed_l.text = "%d km/h" % roundi(hs * 3.6)
	speed_fill.size = Vector2(180.0 * clampf(hs / vmax, 0.0, 1.0), 5)
	speed_fill.color = RED if hs > run + 0.5 else INK
	combo_l.text = "Enchaînement ×%d" % combo if combo > 1 else ""
	(vig_speed.material as ShaderMaterial).set_shader_parameter("strength", clampf((hs - 9.0) / 8.0, 0.0, 0.55))


## Light blue bar, white while sprinting, red when empty until it recovers.
func set_stamina(v: float, exhausted: bool, sprinting: bool, visible_now: bool) -> void:
	stamina_box.visible = visible_now
	stamina_fill.size = Vector2(180.0 * clampf(v, 0.0, 1.0), 8)
	stamina_fill.color = RED if exhausted else (INK if sprinting else Color("#7fd0ff"))


## Bonus effect in use, above the speed ("" hides it).
func set_effect(text: String, color := INK) -> void:
	effect_l.visible = text != ""
	effect_l.text = text
	effect_l.add_theme_color_override("font_color", color)


func set_danger(v: float) -> void:
	(vig_danger.material as ShaderMaterial).set_shader_parameter("strength", v * 0.8)


func flash_screen(alpha: float) -> void:
	flash_rect.color.a = maxf(flash_rect.color.a, alpha)


func flash_move(text: String) -> void:
	flash_l.text = text
	if _flash_tween:
		_flash_tween.kill()
	flash_l.modulate.a = 1.0
	_flash_tween = create_tween()
	_flash_tween.tween_interval(0.5)
	_flash_tween.tween_property(flash_l, "modulate:a", 0.0, 0.4)


func message(text: String) -> void:
	center_sub.text = text
	_msg_t = 2.2


func _process(delta: float) -> void:
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			center_sub.text = ""
	flash_rect.color.a = maxf(0.0, flash_rect.color.a - delta * 2.0)


func set_top(timer: String, phase: String) -> void:
	timer_l.text = timer
	phase_l.text = phase


func set_role(text: String, kind: String, hint: String) -> void:
	role_l.text = text
	var bg := RED if kind == "hunter" else (Color(1, 1, 1, 0.2) if kind == "spec" else INK)
	role_l.add_theme_stylebox_override("normal", _flat(bg, 12))
	role_l.add_theme_color_override("font_color", INK if kind != "normal" else Color("#111"))
	role_hint_l.text = hint


## rows: Array of {name, color, status, hunter, out}
func set_players(rows: Array) -> void:
	for c in players_box.get_children():
		c.queue_free()
	for r in rows:
		var hb := _box(false, 8)
		var dot := ColorRect.new()
		dot.color = RED if r.hunter else r.color
		dot.custom_minimum_size = Vector2(10, 10)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := _label(r.name, 17, f_display)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var s := _label(r.status, 14, f_display, Color("#ff8a80") if r.hunter else MUTED)
		s.uppercase = true
		hb.add_child(dot)
		hb.add_child(n)
		hb.add_child(s)
		hb.modulate.a = 0.45 if r.out else 1.0
		players_box.add_child(hb)


func set_center(big: String) -> void:
	center_big.text = big


func set_hint(text: String) -> void:
	hint_l.text = text
	hint_l.visible = text != ""


func set_pulse(visible_now: bool, text: String) -> void:
	pulse_l.visible = visible_now
	pulse_l.text = "SONAR  " + text


func set_beacon(text: String, color: Color) -> void:
	beacon_l.visible = text != ""
	beacon_l.text = text
	beacon_l.add_theme_color_override("font_color", color)


## Marker i follows beacon i on screen (pos is in viewport pixels).
func set_beacon_marker(i: int, on: bool, pos := Vector2.ZERO, text := "", color := INK) -> void:
	while beacon_marks.size() <= i:
		var m := _label("", 16, f_display)
		m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		m.size = Vector2(120, 44)
		m.visible = false
		game_root.add_child(m)
		beacon_marks.append(m)
	var mark := beacon_marks[i]
	mark.visible = on
	if not on:
		return
	mark.text = "◆\n" + text
	mark.add_theme_color_override("font_color", color)
	mark.position = pos - mark.size / 2.0


func hide_beacon_markers() -> void:
	for m in beacon_marks:
		m.visible = false


func set_cross(mode: String) -> void:
	cross.set_mode(mode)


func set_blind(on: bool, seconds: int) -> void:
	blind.visible = on
	blind_num.text = str(seconds)


## rows: Array of {name, color, tag, score}
func set_board(on: bool, title := "", sub := "", rows := []) -> void:
	board.visible = on
	if not on:
		return
	board_title.text = title
	board_sub.text = sub
	for c in board_rows.get_children():
		c.queue_free()
	for r in rows:
		var hb := _box(false, 12)
		var dot := ColorRect.new()
		dot.color = r.color
		dot.custom_minimum_size = Vector2(12, 12)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var n := _label(r.name, 17, f_body)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t := _label(r.tag, 14, f_display, MUTED)
		t.uppercase = true
		var s := _label(str(r.score), 22, f_display)
		hb.add_child(dot)
		hb.add_child(n)
		hb.add_child(t)
		hb.add_child(s)
		board_rows.add_child(hb)
