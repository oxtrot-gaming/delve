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
	await _test_overflow(colony, world, target)
	await _test_hole(colony, world, target)
	await _test_shove(colony, world, target)
	await _test_clear(colony, world, target)
	await _test_build(colony, world, target)
	_test_reach(unit, world, target)
	_test_camera_collision(main.get_node("Overseer"), world, target)
	_test_highlight(main.get_node("Overseer"), colony, world, target)
	_test_drag(main.get_node("Overseer"), colony, world, target)
	await _test_stuck(colony, world, unit)
	_test_retry(colony, world, target)
	await _test_detour(colony, world, target)
	await _test_clear_haul(colony, world, target)
	await _test_stockpile(colony, world, target)
	await _test_yield(colony, world, target)
	await _test_evict(colony, world, target)

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


## Drag designation: pressing a button anchors a box on the hit face's plane.
## Moving the aim promotes the press to a drag that commits on release; a
## long press makes the box stick — it survives the release, the wheel
## extrudes it into a volume, LMB commits and RMB aborts it.
func _test_drag(overseer: Overseer, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var base := _flat_voxel(world, mined, 56)
	_check(base != Vector3i.MAX, "found a flat stretch for the drag test")
	if base == Vector3i.MAX:
		return
	var g := base.y - 1

	var aim := func(x: int, z: int) -> void:
		var gy := world.ground_height(x, z, mined.y + 32)
		overseer.global_position = Vector3(x + 0.5, gy + 6.5, z + 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer._update_target()

	var click := func(button: MouseButton, pressed: bool) -> void:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		overseer._unhandled_input(ev)

	# The two layers the extrusion checks look at: the surface and one below.
	var count_markers := func() -> int:
		var n := 0
		for dx in 3:
			for dy in 2:
				if colony._designation_markers.has(Vector3i(base.x + dx, g - dy, base.z)):
					n += 1
		return n

	overseer.select_action(overseer.ACTIONS.find(&"mine"))

	# A quick click designates the single voxel under the aim.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		colony._designation_markers.has(Vector3i(base.x, g, base.z)),
		"a click designates the voxel under the aim"
	)
	colony.cancel_designation(Vector3i(base.x, g, base.z))

	# Pressing, aiming across the strip and releasing drags a rect.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	_check(overseer._drag_active, "moving the aim while held promotes the drag")
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 3, "a drag commits every voxel in the rect on release")

	# The same sweep with RMB cancels it again.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_RIGHT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_RIGHT, false)
	_check(count_markers.call() == 0, "a cancel drag clears the rect")

	# A long press makes the box stick: the button can release, the box keeps
	# following the aim, the wheel extrudes it in either direction, and a
	# click commits.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	overseer._press_hold = Overseer.DRAG_HOLD
	overseer._tick_press(0.0)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		overseer._drag_active,
		"a long-press drag stays up after the button releases"
	)
	aim.call(base.x + 2, base.z)
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	_check(overseer._drag_extrude == 1, "the wheel extrudes a drag toward the camera")
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	_check(overseer._drag_extrude == -1, "the wheel extrudes a drag into the face")
	click.call(MOUSE_BUTTON_LEFT, true)
	_check(not overseer._drag_active, "a click commits a sticky drag")
	_check(count_markers.call() == 6, "an extruded drag designates the whole volume")

	# The same volume cancelled: RMB press, aim across, wheel down, release.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_RIGHT, true)
	aim.call(base.x + 2, base.z)
	overseer._unhandled_input(wheel)
	click.call(MOUSE_BUTTON_RIGHT, false)
	_check(count_markers.call() == 0, "an extruded cancel drag clears the volume")

	# While a drag is up, RMB aborts it instead of applying anything.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_RIGHT, true)
	_check(
		not overseer._drag_active and count_markers.call() == 0,
		"RMB aborts a drag without applying it"
	)
	click.call(MOUSE_BUTTON_LEFT, false)

	# A stockpile drag works on the air layer in front of the face.
	overseer.select_action(overseer.ACTIONS.find(&"designate_stockpile"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 1, base.z)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		colony.is_stockpile(base) and colony.is_stockpile(base + Vector3i(1, 0, 0)),
		"a stockpile drag designates the air layer in front of the face"
	)
	colony.undesignate_stockpile(base)
	colony.undesignate_stockpile(base + Vector3i(1, 0, 0))
	overseer.select_action(0)


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


## Stockpiles: designation rules, idle-unit hauling of loose piles, and the
## interrupted-haul drop.
func _test_stockpile(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var sp := Vector3i(mined.x + 16, 0, mined.z + 16)
	sp.y = world.ground_height(sp.x, sp.z, mined.y + 32) + 1

	# Stockpile tiles must be empty voxels resting on a solid block.
	_check(
		not colony.designate_stockpile(sp + Vector3i.UP),
		"a voxel with no ground under it can't be a stockpile"
	)
	_check(
		colony.designate_stockpile(sp),
		"an empty voxel on solid ground designates as a stockpile"
	)
	_check(colony.is_stockpile(sp), "the stockpile designation sticks")
	_check(
		not colony.designate_stockpile(sp),
		"a voxel can't be stockpile-designated twice"
	)
	_check(
		colony.undesignate_stockpile(sp),
		"undesignating removes the stockpile"
	)
	_check(
		colony.designate_stockpile(sp),
		"a voxel can be stockpile-designated again"
	)

	# A pile bigger than one load: hauled to the stockpile in trips.
	var dump := Vector3i(mined.x + 8, 0, mined.z + 8)
	dump.y = world.ground_height(dump.x, dump.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.9), dump
	)
	var saw_carry := [false]
	var hauled := await _wait_until(func() -> bool:
		for unit in colony.units:
			if unit._carried_volume() > 0.0:
				saw_carry[0] = true
		var pile := colony.item_pile_at(sp)
		return pile != null and pile.total_volume() >= 0.85)
	_check(saw_carry[0], "a unit physically carries items while hauling")
	_check(hauled, "items are hauled to the stockpile")

	# Interrupting a haul drops the carried items where the unit stands.
	var dump2 := Vector3i(mined.x + 10, 0, mined.z + 8)
	dump2.y = world.ground_height(dump2.x, dump2.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.6), dump2
	)
	var found := await _wait_until(func() -> bool:
		return colony.units.any(func(u: Unit) -> bool: return u._carried_volume() > 0.0))
	_check(found, "a haul is in progress to interrupt")
	if found:
		var carrier: Unit = null
		for u in colony.units:
			if u._carried_volume() > 0.0:
				carrier = u
		var at := carrier._standing_voxel()
		var load := carrier._carried_volume()
		carrier.abandon_job()
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		# Another unit may already be hauling the fresh pile away — count
		# carried loads near the drop point as well as piled volume.
		var recovered := _volume_near(colony, at, 4.0)
		for u in colony.units:
			if Vector3(at).distance_to(u.global_position) <= 4.0:
				recovered += u._carried_volume()
		_check(
			recovered >= load - 0.01,
			"an interrupted haul drops the carried items"
		)


## A solid item that can't fit in a nearly-full voxel must overflow to the
## nearest voxel with room — not shuttle between the voxel and the one above
## it forever.
func _test_overflow(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var hole := _flat_voxel(world, mined, 48)
	_check(hole != Vector3i.MAX, "found a flat spot for the overflow test")
	if hole == Vector3i.MAX:
		return
	# A one-wide hole: solid floor, four solid sides.
	for side in [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]:
		world.place(hole + side, BlockRegistry.Block.STONE)
	# Fill it so a 0.1 m³ boulder can't join without overfilling.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.95), hole
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 0.1), hole
	)
	var settled := await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(settled, "an oversized drop settles instead of bouncing forever")
	var pile := colony.item_pile_at(hole)
	_check(
		pile != null and pile.total_volume() <= 1.0 + ItemPile.FULL_EPSILON,
		"the hole keeps only what fits"
	)
	var outside := false
	for v in colony.item_piles:
		if v == hole:
			continue
		for item in colony.item_piles[v].items:
			if item.form == DropItem.Form.BOULDER:
				outside = true
	_check(outside, "the oversized item lands outside the hole")


## A dug-out hole — walled on all four sides: a cubic metre of loose drop
## stays in the hole and the surplus rests on the packed pile above it, and
## clearing the hole shovels items out over the rim.
func _test_hole(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var sides := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]
	var hole := Vector3i.MAX
	for z_off in [64, 80, 96, 112]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate == Vector3i.MAX:
			continue
		var clear := (
			not world.is_solid(candidate + Vector3i.UP)
			and colony.item_pile_at(candidate + Vector3i.UP) == null
		)
		for side in sides:
			if colony.item_pile_at(candidate + side) != null:
				clear = false
		if not clear:
			continue
		var walled := true
		for side in sides:
			if not world.is_solid(candidate + side):
				world.place(candidate + side, BlockRegistry.Block.STONE)
			if not world.is_solid(candidate + side):
				walled = false
		if walled:
			hole = candidate
			break
	_check(hole != Vector3i.MAX, "found a walled hole for the hole test")
	if hole == Vector3i.MAX:
		return

	# The mined-dirt case: 1.25 m³ dropped into a walled hole splits into a
	# full metre in the hole and the surplus on the cell above it. The whole
	# deposit chain is synchronous, so the piles are checked before any unit
	# tick could touch them.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.25), hole
	)
	var hole_pile := colony.item_pile_at(hole)
	var rim_pile := colony.item_pile_at(hole + Vector3i.UP)
	_check(
		hole_pile != null and absf(hole_pile.total_volume() - 1.0) < 0.001,
		"a dug-out hole keeps a full cubic metre"
	)
	_check(
		rim_pile != null and absf(rim_pile.total_volume() - 0.25) < 0.001,
		"the surplus spills onto the cell above the hole"
	)

	# Clearing the hole shovels items out over the rim — the only open side
	# is up, so the search must expand past the cell whose landing is the
	# hole itself.
	var job := colony.designate_clear(hole)
	_check(job != null, "a hole pile can be designated for clearing")
	var cleared := await _wait_until(func() -> bool:
		return colony.item_pile_at(hole) == null)
	_check(cleared, "a unit clears the pile out of a walled hole")


## Total item volume piled within [param radius] of [param centre].
func _volume_near(colony: Colony, centre: Vector3i, radius: float) -> float:
	var total := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - centre).length() <= radius:
			total += colony.item_piles[voxel].total_volume()
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


## A unit that fails a job tries a different job before retrying it — a
## recently failed job is only claimable once its retry delay has elapsed
## and nothing else is open, and each consecutive failure stretches the
## delay.
func _test_retry(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# Freeze every unit's own job search so the board can be driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
	# Clear the board: leftover pending jobs would muddy which job is claimed.
	for j in colony.jobs.duplicate():
		if j.is_active():
			colony.cancel_designation(j.voxel_position)

	var pos_a := _flat_voxel(world, mined, 56)
	var pos_b := _flat_voxel(world, mined, 72)
	_check(
		pos_a != Vector3i.MAX and pos_b != Vector3i.MAX,
		"found flat spots for the retry test"
	)
	if pos_a == Vector3i.MAX or pos_b == Vector3i.MAX:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.4), pos_a
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.4), pos_b
	)
	var job_a := colony.designate_clear(pos_a)
	var job_b := colony.designate_clear(pos_b)
	var unit: Unit = colony.units[0]

	var first := colony.claim_job(unit)
	_check(
		first == job_a or first == job_b,
		"the unit claims one of the open jobs"
	)
	colony.release_job(first)
	var second := colony.claim_job(unit)
	_check(
		second != null and second != first,
		"a unit that failed a job claims a different job before retrying it"
	)
	colony.release_job(second)
	_check(
		colony.claim_job(unit) == null,
		"recently failed jobs wait out their retry delay"
	)
	first.dropped_by[unit]["at"] -= Colony.DROPPED_JOB_RETRY_MSEC + 1
	_check(
		colony.claim_job(unit) == first,
		"an expired retry is claimable when nothing else is open"
	)
	colony.release_job(first)
	_check(
		int(first.dropped_by[unit].get("n", 0)) == 2,
		"repeated failures escalate the retry delay"
	)

	colony.cancel_designation(pos_a)
	colony.cancel_designation(pos_b)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A packed pile sitting on the only path to a job site: with a stockpile
## that has room, the unit loads the blockage and hauls it there instead of
## shovelling it into the neighbours — then finishes the job.
func _test_detour(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# A corridor walled on both sides and capped at the far end — the only
	# way to the work spot runs through the pile cell.
	var x := -1
	var gy := 0
	var z: int = mined.z + 120
	for cx in range(mined.x + 4, mined.x + 28):
		var g := world.ground_height(cx, z, mined.y + 32)
		var flat := g > -32
		for wx in range(cx - 1, cx + 7):
			if world.ground_height(wx, z, mined.y + 32) != g:
				flat = false
		for wz in [z - 1, z + 1, z + 3]:
			for wx in range(cx - 1, cx + 6):
				if (
					not world.is_solid(Vector3i(wx, g, wz))
					or world.is_solid(Vector3i(wx, g + 1, wz))
					or world.is_solid(Vector3i(wx, g + 2, wz))
				):
					flat = false
		if flat:
			x = cx
			gy = g
			break
	_check(x >= 0, "found a flat stretch for the detour test")
	if x < 0:
		return

	var level := gy + 1
	# Two blocks high — a one-block wall could be stepped over, which would
	# open a route around the pile and defeat the point of the corridor.
	for wx in range(x - 1, x + 6):
		for wy in [level, level + 1]:
			world.place(Vector3i(wx, wy, z - 1), BlockRegistry.Block.STONE)
			world.place(Vector3i(wx, wy, z + 1), BlockRegistry.Block.STONE)
	world.place(Vector3i(x + 5, level, z), BlockRegistry.Block.STONE)
	world.place(Vector3i(x + 5, level + 1, z), BlockRegistry.Block.STONE)
	var pile_v := Vector3i(x + 2, level, z)
	var target := Vector3i(x + 4, level, z)
	world.place(target, BlockRegistry.Block.STONE)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1.0), pile_v
	)
	var sp := Vector3i(x + 1, level, z + 3)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile with room exists for the detour test")
	if not sp_ok:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return

	var unit: Unit = colony.units[0]
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	unit.global_position = Vector3(x + 0.5, level + 0.9, z + 0.5)

	var job := colony.designate_mine(target)
	_check(job != null, "a detour test designation creates a job")
	if job == null:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._goal_voxel = target
	unit._fetching = false
	unit.state = Unit.State.MOVING

	var done := await _wait_until(func() -> bool:
		return world.get_block(target) == BlockRegistry.Block.AIR)
	_check(done, "the unit reaches the job site past the blocking pile")
	var sp_pile := colony.item_pile_at(sp)
	_check(
		sp_pile != null and sp_pile.total_volume() > 0.4,
		"the blocking pile is hauled to the stockpile"
	)
	var left := colony.item_pile_at(pile_v)
	_check(
		left == null or left.total_volume() < 1.0 - ItemPile.FULL_EPSILON,
		"the corridor pile no longer packs the cell"
	)

	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A clear-space designation with a stockpile that has room: the unit hauls
## the pile's contents there — a load at a time — instead of scattering
## them into the neighbours.
func _test_clear_haul(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_v := _flat_voxel(world, mined, 140)
	_check(pile_v != Vector3i.MAX, "found a flat spot for the clear-haul test")
	if pile_v == Vector3i.MAX:
		return

	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.9), pile_v
	)
	var sp := pile_v + Vector3i(3, 0, 0)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile with room exists for the clear-haul test")
	if not sp_ok:
		return

	var unit: Unit = colony.units[0]
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	unit.global_position = Vector3(pile_v + Vector3i(1, 0, 0)) + Vector3(0.5, 0.9, 0.5)

	var job := colony.designate_clear(pile_v)
	_check(job != null, "a clear-haul designation creates a job")
	if job == null:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._goal_voxel = pile_v
	unit._fetching = false
	unit.state = Unit.State.MOVING

	var emptied := await _wait_until(func() -> bool:
		return colony.item_pile_at(pile_v) == null)
	_check(emptied, "the unit clears the pile with a stockpile in reach")
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "the clear-haul job completes")
	var sp_pile := colony.item_pile_at(sp)
	_check(
		sp_pile != null and sp_pile.total_volume() > 0.8,
		"the cleared items are hauled to the stockpile"
	)

	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A unit with a job shoves an idle unit physically standing in its way —
## the idle unit sidesteps to a neighbouring voxel off the pusher's path.
func _test_yield(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var mover: Unit = colony.units[0]
	var idler: Unit = colony.units[1]

	# A flat stretch so teleported units land on their feet and the idler has
	# standable neighbours to step into.
	var sx := -1
	var sz: int = mined.z + 24
	for x in range(mined.x + 4, mined.x + 28):
		var g := world.ground_height(x, sz, mined.y + 32)
		if (
			world.ground_height(x + 1, sz, mined.y + 32) == g
			and world.ground_height(x + 2, sz, mined.y + 32) == g
			and world.ground_height(x + 3, sz, mined.y + 32) == g
			and colony.item_pile_at(Vector3i(x + 2, g + 1, sz)) == null
		):
			sx = x
			break
	_check(sx >= 0, "found a flat stretch for the yield test")
	if sx < 0:
		return

	# Release any real job before repurposing the units — abandon_job alone
	# would orphan an assigned job on the board.
	for u in [mover, idler]:
		if u.job != null:
			colony.release_job(u.job)
			u.abandon_job()

	var gy := world.ground_height(sx, sz, mined.y + 32)
	var s := Vector3i(sx + 2, gy + 1, sz)
	var start := Vector3i(sx, gy + 1, sz)
	var beyond := Vector3i(sx + 3, gy + 1, sz)
	idler.global_position = Vector3(s) + Vector3(0.5, 0.9, 0.5)
	idler.velocity = Vector3.ZERO
	# The idler must stay idle — otherwise it can wander off on a haul of its
	# own and the sidestep is never exercised.
	idler._job_search_cooldown = 60.0
	mover.global_position = Vector3(start) + Vector3(0.5, 0.9, 0.5)
	mover.velocity = Vector3.ZERO

	# A synthetic walking job whose path runs straight through the idler.
	var fake := ColonyJob.new(ColonyJob.Type.MINE, Vector3i(sx + 6, gy, sz))
	fake.state = ColonyJob.State.ASSIGNED
	fake.assignee = mover
	mover.job = fake
	mover._goal_voxel = fake.voxel_position
	mover._path = PackedVector3Array([
		Vector3(s) + Vector3(0.5, 0.0, 0.5),
		Vector3(beyond) + Vector3(0.5, 0.0, 0.5),
	])
	mover._path_index = 0
	mover.state = Unit.State.MOVING

	var saw_yield := [false]
	var moved := await _wait_until(func() -> bool:
		if idler.state == Unit.State.YIELDING:
			saw_yield[0] = true
		return idler._standing_voxel() != s)
	_check(saw_yield[0], "an idle unit yields when pushed by a unit with a job")
	_check(moved, "the pushed unit steps out of the way")
	_check(
		idler._standing_voxel() != s and idler._standing_voxel() != beyond,
		"the yield spot is off the pusher's path"
	)
	mover.abandon_job()
	idler._job_search_cooldown = 0.0


## Building a dirt block must never bury a unit: idle occupants get shoved
## out like path-blockers, and an occupant with nowhere to go fails the job.
func _test_evict(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var occupant: Unit = colony.units[1]
	if occupant.job != null:
		colony.release_job(occupant.job)
		occupant.abandon_job()
	# The occupant must stay put — no wandering off on a haul of its own.
	occupant._job_search_cooldown = 120.0

	# --- An idle unit standing in the build voxel is shoved out first.
	var target := _flat_voxel(world, mined, 32)
	_check(target != Vector3i.MAX, "found a flat spot for the evict test")
	if target == Vector3i.MAX:
		return
	occupant.global_position = Vector3(target) + Vector3(0.5, 0.9, 0.5)
	occupant.velocity = Vector3.ZERO
	# Dirt close by so delivery is quick.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.7),
		target + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.7),
		target + Vector3i(0, 0, 2)
	)
	var job := colony.designate_build(target)
	_check(job != null, "an occupied empty voxel still designates for building")
	var saw_yield := [false]
	var placed := await _wait_until(func() -> bool:
		if occupant.state == Unit.State.YIELDING:
			saw_yield[0] = true
		return world.is_solid(target))
	_check(saw_yield[0], "the builder shoves the occupant out of the voxel")
	_check(placed, "the block is built once the occupant steps out")
	_check(
		not colony.units.any(
			func(u: Unit) -> bool: return Unit._occupies_voxel(u, target)
		),
		"no unit is buried in the built block"
	)

	# --- An occupant with nowhere to step makes the build fail.
	var pit := _flat_voxel(world, mined, 40)
	_check(pit != Vector3i.MAX, "found a flat spot for the evict pit")
	if pit == Vector3i.MAX:
		return
	# Ring the target one block high, then drop the occupant's floor: it
	# lands one voxel down with its head still inside the target and every
	# sidestep blocked by the ring.
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			world.place(pit + Vector3i(dx, 0, dz), BlockRegistry.Block.STONE)
	occupant.global_position = Vector3(pit) + Vector3(0.5, 0.9, 0.5)
	occupant.velocity = Vector3.ZERO
	world.mine(pit + Vector3i.DOWN)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# Clear the mined drop so the occupant stands at the pit floor.
	for v in [pit + Vector3i.DOWN, pit]:
		var pile := colony.item_pile_at(v)
		if pile != null:
			pile.items.clear()
			colony.remove_pile_if_empty(v)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.7),
		pit + Vector3i(3, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 0.7),
		pit + Vector3i(3, 0, 2)
	)
	var pit_job := colony.designate_build(pit)
	_check(pit_job != null, "the pit voxel still designates for building")
	var gave_up := await _wait_until(func() -> bool:
		return pit_job != null and not pit_job.dropped_by.is_empty())
	_check(gave_up, "the builder abandons when the occupant can't be moved")
	_check(not world.is_solid(pit), "the unbuildable block was never placed")
	colony.cancel_designation(pit)
	occupant._job_search_cooldown = 0.0


## An empty voxel on flat ground [param z_off] rows past [param mined], or
## [constant Vector3i.MAX] if none is found.
func _flat_voxel(world: VoxelWorld, mined: Vector3i, z_off: int) -> Vector3i:
	var z: int = mined.z + z_off
	for x in range(mined.x + 4, mined.x + 28):
		var g := world.ground_height(x, z, mined.y + 32)
		if (
			world.ground_height(x + 1, z, mined.y + 32) == g
			and world.ground_height(x + 2, z, mined.y + 32) == g
			and world.ground_height(x + 3, z, mined.y + 32) == g
			and world.is_solid(Vector3i(x + 1, g, z))
		):
			return Vector3i(x + 1, g + 1, z)
	return Vector3i.MAX


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
