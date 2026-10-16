extends Node
class_name Sfx
## Sound effects synthesised at startup (filtered noise and simple tones), so the
## project ships without audio files.

const RATE := 22050

var _streams := {}
var _pool: Array[AudioStreamPlayer] = []
var _wind: AudioStreamPlayer
var _slide: AudioStreamPlayer


func _ready() -> void:
	_streams.step = _noise(0.07, 1000.0, 0.5, "low")
	_streams.jump = _noise(0.12, 1400.0, 0.45, "band")
	_streams.land = _noise(0.3, 300.0, 0.9, "low")
	_streams.grab = _noise(0.08, 2000.0, 0.5, "band")
	_streams.whoosh = _noise(0.25, 2500.0, 0.35, "high")
	_streams.tag = _mix(_tone_s(880.0, 0.25, 0.5, "square", 0.5), _noise_s(0.15, 3000.0, 0.4, "high"))
	_streams.caught = _wav(_tone_s(330.0, 0.6, 0.5, "saw", 0.4))
	_streams.beep = _wav(_tone_s(660.0, 0.12, 0.4, "tri", 1.0))
	_streams.beep_hi = _wav(_tone_s(1320.0, 0.12, 0.4, "tri", 1.0))
	_streams.heart = _wav(_tone_s(55.0, 0.15, 0.9, "sine", 0.7))
	_streams.sonar = _wav(_tone_s(1200.0, 0.9, 0.4, "sine", 0.35))
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_wind = _loop(_noise_s(2.0, 500.0, 0.6, "band", false))
	_slide = _loop(_noise_s(1.0, 1800.0, 0.5, "band", false))


func play(sound: String, volume := 1.0) -> void:
	match sound:
		"slide_on":
			_slide.volume_db = linear_to_db(0.35)
			return
		"slide_off":
			_slide.volume_db = -80.0
			return
	if not _streams.has(sound):
		return
	for p in _pool:
		if not p.playing:
			p.stream = _streams[sound]
			p.volume_db = linear_to_db(clampf(volume, 0.01, 1.0))
			p.play()
			return


func set_wind(k: float) -> void:
	_wind.volume_db = linear_to_db(clampf(k, 0.0, 1.0) * 0.6 + 0.0001)


func _loop(samples: PackedFloat32Array) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = _wav(samples, true)
	p.volume_db = -80.0
	p.autoplay = true
	add_child(p)
	return p


func _noise(dur: float, freq: float, vol: float, mode: String) -> AudioStreamWAV:
	return _wav(_noise_s(dur, freq, vol, mode))


func _noise_s(dur: float, freq: float, vol: float, mode: String, decay := true) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var a := 1.0 - exp(-TAU * freq / RATE)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var x := randf() * 2.0 - 1.0
		lp += a * (x - lp)
		var y := lp
		if mode == "high":
			y = x - lp
		elif mode == "band":
			lp2 += a * ((x - lp) - lp2)
			y = lp2 * 2.0
		var env := exp(-5.0 * float(i) / n) if decay else 1.0
		out[i] = y * vol * env
	return out


func _tone_s(freq: float, dur: float, vol: float, wave: String, glide: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / n
		ph += freq * pow(glide, t) / RATE
		var fr := fmod(ph, 1.0)
		var y := sin(ph * TAU)
		if wave == "square":
			y = 1.0 if fr < 0.5 else -1.0
		elif wave == "saw":
			y = fr * 2.0 - 1.0
		elif wave == "tri":
			y = 1.0 - absf(fr * 4.0 - 2.0)
		out[i] = y * vol * exp(-5.0 * t)
	return out


func _mix(a: PackedFloat32Array, b: PackedFloat32Array) -> AudioStreamWAV:
	var n := maxi(a.size(), b.size())
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = (a[i] if i < a.size() else 0.0) + (b[i] if i < b.size() else 0.0)
	return _wav(out)


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
