extends SceneTree

## Headless smoke test for the framework.
##
##     godot --headless --path . --script res://scripts/tests/smoke_test.gd
##
## Checks that the generator produces layered terrain, that the blocky library
## bakes, and that a designated mining job actually gets done by a unit and
## drops an item pile where the block was.

const TIMEOUT_SECONDS := 120.0

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	_test_block_registry()
	_test_drops()
	_test_generator()
	await _test_mining_loop()

	if _failures.is_empty():
		print("SMOKE TEST PASSED")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)


func _test_block_registry() -> void:
	print("block registry")
	var library := BlockRegistry.build_library()
	_check(library.models.size() == BlockRegistry.BLOCKS.size(), "library has a model per block type")
	_check(not BlockRegistry.is_solid(BlockRegistry.Block.AIR), "air is not solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.STONE), "stone is solid")
	_check(
		BlockRegistry.drop_of(BlockRegistry.Block.IRON_ORE) == BlockRegistry.Resource_.IRON,
		"iron ore drops iron"
	)


func _test_drops() -> void:
	print("mining drops")
	var dirt_drops := DropItem.for_block(BlockRegistry.Block.DIRT)
	_check(dirt_drops.size() == 1, "soft blocks drop a single item")
	if dirt_drops.size() == 1:
		_check(dirt_drops[0].form == DropItem.Form.LOOSE, "soft blocks drop a loose item")
		_check(
			is_equal_approx(dirt_drops[0].volume, DropItem.DROP_VOLUME),
			"the loose item is 125% of the block's volume"
		)

	var stone_drops := DropItem.for_block(BlockRegistry.Block.STONE)
	var total := 0.0
	var has_boulder := false
	var has_cobble := false
	var has_loose := false
	var all_stone := true
	for item in stone_drops:
		total += item.volume
		all_stone = all_stone and item.material == BlockRegistry.Resource_.STONE
		match item.form:
			DropItem.Form.BOULDER: has_boulder = true
			DropItem.Form.COBBLE: has_cobble = true
			DropItem.Form.LOOSE: has_loose = true
	_check(is_equal_approx(total, DropItem.DROP_VOLUME), "hard block drops total 125% of the block's volume")
	_check(has_boulder and has_cobble and has_loose, "hard blocks drop boulders, cobbles and loose gravel")
	_check(all_stone, "every dropped item has the mined block's material class")


func _test_generator() -> void:
	print("terrain generator")
	var generator := WorldGenerator.new()
	var surface_y := generator.surface_height(0, 0)

	var buffer := VoxelBuffer.new()
	buffer.create(16, 16, 16)
	var origin := Vector3i(0, surface_y - 8, 0)
	generator._generate_block(buffer, origin, 0)

	var found: Dictionary[int, int] = {}
	for x in 16:
		for y in 16:
			for z in 16:
				var block := buffer.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
				found[block] = found.get(block, 0) + 1

	_check(found.has(BlockRegistry.Block.AIR), "generates air above the surface")
	_check(found.has(BlockRegistry.Block.STONE), "generates stone underground")
	_check(
		found.has(BlockRegistry.Block.GRASS) or found.has(BlockRegistry.Block.DIRT),
		"generates a soil layer"
	)

	var sky := VoxelBuffer.new()
	sky.create(16, 16, 16)
	generator._generate_block(sky, Vector3i(0, 512, 0), 0)
	_check(sky.is_uniform(VoxelBuffer.CHANNEL_TYPE), "blocks far above the surface are empty")

	# Rock outcrops: somewhere nearby a column's rock mass rises above the
	# grass line, and the voxel at its top is stone.
	var outcrop := Vector3i.MAX
	for ox in range(-96, 96, 4):
		for oz in range(-96, 96, 4):
			var grass_y: int = generator._terrain_height(ox, oz)
			if generator.surface_height(ox, oz) > grass_y:
				outcrop = Vector3i(ox, generator.surface_height(ox, oz), oz)
				break
		if outcrop != Vector3i.MAX:
			break
	_check(outcrop != Vector3i.MAX, "generates occasional rock outcrops at the surface")
	if outcrop != Vector3i.MAX:
		var chunk := VoxelBuffer.new()
		chunk.create(16, 16, 16)
		var chunk_origin := Vector3i(
			floori(float(outcrop.x) / 16.0) * 16,
			floori(float(outcrop.y) / 16.0) * 16,
			floori(float(outcrop.z) / 16.0) * 16
		)
		generator._generate_block(chunk, chunk_origin, 0)
		var ry := outcrop - chunk_origin
		_check(
			chunk.get_voxel(ry.x, ry.y, ry.z, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.STONE,
			"an outcrop's topmost voxel is stone"
		)


func _test_mining_loop() -> void:
	print("colony mining loop")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)

	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	_check(spawned, "units spawn once the terrain is loaded")
	if not spawned:
		return

	var unit: Unit = colony.units[0]
	_check(
		unit.skin_tone.r <= Unit.SKIN_TONE_PALE.r + 0.001
			and unit.skin_tone.r >= Unit.SKIN_TONE_DARK.r - 0.001
			and unit.skin_tone.g <= unit.skin_tone.r
			and unit.skin_tone.b <= unit.skin_tone.g,
		"a unit's skin tone lies on the pale-to-dark ramp"
	)
	var body := (unit.get_node("MeshInstance3D") as MeshInstance3D) \
		.get_surface_override_material(0) as StandardMaterial3D
	_check(
		body != null and body.albedo_color.is_equal_approx(unit.skin_tone),
		"the unit's body is tinted with its skin tone"
	)
	_check(
		not colony.units.all(
			func(u: Unit) -> bool: return u.skin_tone.is_equal_approx(unit.skin_tone)
		),
		"units get randomized skin tones"
	)

	var target := _pick_mining_target(world, unit)
	_check(target != Vector3i.MAX, "found a designatable voxel near a unit")
	if target == Vector3i.MAX:
		return

	var block_before := world.get_block(target)
	var job := colony.designate_mine(target)
	_check(job != null, "designation creates a job")

	var mined := await _wait_until(func() -> bool: return not world.is_solid(target))
	_check(mined, "a unit mines the designated voxel")
	# The drop may spill into neighboring voxels, so tally every pile: this is a
	# fresh colony, so all existing piles came from this one mining job. Falling
	# piles merge on arrival — wait for any flights to finish first.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var expected := BlockRegistry.drop_of(block_before)
	var total := 0.0
	var item_count := 0
	var same_material := true
	var near_pile := false
	for voxel in colony.item_piles:
		var pile: ItemPile = colony.item_piles[voxel]
		var offset := (voxel - target).abs()
		near_pile = near_pile or maxi(offset.x, maxi(offset.y, offset.z)) <= 2
		for item in pile.items:
			item_count += 1
			total += item.volume
			same_material = same_material and item.material == expected
	_check(near_pile, "mined block drops item piles around the mined voxel")
	_check(item_count > 0, "the piles hold dropped items")
	_check(same_material, "every dropped item has the block's material class")
	_check(
		is_equal_approx(total, DropItem.DROP_VOLUME),
		"dropped items total 125% of the block's volume"
	)

	await _test_spilling(colony, world, target)
	_test_fill(colony, world, unit, target)
	await _test_shove(colony, world, target)
	await _test_clear(colony, world, target)
	await _test_build(colony, world, target)
	_test_reach(unit, world, target)
	_test_camera_collision(main.get_node("Overseer"), world, target)
	_test_highlight(main.get_node("Overseer"), colony, world, target)
	await _test_stuck(colony, world, unit)

	main.queue_free()


## Camera collision: the overseer cannot enter solid terrain — it stops with
## its clearance margin intact, and slides along blocked axes instead of
## sticking.
func _test_camera_collision(overseer: Overseer, world: VoxelWorld, near: Vector3i) -> void:
	var x := near.x + 12
	var z := near.z + 12
	var ground := world.ground_height(x, z, near.y + 32)

	overseer.global_position = Vector3(x + 0.5, ground + 6.5, z + 0.5)
	overseer._slide(Vector3(0, -10, 0))
	_check(
		not world.is_solid(Vector3i(overseer.global_position.floor())),
		"the camera stops outside solid terrain"
	)
	_check(
		overseer.global_position.y >= float(ground + 1) + overseer.camera_margin - 0.001,
		"the camera keeps its clearance above the ground"
	)

	# A wall placed in open air blocks sideways movement too.
	var wall := Vector3i(x + 4, ground + 8, z)
	world.place(wall, BlockRegistry.Block.STONE)
	overseer.global_position = Vector3(wall) + Vector3(-1.5, 0.5, 0.5)
	overseer._slide(Vector3(3, 0, 0))
	_check(
		overseer.global_position.x <= float(wall.x) - overseer.camera_margin + 0.001,
		"the camera cannot fly through a solid block"
	)
	world.mine(wall)


## The highlight marks the voxel the selected action acts on: Mine hits the
## block behind a pile, Clear hits the pile itself, and an action that can't
## act on its target highlights red.
func _test_highlight(overseer: Overseer, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x - 14, 0, mined.z - 4)
	pile_voxel.y = world.ground_height(pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.4), pile_voxel
	)

	overseer.global_position = Vector3(pile_voxel) + Vector3(0.5, 4.5, 0.5)
	overseer.camera.global_transform = Transform3D(
		Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
	)

	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	overseer._update_target()
	_check(
		overseer._targeted != null
			and overseer.highlight.global_position.is_equal_approx(
				Vector3(overseer._targeted.position) + Vector3.ONE * 0.5
			),
		"the mine action highlights the block behind a pile"
	)

	overseer._cycle_action()
	_check(
		overseer.current_action() == &"clear_pile",
		"the action key cycles through overseer actions"
	)
	overseer._update_target()
	_check(
		overseer._targeted != null
			and overseer.highlight.global_position.is_equal_approx(
				Vector3(pile_voxel) + Vector3.ONE * 0.5
			),
		"the clear action highlights the pile's voxel"
	)

	overseer._perform()
	var clear_job := false
	for j in colony.jobs:
		if j.type == ColonyJob.Type.CLEAR and j.voxel_position == pile_voxel:
			clear_job = true
	_check(clear_job, "performing the selected action designates the pile for clearing")
	colony.cancel_designation(pile_voxel)

	# Clearing bare ground can't act — the highlight turns red.
	var bare := pile_voxel + Vector3i(3, 0, 0)
	overseer.global_position = Vector3(bare) + Vector3(0.5, 4.5, 0.5)
	overseer.camera.global_transform = Transform3D(
		Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
	)
	overseer._update_target()
	var highlight_material := overseer.highlight.material_override as StandardMaterial3D
	_check(
		overseer._targeted != null
			and highlight_material != null
			and highlight_material.albedo_color.is_equal_approx(overseer.HIGHLIGHT_INVALID),
		"an action that can't act on the target highlights red"
	)


## Dropping items into voxels: loose items split off a share and solid items
## hop aside, preferring the open voxel below; piles always settle onto solid
## ground, including when the block under them is mined away.
func _test_spilling(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var before := _pile_volume_total(colony)

	# A loose drop into open air sheds part of itself downward; the whole
	# thing settles into the mined column below — into the hole if the mined
	# voxel still has room, or onto its pile if it is packed.
	var base := mined + Vector3i(0, 3, 0)
	var column_before := _column_volume(colony, mined)
	colony._drop_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.4), base)
	var hole_grew := await _wait_until(func() -> bool:
		return _column_volume(colony, mined) > column_before + 0.1)
	_check(hole_grew, "part of a loose drop settles into the mined column")

	# A pile packed onto a shelf of placed stone has no room for more: a solid
	# drop into that voxel must hop aside.
	var shelf := Vector3i(mined.x - 6, 0, mined.z - 6)
	shelf.y = world.ground_height(shelf.x, shelf.z, mined.y + 32) + 5
	var packed := shelf + Vector3i.UP
	world.place(shelf, BlockRegistry.Block.STONE)
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.5), packed)
	var cobble := DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE, DropItem.COBBLE_VOLUME)
	colony._drop_item(cobble, packed)
	_check(
		not colony.item_pile_at(packed).items.has(cobble),
		"a solid drop moves out of a fully occupied voxel"
	)

	# Mining the shelf knocks the support out: the packed pile falls to the
	# floor of the column and comes to rest there, merging with whatever
	# pile is already in the way.
	world.mine(shelf)
	var pit_floor := Vector3i(
		shelf.x, world.ground_height(shelf.x, shelf.z, mined.y + 32) + 1, shelf.z
	)
	var settled := await _wait_until(func() -> bool:
		var pile := colony.item_pile_at(pit_floor)
		return (
			pile != null
			and pile.total_volume() >= 0.99
			and is_equal_approx(pile.position.y, float(pit_floor.y))
		))
	_check(settled, "items fall and come to rest when the block beneath is mined")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		is_equal_approx(_pile_volume_total(colony), before + 0.4 + 1.5 + DropItem.COBBLE_VOLUME),
		"spilling drops conserve volume"
	)


## Fill is floor: a voxel packed with items is impassible like a solid block,
## and both items and units can stand on top of it.
func _test_fill(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	var column := Vector3i(mined.x + 8, 0, mined.z - 8)
	column.y = world.ground_height(column.x, column.z, mined.y + 32) + 1
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.2), column)

	_check(colony.is_packed(column), "a voxel holding a full cubic metre is packed")
	_check(unit._is_blocked(column), "a packed voxel blocks units")
	_check(not unit._is_standable(column), "a packed voxel is not standable")
	_check(unit._is_standable(column + Vector3i.UP), "a unit can stand on a packed voxel")

	var packed_pile := colony.item_pile_at(column)
	var box := packed_pile._fill_shape.shape as BoxShape3D
	_check(
		box != null and is_equal_approx(box.size.y, 1.0),
		"a packed pile's collision fills the voxel"
	)

	var renders_solid := false
	for child in packed_pile.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh is BoxMesh:
			var cube := mesh_instance.mesh as BoxMesh
			renders_solid = minf(minf(cube.size.x, cube.size.y), cube.size.z) > 0.9
	_check(renders_solid, "a packed voxel renders as a solid block")

	# An item dropped above a packed voxel comes to rest on top of it.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 0.1),
		column + Vector3i(0, 3, 0)
	)
	_check(
		colony.item_pile_at(column + Vector3i.UP) != null,
		"items land on top of a packed voxel"
	)

	# A deposit bigger than a cubic metre splits: the voxel keeps a full
	# metre and the excess lands in an adjoining voxel.
	var overfull := Vector3i(mined.x + 12, 0, mined.z - 12)
	overfull.y = world.ground_height(overfull.x, overfull.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.5), overfull
	)
	var over_pile := colony.item_pile_at(overfull)
	_check(
		over_pile != null and over_pile.total_volume() <= 1.0 + ItemPile.FULL_EPSILON,
		"a pile never exceeds one cubic metre"
	)
	var excess_moved := false
	for side in colony.SPILL_SIDES:
		for dy in [1, 0, -1, -2]:
			var spilled := colony.item_pile_at(overfull + side + Vector3i(0, dy, 0))
			if spilled != null and not spilled.items.is_empty():
				excess_moved = true
	_check(excess_moved, "a pile's excess moves to an adjacent voxel")


## A unit blocked by a packed pile shoves its items into neighbouring voxels
## until the cell is passable — conserving the items, not deleting them.
func _test_shove(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var blocked := Vector3i(mined.x - 10, 0, mined.z + 10)
	blocked.y = world.ground_height(blocked.x, blocked.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.2), blocked
	)

	var volume_before := _pile_volume_total(colony)
	_check(colony.shove_pile(blocked), "a packed pile can be shoved aside")
	_check(not colony.is_packed(blocked), "shoving clears the blocked voxel")

	var moved := false
	for side in colony.SPILL_SIDES:
		for offset in [Vector3i.ZERO, Vector3i.DOWN]:
			var pile := colony.item_pile_at(blocked + side + offset)
			if pile != null and not pile.items.is_empty():
				moved = true
	_check(moved, "shoved items land in an adjacent voxel")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		is_equal_approx(_pile_volume_total(colony), volume_before),
		"shoved items keep their volume"
	)


## A clearing designation is a real job: a unit walks up to the pile and
## moves every item into adjoining voxels — the pile empties, nothing is lost.
func _test_clear(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x + 10, 0, mined.z + 6)
	pile_voxel.y = world.ground_height(pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	_check(
		colony.designate_clear(pile_voxel) == null,
		"an empty voxel can't be designated for clearing"
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.4), pile_voxel
	)
	var volume_before := _pile_volume_total(colony)

	var job := colony.designate_clear(pile_voxel)
	_check(job != null, "designating a filled voxel creates a clearing job")
	if job == null:
		return

	var emptied := await _wait_until(func() -> bool:
		return colony.item_pile_at(pile_voxel) == null)
	_check(emptied, "a unit clears the pile out of the voxel")
	# A passing unit may have shoved the packed pile before the job was
	# claimed — the job completes either way once a unit takes it.
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "the clearing job completes")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		is_equal_approx(_pile_volume_total(colony), volume_before),
		"clearing moves items rather than deleting them"
	)


## A build designation gathers loose soil from piles near the site and
## compacts it into a solid dirt block — the inverse of the mining drop.
func _test_build(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var build := Vector3i(mined.x - 16, 0, mined.z - 16)
	build.y = world.ground_height(build.x, build.z, mined.y + 32) + 1

	# A solid voxel can't be built on.
	var solid := Vector3i(mined.x - 16, 0, mined.z - 14)
	solid.y = world.ground_height(solid.x, solid.z, mined.y + 32)
	_check(
		colony.designate_build(solid) == null,
		"a solid voxel can't be designated for building"
	)

	# Two piles of loose dirt near the site, totalling more than the build cost.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.9),
		build + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.8),
		build + Vector3i(-2, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# The unit fetches the pile closest to itself — which may be nowhere near
	# the site — so consumption is measured across every pile in the world.
	var dirt_before := _soil_volume_near(colony, build, 100000.0)

	# Gathering has no distance limit — it targets the closest dirt pile.
	var nearest := colony.nearest_soil_voxel(build)
	_check(
		nearest != Vector3i.MAX and Vector3(nearest - build).length() <= 4.0,
		"the closest dirt pile is picked as the fetch source"
	)

	var job := colony.designate_build(build)
	_check(job != null, "designating an empty voxel creates a build job")
	if job == null:
		return

	# An array so the lambda's capture writes through — GDScript captures
	# plain locals by value.
	var saw_fetch := [false]
	var built := await _wait_until(func() -> bool:
		for unit in colony.units:
			if unit._fetching:
				saw_fetch[0] = true
		return world.get_block(build) == BlockRegistry.Block.DIRT)
	_check(built, "a unit builds a dirt block from gathered soil")
	_check(saw_fetch[0], "the unit hauls dirt to the site")
	_check(job.state == ColonyJob.State.DONE, "the build job completes")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var soil_after := _soil_volume_near(colony, build, 100000.0)
	# Loose-item splits discard sub-0.0001 m³ residuals, so allow a little
	# slack rather than demanding exact conservation.
	_check(
		absf(soil_after - (dirt_before - DropItem.DROP_VOLUME)) < 0.05,
		"building consumed 1.25 m³ of loose dirt (%.4f → %.4f)"
			% [dirt_before, soil_after]
	)


## Total loose-soil volume piled within [param radius] of [param centre].
func _soil_volume_near(colony: Colony, centre: Vector3i, radius: float) -> float:
	var total := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - centre).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.SOIL:
				total += item.volume
	return total


## Reach rule: within 1.5 m of the block's nearest face, with a clear line —
## checked against a small wall built in open air so terrain can't interfere.
func _test_reach(unit: Unit, world: VoxelWorld, mined: Vector3i) -> void:
	var base := Vector3i(mined.x + 4, 0, mined.z + 4)
	base.y = world.ground_height(base.x, base.z, mined.y + 32) + 5
	var behind := base + Vector3i.BACK
	world.place(base, BlockRegistry.Block.STONE)
	world.place(behind, BlockRegistry.Block.STONE)

	var eye := Vector3(base) + Vector3(0.5, 0.5, -0.4)
	_check(unit._can_mine_from(eye, base), "can mine a block with a clear line")
	_check(
		unit._can_mine_from(Vector3(base) + Vector3(0.5, 1.4, 0.5), base),
		"can mine a block from above"
	)
	_check(not unit._can_mine_from(eye, behind), "cannot mine through a solid block")
	_check(
		not unit._can_mine_from(eye + Vector3(0.0, 0.0, -2.0), base),
		"cannot mine beyond reach"
	)

	world.mine(base)
	world.mine(behind)


func _pile_volume_total(colony: Colony) -> float:
	var total := 0.0
	for pile in colony.item_piles.values():
		total += pile.total_volume()
	return total


## Total item volume piled anywhere in [param voxel]'s x/z column.
func _column_volume(colony: Colony, voxel: Vector3i) -> float:
	var total := 0.0
	for key in colony.item_piles:
		if key.x == voxel.x and key.z == voxel.z:
			total += colony.item_piles[key].total_volume()
	return total


## A unit that cannot make progress toward its job site drops the assignment
## after the stuck timeout, freeing the job for someone else.
func _test_stuck(colony: Colony, world: VoxelWorld, unit: Unit) -> void:
	var target := _pick_mining_target(world, unit, 4)
	_check(target != Vector3i.MAX, "found a job site for the stuck test")
	if target == Vector3i.MAX:
		return

	var job := colony.designate_mine(target)
	if job == null:
		_check(false, "stuck test designation creates a job")
		return
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit.state = Unit.State.MOVING
	var old_speed := unit.move_speed
	var old_timeout := unit.stuck_timeout
	# Immobilized: the path may exist but the unit will never get closer.
	unit.move_speed = 0.0
	unit.stuck_timeout = 0.3

	# dropped_by is the release marker — the PENDING window can close between
	# frames if another idle unit reclaims the job first.
	var released := await _wait_until(func() -> bool:
		return job.dropped_by.has(unit))
	_check(released, "a stuck unit drops its job assignment")
	_check(job.dropped_by.has(unit), "a dropped job resists instant reclaim by the same unit")

	unit.move_speed = old_speed
	unit.stuck_timeout = old_timeout
	colony.cancel_designation(target)


## Topmost solid voxel in a column [param distance] voxels away from the unit.
func _pick_mining_target(world: VoxelWorld, unit: Unit, distance: int = 2) -> Vector3i:
	var origin := Vector3i(unit.global_position.floor())
	var offsets: Array[Vector3i] = [
		Vector3i(distance, 0, 0), Vector3i(-distance, 0, 0),
		Vector3i(0, 0, distance), Vector3i(0, 0, -distance)
	]
	for offset in offsets:
		var column := origin + offset
		var ground_y := world.ground_height(column.x, column.z, origin.y + 16, origin.y - 16)
		var candidate := Vector3i(column.x, ground_y, column.z)
		if world.is_solid(candidate):
			return candidate
	return Vector3i.MAX


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
