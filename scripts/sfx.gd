extends Node
class_name Sfx
## Sound effects synthesised at startup, so the project ships without audio files.
##
## Each sound is built from layers: resonant filtered noise (swishes, scuffs,
## grit), pitched sines (thumps, chimes) and short echoes. Physical sounds get a
## few random variants and a small pitch jitter so repeats never sound identical.
## They go through a "World" bus with a light reverb; interface sounds stay dry.

const RATE := 32000
const VARIANTS := {"step": 4, "jump": 3, "land": 3, "grab": 2, "whoosh": 2, "miss": 2}
const JITTER := {"step": 0.07, "jump": 0.05, "land": 0.05, "grab": 0.06, "whoosh": 0.06, "miss": 0.05}
const SLIDE_LEVEL := 0.4
# peak level of each finished sound, so they sit together in the mix
const PEAK := {"step": 0.5, "jump": 0.5, "land": 0.85, "grab": 0.6, "whoosh": 0.55, "miss": 0.6,
	"tag": 0.75, "caught": 0.6, "beep": 0.45, "beep_hi": 0.55, "heart": 0.85, "sonar": 0.6, "slide": 0.6,
	"beacon": 0.55, "beacon_ok": 0.55, "reveal": 0.6, "bonus": 0.55, "block": 0.7}

var _streams := {}   # name -> Array of AudioStreamWAV variants
var _pool: Array[AudioStreamPlayer] = []
var _slide: AudioStreamPlayer
var _slide_target := 0.0
var _slide_level := 0.0


func _ready() -> void:
	var world_bus := _make_world_bus()
	for k in VARIANTS:
		var list := []
		for v in VARIANTS[k]:
			list.append(_wav(_make(k)))
		_streams[k] = list
	for k in ["tag", "caught", "beep", "beep_hi", "heart", "sonar", "beacon", "beacon_ok", "reveal", "bonus", "block"]:
		_streams[k] = [_wav(_make(k))]
	for i in 12:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	for p in _pool.slice(0, 8):
		p.bus = world_bus
	_slide = _loop(_make("slide"))
	_slide.bus = world_bus


func play(sound: String, volume := 1.0) -> void:
	match sound:
		"slide_on":
			_slide_target = SLIDE_LEVEL
			return
		"slide_off":
			_slide_target = 0.0
			return
	if not _streams.has(sound):
		return
	var physical := VARIANTS.has(sound)
	# the first 8 players feed the reverb bus, the others stay dry
	var from := 0 if physical else 8
	for i in range(from, from + (8 if physical else 4)):
		var p := _pool[i]
		if not p.playing:
			var list: Array = _streams[sound]
			p.stream = list[randi() % list.size()]
			p.volume_db = linear_to_db(clampf(volume, 0.01, 1.0))
			var j: float = JITTER.get(sound, 0.0)
			p.pitch_scale = 1.0 + randf_range(-j, j)
			p.play()
			return


## The slide loop fades in and out instead of jumping, so it never clicks.
func _process(delta: float) -> void:
	_slide_level = move_toward(_slide_level, _slide_target, delta * (6.0 if _slide_target > 0.0 else 4.0))
	_slide.volume_db = linear_to_db(_slide_level + 0.0001)


func _make_world_bus() -> String:
	var bus := "World"
	if AudioServer.get_bus_index(bus) == -1:
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus)
		AudioServer.set_bus_send(i, "Master")
		var rev := AudioEffectReverb.new()
		rev.room_size = 0.3
		rev.damping = 0.65
		rev.spread = 0.6
		rev.dry = 1.0
		rev.wet = 0.1
		rev.predelay_msec = 25.0
		AudioServer.add_bus_effect(i, rev)
	return bus


## Builds one sound with its _make_<name> recipe and brings it to its peak level.
func _make(sound: String) -> PackedFloat32Array:
	var o: PackedFloat32Array = call("_make_" + sound)
	_normalize(o, PEAK[sound])
	return o


func _loop(samples: PackedFloat32Array) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = _wav(samples, true)
	p.volume_db = -80.0
	p.autoplay = true
	add_child(p)
	return p


# ------------------------------------------------------------------ sounds

func _make_step() -> PackedFloat32Array:
	var o := _buf(0.14)
	var f := randf_range(0.85, 1.2)
	_add(o, _tone(0.1, 125.0 * f, 70.0, 0.002, 0.022), 0, 0.55)               # heel thump
	_add(o, _noise(0.1, 1900.0 * f, 900.0, 1.3, "band", 0.001, 0.016), 0, 0.5)  # sole scuff
	_add(o, _noise(0.05, 4500.0, 4500.0, 0.7, "high", 0.0, 0.006), 0, 0.12)     # grit
	return o


func _make_jump() -> PackedFloat32Array:
	var o := _buf(0.3)
	_add(o, _tone(0.12, 150.0, 80.0, 0.002, 0.03), 0, 0.4)                                   # push-off
	_add(o, _noise(0.08, 1600.0, 800.0, 1.2, "band", 0.001, 0.012), 0, 0.3)
	_add(o, _noise(0.28, randf_range(450.0, 600.0), 2400.0, 0.9, "band", 0.018, 0.08, 2), 0.01, 0.5)  # cloth swish
	return o


func _make_land() -> PackedFloat32Array:
	var o := _buf(0.5)
	_add(o, _tone(0.4, 95.0, 42.0, 0.002, 0.09), 0, 0.85)                       # body thud
	_add(o, _noise(0.3, 420.0, 200.0, 0.7, "low", 0.001, 0.06), 0, 0.6)
	_add(o, _noise(0.12, randf_range(2200.0, 3000.0), 1400.0, 1.0, "band", 0.0, 0.025), 0, 0.3)  # crunch
	_add(o, _noise(0.08, 1700.0, 900.0, 1.3, "band", 0.001, 0.015), 0.07, 0.18)  # second foot
	return o


func _make_grab() -> PackedFloat32Array:
	var o := _buf(0.3)
	_add(o, _noise(0.06, randf_range(2000.0, 2600.0), 1600.0, 1.6, "band", 0.0005, 0.011), 0, 0.65)  # hand slap
	_add(o, _tone(0.08, 170.0, 95.0, 0.001, 0.02), 0, 0.35)
	_add(o, _noise(0.2, 900.0, 1600.0, 0.9, "band", 0.02, 0.06, 2), 0.03, 0.22)   # pull-up rustle
	return o


func _make_whoosh() -> PackedFloat32Array:
	var d := randf_range(0.3, 0.36)
	var o := _noise_bell(d, randf_range(320.0, 420.0), 2100.0, 2.0, 0.65)
	_add(o, _noise_bell(d, 1200.0, 4200.0, 1.2, 0.18), 0, 1.0)
	return o


func _make_miss() -> PackedFloat32Array:
	var o := _noise_bell(0.2, randf_range(2600.0, 3000.0), 650.0, 1.6, 0.7)   # arm swinging through air
	return o


func _make_tag() -> PackedFloat32Array:
	var o := _buf(0.8)
	_add(o, _tone(0.12, 210.0, 100.0, 0.001, 0.035), 0, 0.6)                    # contact
	_add(o, _noise(0.06, 1500.0, 1000.0, 1.0, "band", 0.0, 0.014), 0, 0.5)
	_add(o, _bell(0.7, 1318.5, 0.2), 0.035, 0.32)                                # E6 + B6 chime
	_add(o, _bell(0.65, 1975.5, 0.16), 0.075, 0.26)
	return o


func _make_caught() -> PackedFloat32Array:
	var o := _buf(1.1)
	_add(o, _warm(0.3, 466.2, 440.0, 0.12), 0, 0.42)          # Bb4...
	_add(o, _warm(0.8, 349.2, 311.1, 0.3, 5.0), 0.24, 0.48)   # ...sliding down to Eb4
	return o


func _make_beep() -> PackedFloat32Array:
	var o := _tone(0.2, 880.0, 880.0, 0.003, 0.055)
	_add(o, _tone(0.2, 1760.0, 1760.0, 0.003, 0.03), 0, 0.2)
	return o


func _make_beep_hi() -> PackedFloat32Array:
	var o := _buf(0.6)
	_add(o, _tone(0.55, 1318.5, 1318.5, 0.004, 0.16), 0, 0.3)
	_add(o, _tone(0.55, 1760.0, 1760.0, 0.004, 0.16), 0.02, 0.24)
	_add(o, _tone(0.4, 2637.0, 2637.0, 0.004, 0.06), 0.02, 0.08)
	return o


func _make_heart() -> PackedFloat32Array:
	var o := _buf(0.45)
	_add(o, _tone(0.2, 68.0, 44.0, 0.006, 0.045), 0, 0.9)       # lub
	_add(o, _noise(0.08, 220.0, 120.0, 0.7, "low", 0.004, 0.02), 0, 0.35)
	_add(o, _tone(0.2, 60.0, 40.0, 0.006, 0.04), 0.17, 0.65)    # dub
	return o


func _make_sonar() -> PackedFloat32Array:
	var ping := _buf(0.9)
	_add(ping, _tone(0.9, 1250.0, 1170.0, 0.002, 0.28), 0, 0.4)
	_add(ping, _tone(0.5, 2500.0, 2340.0, 0.002, 0.1), 0, 0.08)
	_add(ping, _tone(0.4, 190.0, 150.0, 0.004, 0.12), 0, 0.25)
	var o := _buf(1.7)
	_add(o, ping, 0, 1.0)
	_add(o, ping, 0.26, 0.32)   # echoes off the city
	_add(o, ping, 0.52, 0.12)
	return o


func _make_beacon() -> PackedFloat32Array:
	var o := _buf(0.9)
	_add(o, _bell(0.6, 880.0, 0.22), 0, 0.4)       # A5...
	_add(o, _bell(0.75, 1318.5, 0.3), 0.14, 0.45)  # ...E6, a rising call
	return o


func _make_beacon_ok() -> PackedFloat32Array:
	var o := _buf(0.7)
	var notes := [1046.5, 1318.5, 1568.0, 2093.0]   # C6 E6 G6 C7
	for i in notes.size():
		_add(o, _tone(0.4, notes[i], notes[i], 0.003, 0.09 + 0.05 * i), 0.055 * i, 0.32)
	return o


func _make_bonus() -> PackedFloat32Array:
	var o := _buf(0.6)
	_add(o, _noise_bell(0.22, 600.0, 3600.0, 2.0, 1.0), 0, 0.35)   # rising sparkle
	_add(o, _tone(0.35, 784.0, 1568.0, 0.003, 0.1), 0, 0.3)         # quick upward slide
	_add(o, _bell(0.45, 2093.0, 0.14), 0.12, 0.3)                    # ...landing on a chime
	return o


func _make_block() -> PackedFloat32Array:
	var o := _buf(0.7)
	_add(o, _noise(0.05, 2500.0, 1500.0, 1.0, "band", 0.0, 0.01), 0, 0.6)   # impact
	_add(o, _bell(0.65, 523.3, 0.25), 0, 0.5)                                # metal ring
	_add(o, _bell(0.5, 659.3, 0.18), 0.01, 0.3)
	return o


func _make_reveal() -> PackedFloat32Array:
	var o := _buf(0.8)
	for i in 2:   # two low warning pulses
		_add(o, _warm(0.3, 233.1, 207.7, 0.12), 0.2 * i, 0.5)
	_add(o, _noise(0.5, 900.0, 400.0, 2.0, "band", 0.01, 0.15), 0, 0.12)
	return o


func _make_slide() -> PackedFloat32Array:
	var dur := 2.0
	var xf := 0.25
	var n := int(dur * RATE)
	var total := int((dur + xf) * RATE)
	var scrape := _svf_noise(total, _const(total, 1900.0), 0.9, "band", 2)
	var rumble := _svf_noise(total, _const(total, 240.0), 0.7, "low", 2)
	var o := PackedFloat32Array()
	o.resize(total)
	var grit := 0.0
	for i in total:
		var t := float(i) / RATE
		var flutter := 1.0 + 0.18 * sin(TAU * 8.0 * t) + 0.08 * sin(TAU * 13.5 * t)
		if randf() < 0.0025:   # sparse gravel crackle
			grit = randf_range(0.4, 0.9)
		grit *= 0.93
		o[i] = (scrape[i] * 0.55 + rumble[i] * 0.6) * flutter + (randf() * 2.0 - 1.0) * grit * 0.25
	return _loop_xfade(o, n, int(xf * RATE))


# ------------------------------------------------------------------ building blocks

func _buf(dur: float) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(int(dur * RATE))
	return o


## Mixes src into dst, starting `at` seconds in.
func _add(dst: PackedFloat32Array, src: PackedFloat32Array, at: float, gain: float) -> void:
	var off := int(at * RATE)
	for i in mini(src.size(), dst.size() - off):
		dst[off + i] += src[i] * gain


func _normalize(o: PackedFloat32Array, peak: float) -> void:
	var m := 0.0
	for s in o:
		m = maxf(m, absf(s))
	if m > 0.0:
		_scale(o, peak / m)


func _scale(o: PackedFloat32Array, gain: float) -> void:
	for i in o.size():
		o[i] *= gain


func _const(n: int, v: float) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(n)
	o.fill(v)
	return o


## Attack-then-exponential-decay envelope with a short fade at the very end.
func _env(i: int, n: int, attack: float, decay: float) -> float:
	var t := float(i) / RATE
	var e := t / attack if t < attack else exp(-(t - attack) / decay)
	var tail := float(n - i) / (0.004 * RATE)
	return e * minf(tail, 1.0)


## Sine with an exponential pitch glide from f0 to f1.
func _tone(dur: float, f0: float, f1: float, attack: float, decay: float) -> PackedFloat32Array:
	var o := _buf(dur)
	var n := o.size()
	var ph := 0.0
	for i in n:
		ph += f0 * pow(f1 / f0, float(i) / n) / RATE
		o[i] = sin(ph * TAU) * _env(i, n, attack, decay)
	return o


## Soft tone with a few harmonics and optional vibrato, for the musical cues.
func _warm(dur: float, f0: float, f1: float, decay: float, vib := 0.0) -> PackedFloat32Array:
	var o := _buf(dur)
	var n := o.size()
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := f0 * pow(f1 / f0, float(i) / n) * (1.0 + 0.012 * sin(TAU * vib * t) * minf(t * 4.0, 1.0))
		ph += f / RATE
		var x := ph * TAU
		o[i] = (sin(x) + 0.35 * sin(2.0 * x) + 0.12 * sin(3.0 * x)) * _env(i, n, 0.012, decay) * 0.7
	return o


## Struck-metal partials: quick attack, upper partials die out first.
func _bell(dur: float, f: float, decay: float) -> PackedFloat32Array:
	var o := _buf(dur)
	var n := o.size()
	for i in n:
		var t := float(i) / RATE
		var x := TAU * f * t
		o[i] = (sin(x) * _env(i, n, 0.001, decay)
			+ 0.4 * sin(x * 2.76) * _env(i, n, 0.001, decay * 0.45)
			+ 0.2 * sin(x * 5.4) * _env(i, n, 0.001, decay * 0.2))
	return o


## Filtered noise burst with the cutoff gliding from f0 to f1.
func _noise(dur: float, f0: float, f1: float, q: float, mode: String, attack: float, decay: float, stages := 1) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var cut := PackedFloat32Array()
	cut.resize(n)
	for i in n:
		cut[i] = f0 * pow(f1 / f0, float(i) / n)
	var o := _svf_noise(n, cut, q, mode, stages)
	for i in n:
		o[i] *= _env(i, n, maxf(attack, 0.0002), decay)
	return o


## Band-passed noise sweep with a smooth rise and fall (sin² envelope).
func _noise_bell(dur: float, f0: float, f1: float, q: float, vol: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var cut := PackedFloat32Array()
	cut.resize(n)
	for i in n:
		var u := float(i) / n
		cut[i] = f0 * pow(f1 / f0, sin(u * PI * 0.5))
	var o := _svf_noise(n, cut, q, "band", 2)
	for i in n:
		var s := sin(PI * float(i) / n)
		o[i] *= s * s * vol
	return o


## White noise through a state-variable filter (TPT form, stable at any cutoff),
## normalised to a peak of 1 so layer gains compare directly. Each extra stage
## runs the result through the same filter again, for a steeper slope.
func _svf_noise(n: int, cut: PackedFloat32Array, q: float, mode: String, stages := 1) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(n)
	for i in n:
		o[i] = randf() * 2.0 - 1.0
	var k := 1.0 / q
	for st in stages:
		var ic1 := 0.0
		var ic2 := 0.0
		for i in n:
			var g := tan(PI * minf(cut[i], RATE * 0.45) / RATE)
			var a1 := 1.0 / (1.0 + g * (g + k))
			var a2 := g * a1
			var a3 := g * a2
			var x := o[i]
			var v3 := x - ic2
			var v1 := a1 * ic1 + a2 * v3
			var v2 := ic2 + a2 * ic1 + a3 * v3
			ic1 = 2.0 * v1 - ic1
			ic2 = 2.0 * v2 - ic2
			match mode:
				"low":
					o[i] = v2
				"high":
					o[i] = x - k * v1 - v2
				_:
					o[i] = v1 * k
	_normalize(o, 1.0)
	return o


## Folds the extra tail over the start so the loop seam is inaudible.
func _loop_xfade(o: PackedFloat32Array, n: int, xf: int) -> PackedFloat32Array:
	var out := o.slice(0, n)
	for i in xf:
		var u := float(i) / xf
		out[i] = o[i] * sqrt(u) + o[n + i] * sqrt(1.0 - u)
	return out


func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w
