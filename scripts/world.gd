extends Node3D
class_name World
## Builds the rooftop city (same seed on every machine) and answers the geometric
## questions the parkour controller asks: which wall is beside me, where is the top
## of that ledge, is there room to stand here.
##
## Every solid is an axis-aligned box registered with add_box(). The boxes feed both
## Godot's collision (StaticBody3D) and a small spatial grid used by the probes.

const R := 0.35
const HS := 1.8
const HL := 0.95
const CELL := 8.0

class Box:
	var x0: float
	var y0: float
	var z0: float
	var x1: float
	var y1: float
	var z1: float
	var kind: String
	var tint: Color
	var stamp := 0

	func _init(ax0: float, ay0: float, az0: float, ax1: float, ay1: float, az1: float, akind: String, atint: Color) -> void:
		x0 = minf(ax0, ax1)
		x1 = maxf(ax0, ax1)
		z0 = minf(az0, az1)
		z1 = maxf(az0, az1)
		y0 = ay0
		y1 = ay1
		kind = akind
		tint = atint


class Ramp:
	var x0: float
	var x1: float
	var z0: float
	var z1: float
	var lo: float
	var hi: float
	var ax: String   # "x" or "z": the axis the slope runs along
	var up: int      # +1: high end at x1/z1, -1: high end at x0/z0
	var thick: float # < 0: solid down to the street; else a slab this thick (a bridge)

	func _init(ax0: float, ax1: float, az0: float, az1: float, alo: float, ahi: float, aax: String, aup: int, athick := -1.0) -> void:
		x0 = ax0
		x1 = ax1
		z0 = az0
		z1 = az1
		lo = alo
		hi = ahi
		ax = aax
		up = aup
		thick = athick

	## Underside of the ramp at (x, z): the street for a solid ramp.
	func bottom_at(x: float, z: float) -> float:
		return 0.0 if thick < 0.0 else maxf(0.0, y_at(x, z) - thick)

	func contains(x: float, z: float) -> bool:
		return x >= x0 and x <= x1 and z >= z0 and z <= z1

	func y_at(x: float, z: float) -> float:
		var t := (x - x0) / (x1 - x0) if ax == "x" else (z - z0) / (z1 - z0)
		if up < 0:
			t = 1.0 - t
		return lo + (hi - lo) * clampf(t, 0.0, 1.0)

	## Horizontal direction pointing downhill.
	func downhill() -> Vector3:
		return Vector3(-up, 0, 0) if ax == "x" else Vector3(0, 0, -up)

	func grade() -> float:
		return (hi - lo) / ((x1 - x0) if ax == "x" else (z1 - z0))


class Bucket:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var c := PackedColorArray()


var boxes: Array[Box] = []
var ramps: Array[Ramp] = []
var decor: Array = []          # render-only skyline boxes
var buildings: Array = []      # one Dictionary per city block (null for the plaza)
var spawns_runner: Array[Vector3] = []
var beacon_spots: Array[Vector3] = []   # where the server may place a beacon
var crate_steps: Array = []    # {p: street point in front, n: normal out of the wall, top: roof}
var hunter_spawn := Vector3(0, 2.2, 0)

var _keep_clear: Array[Rect2] = []   # roof areas (x, z) where bridges and ramps land
var _grid := {}
var _stamp := 0
var _q: Array[Box] = []
var _rng := RandomNumberGenerator.new()


# ------------------------------------------------------------------ queries

func add_box(x0: float, y0: float, z0: float, x1: float, y1: float, z1: float, kind: String, tint := Color.WHITE) -> Box:
	var b := Box.new(x0, y0, z0, x1, y1, z1, kind, tint)
	boxes.append(b)
	return b


func _key(gx: int, gz: int) -> int:
	return (gx + 512) * 1024 + (gz + 512)


func _index() -> void:
	_grid.clear()
	for b in boxes:
		for gx in range(floori(b.x0 / CELL), floori(b.x1 / CELL) + 1):
			for gz in range(floori(b.z0 / CELL), floori(b.z1 / CELL) + 1):
				var k := _key(gx, gz)
				if not _grid.has(k):
					_grid[k] = []
				_grid[k].append(b)


## Boxes whose grid cells touch the rectangle. The returned array is reused by the
## next call, so never call another query while iterating it.
func query(x0: float, z0: float, x1: float, z1: float) -> Array[Box]:
	_q.clear()
	_stamp += 1
	for gx in range(floori(x0 / CELL), floori(x1 / CELL) + 1):
		for gz in range(floori(z0 / CELL), floori(z1 / CELL) + 1):
			var cell = _grid.get(_key(gx, gz))
			if cell == null:
				continue
			for b: Box in cell:
				if b.stamp != _stamp:
					b.stamp = _stamp
					_q.append(b)
	return _q


func box_hit(x0: float, y0: float, z0: float, x1: float, y1: float, z1: float) -> Box:
	for b in query(x0, z0, x1, z1):
		if x0 < b.x1 and x1 > b.x0 and y0 < b.y1 and y1 > b.y0 and z0 < b.z1 and z1 > b.z0:
			return b
	return null


## The ramp whose surface is under (x, z). With y given, only one whose surface
## is within half a metre of y, so a runner under a bridge is not "on" it.
func ramp_at(x: float, z: float, y := NAN) -> Ramp:
	for r in ramps:
		if r.contains(x, z) and (is_nan(y) or absf(r.y_at(x, z) - y) < 0.5):
			return r
	return null


func is_free(x: float, y: float, z: float, h: float) -> bool:
	if box_hit(x - R, y + 0.01, z - R, x + R, y + h, z + R) != null:
		return false
	for r in ramps:
		if r.contains(x, z) and y < r.y_at(x, z) - 0.05 and y + h > r.bottom_at(x, z) + 0.01:
			return false
	return true


## Highest walkable surface under (x, z) between y - depth and y. NAN when none.
func support_top(x: float, y: float, z: float, depth: float) -> float:
	var best := NAN
	for b in query(x - R, z - R, x + R, z + R):
		if x - R < b.x1 and x + R > b.x0 and z - R < b.z1 and z + R > b.z0 and b.y1 <= y + 0.01 and b.y1 >= y - depth:
			if is_nan(best) or b.y1 > best:
				best = b.y1
	for r in ramps:
		if not r.contains(x, z):
			continue
		var sy := r.y_at(x, z)
		if sy <= y + 0.01 and sy >= y - depth and (is_nan(best) or sy > best):
			best = sy
	return best


## Thin slab beside the player on the side the wall would be, for a wall whose
## normal (pointing back at the player) is n. Returned as (x0, z0, x1, z1).
func _slab(p: Vector3, n: Vector2i, dist: float) -> Vector4:
	var x0 := p.x - R + 0.05
	var x1 := p.x + R - 0.05
	var z0 := p.z - R + 0.05
	var z1 := p.z + R - 0.05
	if n.x > 0:
		x1 = p.x - R
		x0 = x1 - dist
	elif n.x < 0:
		x0 = p.x + R
		x1 = x0 + dist
	if n.y > 0:
		z1 = p.z - R
		z0 = z1 - dist
	elif n.y < 0:
		z0 = p.z + R
		z1 = z0 + dist
	return Vector4(x0, z0, x1, z1)


## Tallest box within `dist` of the player on the wall side of normal n, overlapping
## the height band [p.y + ylo, p.y + yhi].
func wall_probe(p: Vector3, n: Vector2i, dist: float, ylo: float, yhi: float) -> Box:
	var r := _slab(p, n, dist)
	var y0 := p.y + ylo
	var y1 := p.y + yhi
	var best: Box = null
	for b in query(r.x, r.y, r.z, r.w):
		if r.x < b.x1 and r.z > b.x0 and r.y < b.z1 and r.w > b.z0 and y0 < b.y1 and y1 > b.y0:
			if best == null or b.y1 > best.y1:
				best = b
	return best


## A ledge in front of the player whose top lies between p.y + lo and p.y + hi, with
## room to crouch on top. Box tops and ramp edges both count. Returns {} or
## {top, tx, tz, n, face}.
func find_ledge(p: Vector3, cur_h: float, n: Vector2i, lo: float, hi: float, dist: float) -> Dictionary:
	var r := _slab(p, n, dist)
	var top := -INF
	var face := 0.0
	if wall_probe(p, n, dist, lo - 0.6, hi) != null:
		for c in query(r.x, r.y, r.z, r.w):
			if not (r.x < c.x1 and r.z > c.x0 and r.y < c.z1 and r.w > c.z0):
				continue
			if c.y1 < p.y + lo or c.y1 > p.y + hi or c.y1 - c.y0 < 0.25:
				continue
			if c.y1 > top:
				top = c.y1
				face = _face_of(n, c.x0, c.x1, c.z0, c.z1)
	# the edge of a ramp ahead: its surface where the player would pull up to
	for rp in ramps:
		if not (r.x < rp.x1 and r.z > rp.x0 and r.y < rp.z1 and r.w > rp.z0):
			continue
		var f := _face_of(n, rp.x0, rp.x1, rp.z0, rp.z1)
		var ahead := (f - p.x) * -n.x if n.x != 0 else (f - p.z) * -n.y
		if ahead < R - 0.05:   # that edge is beside or behind us: we are on this ramp
			continue
		var rx := f - n.x * (R + 0.3) if n.x != 0 else p.x
		var rz := f - n.y * (R + 0.3) if n.y != 0 else p.z
		if not rp.contains(rx, rz):
			continue
		# an edge level with our feet (the foot of a ramp) is walked onto, not vaulted
		var ex := f if n.x != 0 else p.x
		var ez := f if n.y != 0 else p.z
		if absf(rp.y_at(ex, ez) - p.y) < 0.2:
			continue
		var ry := rp.y_at(rx, rz)
		if ry < p.y + lo or ry > p.y + hi or ry - rp.bottom_at(rx, rz) < 0.25:
			continue
		if ry > top:
			top = ry
			face = f
	if top == -INF:
		return {}
	var tx := face - n.x * (R + 0.3) if n.x != 0 else p.x
	var tz := face - n.y * (R + 0.3) if n.y != 0 else p.z
	var tr := ramp_at(tx, tz, top)
	if tr != null:   # pulling up onto a slope: land on its surface there
		top = tr.y_at(tx, tz)
	if not is_free(tx, top, tz, HL):
		return {}
	if box_hit(p.x - R, p.y + cur_h, p.z - R, p.x + R, top + HL, p.z + R) != null:
		return {}
	return {"top": top, "tx": tx, "tz": tz, "n": n, "face": face}


## The side of a rectangle facing a player whose wall normal is n.
static func _face_of(n: Vector2i, x0: float, x1: float, z0: float, z1: float) -> float:
	if n.x > 0:
		return x1
	if n.x < 0:
		return x0
	if n.y > 0:
		return z1
	return z0


## True when the ramp under p carries on, level, onto that ledge: walking up a
## ramp onto a roof or a landing is a step, not something to vault.
func ramp_leads_to(p: Vector3, ledge: Dictionary) -> bool:
	var r := ramp_at(p.x, p.z, p.y)
	return r != null and absf(r.y_at(float(ledge.tx), float(ledge.tz)) - float(ledge.top)) < 0.2


static func wall_key(n: Vector2i, b: Box) -> String:
	var f := b.x1 if n.x > 0 else (b.x0 if n.x < 0 else (b.z1 if n.y > 0 else b.z0))
	return "%d,%d,%.1f" % [n.x, n.y, f]


## Distance along the ray to the box, or -1 when it misses.
static func ray_box(o: Vector3, d: Vector3, bmin: Vector3, bmax: Vector3) -> float:
	var tmin := 0.0
	var tmax := INF
	for i in 3:
		if absf(d[i]) < 1e-9:
			if o[i] < bmin[i] or o[i] > bmax[i]:
				return -1.0
			continue
		var t1 := (bmin[i] - o[i]) / d[i]
		var t2 := (bmax[i] - o[i]) / d[i]
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	return tmin


func ray_blocked(o: Vector3, d: Vector3, max_t: float) -> bool:
	var e := o + d * max_t
	for b in query(minf(o.x, e.x), minf(o.z, e.z), maxf(o.x, e.x), maxf(o.z, e.z)):
		var t := ray_box(o, d, Vector3(b.x0, b.y0, b.z0), Vector3(b.x1, b.y1, b.z1))
		if t >= 0.0 and t < max_t:
			return true
	return false


# ------------------------------------------------------------------ map

func _rnd() -> float:
	return _rng.randf()


func _height_at(rec: Dictionary, x: float, z: float) -> float:
	var h := 0.0
	for p in rec.parts:
		if x >= p[0] - 0.01 and x <= p[1] + 0.01 and z >= p[2] - 0.01 and z <= p[3] + 0.01:
			h = maxf(h, p[4])
	return h


func generate() -> void:
	_rng.seed = 20261016
	var lots := [-40.0, -20.0, 0.0, 20.0, 40.0]
	# Roofs climb towards the centre one step at a time (1 to 1.5 m): heading in, a
	# jump across the street ends in a vault; heading out, the bridges slide down.
	var ht := [[4.5, 5.5, 6.5, 5.5, 4.5], [5.5, 7.0, 8.0, 7.0, 5.5], [6.5, 8.0, 0.0, 8.0, 6.5], [5.5, 7.0, 8.0, 7.0, 5.5], [4.5, 5.5, 6.5, 5.5, 4.5]]
	var tints := [Color("#e8dccb"), Color("#d3dbe3"), Color("#e6cfbd"), Color("#d4dcc9"), Color("#ddd6cd"), Color("#d9d9d9")]
	add_box(-300, -1, -300, 300, 0, 300, "ground")

	for j in 5:
		for i in 5:
			if i == 2 and j == 2:
				buildings.append(null)
				continue
			# 15-16 m blocks on a 20 m grid: streets of 3.6 to 5.2 m, jumpable at a run
			var cx: float = lots[i] + (_rnd() - 0.5) * 0.8
			var cz: float = lots[j] + (_rnd() - 0.5) * 0.8
			var sx := 15.2 + _rnd() * 0.8
			var sz := 15.2 + _rnd() * 0.8
			var h: float = ht[j][i]
			var rec := {"x0": cx - sx / 2, "x1": cx + sx / 2, "z0": cz - sz / 2, "z1": cz + sz / 2, "h": h, "i": i, "j": j, "cx": cx, "cz": cz, "parts": [], "ramp": ""}
			var tint: Color = tints[_rng.randi() % tints.size()]
			if _rnd() < 0.4:   # a terrace 1.5 m lower on one side: one more step to vault
				var f := 0.3 + _rnd() * 0.15
				var low_first := _rnd() < 0.5
				var a := f if low_first else 1.0 - f
				var ha := h - 1.5 if low_first else h
				var hb := h if low_first else h - 1.5
				if _rnd() < 0.5:
					var xm: float = rec.x0 + sx * a
					rec.parts = [[rec.x0, xm, rec.z0, rec.z1, ha], [xm, rec.x1, rec.z0, rec.z1, hb]]
				else:
					var zm: float = rec.z0 + sz * a
					rec.parts = [[rec.x0, rec.x1, rec.z0, zm, ha], [rec.x0, rec.x1, zm, rec.z1, hb]]
			else:
				rec.parts = [[rec.x0, rec.x1, rec.z0, rec.z1, h]]
			for p in rec.parts:
				add_box(p[0], 0, p[2], p[1], p[4], p[3], "bld", tint)
			buildings.append(rec)

	# street access: a long ramp along an outer wall of the corner and mid-side
	# blocks, and two ramps from the plaza up onto the blocks around it
	for rec in buildings:
		if rec == null or (rec.i + rec.j) % 2 == 1:
			continue
		var outer := []
		if rec.j == 0:
			outer.append("n")
		if rec.j == 4:
			outer.append("s")
		if rec.i == 0:
			outer.append("w")
		if rec.i == 4:
			outer.append("e")
		if not outer.is_empty():
			_side_ramp(rec, outer[_rng.randi() % outer.size()])
	_side_ramp(buildings[1 * 5 + 2], "s")
	_side_ramp(buildings[3 * 5 + 2], "n")

	# on another face of every block, two crates up against the wall: vault, vault,
	# then a jump into a wall climb up the last stretch
	for rec in buildings:
		if rec == null:
			continue
		var sides := ["n", "s", "w", "e"].filter(func(sd): return sd != rec.ramp)
		_crate_steps(rec, sides[_rng.randi() % sides.size()])
		for k in 1 + _rng.randi() % 2:   # loose crates along the streets, to vault
			var sd: String = sides[_rng.randi() % sides.size()]
			var big := _rnd() < 0.35
			_street_crate(rec, sd, 2.2 if big else 1.2, 1.3 if big else 1.2, "dark" if big else "red")

	# links between neighbouring roofs: now and then a sloped bridge down to the
	# lower roof, and wall-run billboards
	for j in 5:
		for i in 5:
			var a = buildings[j * 5 + i]
			if a == null:
				continue
			for dd in [Vector2i(1, 0), Vector2i(0, 1)]:
				if i + dd.x > 4 or j + dd.y > 4:
					continue
				var c = buildings[(j + dd.y) * 5 + i + dd.x]
				if c == null:
					continue
				_link(a, c, dd.x == 1)

	# rooftop obstacles last, kept off the lanes where bridges and ramps arrive
	for rec in buildings:
		if rec != null:
			_roof_course(rec)

	# central plaza
	add_box(-3, 0, -3, 3, 2.2, 3, "red")
	ramps.append(Ramp.new(3, 9, -1.5, 1.5, 0, 2.2, "x", -1))
	ramps.append(Ramp.new(-9, -3, -1.5, 1.5, 0, 2.2, "x", 1))
	add_box(-9.5, 0, -8.2, -3.5, 4.5, -7.8, "light")     # wall-run walls
	add_box(3.5, 0, 7.8, 9.5, 4.5, 8.2, "light")
	add_box(-8, 0, 4.5, -4, 1.0, 5.0, "light")           # vault walls
	add_box(4, 0, -5.0, 8, 1.0, -4.5, "light")
	for zs in [1.0, -1.0]:                                # slide-under beams on posts
		var za: float = 6.0 * zs
		var zb: float = 6.3 * zs
		add_box(-1.5, 0, za, -1.2, 1.15, zb, "dark")
		add_box(1.2, 0, za, 1.5, 1.15, zb, "dark")
		add_box(-1.5, 1.15, za, 1.5, 1.45, zb, "dark")

	# skyline ring that closes the map
	for a in range(-70, 70, 10):
		add_box(a, 0, -70, a + 10, 18 + _rnd() * 24, -58, "bld", tints[_rng.randi() % tints.size()])
		add_box(a, 0, 58, a + 10, 18 + _rnd() * 24, 70, "bld", tints[_rng.randi() % tints.size()])
	for a in range(-58, 58, 10):
		add_box(-70, 0, a, -58, 18 + _rnd() * 24, a + 10, "bld", tints[_rng.randi() % tints.size()])
		add_box(58, 0, a, 70, 18 + _rnd() * 24, a + 10, "bld", tints[_rng.randi() % tints.size()])
	for k in 90:
		var ang := _rnd() * TAU
		var dist := 95.0 + _rnd() * 120.0
		var s := 10.0 + _rnd() * 18.0
		var dh := 25.0 + _rnd() * 70.0
		var dx := cos(ang) * dist
		var dz := sin(ang) * dist
		decor.append({"x0": dx - s / 2, "x1": dx + s / 2, "z0": dz - s / 2, "z1": dz + s / 2, "h": dh, "tint": tints[k % tints.size()]})

	_index()

	for rec in buildings:
		if rec == null or absf(rec.cx) + absf(rec.cz) < 30.0:
			continue
		for p in rec.parts:
			var x: float = (p[0] + p[1]) / 2.0
			var z: float = (p[2] + p[3]) / 2.0
			for o in [Vector2(0, 0), Vector2(2.5, 2.5), Vector2(-2.5, -2.5), Vector2(2.5, -2.5)]:
				var top := support_top(x + o.x, 80.0, z + o.y, 100.0)
				if not is_nan(top) and is_free(x + o.x, top, z + o.y, HS):
					spawns_runner.append(Vector3(x + o.x, top, z + o.y))
					break
	var ht0 := support_top(0, 80, 0, 100)
	hunter_spawn = Vector3(0, 2.2 if is_nan(ht0) else ht0, 0)
	_find_beacon_spots()


## Beacon candidates: the middle of every roof (or a clear spot near it) and the
## street crossings, so runners are sent both up high and down low.
func _find_beacon_spots() -> void:
	var tries: Array[Vector2] = [Vector2(0, 0), Vector2(2.5, 2.5), Vector2(-2.5, -2.5), Vector2(2.5, -2.5), Vector2(-2.5, 2.5)]
	for rec in buildings:
		if rec == null:
			continue
		for p in rec.parts:
			var x: float = (p[0] + p[1]) / 2.0
			var z: float = (p[2] + p[3]) / 2.0
			for o in tries:
				var top := support_top(x + o.x, 80.0, z + o.y, 100.0)
				if not is_nan(top) and top > 1.0 and is_free(x + o.x, top, z + o.y, HS):
					beacon_spots.append(Vector3(x + o.x, top, z + o.y))
					break
	for sx in [-30.0, -10.0, 10.0, 30.0]:
		for sz in [-30.0, -10.0, 10.0, 30.0]:
			var top := support_top(sx, 2.0, sz, 3.0)
			if not is_nan(top) and is_free(sx, top, sz, HS):
				beacon_spots.append(Vector3(sx, top, sz))


## Rooftop obstacles laid along the running lines: vault units spaced to chain,
## the odd pipe to slide under, and a hut pushed into a corner.
func _roof_course(rec: Dictionary) -> void:
	for p in rec.parts:
		var w: float = p[1] - p[0]
		var d: float = p[3] - p[2]
		var top: float = p[4]
		var cx: float = (p[0] + p[1]) / 2.0
		var cz: float = (p[2] + p[3]) / 2.0
		var long_x := w >= d
		var length := w if long_x else d
		var n := 2 if length > 9.0 else 1
		var side := 1.0 if _rnd() < 0.5 else -1.0
		for k in n:   # a line of units across the long axis, 2.5 m off the middle
			var t := (float(k + 1) / (n + 1) - 0.5) * length
			var ux := cx + t if long_x else cx + side * 2.5
			var uz := cz + side * 2.5 if long_x else cz + t
			var uh := 0.9 + _rnd() * 0.25
			var hw := Vector2(0.5, 0.9) if long_x else Vector2(0.9, 0.5)
			_roof_box(p, ux - hw.x, uz - hw.y, ux + hw.x, uz + hw.y, top, top + uh, "light")
		if _rnd() < 0.35:   # pipe across the short axis, to slide under
			var m := (cx if long_x else cz) + (_rnd() - 0.5) * length * 0.5
			if long_x:
				_roof_box(p, m - 0.15, p[2] + 0.2, m + 0.15, p[3] - 0.2, top + 1.15, top + 1.45, "dark", false)
			else:
				_roof_box(p, p[0] + 0.2, m - 0.15, p[1] - 0.2, m + 0.15, top + 1.15, top + 1.45, "dark", false)
		if w * d > 120.0 and _rnd() < 0.3:   # hut in a corner: a wall to run or climb
			var hx: float = p[0] + 0.8 if _rnd() < 0.5 else p[1] - 4.4
			var hz: float = p[2] + 0.8 if _rnd() < 0.5 else p[3] - 3.8
			_roof_box(p, hx, hz, hx + 3.6, hz + 3.0, top, top + 2.6, "light")


## Adds a rooftop box unless it would stick out over the edge or sit on a lane
## kept clear for a bridge or a ramp landing.
func _roof_box(p: Array, x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, kind: String, inside := true) -> void:
	if inside and (x0 < p[0] + 0.8 or x1 > p[1] - 0.8 or z0 < p[2] + 0.8 or z1 > p[3] - 0.8):
		return
	var r := Rect2(x0, z0, x1 - x0, z1 - z0)
	for lane in _keep_clear:
		if lane.intersects(r):
			return
	add_box(x0, y0, z0, x1, y1, z1, kind)


## Keeps a 4 m deep, 3.4 m wide lane clear on the roof on each side of a link
## spanning the street from g0 to g1 at m.
func _clear_lane(along_x: bool, g0: float, g1: float, m: float) -> void:
	if along_x:
		_keep_clear.append(Rect2(g0 - 4.0, m - 1.7, (g1 - g0) + 8.0, 3.4))
	else:
		_keep_clear.append(Rect2(m - 1.7, g0 - 4.0, 3.4, (g1 - g0) + 8.0))


## Long ramp along one face of a block, from the street up to a landing level
## with the roof: the runner steps sideways onto the roof there, or slides down
## the ramp for speed.
func _side_ramp(rec: Dictionary, side: String) -> void:
	var w := 2.6
	var m := 0.6       # keeps clear of the corners
	var landing := 2.6
	var up := 1 if _rnd() < 0.5 else -1
	rec.ramp = side
	if side == "n" or side == "s":
		var x0: float = rec.x0 + m
		var x1: float = rec.x1 - m
		var zin: float = rec.z0 + 0.2 if side == "n" else rec.z1 - 0.2
		var hi := _height_at(rec, x1 - 0.2 if up > 0 else x0 + 0.2, zin)
		var z0: float = rec.z0 - w if side == "n" else rec.z1
		var lx := x1 - landing if up > 0 else x0
		if up > 0:
			ramps.append(Ramp.new(x0, x1 - landing, z0, z0 + w, 0, hi, "x", up))
		else:
			ramps.append(Ramp.new(x0 + landing, x1, z0, z0 + w, 0, hi, "x", up))
		add_box(lx, 0, z0, lx + landing, hi, z0 + w, "red")
		_keep_clear.append(Rect2(lx - 1.0, rec.z0 - 0.1 if side == "n" else rec.z1 - 4.0, landing + 2.0, 4.1))
	else:
		var z0: float = rec.z0 + m
		var z1: float = rec.z1 - m
		var xin: float = rec.x0 + 0.2 if side == "w" else rec.x1 - 0.2
		var hi := _height_at(rec, xin, z1 - 0.2 if up > 0 else z0 + 0.2)
		var x0: float = rec.x0 - w if side == "w" else rec.x1
		var lz := z1 - landing if up > 0 else z0
		if up > 0:
			ramps.append(Ramp.new(x0, x0 + w, z0, z1 - landing, 0, hi, "z", up))
		else:
			ramps.append(Ramp.new(x0, x0 + w, z0 + landing, z1, 0, hi, "z", up))
		add_box(x0, 0, lz, x0 + w, hi, lz + landing, "red")
		_keep_clear.append(Rect2(rec.x0 - 0.1 if side == "w" else rec.x1 - 4.0, lz - 1.0, 4.1, landing + 2.0))


## Footprint (x0, z0, x1, z1) of something set against face `side`, `depth` out
## into the street, `length` along the face starting `t` from the face's start.
func _against(rec: Dictionary, side: String, t: float, length: float, depth: float) -> Vector4:
	match side:
		"n":
			return Vector4(rec.x0 + t, rec.z0 - depth, rec.x0 + t + length, rec.z0)
		"s":
			return Vector4(rec.x0 + t, rec.z1, rec.x0 + t + length, rec.z1 + depth)
		"w":
			return Vector4(rec.x0 - depth, rec.z0 + t, rec.x0, rec.z0 + t + length)
	return Vector4(rec.x1, rec.z0 + t, rec.x1 + depth, rec.z0 + t + length)


func _face_len(rec: Dictionary, side: String) -> float:
	return (rec.x1 - rec.x0) if side == "n" or side == "s" else (rec.z1 - rec.z0)


## Two crates stepping up to a wall: 1.25 m out in the street, 2.5 m against it.
func _crate_steps(rec: Dictionary, side: String) -> void:
	var length := 2.4
	var t := 1.5 + _rnd() * (_face_len(rec, side) - 3.0 - length)
	var inner := _against(rec, side, t, length, 1.3)
	var outer := _against(rec, side, t, length, 2.6)
	add_box(inner.x, 0, inner.y, inner.z, 2.5, inner.w, "dark")
	var n := {"n": Vector2i(0, -1), "s": Vector2i(0, 1), "w": Vector2i(-1, 0), "e": Vector2i(1, 0)}[side] as Vector2i
	var mid := Vector3((outer.x + outer.z) / 2.0, 0, (outer.y + outer.w) / 2.0)
	var edge := mid + Vector3(n.x, 0, n.y) * 1.3   # outer face of the low crate
	var wall_pt := mid - Vector3(n.x, 0, n.y) * 1.5
	crate_steps.append({"p": edge, "n": n, "top": _height_at(rec, wall_pt.x, wall_pt.z)})
	match side:   # the outer crate is the part of `outer` beyond `inner`
		"n":
			add_box(outer.x, 0, outer.y, outer.z, 1.25, inner.y, "red")
		"s":
			add_box(outer.x, 0, inner.w, outer.z, 1.25, outer.w, "red")
		"w":
			add_box(outer.x, 0, outer.y, inner.x, 1.25, outer.w, "red")
		_:
			add_box(inner.z, 0, outer.y, outer.z, 1.25, outer.w, "red")


func _street_crate(rec: Dictionary, side: String, length: float, hh: float, kind: String) -> void:
	var t := 1.0 + _rnd() * (_face_len(rec, side) - 2.0 - length)
	var f := _against(rec, side, t, length, 1.2)
	add_box(f.x, 0, f.y, f.z, hh, f.w, kind)


## What joins two neighbouring roofs across the street between them.
func _link(a: Dictionary, c: Dictionary, along_x: bool) -> void:
	var o0: float = maxf(a.z0, c.z0) if along_x else maxf(a.x0, c.x0)
	var o1: float = minf(a.z1, c.z1) if along_x else minf(a.x1, c.x1)
	if o1 - o0 < 6.0:
		return
	var g0: float = a.x1 if along_x else a.z1
	var g1: float = c.x0 if along_x else c.z0
	var used := NAN
	var m := o0 + 2.5 + _rnd() * (o1 - o0 - 5.0)
	var ha := _height_at(a, a.x1 - 0.1, m) if along_x else _height_at(a, m, a.z1 - 0.1)
	var hc := _height_at(c, c.x0 + 0.1, m) if along_x else _height_at(c, m, c.z0 + 0.1)
	if absf(ha - hc) >= 0.9 and _rnd() < 0.35:
		# bridge sloping down to the lower roof, flush with both edges
		var up := 1 if hc > ha else -1
		var lo := minf(ha, hc)
		var hi := maxf(ha, hc)
		if along_x:
			ramps.append(Ramp.new(g0, g1, m - 1.2, m + 1.2, lo, hi, "x", up, 0.3))
		else:
			ramps.append(Ramp.new(m - 1.2, m + 1.2, g0, g1, lo, hi, "z", up, 0.3))
		_clear_lane(along_x, g0, g1, m)
		used = m
	if _rnd() < 0.45:   # billboard over the street: run along it to cross
		var b := o0 + 0.8 if _rnd() < 0.5 else o1 - 0.8
		if not is_nan(used) and absf(b - used) < 3.0:
			b = o1 - 0.8 if b == o0 + 0.8 else o0 + 0.8
		var hb := _height_at(a, a.x1 - 0.1, b) if along_x else _height_at(a, b, a.z1 - 0.1)
		var hd := _height_at(c, c.x0 + 0.1, b) if along_x else _height_at(c, b, c.z0 + 0.1)
		var y0 := maxf(2.4, minf(hb, hd) - 1.2)
		var y1 := maxf(hb, hd) + 2.8
		if along_x:
			add_box(g0 - 1.5, y0, b - 0.18, g1 + 1.5, y1, b + 0.18, "red")
		else:
			add_box(b - 0.18, y0, g0 - 1.5, b + 0.18, y1, g1 + 1.5, "red")


# ------------------------------------------------------------------ collision

func build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "Solids"
	add_child(body)
	for b in boxes:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(b.x1 - b.x0, b.y1 - b.y0, b.z1 - b.z0)
		cs.shape = bs
		cs.position = Vector3((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, (b.z0 + b.z1) / 2)
		body.add_child(cs)
	for r in ramps:
		var pts := PackedVector3Array()
		for c in [Vector2(r.x0, r.z0), Vector2(r.x1, r.z0), Vector2(r.x1, r.z1), Vector2(r.x0, r.z1)]:
			pts.append(Vector3(c.x, r.bottom_at(c.x, c.y), c.y))
			var top := r.y_at(c.x, c.y)
			if top > 0.01:
				pts.append(Vector3(c.x, top, c.y))
		var cs := CollisionShape3D.new()
		var shape := ConvexPolygonShape3D.new()
		shape.points = pts
		cs.shape = shape
		body.add_child(cs)


# ------------------------------------------------------------------ visuals

const SCALE := {"wall": 4.0, "roof": 4.0, "ground": 8.0, "red": 2.0, "dark": 2.0, "light": 2.0}


func build_visuals() -> void:
	var mats := {}
	for k in SCALE:
		var m := StandardMaterial3D.new()
		m.albedo_texture = _make_texture(k)
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.6 if k == "red" else 0.85
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		mats[k] = m
	var buckets := {}
	for k in SCALE:
		buckets[k] = Bucket.new()

	for b in boxes:
		var t := [b.y1, b.y1, b.y1, b.y1]
		if b.kind == "ground":
			_prism(buckets, "ground", "ground", b.x0, b.y0, b.z0, b.x1, b.z1, t, Color.WHITE, false)
		elif b.kind == "bld":
			_prism(buckets, "wall", "roof", b.x0, b.y0, b.z0, b.x1, b.z1, t, b.tint, true)
		else:
			_prism(buckets, b.kind, b.kind, b.x0, b.y0, b.z0, b.x1, b.z1, t, Color.WHITE, true)
	for d in decor:
		_prism(buckets, "wall", "roof", d.x0, 0, d.z0, d.x1, d.z1, [d.h, d.h, d.h, d.h], d.tint, true)
	for r in ramps:
		var t := [r.y_at(r.x0, r.z0), r.y_at(r.x1, r.z0), r.y_at(r.x1, r.z1), r.y_at(r.x0, r.z1)]
		var bot := [r.bottom_at(r.x0, r.z0), r.bottom_at(r.x1, r.z0), r.bottom_at(r.x1, r.z1), r.bottom_at(r.x0, r.z1)]
		_prism(buckets, "red", "red", r.x0, 0, r.z0, r.x1, r.z1, t, Color.WHITE, true, bot)

	for k in buckets:
		var bk: Bucket = buckets[k]
		if bk.v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = bk.v
		arrays[Mesh.ARRAY_NORMAL] = bk.n
		arrays[Mesh.ARRAY_TEX_UV] = bk.uv
		arrays[Mesh.ARRAY_COLOR] = bk.c
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mats[k]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if k == "ground" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mi)


func _uv(v: Vector3, mode: int, s: float) -> Vector2:
	if mode == 0:
		return Vector2(v.x, v.z) / s
	if mode == 1:
		return Vector2(v.z, -v.y) / s
	return Vector2(v.x, -v.y) / s


## Quad a-b-c-d given counter-clockwise as seen from outside. Godot treats clockwise
## triangles as front faces, so each triangle is emitted reversed.
func _quad(bk: Bucket, a: Vector3, b: Vector3, c: Vector3, d: Vector3, mode: int, s: float, col: Color) -> void:
	var nrm := (c - a).cross(d - b)
	if nrm.length_squared() < 1e-10:
		return
	nrm = nrm.normalized()
	for vtx: Vector3 in [a, c, b, a, d, c]:
		bk.v.append(vtx)
		bk.n.append(nrm)
		bk.c.append(col)
		bk.uv.append(_uv(vtx, mode, s))


## Box whose top corners can sit at different heights (ramps). Corner order for t
## (and for bot, the bottom corners of a bridge slab; flat at y0 when empty):
## (x0,z0), (x1,z0), (x1,z1), (x0,z1).
func _prism(buckets: Dictionary, side_k: String, top_k: String, x0: float, y0: float, z0: float, x1: float, z1: float, t: Array, col: Color, sides: bool, bot := []) -> void:
	var ta: float = t[0]
	var tb: float = t[1]
	var tc: float = t[2]
	var td: float = t[3]
	var b := [y0, y0, y0, y0] if bot.is_empty() else bot
	var ba: float = b[0]
	var bb: float = b[1]
	var bc: float = b[2]
	var bd: float = b[3]
	var bt: Bucket = buckets[top_k]
	var bs: Bucket = buckets[side_k]
	var st: float = SCALE[top_k]
	var ss: float = SCALE[side_k]
	_quad(bt, Vector3(x0, ta, z0), Vector3(x0, td, z1), Vector3(x1, tc, z1), Vector3(x1, tb, z0), 0, st, col)
	if not sides:
		return
	_quad(bs, Vector3(x1, bb, z0), Vector3(x1, tb, z0), Vector3(x1, tc, z1), Vector3(x1, bc, z1), 1, ss, col)
	_quad(bs, Vector3(x0, bd, z1), Vector3(x0, td, z1), Vector3(x0, ta, z0), Vector3(x0, ba, z0), 1, ss, col)
	_quad(bs, Vector3(x1, bc, z1), Vector3(x1, tc, z1), Vector3(x0, td, z1), Vector3(x0, bd, z1), 2, ss, col)
	_quad(bs, Vector3(x0, ba, z0), Vector3(x0, ta, z0), Vector3(x1, tb, z0), Vector3(x1, bb, z0), 2, ss, col)
	if not bot.is_empty():   # underside, seen from the street below a bridge
		_quad(bs, Vector3(x0, ba, z0), Vector3(x1, bb, z0), Vector3(x1, bc, z1), Vector3(x0, bd, z1), 0, ss, col)
	if y0 > 0.01:   # underside of floating pieces (catwalks, pipes, billboards)
		_quad(bs, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), 0, ss, col)


func _grid_lines(img: Image, step: int, col: Color, w: int) -> void:
	var s := img.get_width()
	for p in range(0, s, step):
		img.fill_rect(Rect2i(p, 0, w, s), col)
		img.fill_rect(Rect2i(0, p, s, w), col)


func _speckle(img: Image, n: int, amount: float) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	var s := img.get_width()
	for i in n:
		var x := r.randi() % (s - 1)
		var y := r.randi() % (s - 1)
		var c := img.get_pixel(x, y).darkened(r.randf() * amount)
		img.fill_rect(Rect2i(x, y, 2, 2), c)


func _make_texture(kind: String) -> ImageTexture:
	var size := 256 if kind in ["wall", "roof", "ground"] else 128
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	match kind:
		"wall":   # 4 m tile, 64 px per metre, floor at the bottom of the image
			img.fill(Color("#c6c4bf"))
			for k in 2:
				var x := int((k * 2 + 0.35) * 64)
				var w := int(1.3 * 64)
				var y := size - int(3.3 * 64)
				var h := int(2.4 * 64)
				img.fill_rect(Rect2i(x - 3, y - 3, w + 6, h + 6), Color("#9da1a5"))
				for row in h:
					img.fill_rect(Rect2i(x, y + row, w, 1), Color("#a8c6de").lerp(Color("#6d8fb0"), float(row) / h))
				img.fill_rect(Rect2i(x + 6, y + 6, int(w * 0.3), h - 12), Color("#b4c8d8"))
			img.fill_rect(Rect2i(0, size - 16, size, 16), Color("#acaca8"))
		"roof":
			img.fill(Color("#94979a"))
			_speckle(img, 900, 0.08)
			_grid_lines(img, 64, Color("#888b8e"), 2)
			_grid_lines(img, 256, Color("#7b7e82"), 4)
		"ground":
			img.fill(Color("#5c6169"))
			_speckle(img, 2500, 0.25)
			_grid_lines(img, 128, Color("#676c74"), 3)
		"red":
			img.fill(Color("#d63a2f"))
			img.fill_rect(Rect2i(0, 0, size, size / 2), Color("#da463c"))
			_grid_lines(img, 32, Color("#c4352b"), 2)
		"dark":
			img.fill(Color("#3b414a"))
			_grid_lines(img, 32, Color("#454b54"), 2)
		_:
			img.fill(Color("#bbb8b0"))
			_speckle(img, 200, 0.06)
			_grid_lines(img, 64, Color("#aaa79f"), 2)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
