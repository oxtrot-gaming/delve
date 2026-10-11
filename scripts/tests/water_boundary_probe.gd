extends SceneTree

## River boundary-wiring probe (PLAN item 51) on a synthetic SiteField:
## an 8×8-cell field carrying two reaches — a through-river entering
## and leaving the site bounds, and a spring-fed reach that rises
## inside and exits — checks SiteField.river_boundaries' pairing rules
## (sources only at off-site heads, drains only on sourced components),
## then runs a bare DelveSim end-to-end to prove the source/drain pair
## actually moves water down the channel and the flow-field query
## reports the current.
##
##     godot --headless --path . --script res://scripts/tests/water_boundary_probe.gd

var _failures := PackedStringArray()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)
		printerr("FAIL: ", message)


## Field cells are 4 m; the site bounds cover cells (2..5)², so the
## row-4 reach crosses the boundary both ways (cells 0..7) while the
## row-2 reach rises inside bounds (cells 2..7) with no off-site head.
const SIDE := 8
const M := 4
const ORIGIN := Vector2i(-16, -16)
const BOUNDS := Rect2i(-8, -8, 16, 16)
const LEVEL := 31
const ACCUM := 2000
const PRECIP := 100.0


func _field() -> SiteField:
	var f := SiteField.new()
	f.side = SIDE
	f.cell_m = M
	f.origin = ORIGIN
	var n := SIDE * SIDE
	f.flags = PackedByteArray()
	f.flags.resize(n)
	f.carve = PackedByteArray()
	f.carve.resize(n)
	f.water = PackedInt32Array()
	f.water.resize(n)
	f.water.fill(SiteField.DRY)
	f.flow_next = PackedInt32Array()
	f.flow_next.resize(n)
	f.flow_next.fill(-1)
	f.accum = PackedInt32Array()
	f.accum.resize(n)
	f.accum.fill(1)
	f.soil = PackedByteArray()
	f.soil.resize(n)
	f.depth_q = PackedByteArray()
	f.depth_q.resize(n)
	f.specs = [
		{&"topsoil": {&"sand": 1}, &"subsoil": {}, &"depth_m": 1.0}
	]
	# Through-reach at row 4: enters off the -x boundary, leaves at +x.
	for cx in SIDE:
		var i := 4 * SIDE + cx
		f.flags[i] = SiteField.FLAG_WATER | SiteField.FLAG_RIVER
		f.carve[i] = SiteField.RIVER_CUT
		f.water[i] = LEVEL
		f.accum[i] = ACCUM
		if cx < SIDE - 1:
			f.flow_next[i] = i + 1
	# Spring-fed reach at row 2: cells 2..7, no off-site predecessor,
	# exits the bounds at +x — its drains must NOT install.
	for cx in range(2, SIDE):
		var i := 2 * SIDE + cx
		f.flags[i] = SiteField.FLAG_WATER | SiteField.FLAG_RIVER
		f.carve[i] = SiteField.RIVER_CUT
		f.water[i] = LEVEL
		f.accum[i] = ACCUM
		if cx < SIDE - 1:
			f.flow_next[i] = i + 1
	return f


func _initialize() -> void:
	DataPackage.install(&"vanilla", &"lost_tribe")
	var gen := WorldGenerator.new()
	gen.terrain_amplitude = 0.0 # flat bedrock — the channel's carve
	# does all the shaping, so assertions stay exact.
	var field := _field()
	gen.install_site_field(field) # resolves field.flood

	var pairs := field.river_boundaries(BOUNDS, gen, PRECIP)
	var sources: Array = pairs[&"sources"]
	var drains: Array = pairs[&"drains"]

	# Sources land only under cell (2,4): voxel x in [-8,-4), z in [0,4).
	# Drains land only under cell (5,4): voxel x in [4,8), z in [0,4).
	_check(not sources.is_empty(), "through-reach produced sources")
	_check(not drains.is_empty(), "through-reach produced drains")
	var src_ok := true
	for s in sources:
		var p: Vector3i = s[&"pos"]
		if not (p.x >= -8 and p.x < -4 and p.z >= 0 and p.z < 4):
			src_ok = false
	_check(src_ok, "all source columns sit under the head cell (2,4)")
	var drn_ok := true
	for d in drains:
		var p: Vector3i = d[&"pos"]
		if not (p.x >= 4 and p.x < 8 and p.z >= 0 and p.z < 4):
			drn_ok = false
	_check(drn_ok, "all drain columns sit under the exit cell (5,4)")
	# The spring reach at row 2 (voxel z in [-8,-4)) must get neither.
	for s in sources:
		var p: Vector3i = s[&"pos"]
		_check(
			not (p.z >= -8 and p.z < -4),
			"spring reach carries no source at %s" % p
		)
	for d in drains:
		var p: Vector3i = d[&"pos"]
		_check(
			not (p.z >= -8 and p.z < -4),
			"lone drain suppressed on spring reach at %s" % p
		)
	# Rates: accum × precip × RIVER_RUNOFF_PER_ACCUM per field cell,
	# spread over the cell's wet columns.
	var expected := int(ACCUM * PRECIP * SiteField.RIVER_RUNOFF_PER_ACCUM)
	var total := 0
	for s in sources:
		total += int(s[&"rate"])
	_check(
		absi(total - expected) < sources.size(),
		"source rate ≈ catchment rate (%d of %d)" % [total, expected]
	)

	# End-to-end on a bare DelveSim: seed, register, tick, and read
	# whether the pair keeps water cycling down the reach.
	if not ClassDB.class_exists(&"DelveSim"):
		printerr("no DelveSim — extension missing?")
		quit(2)
		return
	var sim: RefCounted = ClassDB.instantiate(&"DelveSim")
	_check(bool(sim.configure(gen.native_generator())), "DelveSim configured")
	sim.water_seed_flood(
		field.flood, field.origin, SIDE * M, field.flags, M
	)
	for s in sources:
		sim.water_set_source(s[&"pos"], s[&"rate"])
	for d in drains:
		sim.water_set_drain(d[&"pos"], d[&"rate"])

	var reach_volume := func() -> int:
		var t := 0
		for x in range(-16, 16):
			for z in range(0, 4):
				var level := int(sim.water_level_at(x, z))
				if level == SiteField.DRY:
					continue
				for y in range(20, level + 1):
					t += int(sim.water_volume_at(Vector3i(x, y, z)))
		return t

	var seeded := int(reach_volume.call())
	_check(seeded > 0, "seeded reach holds water (%d cm³)" % seeded)
	for i in 30:
		sim.tick(0.2)
	var after := int(reach_volume.call())
	_check(
		after > seeded / 2 and after < seeded * 3 / 2,
		"paired reach holds near its level (%.2f → %.2f m³)"
		% [seeded / 1.0e6, after / 1.0e6]
	)
	# The flow field must report the current — dominant +x down the
	# reach over its wet surface cells.
	var flux: PackedVector3Array = sim.water_flow_field()
	var saw_flow := false
	var saw_downstream := false
	for k in range(0, flux.size(), 2):
		var pos: Vector3 = flux[k]
		var f: Vector3 = flux[k + 1]
		if pos.z >= 0 and pos.z < 4 and f.length() > 0.0:
			saw_flow = true
			if f.x > 0.0 and absf(f.x) > absf(f.z):
				saw_downstream = true
	_check(saw_flow, "flow field reports surface flux on the reach")
	_check(saw_downstream, "reach flux points downstream (+x)")
	# Cut the sources: the drains must now empty the reach — the pair
	# isn't decorative.
	for s in sources:
		sim.water_set_source(s[&"pos"], 0)
	for i in 60:
		sim.tick(0.2)
	var drained := int(reach_volume.call())
	_check(
		drained < after * 3 / 4,
		"drains empty the reach once unfed (%.2f → %.2f m³)"
		% [after / 1.0e6, drained / 1.0e6]
	)

	if _failures.is_empty():
		print("WATER BOUNDARY PROBE PASSED")
	else:
		printerr("water boundary probe: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
