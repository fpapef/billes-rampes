extends Node
## Sons synthétisés au démarrage : aucun fichier audio n'est nécessaire.

const RATE := 22050

var streams := {}
var _players3d: Array[AudioStreamPlayer3D] = []
var _players: Array[AudioStreamPlayer] = []
var _next3d := 0
var _next := 0
var _last_tick_ms := 0
var _roll: AudioStreamPlayer


func _ready() -> void:
	streams["tick"] = _synth([[2600.0, 0.0]], 0.03, "tri", 0.5)
	streams["pick"] = _synth([[520.0, 0.0]], 0.08, "sine", 0.5, 220.0)
	streams["place"] = _synth([[360.0, 0.0]], 0.1, "sine", 0.55, -90.0)
	streams["snap"] = _synth([[1400.0, 0.0], [2100.0, 0.04]], 0.06, "tri", 0.45)
	streams["del"] = _synth([[240.0, 0.0]], 0.22, "saw", 0.3, -150.0)
	streams["click"] = _synth([[1100.0, 0.0]], 0.04, "square", 0.2)
	streams["chime"] = _synth([[784.0, 0.0], [988.0, 0.09], [1318.0, 0.18]], 0.4, "sine", 0.4)
	streams["star"] = _synth([[1318.0, 0.0], [1760.0, 0.06]], 0.25, "tri", 0.4)
	streams["win"] = _synth([[523.0, 0.0], [659.0, 0.11], [784.0, 0.22], [1046.0, 0.33], [1318.0, 0.44]], 0.5, "tri", 0.35)
	streams["fail"] = _synth([[392.0, 0.0], [330.0, 0.15], [262.0, 0.3]], 0.3, "sine", 0.4)

	for i in 10:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 2.0
		add_child(p)
		_players3d.append(p)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

	# Roulement : bruit grave en boucle, volume et hauteur réglés selon la vitesse des billes
	_roll = AudioStreamPlayer.new()
	_roll.stream = _noise_loop(1.0)
	_roll.volume_db = -80.0
	add_child(_roll)
	_roll.play()


## Joue un son, positionné dans l'espace si `pos` est donné.
func play(sound: String, pos = null, volume := 1.0, pitch := 1.0) -> void:
	if not streams.has(sound):
		return
	var db := linear_to_db(clampf(volume, 0.001, 1.0))
	if pos is Vector3:
		var p := _players3d[_next3d]
		_next3d = (_next3d + 1) % _players3d.size()
		p.stream = streams[sound]
		p.global_position = pos
		p.volume_db = db
		p.pitch_scale = pitch
		p.play()
	else:
		var p := _players[_next]
		_next = (_next + 1) % _players.size()
		p.stream = streams[sound]
		p.volume_db = db
		p.pitch_scale = pitch
		p.play()


## Petit choc de bille, limité pour ne pas saturer.
func tick(pos: Vector3, strength: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_tick_ms < 28:
		return
	_last_tick_ms = now
	play("tick", pos, 0.15 + 0.85 * strength, randf_range(0.75, 1.3))


## speed_sum : somme des vitesses des billes en contact ; speed_max : la plus rapide.
func set_rolling(speed_sum: float, speed_max: float) -> void:
	var target := minf(0.45, speed_sum * 0.12)
	var cur := db_to_linear(_roll.volume_db)
	_roll.volume_db = linear_to_db(maxf(0.0001, lerpf(cur, target, 0.15)))
	_roll.pitch_scale = clampf(0.6 + speed_max * 0.5, 0.6, 2.2)


func _synth(notes: Array, dur: float, wave := "sine", vol := 0.5, slide := 0.0) -> AudioStreamWAV:
	var total := 0.0
	for n in notes:
		total = maxf(total, float(n[1]) + dur)
	var count := int(total * RATE) + 1
	var buf := PackedFloat32Array()
	buf.resize(count)
	var n_len := int(dur * RATE)
	for n in notes:
		var f0: float = n[0]
		var start := int(float(n[1]) * RATE)
		var phase := 0.0
		for i in n_len:
			if start + i >= count:
				break
			var t := float(i) / RATE
			phase += (f0 + slide * t / dur) / RATE
			var x := phase - floorf(phase)
			var v := 0.0
			match wave:
				"tri":
					v = 4.0 * absf(x - 0.5) - 1.0
				"square":
					v = 1.0 if x < 0.5 else -1.0
				"saw":
					v = 2.0 * x - 1.0
				_:
					v = sin(TAU * phase)
			var env := exp(-5.0 * t / dur) * minf(1.0, t * 400.0)
			buf[start + i] += v * env * vol
	return _to_wav(buf, false)


func _noise_loop(seconds: float) -> AudioStreamWAV:
	var count := int(seconds * RATE)
	var buf := PackedFloat32Array()
	buf.resize(count)
	var lp := 0.0
	var peak := 0.001
	for i in count:
		lp += 0.08 * (randf_range(-1.0, 1.0) - lp)
		buf[i] = lp
		peak = maxf(peak, absf(lp))
	for i in count:
		buf[i] = buf[i] / peak * 0.8
	return _to_wav(buf, true)


func _to_wav(buf: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(buf.size() * 2)
	for i in buf.size():
		data.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = buf.size()
	return w
