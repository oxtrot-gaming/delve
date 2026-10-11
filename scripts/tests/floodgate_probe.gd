extends SceneTree

## Regulated-edge probe (PLAN item 52) on a bare DelveSim: a flat field
## and a two-cell transfer tank. Checks the seam's semantics — the
## canonical (undirected) edge lookup, the full-open default, a sealed
## edge moving nothing, a half-open edge moving a fraction of the open
## one, and reopening restoring full flow — then an integration pass on
## the same through-river as water_boundary_probe, where a sealed
## curtain starves downstream and the flow overlay's flux collapses.
##
##     godot --headless --path . --script res://scripts/tests/floodgate_probe.gd

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


## The first air voxel over ground at (x, z) — the tank cells sit on
## flat bedrock away from the river's carve.
func _ground_air(sim: RefCounted, x: int, z: int) -> Vector3i:
	for y in range(12, 72):
		if not bool(sim.is_solid(Vector3i(x, y, z))):
			return Vector3i(x, y, z)
	return Vector3i.MAX


## Builds a walled two-cell channel at (x, z): A at the anchor, B one
## voxel +x, every other lateral neighbour of both cells plugged with
## the ground's own block id at two heights — so the A->B edge is the
## only route water out of A can take. Returns [A, B] or null.
func _tank(sim: RefCounted, x: int, z: int) -> Variant:
	var A := _ground_air(sim, x, z)
	var B := A + Vector3i(1, 0, 0)
	if A == Vector3i.MAX or bool(sim.is_solid(B)):
		return null
	var wall: int = sim.get_block(A + Vector3i(0, -1, 0))
	if wall <= 0:
		return null
	for cell: Vector3i in [A, B]:
		for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var side: Vector3i = cell + d
			if side == A or side == B:
				continue
			sim.set_block(side, wall)
			sim.set_block(side + Vector3i.UP, wall)
	return [A, B]


func _initialize() -> void:
	DataPackage.install(&"vanilla", &"lost_tribe")
	var gen := WorldGenerator.new()
	gen.terrain_amplitude = 0.0
	var field := _field()
	gen.install_site_field(field)
	var pairs := field.river_boundaries(BOUNDS, gen, PRECIP)

	if not ClassDB.class_exists(&"DelveSim"):
		printerr("no DelveSim — extension missing?")
		quit(2)
		return
	var sim: RefCounted = ClassDB.instantiate(&"DelveSim")
	_check(bool(sim.configure(gen.native_generator())), "DelveSim configured")
	sim.water_seed_flood(
		field.flood, field.origin, SIDE * M, field.flags, M
	)
	for s in pairs[&"sources"]:
		sim.water_set_source(s[&"pos"], s[&"rate"])
	for d in pairs[&"drains"]:
		sim.water_set_drain(d[&"pos"], d[&"rate"])

	# --- The getter: absent record reads fully open, from either side.
	var a := Vector3i(0, LEVEL, 1)
	var b := a + Vector3i(1, 0, 0)
	_check(
		is_equal_approx(
			float(sim.water_edge_scale_at(a, Vector3i(1, 0, 0))), 1.0
		),
		"an unregulated edge reads 1.0"
	)
	sim.water_set_edge_scale(a, Vector3i(1, 0, 0), 0.25)
	_check(
		is_equal_approx(
			float(sim.water_edge_scale_at(b, Vector3i(-1, 0, 0))), 0.25
		),
		"the edge is undirected — set via a, read via b"
	)
	sim.water_set_edge_scale(b, Vector3i(-1, 0, 0), 0.5)
	_check(
		is_equal_approx(
			float(sim.water_edge_scale_at(a, Vector3i(1, 0, 0))), 0.5
		),
		"set via b reads back via a"
	)
	sim.water_set_edge_scale(a, Vector3i(1, 0, 0), 1.0)
	_check(
		is_equal_approx(
			float(sim.water_edge_scale_at(a, Vector3i(1, 0, 0))), 1.0
		),
		"1.0 clears the record back to full flow"
	)

	# --- The tank: a fed source cell A on dry flat ground, all four
	#     lateral edges throttled to a monotone ladder — sealed, open,
	#     half and quarter — so the landed volumes rank by opening.
	#     Each tick tops A up so the four edges compare against the
	#     same driving head.
	# --- The tanks: three walled two-cell channels on dry flat ground.
	#     Walls force the gated A->B edge to be the only way water can
	#     leave A, so the volume landed in B measures that one edge's
	#     throttle directly — no back-door flow through the field.
	var tanks: Array = []
	var tank_spots := [
		Vector2i(10, 12), Vector2i(14, 12), Vector2i(8, 9),
		Vector2i(12, 9), Vector2i(10, 15), Vector2i(14, 15),
	]
	var tank_fail := 0
	for spot in tank_spots:
		if tanks.size() == 3:
			break
		var pair: Variant = _tank(sim, spot.x, spot.y)
		if pair == null:
			tank_fail += 1
			continue
		tanks.append(pair)
	_check(
		tanks.size() == 3,
		"three walled tanks built (%d candidates failed)" % tank_fail
	)
	if tanks.size() == 3:
		var dir := Vector3i(1, 0, 0)
		sim.water_set_edge_scale(tanks[0][0], dir, 0.0) # sealed
		sim.water_set_edge_scale(tanks[1][0], dir, 0.5) # half
		# tanks[2] stays unregulated.
		for pair: Array in tanks:
			sim.water_add(pair[0], 1_000_000)
		for i in 25:
			sim.tick(0.2)
		var v_sealed := int(sim.water_volume_at(tanks[0][1]))
		var v_half := int(sim.water_volume_at(tanks[1][1]))
		var v_open := int(sim.water_volume_at(tanks[2][1]))
		_check(
			v_sealed == 0,
			"a sealed edge moves no water (%d cm³)" % v_sealed
		)
		_check(
			v_half > 0 and v_half < v_open,
			"a half-open edge moves a fraction of the open one "
			+ "(%d vs %d cm³)" % [v_half, v_open]
		)
		_check(
			v_open > 0,
			"the unregulated edge flows freely (%d cm³)" % v_open
		)

		# Reopen the sealed tank — its edge carries water now.
		sim.water_set_edge_scale(tanks[0][0], dir, 1.0)
		for i in 25:
			sim.tick(0.2)
		_check(
			int(sim.water_volume_at(tanks[0][1])) > 0,
			"a reopened edge flows again (%d cm³)"
			% int(sim.water_volume_at(tanks[0][1]))
		)

	# --- Integration: the river reach carries +x flux across a full
	#     cross-section curtain at x=0; sealing every wet cell's +x edge
	#     starves the downstream and zeroes the overlay's crossing flux.
	var curtain_flux := func() -> float:
		var total := 0.0
		var flux: PackedVector3Array = sim.water_flow_field()
		for k in range(0, flux.size(), 2):
			var pos: Vector3 = flux[k]
			if pos.x >= -2 and pos.x <= 1 and pos.z >= 0 and pos.z < 4:
				total += absf(flux[k + 1].x)
		return total
	var downstream := func() -> int:
		var t := 0
		for x in range(1, 16):
			for z in range(0, 4):
				var level := int(sim.water_level_at(x, z))
				if level == SiteField.DRY:
					continue
				for y in range(20, level + 1):
					t += int(sim.water_volume_at(Vector3i(x, y, z)))
		return t

	# The flow overlay reads per-step flux — a quiet tick can sample 0,
	# so both ends of the comparison take the max over a short window.
	var down0: int = downstream.call()
	var flux0 := 0.0
	for i in 8:
		sim.tick(0.2)
		flux0 = maxf(flux0, curtain_flux.call())
	_check(
		flux0 > 0.0,
		"surface flux crosses the open curtain column (%.0f cm³)" % flux0
	)
	for z in range(0, 4):
		for y in range(20, LEVEL + 1):
			sim.water_set_edge_scale(
				Vector3i(0, y, z), Vector3i(1, 0, 0), 0.0
			)
	for i in 80:
		sim.tick(0.2)
	var down_sealed: int = downstream.call()
	var flux_sealed := 0.0
	for i in 8:
		sim.tick(0.2)
		flux_sealed = maxf(flux_sealed, curtain_flux.call())
	_check(
		down_sealed < down0,
		"a sealed curtain starves downstream (%.2f -> %.2f m³)"
		% [down0 / 1.0e6, down_sealed / 1.0e6]
	)
	_check(
		flux_sealed < flux0,
		"the flow overlay sees the seal (%.0f -> %.0f cm³)"
		% [flux0, flux_sealed]
	)

	if _failures.is_empty():
		print("FLOODGATE PROBE PASSED")
	else:
		printerr("FLOODGATE PROBE: %d failure(s)" % _failures.size())
	quit(1 if _failures.is_empty() else 2)
