extends SceneTree

## Water traversal probe (PLAN item 54) on a bare DelveSim: buoyancy,
## the swim-gated astar, and surge dampening. Fixtures are carved on
## flat ground — a wading-depth cell, a basin two voxels deep, and a
## moat-ringed island — so every gate reads against known geometry:
##
##   - wading: water 1 m or less over the floor keeps the unit grounded
##   - swimming: deeper water floats the capsule at the draught line
##   - clamber: a jump impulse while floating pops the unit onto a bank
##   - paths: submerged cells open only for swimmers, and only with
##     headroom above the waterline
##   - surge: a breach advances one ring per water step — a cell
##     exports only what it settled with, never this step's inflow
##
##     godot --headless --path . --script res://scripts/tests/water_swimming_probe.gd

var _failures := PackedStringArray()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)
		printerr("FAIL: ", message)


const SIDE := 8
const M := 4
const ORIGIN := Vector2i(-16, -16)
const BOUNDS := Rect2i(-8, -8, 16, 16)
const LEVEL := 31
const ACCUM := 2000
const PRECIP := 100.0
const CELL_CAP := 1_000_000
const GRAVITY := 22.0
const JUMP := 7.5
const WALK := 4.0


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
	for cx in SIDE:
		var i := 4 * SIDE + cx
		f.flags[i] = SiteField.FLAG_WATER | SiteField.FLAG_RIVER
		f.carve[i] = SiteField.RIVER_CUT
		f.water[i] = LEVEL
		f.accum[i] = ACCUM
		if cx < SIDE - 1:
			f.flow_next[i] = i + 1
	return f


## The first air voxel over ground at (x, z).
func _ground_air(sim: RefCounted, x: int, z: int) -> Vector3i:
	for y in range(12, 72):
		if not bool(sim.is_solid(Vector3i(x, y, z))):
			return Vector3i(x, y, z)
	return Vector3i.MAX


## Steps the unit a beat and returns the last result dictionary.
func _walk(
	sim: RefCounted, id: int, heading: Vector3, steps: int,
	jump := false
) -> Dictionary:
	var res := {}
	for i in steps:
		res = sim.unit_step(
			id, heading, JUMP if jump and i == 0 else 0.0,
			GRAVITY, 1.0 / 60.0, 0.0
		)
	return res


func _initialize() -> void:
	DataPackage.install(&"vanilla", &"lost_tribe")
	var gen := WorldGenerator.new()
	gen.terrain_amplitude = 0.0
	var field := _field()
	gen.install_site_field(field)

	if not ClassDB.class_exists(&"DelveSim"):
		printerr("no DelveSim — extension missing?")
		quit(2)
		return
	var sim: RefCounted = ClassDB.instantiate(&"DelveSim")
	_check(bool(sim.configure(gen.native_generator())), "DelveSim configured")
	# The field's flood seed fixes the water bounds — without it
	# water_in_bounds refuses every lateral transfer anywhere.
	var pairs := field.river_boundaries(BOUNDS, gen, PRECIP)
	sim.water_seed_flood(
		field.flood, field.origin, SIDE * M, field.flags, M
	)
	for s in pairs[&"sources"]:
		sim.water_set_source(s[&"pos"], s[&"rate"])
	for d in pairs[&"drains"]:
		sim.water_set_drain(d[&"pos"], d[&"rate"])

	var wall: int = sim.get_block(_ground_air(sim, 8, 8) + Vector3i(0, -1, 0))
	_check(wall > 0, "ground block read for fixture walls")

	# --- Fixture: flat bank on dry ground with three water cells.
	#     WADE — a plain bank cell holding a shallow puddle; BASIN —
	#     the same cell depth carved one down and filled two deep;
	#     MOAT — a ring carved around an island cell for the astar.
	var wade := _ground_air(sim, 10, 6)
	var basin_edge := _ground_air(sim, 14, 6)
	_check(
		wade != Vector3i.MAX and basin_edge != Vector3i.MAX,
		"flat ground found for water fixtures"
	)
	if wade == Vector3i.MAX or basin_edge == Vector3i.MAX:
		_finish()
		return

	# The basin: two cells carved below the neighbour column's surface,
	# both filled — 2 m of water with the surface at bank level, over
	# a floor the unit can drop to.
	var basin_air := _ground_air(sim, basin_edge.x + 1, basin_edge.z)
	_check(basin_air != Vector3i.MAX, "basin column found")
	if basin_air == Vector3i.MAX:
		_finish()
		return
	var basin := basin_air + Vector3i(0, -2, 0)
	sim.set_block(basin_air + Vector3i(0, -1, 0), 0)
	sim.set_block(basin, 0)
	sim.water_add(basin, CELL_CAP)
	sim.water_add(basin + Vector3i.UP, CELL_CAP)

	# The wade puddle: a shallow fill at plain ground level.
	sim.water_add(wade, int(CELL_CAP * 0.5))
	# Hold the fixtures still — water flow isn't under test here.
	sim.water_set_paused(true)

	# --- Wading: a unit walks into the puddle and stays grounded.
	sim.unit_register(1, Vector3(wade) + Vector3(-0.5, 0.901, 0.5))
	var res := _walk(sim, 1, Vector3(WALK, 0, 0), 30)
	_check(
		bool(res["grounded"]) and not bool(res["swimming"]),
		"a wader keeps its feet — half-depth water is walking"
	)

	# --- Swimming: over the basin lip the same unit floats.
	sim.unit_register(2, Vector3(basin_edge) + Vector3(0.5, 0.901, 0.5))
	res = _walk(sim, 2, Vector3(WALK, 0, 0), 45)
	_check(bool(res["swimming"]), "deep water floats the capsule")
	var feet := Vector3(sim.unit_pos(2)).y - 0.9
	# Water surface = the rim level; draught rides the feet 0.9 below.
	var surface := float(basin_air.y)
	_check(
		absf(feet - (surface - 0.9)) < 0.25,
		"the float settles at the surface draught"
	)
	_check(
		not bool(res["grounded"]),
		"a swimmer is not grounded"
	)

	# --- Sunken entry: a unit registered at a basin floor bobs up. Its
	#     own column — sharing unit 2's shaft would collide capsules.
	var sink_air := _ground_air(sim, basin_air.x, basin_air.z + 1)
	var sink := sink_air + Vector3i(0, -2, 0)
	sim.set_block(sink_air + Vector3i(0, -1, 0), 0)
	sim.set_block(sink, 0)
	sim.water_add(sink, CELL_CAP)
	sim.water_add(sink + Vector3i.UP, CELL_CAP)
	sim.unit_register(3, Vector3(sink) + Vector3(0.5, 0.901, 0.5))
	var y0 := Vector3(sim.unit_pos(3)).y
	for i in 30:
		res = sim.unit_step(3, Vector3.ZERO, 0.0, GRAVITY, 1.0 / 60.0, 0.0)
	_check(
		bool(res["swimming"])
			and Vector3(sim.unit_pos(3)).y > y0 + 0.4,
		"buoyancy lifts a submerged capsule to the surface"
	)

	# --- Clamber: swimmer + heading at the bank + a jump impulse lands
	#     the capsule on the far side.
	var clambered := false
	for burst in 8:
		res = _walk(
			sim, 3, Vector3(0, 0, -WALK), 12, burst > 0
		)
		if bool(res["grounded"]):
			clambered = true
			break
	_check(clambered, "a jump impulse while floating clambers out")
	_check(
		Vector3i(Vector3(sim.unit_pos(3)).floor()) != basin,
		"the clamber leaves the water cell"
	)

	# --- Paths: a moat of deep water around an island admits only the
	#     swimmer; roof the moat and nobody crosses.
	var island := _ground_air(sim, 10, 18)
	_check(island != Vector3i.MAX, "island ground found")
	if island == Vector3i.MAX:
		_finish()
		return
	var ring_cells: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var ring_air := _ground_air(sim, island.x + dx, island.z + dz)
			ring_cells.append(ring_air)
			sim.set_block(ring_air + Vector3i(0, -1, 0), 0)
			sim.set_block(ring_air + Vector3i(0, -2, 0), 0)
			sim.water_add(ring_air + Vector3i(0, -2, 0), CELL_CAP)
			sim.water_add(ring_air + Vector3i(0, -1, 0), CELL_CAP)
	var shore := island + Vector3i(3, 0, 0)
	if bool(sim.is_solid(shore)):
		shore = _ground_air(sim, island.x + 3, island.z)
	var dry_path: PackedVector3Array = sim.find_path(shore, island, false, 24, false)
	_check(
		dry_path.is_empty(),
		"a non-swimmer won't route across deep water"
	)
	var swim_path: PackedVector3Array = sim.find_path(shore, island, false, 24, true)
	_check(
		not swim_path.is_empty(),
		"a swimmer routes straight across the moat"
	)
	# The routed path crosses the water, not around: a swim leg leaves
	# a node floating over water — the cell below it is wet.
	var swam := false
	for c in swim_path:
		var v := Vector3i(c.floor())
		if int(sim.water_volume_at(v + Vector3i(0, -1, 0))) > 0:
			swam = true
			break
	_check(swam, "the swim path actually goes through water")

	# Headroom: roof the moat at the cell above each waterline and the
	# gate closes again — a submerged tunnel is nobody's path.
	for ring_air in ring_cells:
		sim.set_block(ring_air, wall)
	# A roof is also a floor — the route may walk over it; what it may
	# not do is pass through the water under a capped cell.
	var roofed_path: PackedVector3Array = sim.find_path(
		shore, island, false, 24, true
	)
	var swam_roofed := false
	for c in roofed_path:
		var v := Vector3i(c.floor())
		if int(sim.water_volume_at(v + Vector3i(0, -1, 0))) > 0:
			swam_roofed = true
			break
	_check(
		not swam_roofed,
		"no headroom above the waterline walls the swim route"
	)

	# --- Surge: a walled channel one deep, cell A full, the rest dry.
	#     One water step moves the front exactly one cell — before the
	#     settled cap, the first receiver relayed in the same pass. The
	#     channel needs six supported cells in a row or the water just
	#     falls through — scan a few candidates for a floored run.
	var ch: Array[Vector3i] = []
	# Water flow needs cells inside the field's bounds (|x|,|z| < 16).
	for anchor in [Vector2i(4, 8), Vector2i(8, 9), Vector2i(12, 8),
			Vector2i(6, 10), Vector2i(10, 10), Vector2i(4, -8)]:
		var first := _ground_air(sim, anchor.x, anchor.y)
		if first == Vector3i.MAX:
			continue
		var run: Array[Vector3i] = []
		for i in 6:
			var c := Vector3i(first.x + i, first.y, first.z)
			if (
				bool(sim.is_solid(c))
				or not bool(sim.is_solid(c + Vector3i(0, -1, 0)))
			):
				run.clear()
				break
			run.append(c)
		if run.size() == 6:
			ch = run
			break
	_check(ch.size() == 6, "channel ground found")
	if ch.size() != 6:
		_finish()
		return
	for c in ch:
		for d in [Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			sim.set_block(c + d, wall)
	# Cap the back of the channel — the front reads cleanest when the
	# water has nowhere to go but forward.
	sim.set_block(ch[0] + Vector3i(-1, 0, 0), wall)
	sim.water_add(ch[0], CELL_CAP)
	sim.water_set_paused(false)
	sim.tick(0.2)
	_check(
		int(sim.water_volume_at(ch[1])) > 0,
		"the breach wets the first cell"
	)
	_check(
		int(sim.water_volume_at(ch[2])) == 0,
		"the front stops at one ring per step"
	)
	sim.tick(0.2)
	_check(
		int(sim.water_volume_at(ch[2])) > 0
			and int(sim.water_volume_at(ch[3])) == 0,
		"the next step advances the front exactly one more cell"
	)

	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("WATER SWIMMING PROBE PASSED")
	else:
		printerr("WATER SWIMMING PROBE FAILED: %d checks" % _failures.size())
		for f in _failures:
			printerr("  - ", f)
	quit(0 if _failures.is_empty() else 1)
