extends SceneTree

## DelveSim mirror parity: the native voxel mirror must agree with
## VoxelTool on solidity/standability, track edits and packed piles, and
## its A* must agree with VoxelAStarGrid3D on reachability.
##
##     godot --headless --path . --script res://scripts/tests/sim_parity.gd

const TIMEOUT_SECONDS := 120.0
const SAMPLES := 400

var _checks := 0
var _failures: PackedStringArray = []


func _initialize() -> void:
	_run()


func _run() -> void:
	print("== sim parity ==")
	await _run_inner()
	print(_checks)
	print(_failures.size())
	for failure in _failures:
		print("FAIL: ", failure)
	if _failures.is_empty():
		print("SIM PARITY PASSED")
	else:
		print("SIM PARITY FAILED")
	quit(0 if _failures.is_empty() else 1)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false


func _run_inner() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	_check(spawned, "scene became playable")
	if not spawned:
		return
	colony.forest.set_process(false)

	var sim = world.sim
	_check(sim != null, "world.sim configured")
	if sim == null:
		return

	# Voxel parity over the streamed area: mirror vs VoxelTool.
	var center: Vector3i = colony.units[0]._standing_voxel()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var loaded := 0
	var solid_mismatch := 0
	var id_mismatch := 0
	var standable_mismatch := 0
	for i in SAMPLES:
		var pos := center + Vector3i(
			rng.randi_range(-48, 48), rng.randi_range(-32, 32), rng.randi_range(-48, 48)
		)
		if not world.is_editable(pos):
			continue
		loaded += 1
		if sim.is_solid(pos) != world.is_solid(pos):
			solid_mismatch += 1
		if sim.get_block(pos) != world.get_block(pos):
			id_mismatch += 1
		if sim.is_standable(pos) != world.is_standable(pos):
			standable_mismatch += 1
	_check(loaded > 50, "enough sampled voxels were loaded (%d)" % loaded)
	_check(solid_mismatch == 0, "is_solid parity (%d mismatches)" % solid_mismatch)
	_check(id_mismatch == 0, "get_block parity (%d mismatches)" % id_mismatch)
	_check(standable_mismatch == 0, "is_standable parity (%d mismatches)" % standable_mismatch)

	# Edit sync: mine clears, place sets, remove_voxel clears.
	var mine_target := _solid_spot(world, center)
	if mine_target != Vector3i.MAX:
		world.mine(mine_target)
		_check(sim.get_block(mine_target) == 0, "sim saw the mine")
		var place_target := mine_target
		world.place(place_target, BlockRegistry.Block.STONE)
		_check(
			sim.get_block(place_target) == BlockRegistry.Block.STONE,
			"sim saw the place"
		)
		world.remove_voxel(place_target)
		_check(sim.get_block(place_target) == 0, "sim saw remove_voxel")

	# Packed-pile sync: fill a voxel, then empty it.
	var spot := _open_spot(world, center)
	if spot != Vector3i.MAX:
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 600_000), spot
		)
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 600_000), spot
		)
		# Over-capacity deposits may spill/settle; packed state must match
		# the colony's own view wherever the pile ended up.
		for voxel in colony.item_piles:
			_check(
				sim.is_packed(voxel) == (colony.item_piles[voxel].is_full() and not world.is_solid(voxel)),
				"packed bit matches pile at %s" % voxel
			)
		var pile: ItemPile = colony.item_piles.get(spot)
		if pile != null and pile.is_full():
			pile.take_up_to(DropItem.BLOCK_CM3)
			_check(not sim.is_packed(spot), "packed bit cleared on take")

	# Fill-map sync: sim.fill_of must equal colony.voxel_fill on piles,
	# air and solid voxels alike — the spill/settle searches read it.
	var fill_mismatch := 0
	for i in SAMPLES / 4:
		var pos := center + Vector3i(
			rng.randi_range(-32, 32), rng.randi_range(-16, 16), rng.randi_range(-32, 32)
		)
		if int(sim.fill_of(pos)) != colony.voxel_fill(pos):
			fill_mismatch += 1
	for voxel in colony.item_piles:
		if int(sim.fill_of(voxel)) != colony.item_piles[voxel].total_volume():
			fill_mismatch += 1
	_check(fill_mismatch == 0, "fill_of parity (%d mismatches)" % fill_mismatch)

	# settle_floor: a boulder (unsplittable) walks down to the loaded edge
	# or rests where the cell below is a floor — blocked, or a pile it
	# would overfill.
	var settle: Vector3i = sim.settle_floor(spot, DropItem.BOULDER_CM3, false)
	_check(settle.y <= spot.y, "settle_floor never climbs")
	var settle_below: Vector3i = settle + Vector3i.DOWN
	_check(
		not world.is_editable(settle_below)
			or colony.is_packed(settle_below)
			or sim.fill_of(settle_below) > DropItem.BLOCK_CM3 - DropItem.BOULDER_CM3,
		"settle_floor rests on a floor"
	)

	# Path parity: reachability agreement with VoxelAStarGrid3D.
	var paths_checked := 0
	var disagree := 0
	for i in 12:
		var angle := TAU * float(i) / 12.0
		var x := center.x + int(cos(angle) * 20.0)
		var z := center.z + int(sin(angle) * 20.0)
		var target := Vector3i(x, world.ground_height(x, z) + 1, z)
		if not world.is_standable(target):
			continue
		# Reference path through the engine pathfinder (same region rule).
		var min_corner := center.min(target) - Vector3i.ONE * 24
		var max_corner := center.max(target) + Vector3i.ONE * 24
		world._astar.set_region(AABB(Vector3(min_corner), Vector3(max_corner - min_corner)))
		var ref_path := world._astar.find_path(center, target)
		var native_path: PackedVector3Array = sim.find_path(center, target)
		paths_checked += 1
		if ref_path.is_empty() != native_path.is_empty():
			disagree += 1
		elif not ref_path.is_empty() and absf(ref_path.size() - native_path.size()) > ref_path.size() * 0.25 + 2:
			disagree += 1
	_check(paths_checked > 4, "enough paths compared (%d)" % paths_checked)
	_check(disagree == 0, "path reachability parity (%d disagreements)" % disagree)

	# work_spots: every returned spot is unit-standable and within reach of
	# the target's face; a solid wall voxel should have several.
	var unit: Unit = colony.units[0]
	var wall := _solid_spot(world, center)
	var spots := unit._work_spots(wall, true)
	_check(not spots.is_empty(), "work_spots finds spots beside a wall")
	var bad_spots := 0
	for candidate in spots:
		if not sim.is_unit_standable(Vector3i(candidate)):
			bad_spots += 1
	_check(bad_spots == 0, "all work spots are unit-standable (%d bad)" % bad_spots)


func _solid_spot(world: VoxelWorld, center: Vector3i) -> Vector3i:
	for dx in range(-20, 20):
		for dz in range(-20, 20):
			var pos := Vector3i(center.x + dx, center.y - 1, center.z + dz)
			if world.is_solid(pos) and world.is_editable(pos):
				return pos
	return Vector3i.MAX


func _open_spot(world: VoxelWorld, center: Vector3i) -> Vector3i:
	for dx in range(-20, 20):
		for dz in range(-20, 20):
			var pos := Vector3i(center.x + dx, center.y, center.z + dz)
			if world.is_editable(pos) and not world.is_solid(pos):
				return pos
	return Vector3i.MAX
