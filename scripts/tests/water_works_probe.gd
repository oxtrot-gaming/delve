extends SceneTree

## Flux-consumer probe (PLAN item 53) on a bare DelveSim: the pump seam
## and the flux read a water wheel lives on. A walled two-cell tank
## with a *sealed* A->B edge isolates pump transfer from natural head
## flow — water only crosses if the pump moves it — so the checks read
## conservation, rate limiting, dry-intake and full-outflow behavior,
## and the pump-bypasses-the-gate property directly. The flux getter
## is read on the same tank with the edge open.
##
##     godot --headless --path . --script res://scripts/tests/water_works_probe.gd

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


## Builds a walled two-cell channel at (x, z) — like the floodgate
## probe's tank, but the A->B edge is *sealed* on top of the walls so
## natural head flow moves nothing; the pump is the only route water
## out of A can take. Returns [A, B] or null.
func _sealed_tank(sim: RefCounted, x: int, z: int) -> Variant:
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
	sim.water_set_edge_scale(A, Vector3i(1, 0, 0), 0.0)
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

	# --- The pump: three walled two-cell channels on dry flat ground,
	#     each with its A->B edge sealed so the pump is the only route
	#     water can take. Candidate spots are tried in order — a few
	#     always collide with the carved river or rough ground.
	var tank_spots := [
		Vector2i(10, 12), Vector2i(14, 12), Vector2i(8, 9),
		Vector2i(12, 9), Vector2i(10, 15), Vector2i(14, 15),
	]
	var tanks: Array = []
	for spot in tank_spots:
		if tanks.size() == 3:
			break
		var pair: Variant = _sealed_tank(sim, spot.x, spot.y)
		if pair != null:
			tanks.append(pair)
	_check(tanks.size() == 3, "three sealed tanks built")
	if tanks.size() != 3:
		_finish()
		return
	var A: Vector3i = tanks[0][0]
	var B: Vector3i = tanks[0][1]
	sim.water_add(A, CELL_CAP)
	var a0 := int(sim.water_volume_at(A))
	var b0 := int(sim.water_volume_at(B))
	_check(a0 > 0 and b0 == 0, "tank primed: intake full, outflow dry")

	sim.water_set_pump(A, B, 200_000)
	sim.tick(0.2)
	var moved := int(sim.water_volume_at(B)) - b0
	_check(moved > 0, "a powered pump moves water through a sealed edge")
	_check(
		int(sim.water_volume_at(A)) == a0 - moved,
		"pump transfer is conservative — out equals in"
	)
	_check(
		moved <= 200_000,
		"the pump moves no more than its rated step"
	)

	# Run it down: the pump drains the intake toward empty, capped by
	# its rate per step, then does nothing on a dry intake.
	for i in 10:
		sim.tick(0.2)
	_check(
		int(sim.water_volume_at(A)) == 0,
		"the pump empties its intake"
	)
	var b_full := int(sim.water_volume_at(B))
	sim.tick(0.2)
	_check(
		int(sim.water_volume_at(B)) == b_full,
		"a dry intake moves nothing"
	)

	# Full outflow: a pump into a topped-up cell moves nothing, so the
	# intake keeps its water rather than minting or losing it.
	var A2: Vector3i = tanks[1][0]
	var B2: Vector3i = tanks[1][1]
	sim.water_add(A2, CELL_CAP)
	sim.water_add(B2, CELL_CAP)
	sim.water_set_pump(A2, B2, 200_000)
	sim.tick(0.2)
	_check(
		int(sim.water_volume_at(A2)) == CELL_CAP,
		"a pump into a full outflow backs up — nothing minted"
	)
	# Stand the record down — rate 0 clears it. Drain B2 once; a
	# cleared record lets it stay down, a live one would refill
	# from A2 next step.
	sim.water_set_pump(A2, B2, 0)
	sim.water_set_drain(B2, CELL_CAP)
	sim.tick(0.2)
	sim.water_set_drain(B2, 0)
	sim.tick(0.2)
	_check(
		int(sim.water_volume_at(B2)) < 200_000
			and int(sim.water_volume_at(A2)) == CELL_CAP,
		"a cleared pump record stands down"
	)

	# --- The flux read: open the edge and the donor cell's outflow
	# vector points downstream; a sealed edge reads nothing.
	var A3: Vector3i = tanks[2][0]
	var B3: Vector3i = tanks[2][1]
	sim.water_add(A3, CELL_CAP)
	sim.tick(0.2)
	_check(
		Vector3i(sim.water_flux_at(A3)).length() < 0.5,
		"a sealed edge leaves no flux for a wheel to read"
	)
	sim.water_set_edge_scale(A3, Vector3i(1, 0, 0), 1.0)
	var saw_flux := false
	for i in 6:
		sim.tick(0.2)
		if Vector3i(sim.water_flux_at(A3)).length() > 0.5:
			saw_flux = true
			break
	_check(saw_flux, "open flow leaves flux on the donor cell")
	_check(
		Vector3i(sim.water_flux_at(B3)).length() < 0.5
			or Vector3i(sim.water_flux_at(B3)).x <= 0,
		"flux at the receiving cell doesn't point back upstream"
	)
	_check(
		Vector3i(sim.water_flux_at(B3 + Vector3i(0, 0, 1))) == Vector3i.ZERO,
		"a dry cell reads a zero flux vector"
	)

	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("WATER WORKS PROBE PASSED")
	else:
		printerr("WATER WORKS PROBE FAILED: %d checks" % _failures.size())
		for f in _failures:
			printerr("  - ", f)
	quit(0 if _failures.is_empty() else 1)
