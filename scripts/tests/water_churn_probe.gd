extends SceneTree

## Water-settling churn probe: boots the playtest world, lets the
## embark state settle, then measures how many columns still change
## surface height per tick — and whether individual columns oscillate
## (top going up-down-up), which would render as the flickering sheets
## seen in playtesting. Report goes to user://water_churn_report.txt.

var _report: FileAccess


func _initialize() -> void:
	_report = FileAccess.open("user://water_churn_report.txt", FileAccess.WRITE)
	_out("churn probe start")
	Main.pending_world = {
		&"seed": 158916680,
		&"ocean_pct": 60,
		&"temp_bias_c": 0.0,
		&"moist_bias": 0.0,
		&"axial_tilt_deg": 23.0,
		&"world_tile": 99285,
		&"package": &"vanilla",
		&"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	_out("=== booted ===")
	var sim: RefCounted = main.world.sim
	var b: Rect2i = main.site.bounds
	# Burn the embark settle storm first — a body mid-pour legitimately
	# churns; the question is whether it converges.
	for i in 150:
		sim.tick(0.2)
	_out("settle burn done")
	# Now measure churn over 60 ticks: dirty-column count per tick, plus
	# surface-height sign flips per column, split into whole-cell top
	# flips (the flicker signature) and sub-cell fill wiggle.
	var prev: Dictionary = {}
	var flips := 0
	var cell_flips := 0
	var movers_total := 0
	var flip_examples: Array = []
	for t in 60:
		sim.tick(0.2)
		var dirty: PackedVector3Array = sim.water_drain_dirty()
		movers_total += dirty.size()
		var cur := {}
		for c in dirty:
			var x := int(c.x)
			var z := int(c.z)
			var s: float = sim.water_surface_at(x, z)
			cur[Vector2i(x, z)] = s
		for col: Vector2i in cur:
			if not prev.has(col):
				continue
			var d: float = cur[col] - prev[col]
			# A flip = the column's surface moved the opposite way from
			# its last move — the signature of ping-pong oscillation.
			var key := str(col)
			if _last_dir.has(key) and d != 0.0 and signf(d) != _last_dir[key]:
				flips += 1
				if absf(d) >= 0.5:
					cell_flips += 1
				_flip_count[col] = int(_flip_count.get(col, 0)) + 1
				if flip_examples.size() < 10:
					flip_examples.append(
						"%s: %.3f -> %.3f" % [col, prev[col], cur[col]])
			if d != 0.0:
				_last_dir[key] = signf(d)
		# Seed next comparison: keep surfaces for ALL dirty columns so a
		# column quiet one tick still has a baseline.
		for col: Vector2i in cur:
			prev[col] = cur[col]
		if t % 10 == 9:
			_out("tick %d: dirty cols so far=%d, flips=%d (cell=%d), active=%d"
					% [t + 1, movers_total, flips, cell_flips,
					int(sim.debug_stats().get("water_active", -1))])
	_out(
		"RESULT: %d dirty-column events over 60 ticks, %d flips, %d whole-cell"
		% [movers_total, flips, cell_flips]
	)
	for e in flip_examples:
		_out("   flip %s" % e)
	# Vertical profile of the heaviest flippers — dump each one's water
	# cells over 6 ticks to see which mechanism ping-pongs.
	var ranked := _flip_count.keys()
	ranked.sort_custom(
		func(a, b): return _flip_count[a] > _flip_count[b])
	_out("top flippers: %s" % str(ranked.slice(0, 8)))
	for col: Vector2i in ranked.slice(0, 3):
		_out("--- column %s profile ---" % col)
		var level := int(sim.water_level_at(col.x, col.y))
		for t in 6:
			sim.tick(0.2)
			var line := "  t%d:" % t
			for y in range(level - 3, level + 4):
				var v := int(sim.water_volume_at(
					Vector3i(col.x, y, col.y)))
				if v > 0:
					line += " y%d=%d" % [y, v]
			var top: int = sim.water_level_at(col.x, col.y)
			line += " | top=%d surf=%.3f" % [
				top, sim.water_surface_at(col.x, col.y)]
			_out(line)
	quit(0)


var _flip_count := {}


var _last_dir := {}


func _out(line: String) -> void:
	print(line)
	if _report != null:
		_report.store_line(line)
		_report.flush()
