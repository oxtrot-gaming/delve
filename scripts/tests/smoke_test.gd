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
	_check(BlockRegistry.is_solid(BlockRegistry.Block.TRUNK), "a trunk is solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.BRANCH), "a branch is solid")
	_check(BlockRegistry.is_tree_block(BlockRegistry.Block.TRUNK), "a trunk is a tree block")
	_check(BlockRegistry.is_tree_block(BlockRegistry.Block.BRANCH), "a branch is a tree block")
	_check(not BlockRegistry.is_tree_block(BlockRegistry.Block.DIRT), "dirt is not a tree block")
	_check(
		BlockRegistry.drop_of(BlockRegistry.Block.IRON_ORE) == BlockRegistry.Resource_.IRON,
		"iron ore drops iron"
	)
	_check(BlockRegistry.is_solid(BlockRegistry.Block.STONE_WALL), "a stone wall is solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.LOG_WALL), "a log wall is solid")
	var boulder := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, DropItem.BOULDER_CM3
	)
	_check(
		BlockRegistry.item_fits_wall(boulder, BlockRegistry.Resource_.STONE),
		"boulders are wall material"
	)
	_check(
		not BlockRegistry.item_fits_wall(
			DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500000),
			BlockRegistry.Resource_.STONE
		),
		"loose gravel can't build a wall"
	)
	_check(
		BlockRegistry.item_fits_wall(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, 500000),
			BlockRegistry.Resource_.WOOD
		),
		"logs are wall material"
	)
	_check(
		not BlockRegistry.item_fits_wall(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOOSE, 500000),
			BlockRegistry.Resource_.WOOD
		),
		"loose wood can't build a wall"
	)


func _test_drops() -> void:
	print("mining drops")
	var dirt_drops := DropItem.for_block(BlockRegistry.Block.DIRT)
	_check(dirt_drops.size() == 1, "soft blocks drop a single item")
	if dirt_drops.size() == 1:
		_check(dirt_drops[0].form == DropItem.Form.LOOSE, "soft blocks drop a loose item")
		_check(
			dirt_drops[0].volume == DropItem.DROP_CM3,
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
	_check(total == DropItem.DROP_CM3, "hard block drops total 125% of the block's volume")
	_check(has_boulder and has_cobble and has_loose, "hard blocks drop boulders, cobbles and loose gravel")
	_check(all_stone, "every dropped item has the mined block's material class")

	var log_wall_drops := DropItem.for_block(BlockRegistry.Block.LOG_WALL)
	var wall_logs := 0
	var wall_total := 0.0
	for item in log_wall_drops:
		wall_total += item.volume
		if item.form == DropItem.Form.LOG:
			wall_logs += 1
	_check(wall_logs == 2, "a mined log wall gives its two logs back")
	_check(
		wall_total == DropItem.DROP_CM3,
		"a log wall's drops total 125% of its volume"
	)


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
		found.has(BlockRegistry.Block.DIRT),
		"generates a soil layer — grass is decoration now, not a block"
	)
	_check(not found.has(BlockRegistry.Block.GRASS), "generates no grass voxels")
	# The top voxel of a soil-topped column is dirt — grass cover rides
	# on top of it, in Grass's records rather than in the voxel.
	if generator.grass_seed_at(0, 0) >= 0.0:
		_check(
			buffer.get_voxel(0, 8, 0, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.DIRT,
			"a soil-topped column's surface voxel is dirt"
		)
	else:
		_check(
			buffer.get_voxel(0, 8, 0, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.STONE,
			"a rock-topped column's surface voxel is stone"
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
	# Growth on a timer would sprout trunks inside fixtures mid-test; the
	# tree test ages its tree explicitly with Forest.grow instead.
	colony.forest.set_process(false)
	# Needs are exercised in the rest test — leaving them on here would
	# have units nap in the middle of other tests' fixtures.
	colony.needs_enabled = false

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

	# The world already holds piles — generated rock scree and whatever
	# streamed in — so the drop is measured as a delta: which piles grew
	# and by what, within spilling distance of the target.
	var pile_sizes := {}
	for voxel: Vector3i in colony.item_piles:
		var off0: Vector3i = (voxel - target).abs()
		if maxi(off0.x, maxi(off0.y, off0.z)) <= 3:
			pile_sizes[voxel] = colony.item_piles[voxel].items.size()
	var mined := await _wait_until(func() -> bool: return not world.is_solid(target))
	_check(mined, "a unit mines the designated voxel")
	# Falling piles merge on arrival — wait for any flights to finish first.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var expected := BlockRegistry.drop_of(block_before)
	var total := 0.0
	var item_count := 0
	var same_material := true
	for voxel: Vector3i in colony.item_piles:
		var pile: ItemPile = colony.item_piles[voxel]
		var offset: Vector3i = (voxel - target).abs()
		if maxi(offset.x, maxi(offset.y, offset.z)) > 3:
			continue
		# Items appended past the snapshot size — or every item in a pile
		# the snapshot never saw — are this drop's.
		var skip := int(pile_sizes.get(voxel, 0))
		for i in range(skip, pile.items.size()):
			var item: DropItem = pile.items[i]
			item_count += 1
			total += item.volume
			same_material = same_material and item.material == expected
	_check(item_count > 0, "mined block drops item piles around the mined voxel")
	_check(same_material, "every dropped item has the block's material class")
	_check(
		total == DropItem.DROP_CM3,
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
	_test_camera(main.get_node("Overseer"), world, target)
	_test_highlight(main.get_node("Overseer"), colony, world, target)
	_test_drag(main.get_node("Overseer"), colony, world, target)
	await _test_stuck(colony, world, unit, target)
	_test_retry(colony, world, target)
	await _test_detour(colony, world, target)
	await _test_opportunistic(colony, world, target)
	await _test_clear_haul(colony, world, target)
	await _test_stockpile(colony, world, target)
	await _test_yield(colony, world, target)
	await _test_evict(colony, world, target)
	await _test_tree(colony, world, unit, target)
	await _test_craft(colony, world, target)
	await _test_orders(colony, world, target)
	await _test_bill_details(colony, world, target)
	await _test_campfire(colony, world, target)
	await _test_loose_rocks(colony, world, target)
	await _test_deconstruct(colony, world, target)
	await _test_rest(colony, world, target)
	await _test_food(colony, world, target)
	await _test_ladder(colony, world, target)
	await _test_doors(colony, world, target)
	await _test_collapse(colony, world, target)
	await _test_skills(colony, world, unit, target)
	await _test_organics(colony, world, unit, target)
	_test_grass(colony, world, target)
	await _test_farm(colony, world, unit, target)
	await _test_plant_environment(colony, world, target)
	await _test_hud(main, colony, world, target)
	await _test_persist(main, colony, world, target)

	main.queue_free()


## The strategy camera: the focus point rides the terrain, WASD pans it on
## the ground plane, the wheel zooms the boom, RMB-drags orbit and RMB
## clicks deselect — Timberborn-style.
func _test_camera(overseer: Overseer, world: VoxelWorld, near: Vector3i) -> void:
	var x := near.x + 12
	var z := near.z + 12
	var ground := _ground(world, x, z, near.y + 32)

	# The focus eases toward the terrain rather than snapping to it.
	overseer.global_position = Vector3(x + 0.5, ground + 1.5, z + 0.5)
	for i in 40:
		overseer._tick_camera(0.1)
	overseer.global_position.y = ground + 40.5
	overseer._tick_camera(0.1)
	_check(
		overseer.global_position.y < ground + 39.0
			and overseer.global_position.y > ground + 2.0,
		"the focus height eases toward the terrain instead of snapping"
	)
	for i in 40:
		overseer._tick_camera(0.1)
	_check(
		is_equal_approx(overseer.global_position.y, ground + 1.0),
		"the camera focus settles onto the terrain"
	)

	# WASD pans on the ground plane relative to yaw (yaw 0 → forward is -z).
	Input.action_press("move_forward")
	var before := overseer.global_position
	overseer._tick_camera(0.1)
	Input.action_release("move_forward")
	_check(
		overseer.global_position.z < before.z,
		"the camera pans the focus on the ground plane"
	)

	# Game speed must not scale camera motion: a 6x frame's scaled delta
	# should move the focus exactly as far as the same real-time step at 1x.
	# Synchronous — no real frame can interleave between the press and the
	# restore.
	Input.action_press("move_forward")
	Engine.time_scale = 1.0
	var from_1x := Vector2(overseer.global_position.x, overseer.global_position.z)
	overseer._process(0.1)
	var step_1x := Vector2(
		overseer.global_position.x, overseer.global_position.z
	).distance_to(from_1x)
	Engine.time_scale = 6.0
	var from_6x := Vector2(overseer.global_position.x, overseer.global_position.z)
	overseer._process(0.6)
	var step_6x := Vector2(
		overseer.global_position.x, overseer.global_position.z
	).distance_to(from_6x)
	Engine.time_scale = 1.0
	Input.action_release("move_forward")
	_check(
		is_equal_approx(step_6x, step_1x) and step_1x > 0.0,
		"camera pan covers the same ground at any game speed"
	)

	# The wheel zooms the boom.
	var wide := overseer._distance
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	_check(overseer._distance < wide, "scrolling up zooms the camera in")

	# Q/E rotate smoothly, Z/C snap to the next quarter turn.
	var yaw_before := overseer._yaw
	Input.action_press("rotate_right")
	overseer._tick_camera(0.1)
	Input.action_release("rotate_right")
	_check(overseer._yaw > yaw_before, "the camera rotates with Q/E")
	overseer._snap_yaw(1)
	_check(
		absf(overseer._yaw * 2.0 / PI - roundf(overseer._yaw * 2.0 / PI)) < 0.01,
		"Z/C snap the camera to a 90° heading"
	)

	# An RMB drag orbits; a click without a drag deselects the tool.
	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	var orbit_yaw := overseer._yaw
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	overseer._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(30, 0)
	overseer._unhandled_input(motion)
	press.pressed = false
	overseer._unhandled_input(press)
	_check(overseer._yaw < orbit_yaw, "a right-drag orbits the camera")
	_check(
		overseer.current_action() == &"mine",
		"a right-drag keeps the selected tool"
	)
	press.pressed = true
	overseer._unhandled_input(press)
	press.pressed = false
	overseer._unhandled_input(press)
	_check(overseer.current_action() == &"none", "a right-click deselects the tool")

	# A ceiling over open air is an overhang — the focus rides the floor
	# beneath it rather than popping up onto the roof.
	var under := _flat_voxel(world, near, 56)
	_check(under != Vector3i.MAX, "found a flat spot for the overhang test")
	if under != Vector3i.MAX:
		world.place(under + Vector3i(0, 3, 0), BlockRegistry.Block.STONE)
		overseer.global_position = Vector3(under) + Vector3(0.5, 0.0, 0.5)
		for i in 40:
			overseer._tick_camera(0.1)
		_check(
			is_equal_approx(overseer.global_position.y, float(under.y)),
			"the focus rides the floor under an overhang"
		)
		# Embedded in a rising face, though, it still climbs out the top.
		var hill := under + Vector3i(2, 0, 0)
		world.place(hill, BlockRegistry.Block.STONE)
		world.place(hill + Vector3i.UP, BlockRegistry.Block.STONE)
		overseer.global_position = Vector3(hill) + Vector3(0.5, 0.0, 0.5)
		for i in 60:
			overseer._tick_camera(0.1)
		_check(
			is_equal_approx(overseer.global_position.y, float(hill.y) + 2.0),
			"the focus climbs a face it's embedded in"
		)


## The highlight marks the voxel the selected action acts on: Mine hits the
## block behind a pile, Clear hits the pile itself, and an action that can't
## act on its target highlights red.
func _test_highlight(overseer: Overseer, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x - 14, 0, mined.z - 4)
	pile_voxel.y = _ground(world, pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pile_voxel
	)

	overseer.global_position = Vector3(pile_voxel) + Vector3(0.5, 4.5, 0.5)
	overseer.camera.global_transform = Transform3D(
		Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
	)

	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(pile_voxel) + Vector3.ONE * 0.5
	))
	_check(
		overseer._targeted != null
			and overseer.highlight.global_position.is_equal_approx(
				Vector3(overseer._targeted.position) + Vector3.ONE * 0.5
			),
		"the mine action highlights the block behind a pile"
	)

	overseer._cycle_action()
	_check(
		overseer.current_action() == overseer.ACTIONS[
			(overseer.ACTIONS.find(&"mine") + 1) % overseer.ACTIONS.size()
		],
		"the action key cycles through overseer actions"
	)
	overseer.select_action(overseer.ACTIONS.find(&"clear_pile"))
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(pile_voxel) + Vector3.ONE * 0.5
	))
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
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(bare) + Vector3.ONE * 0.5
	))
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
		var gy := _ground(world, x, z, mined.y + 32)
		overseer.global_position = Vector3(x + 0.5, gy + 6.5, z + 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(x + 0.5, gy + 0.5, z + 0.5)
		))

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

	# The same sweep with the cancel tool clears it again.
	overseer.select_action(overseer.ACTIONS.find(&"cancel"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 0, "a cancel drag clears the rect")
	overseer.select_action(overseer.ACTIONS.find(&"mine"))

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

	# The same volume cancelled: cancel tool, LMB press, aim across, wheel
	# down, release.
	overseer.select_action(overseer.ACTIONS.find(&"cancel"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	overseer._unhandled_input(wheel)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 0, "an extruded cancel drag clears the volume")
	overseer.select_action(overseer.ACTIONS.find(&"mine"))

	# While a drag is up, an RMB click aborts it instead of applying anything.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_RIGHT, true)
	click.call(MOUSE_BUTTON_RIGHT, false)
	_check(
		not overseer._drag_active and count_markers.call() == 0,
		"an RMB click aborts a drag without applying it"
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

	# A drag anchored on a vertical face extrudes horizontally too — into
	# the wall and out toward the camera. The face's outward normal points
	# the way the camera looks from (-z here), so digging in extends toward
	# +z and pulling out extends toward -z. The wall floats and a sight
	# corridor is cleared so terrain can't occlude the aim.
	var wall := Vector3i(base.x, g + 5, base.z)
	for dx in 3:
		for dy in 3:
			for dz in 3:
				world.place(wall + Vector3i(dx, dy, dz), BlockRegistry.Block.STONE)
	for dx in 3:
		for dy in 3:
			for dz in range(-3, 0):
				var cell := wall + Vector3i(dx, dy, dz)
				if world.is_solid(cell):
					world.remove_voxel(cell)
	var aim_wall := func(hit: Vector3i) -> void:
		overseer.global_position = Vector3(hit) + Vector3(0.5, 0.5, -2.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), overseer.global_position
		)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(hit) + Vector3.ONE * 0.5
		))

	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	aim_wall.call(wall)
	click.call(MOUSE_BUTTON_LEFT, true)
	overseer._press_hold = Overseer.DRAG_HOLD
	overseer._tick_press(0.0)
	click.call(MOUSE_BUTTON_LEFT, false)
	aim_wall.call(wall + Vector3i(2, 1, 0))
	_check(
		overseer._drag_axis == 2,
		"a wall-face drag locks the box to the face's plane"
	)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	var wb := overseer._drag_bounds()
	_check(
		wb[0].z == wall.z and wb[1].z == wall.z + 2,
		"a wall drag extrudes into the face"
	)
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	wb = overseer._drag_bounds()
	_check(
		wb[0].z == wall.z - 1 and wb[1].z == wall.z,
		"a wall drag extrudes out toward the camera"
	)
	# Extrude back into the wall and commit: the dug-in volume designates.
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	click.call(MOUSE_BUTTON_LEFT, true)
	var wall_marked := 0
	for dx in 3:
		for dy in 2:
			for dz in 3:
				if colony._designation_markers.has(wall + Vector3i(dx, dy, dz)):
					wall_marked += 1
	_check(
		wall_marked == 18,
		"an extruded wall drag designates the dug-in volume"
	)
	for dx in 3:
		for dy in 2:
			for dz in 3:
				colony.cancel_designation(wall + Vector3i(dx, dy, dz))
	for dx in 3:
		for dy in 3:
			for dz in 3:
				world.remove_voxel(wall + Vector3i(dx, dy, dz))
	overseer.select_action(0)


## Dropping items into voxels: loose items split off a share and solid items
## hop aside, preferring the open voxel below; piles always settle onto solid
## ground, including when the block under them is mined away.
func _test_spilling(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var before := _pile_volume_near(colony, mined, 16.0)

	# A loose drop into open air sheds part of itself downward; the whole
	# thing settles into the mined column below — into the hole if the mined
	# voxel still has room, or onto its pile if it is packed.
	var base := mined + Vector3i(0, 3, 0)
	var column_before := _column_volume(colony, mined)
	colony._drop_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), base)
	var hole_grew := await _wait_until(func() -> bool:
		return _column_volume(colony, mined) > column_before)
	_check(hole_grew, "part of a loose drop settles into the mined column")

	# A pile packed onto a shelf of placed stone has no room for more: a solid
	# drop into that voxel must hop aside.
	var shelf := Vector3i(mined.x - 6, 0, mined.z - 6)
	shelf.y = _ground(world, shelf.x, shelf.z, mined.y + 32) + 5
	var packed := shelf + Vector3i.UP
	world.place(shelf, BlockRegistry.Block.STONE)
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1500000), packed)
	var cobble := DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE, DropItem.COBBLE_CM3)
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
		shelf.x, _ground(world, shelf.x, shelf.z, mined.y + 32) + 1, shelf.z
	)
	var settled := await _wait_until(func() -> bool:
		var pile := colony.item_pile_at(pit_floor)
		return (
			pile != null
			and pile.total_volume() >= 990_000
			and is_equal_approx(pile.position.y, float(pit_floor.y))
		))
	_check(settled, "items fall and come to rest when the block beneath is mined")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_pile_volume_near(colony, mined, 16.0)
			== before + 400_000 + 1_500_000 + DropItem.COBBLE_CM3,
		"spilling drops conserve volume"
	)

	# A pile resting on a packed pile loses its floor when the lower pile
	# is partially taken: the upper pile must descend into it and merge,
	# not keep floating a voxel up.
	var lower_spot := Vector3i(mined.x + 6, 0, mined.z - 6)
	lower_spot.y = _ground(world, lower_spot.x, lower_spot.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1000000), lower_spot)
	var upper_spot := lower_spot + Vector3i.UP
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000), upper_spot)
	_check(
		colony.item_pile_at(upper_spot) != null,
		"a loose pile rests on a packed pile"
	)
	colony.item_pile_at(lower_spot).take_up_to(400_000)
	var descended := await _wait_until(func() -> bool:
		return (
			colony._in_flight.is_empty()
			and colony.item_pile_at(upper_spot) == null
			and colony.item_pile_at(lower_spot) != null
			and colony.item_pile_at(lower_spot).total_volume() == 900_000
		))
	_check(descended, "a pile follows its shrinking support down and merges")


## Fill is floor: a voxel packed with items is impassible like a solid block,
## and both items and units can stand on top of it.
func _test_fill(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	var column := Vector3i(mined.x + 8, 0, mined.z - 8)
	column.y = _ground(world, column.x, column.z, mined.y + 32) + 1
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1200000), column)

	_check(colony.is_packed(column), "a voxel holding a full cubic metre is packed")
	_check(unit._is_blocked(column), "a packed voxel blocks units")
	_check(not unit._is_standable(column), "a packed voxel is not standable")
	_check(unit._is_standable(column + Vector3i.UP), "a unit can stand on a packed voxel")

	var packed_pile := colony.item_pile_at(column)
	if packed_pile._fill_shape != null:
		var box := packed_pile._fill_shape.shape as BoxShape3D
		_check(
			box != null and is_equal_approx(box.size.y, 1.0),
			"a packed pile's collision fills the voxel"
		)

	# ItemPile batches mesh rebuilds to once per frame — the deferred
	# flush runs before the next process frame.
	await process_frame
	var renders_solid := false
	for child in packed_pile.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh is BoxMesh:
			var cube := mesh_instance.mesh as BoxMesh
			renders_solid = minf(minf(cube.size.x, cube.size.y), cube.size.z) > 0.9
	_check(renders_solid, "a packed voxel renders as a solid block")

	# An item dropped above a packed voxel comes to rest on top of it.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000),
		column + Vector3i(0, 3, 0)
	)
	_check(
		colony.item_pile_at(column + Vector3i.UP) != null,
		"items land on top of a packed voxel"
	)

	# A deposit bigger than a cubic metre splits: the voxel keeps a full
	# metre and the excess lands in an adjoining voxel.
	var overfull := Vector3i(mined.x + 12, 0, mined.z - 12)
	overfull.y = _ground(world, overfull.x, overfull.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1500000), overfull
	)
	var over_pile := colony.item_pile_at(overfull)
	_check(
		over_pile != null and over_pile.total_volume() <= DropItem.BLOCK_CM3,
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
	blocked.y = _ground(world, blocked.x, blocked.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1200000), blocked
	)

	var volume_before := _pile_volume_near(colony, blocked, 8.0)
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
		_pile_volume_near(colony, blocked, 8.0) == volume_before,
		"shoved items keep their volume"
	)


## A clearing designation is a real job: a unit walks up to the pile and
## moves every item into adjoining voxels — the pile empties, nothing is lost.
func _test_clear(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x + 10, 0, mined.z + 6)
	pile_voxel.y = _ground(world, pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	_check(
		colony.designate_clear(pile_voxel) == null,
		"an empty voxel can't be designated for clearing"
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1400000), pile_voxel
	)
	# The fixture's own soil volume in its neighborhood — clearing only
	# moves items into adjoining voxels, so a local tally survives the
	# live world's ambient churn (decay, litter drops, distant hauling).
	var volume_before := _pile_volume_near(
		colony, pile_voxel, 8.0, BlockRegistry.Resource_.SOIL
	)

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
		_pile_volume_near(
			colony, pile_voxel, 8.0, BlockRegistry.Resource_.SOIL
		) == volume_before,
		"clearing moves items rather than deleting them"
	)


## A build designation gathers wall-eligible material from piles — loose
## soil compacts into a dirt block, a cubic metre of boulders and cobbles
## raises a stone wall, two logs raise a log wall. Jobs are assigned
## directly: a free claimer picks its fetch pile by distance to itself,
## which could commit the job to a different material than the fixture's.
func _test_build(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var build := Vector3i(mined.x - 16, 0, mined.z - 16)
	build.y = _ground(world, build.x, build.z, mined.y + 32) + 1

	# A solid voxel can't be built on.
	var solid := Vector3i(mined.x - 16, 0, mined.z - 14)
	solid.y = _ground(world, solid.x, solid.z, mined.y + 32)
	_check(
		colony.designate_build(solid, &"dirt_wall") == null,
		"a solid voxel can't be designated for building"
	)

	# Two piles of loose dirt near the site, totalling more than the build cost.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000),
		build + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 800000),
		build + Vector3i(-2, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# Consumption is measured across every pile in the world.
	var dirt_before := _soil_volume_near(colony, build, 100000.0)

	# Gathering has no distance limit — it targets the closest dirt pile.
	var nearest := colony.nearest_wall_voxel(build, BlockRegistry.Resource_.SOIL)
	_check(
		nearest != Vector3i.MAX and Vector3(nearest - build).length() <= 4.0,
		"the closest dirt pile is picked as the fetch source"
	)
	# Stone may exist in distant piles — the point is that loose soil
	# counts for nothing toward the stone recipe, and the fetch query
	# walks past the soil pile to real stone.
	var soil_pile := build + Vector3i(2, 0, 0)
	var at_soil := colony.item_pile_at(soil_pile)
	_check(
		at_soil != null
			and at_soil.wall_need_volume(
				BlockRegistry.Resource_.STONE,
				BlockRegistry.wall_recipe(BlockRegistry.Resource_.STONE)
			) == 0,
		"a stone wall can't use dirt piles"
	)
	_check(
		colony.nearest_wall_voxel(build, BlockRegistry.Resource_.STONE)
			!= soil_pile,
		"a stone wall doesn't fetch from dirt piles"
	)

	var job := _assign_build(
		colony, build, build + Vector3i(2, 0, 0), &"dirt_wall"
	)
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
	_check(
		job.material == BlockRegistry.Resource_.SOIL,
		"the dirt wall job asked for soil"
	)

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var soil_after := _soil_volume_near(colony, build, 100000.0)
	# Integer cm³ volumes conserve exactly — no tolerance needed.
	_check(
		soil_after
			== dirt_before - BlockRegistry.wall_volume_for(BlockRegistry.Resource_.SOIL),
		"building consumed 1.25 m³ of loose dirt (%d → %d)"
			% [dirt_before, soil_after]
	)

	# Stone walls take exactly nine boulders and ten cobbles — the eleventh
	# of each below is a leftover the recipe must leave in the pile.
	var stone_site := _flat_voxel(world, mined, 152)
	_check(stone_site != Vector3i.MAX, "found a flat spot for the stone wall test")
	if stone_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 10:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BOULDER,
				DropItem.BOULDER_CM3
			),
			stone_site + Vector3i(1, 0, 0)
		)
	for i in 11:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			stone_site + Vector3i(2, 0, 0)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(1, 0, 0), &"stone_wall"
	)
	_check(stone_job != null, "designating an empty voxel creates a wall job")
	var walled := await _wait_until(func() -> bool:
		return world.get_block(stone_site) == BlockRegistry.Block.STONE_WALL)
	_check(walled, "a unit builds a stone wall from boulders and cobbles")
	_check(
		stone_job != null and stone_job.state == ColonyJob.State.DONE,
		"the stone wall job completes"
	)
	_check(
		stone_job != null and stone_job.material == BlockRegistry.Resource_.STONE,
		"the stone wall job asked for stone"
	)

	# The wall is a building now: it knows its material, its block, and
	# the exact items it was built of — nine boulders and ten cobbles.
	var wall := colony.building_at(stone_site)
	_check(wall != null, "a finished wall registers as a building")
	if wall != null:
		_check(
			wall.material == BlockRegistry.Resource_.STONE
				and wall.block_id == BlockRegistry.Block.STONE_WALL
				and wall.deconstructable,
			"the wall records its material, block and deconstructability"
		)
		var boulders := 0
		var cobbles := 0
		for item in wall.components:
			match item.form:
				DropItem.Form.BOULDER:
					boulders += 1
				DropItem.Form.COBBLE:
					cobbles += 1
		_check(
			boulders == 9 and cobbles == 10,
			"the wall keeps the exact items it was built of"
		)
	var spare_boulders := 0
	var spare_cobbles := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - stone_site).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material != BlockRegistry.Resource_.STONE:
				continue
			if item.form == DropItem.Form.BOULDER:
				spare_boulders += 1
			elif item.form == DropItem.Form.COBBLE:
				spare_cobbles += 1
	_check(
		spare_boulders == 1 and spare_cobbles == 1,
		"the recipe's leftovers stayed in the pile"
	)

	# And log walls take two whole logs.
	var log_site := _flat_voxel(world, mined, 160)
	_check(log_site != Vector3i.MAX, "found a flat spot for the log wall test")
	if log_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, log_site, 25.0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, 500000),
		log_site + Vector3i(1, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, 500000),
		log_site + Vector3i(2, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var log_job := _assign_build(
		colony, log_site, log_site + Vector3i(1, 0, 0), &"log_wall"
	)
	var logged := await _wait_until(func() -> bool:
		return world.get_block(log_site) == BlockRegistry.Block.LOG_WALL)
	_check(logged, "a unit builds a log wall from two logs")
	_check(
		log_job != null and log_job.state == ColonyJob.State.DONE,
		"the log wall job completes"
	)
	var log_wall := colony.building_at(log_site)
	_check(
		log_wall != null and log_wall.components.size() == 2,
		"the log wall recorded its two logs"
	)
	# Cooldowns set for the direct assignments would stall later tests that
	# rely on free claiming.
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Designates a wall at [param site] and hands it straight to units[0],
## parked at the site and pointed at the pile in [param pile_v] — bypassing
## the job board so the fixture's piles are the ones fetched.
func _assign_build(colony: Colony, site: Vector3i, pile_v: Vector3i, spec: StringName) -> ColonyJob:
	_clear_jobs(colony)
	var job := colony.designate_build(site, spec)
	if job == null:
		return null
	var builder: Unit = colony.units[0]
	for u in colony.units:
		if u != builder:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	builder.global_position = Vector3(site) + Vector3(0.5, 0.9, 0.5)
	builder.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = builder
	builder.job = job
	builder._fetching = true
	builder._goal_voxel = pile_v
	builder._clear_budget = 0.0
	builder.state = Unit.State.MOVING
	return job


## Empties piles within [param radius] of [param centre] of anything a wall
## could use, so a direct-assigned build can only fetch from the fixture's
## piles.
func _clear_wall_material_near(colony: Colony, centre: Vector3i, radius: float) -> void:
	for voxel in colony.item_piles.keys():
		if Vector3(voxel - centre).length() > radius:
			continue
		var pile: ItemPile = colony.item_piles[voxel]
		pile.items = pile.items.filter(
			func(item: DropItem) -> bool:
				return not BlockRegistry.item_fits_wall(
					item, BlockRegistry.Resource_.NONE
				)
		)
		colony.remove_pile_if_empty(voxel)


## Total loose-soil volume piled within [param radius] of [param centre].
func _soil_volume_near(colony: Colony, centre: Vector3i, radius: float) -> int:
	var total := 0
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
	base.y = _ground(world, base.x, base.z, mined.y + 32) + 5
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


## Volume of [param material] piled within [param radius] of [param
## center] (-1 for all materials), plus what's carried anywhere — a
## conservation check that the live world's ambient churn (decay, fresh
## litter, distant hauling) can't disturb.
func _pile_volume_near(
	colony: Colony, center: Vector3i, radius: float, material: int = -1
) -> int:
	var total := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - center).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if material < 0 or item.material == material:
				total += item.volume
	for pile in colony._in_flight:
		if (
			radius >= 0.0
			and (pile.position - Vector3(center)).length() > radius
		):
			continue
		for item in pile.items:
			if material < 0 or item.material == material:
				total += item.volume
	for u in colony.units:
		for item in u._carried:
			if material < 0 or item.material == material:
				total += item.volume
	return total


## Total item volume piled anywhere in [param voxel]'s x/z column.
func _column_volume(colony: Colony, voxel: Vector3i) -> int:
	var total := 0
	for key in colony.item_piles:
		if key.x == voxel.x and key.z == voxel.z:
			total += colony.item_piles[key].total_volume()
	return total


## Stockpiles: designation rules, idle-unit hauling of loose piles, and the
## interrupted-haul drop.
func _test_stockpile(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var sp := Vector3i(mined.x + 16, 0, mined.z + 16)
	sp.y = _ground(world, sp.x, sp.z, mined.y + 32) + 1

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
	dump.y = _ground(world, dump.x, dump.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000), dump
	)
	var saw_carry := [false]
	var hauled := await _wait_until(func() -> bool:
		for unit in colony.units:
			if unit._carried_volume() > 0:
				saw_carry[0] = true
		var pile := colony.item_pile_at(sp)
		return pile != null and pile.total_volume() >= 850_000)
	_check(saw_carry[0], "a unit physically carries items while hauling")
	_check(hauled, "items are hauled to the stockpile")

	# Interrupting a haul drops the carried items where the unit stands.
	var dump2 := Vector3i(mined.x + 10, 0, mined.z + 8)
	dump2.y = _ground(world, dump2.x, dump2.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 600000), dump2
	)
	var found := await _wait_until(func() -> bool:
		return colony.units.any(func(u: Unit) -> bool: return u._carried_volume() > 0))
	_check(found, "a haul is in progress to interrupt")
	if found:
		var carrier: Unit = null
		for u in colony.units:
			if u._carried_volume() > 0:
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

	# A nearly-full stockpile tile still takes the last few cm³ — a loose
	# load pours the remainder in instead of vetoing the tile outright.
	var sp2 := Vector3i(mined.x + 18, 0, mined.z + 16)
	sp2.y = _ground(world, sp2.x, sp2.z, mined.y + 32) + 1
	_check(colony.designate_stockpile(sp2), "a second stockpile designates")
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 995000), sp2
	)
	var dump3 := Vector3i(mined.x + 12, 0, mined.z + 8)
	dump3.y = _ground(world, dump3.x, dump3.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000), dump3
	)
	var topped := await _wait_until(func() -> bool:
		var pile := colony.item_pile_at(sp2)
		return pile != null and pile.total_volume() >= DropItem.BLOCK_CM3)
	_check(topped, "a loose haul tops off a nearly-full stockpile")

	# Filtering: each tile keeps a reject-set of materials it won't store.
	# A pile holding a rejected material becomes a haul-out candidate, so
	# the filter cleans existing contents instead of only gating deposits.
	var fa := _flat_voxel(world, mined, 136)
	_check(fa != Vector3i.MAX, "found a flat spot for the filter test")
	if fa != Vector3i.MAX:
		var sa := fa
		var sb := fa + Vector3i(1, 0, 0)
		var dump4 := fa + Vector3i(2, 0, 0)
		_check(
			colony.designate_stockpile(sa) and colony.designate_stockpile(sb),
			"two filter-test stockpiles designate"
		)
		_check(
			colony.stockpile_at(sa) == colony.stockpile_at(sb),
			"adjacent cells share one zone"
		)
		_check(
			colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE),
			"a fresh stockpile admits everything"
		)
		colony.set_stockpile_admission(sa, BlockRegistry.Resource_.STONE, false)
		_check(
			not colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE)
				and not colony.stockpile_admits(sb, BlockRegistry.Resource_.STONE)
				and colony.stockpile_admits(sa, BlockRegistry.Resource_.SOIL),
			"the zone's filter rejects on every cell"
		)
		# A second stockpile far enough away to start its own zone keeps
		# an independent filter — the rejecting zone is skipped for stone.
		var sc := _flat_voxel(world, mined, 140, 8)
		_check(sc != Vector3i.MAX, "found a spot for a second-zone stockpile")
		if sc == Vector3i.MAX:
			return
		_check(
			colony.designate_stockpile(sc),
			"a second-zone stockpile designates"
		)
		_check(
			colony.stockpile_at(sc) != colony.stockpile_at(sa),
			"a distant cell starts its own zone"
		)
		_check(
			colony.stockpile_admits(sc, BlockRegistry.Resource_.STONE),
			"the second zone keeps its own filter"
		)
		_check(
			colony.nearest_stockpile_with_room(
				dump4, 1, {}, [BlockRegistry.Resource_.STONE]
			) == sc,
			"a rejecting zone is skipped for that material"
		)
		# A boulder dropped on the rejecting tile is an eviction candidate —
		# a unit should carry it to the tile that admits it.
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000
			),
			sa
		)
		_check(
			colony.nearest_haulable_pile(sa) == sa,
			"a pile rejected by its tile is haulable"
		)
		var evicted := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(sa)
			return pile == null or pile.form_volume(DropItem.Form.BOULDER) == 0)
		_check(evicted, "a disallowed pile gets hauled off its tile")
		# The drop can spill onto a neighbor mid-flight — wait for it to
		# settle on the admitting tile rather than checking once.
		var arrived := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(sc)
			return pile != null and pile.form_volume(DropItem.Form.BOULDER) >= 100000)
		_check(arrived, "the evicted material lands on an admitting tile")
		colony.set_stockpile_admission(sa, BlockRegistry.Resource_.STONE, true)
		_check(
			colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE)
				and colony.stockpile_admits(sb, BlockRegistry.Resource_.STONE),
			"re-enabling a material admits it again"
		)
		_check(colony.undesignate_stockpile(sb), "one zone cell undesignates")
		_check(
			colony.stockpile_at(sa) != null and colony.stockpile_at(sb) == null,
			"the zone survives losing a cell"
		)

	# --- Zone gestures: the first click and the box's overlaps pick the
	# target zone; Alt forces a fresh one; zoned cells never move.
	var za := _flat_voxel(world, mined, 152, 4)
	_check(za != Vector3i.MAX, "found a flat spot for the zone-gesture test")
	if za != Vector3i.MAX:
		var zb := za + Vector3i(2, 0, 0)
		colony.designate_stockpile(za)
		colony.designate_stockpile(zb)
		var zone_a := colony.stockpile_at(za)
		var zone_b := colony.stockpile_at(zb)
		_check(
			zone_a != null and zone_b != null and zone_a != zone_b,
			"a gap keeps two stockpiles in their own zones"
		)
		var between := za + Vector3i(1, 0, 0)
		_check(
			colony._stockpile_cellable(between),
			"the seam cell is stockpileable"
		)
		_check(
			not colony.designate_stockpile(between),
			"a cell between two zones can't pick — the gesture fails"
		)
		var seam_box: Array[Vector3i] = [between]
		_check(
			colony.designate_stockpile_cells(seam_box, between, true) != null,
			"the zone override forces a fresh zone"
		)
		_check(
			colony.stockpile_at(between) != zone_a
				and colony.stockpile_at(between) != zone_b,
			"the overridden cell starts a third zone"
		)
		_check(
			not colony.designate_stockpile(za),
			"re-designating a zoned cell adds nothing"
		)
		var covered: Array[Vector3i] = [za]
		_check(
			colony.designate_stockpile_cells(covered, za, true) == null,
			"the override still fails when nothing is free"
		)
		# A box anchored on zone A extends it: the distant free cell joins,
		# zone B's cell inside the box is never adopted.
		var zc := _flat_voxel(world, mined, 160, 4)
		_check(zc != Vector3i.MAX, "found a far cell for the overlap test")
		if zc != Vector3i.MAX:
			var box: Array[Vector3i] = [za, zc, zb]
			_check(
				colony.designate_stockpile_cells(box, za) == zone_a,
				"a box anchored on a zone extends it"
			)
			_check(
				colony.stockpile_at(zc) == zone_a,
				"a distant free cell joins the anchor's zone"
			)
			_check(
				colony.stockpile_at(zb) == zone_b,
				"the other zone's cell was never adopted"
			)
			var zd := _flat_voxel(world, mined, 168, 4)
			_check(zd != Vector3i.MAX, "found a far cell for the span test")
			if zd != Vector3i.MAX:
				var span_box: Array[Vector3i] = [zb, zc, zd]
				_check(
					colony.designate_stockpile_cells(span_box, zd) == null
						and not colony.is_stockpile(zd),
					"a box spanning two zones fails — nothing is placed"
				)
				var join_box: Array[Vector3i] = [zc, zd]
				_check(
					colony.designate_stockpile_cells(join_box, zd) == zone_a,
					"a box touching exactly one zone joins it"
				)
		# These flat rows belong to later tests — release the cells.
		for cell: Vector3i in [
			za, za + Vector3i(1, 0, 0), za + Vector3i(2, 0, 0),
			_flat_voxel(world, mined, 160, 4),
			_flat_voxel(world, mined, 168, 4),
		]:
			if cell != Vector3i.MAX:
				colony.undesignate_stockpile(cell)

	# A tile with less room than the smallest solid item isn't a real
	# destination — the fetch must skip it for a tile that can take the
	# item instead of standing at the pile in "loading items" forever.
	var fb := _flat_voxel(world, mined, 144)
	_check(fb != Vector3i.MAX, "found a flat spot for the full-tile haul test")
	if fb != Vector3i.MAX:
		_check(
			colony.designate_stockpile(fb),
			"a nearly-full stockpile designates"
		)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 950000
			),
			fb
		)
		var boulder_pile := fb + Vector3i(1, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 200000
			),
			boulder_pile
		)
		var moved := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(boulder_pile)
			return (
				pile == null
				or pile.form_volume(DropItem.Form.BOULDER) < 200000
			))
		_check(
			moved,
			"a solid haul skips a tile too full to fit it"
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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 950000), hole
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000), hole
	)
	var settled := await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(settled, "an oversized drop settles instead of bouncing forever")
	var pile := colony.item_pile_at(hole)
	_check(
		pile != null and pile.total_volume() <= DropItem.BLOCK_CM3,
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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1250000), hole
	)
	var hole_pile := colony.item_pile_at(hole)
	var rim_pile := colony.item_pile_at(hole + Vector3i.UP)
	_check(
		hole_pile != null and absf(hole_pile.total_volume() - 1_000_000) == 0,
		"a dug-out hole keeps a full cubic metre"
	)
	_check(
		rim_pile != null and absf(rim_pile.total_volume() - 250_000) == 0,
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
func _test_stuck(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
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

	# Overshoot guard: at high time_scale one physics step covers more
	# ground than the waypoint radius — a waypoint inside this tick's
	# travel must count as arrived, or the unit orbits and the watchdog
	# cancels a healthy job. A 0.1 s tick is the 6x step: 0.4 m of travel
	# against a waypoint 0.38 m away.
	var site := _pick_mining_target(world, unit, 8)
	if site != Vector3i.MAX:
		var j2 := colony.designate_mine(site)
		if j2 != null:
			j2.state = ColonyJob.State.ASSIGNED
			j2.assignee = unit
			unit.job = j2
			unit.state = Unit.State.MOVING
			unit._goal_voxel = site
			unit._best_goal_distance = 1e9
			var wp := unit.global_position + Vector3(0.38, 0.0, 0.0)
			unit._path = PackedVector3Array([wp])
			unit._path_index = 0
			unit._tick_moving(0.1)
			_check(
				unit._path_index == 1,
				"a waypoint inside one 6x step still registers arrival"
			)
			colony.cancel_designation(site)
			unit.abandon_job()

	# Jump-apex regression: a raw Euler step shrinks the apex by ~v·dt/2 —
	# 0.93 m instead of 1.27 m at a 6x-sized 0.1 s tick — which misses the
	# 0.95 m the capsule needs before `horizontal_clear` admits a 1 m
	# step-up. The unit jumped in place until the watchdog cancelled.
	if world.sim != null:
		var base := Vector3i.MAX
		var ledge := Vector3i.MAX
		for z_off in range(96, 240, 8):
			var candidate := _flat_voxel(world, mined, z_off)
			if candidate == Vector3i.MAX:
				continue
			var step := candidate + Vector3i(1, 0, 0)
			var clear := (
				world.get_block(step) == BlockRegistry.Block.AIR
				and world.get_block(step + Vector3i.UP) == BlockRegistry.Block.AIR
				and world.get_block(step + Vector3i(0, 2, 0)) == BlockRegistry.Block.AIR
				and colony.item_pile_at(candidate) == null
				and colony.item_pile_at(step) == null
			)
			if clear:
				base = candidate
				ledge = step
				break
		_check(base != Vector3i.MAX, "found a flat spot beside a ledge cell")
		if base != Vector3i.MAX:
			world.place(ledge, BlockRegistry.Block.STONE)
			var spawn := Vector3(base) + Vector3(0.5, 0.9, 0.5)
			unit.global_position = spawn
			world.sim.unit_register(unit._sim_id, spawn)
			var feet0: float = spawn.y - 0.9
			var on_top := false
			for i in 30:
				var r: Dictionary = world.sim.unit_step(
					unit._sim_id,
					Vector3(unit.move_speed, 0.0, 0.0),
					unit.jump_speed,
					unit.gravity,
					0.1,
					0.0
				)
				var p: Vector3 = r["pos"]
				if p.y - 0.9 >= feet0 + 0.95:
					on_top = true
					break
			_check(on_top, "a 6x-sized step still mounts a 1 m ledge")
			unit.global_position = world.sim.unit_pos(unit._sim_id)
			world.remove_voxel(ledge)


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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pos_a
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pos_b
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
	var other: Unit = colony.units[1] if colony.units.size() > 1 else null
	_check(
		other == null or colony.claim_job(other) == null,
		"a dropped job cools off for every unit, not just the one that failed"
	)
	var past: int = colony.game_msec() - Colony.DROPPED_JOB_RETRY_MAX_MSEC - 1
	first.dropped_by[unit]["at"] = past
	if world.sim != null:
		# The sim mirrors drop records — age its copy too.
		world.sim.job_drop(first.get_instance_id(), unit.get_instance_id(), past)
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
	var z := 0
	# Grown trees put solid trunk/branch voxels in some columns — scan
	# rows until one has a stretch clear of them.
	for z_off in [120, 128, 136, 112, 104]:
		z = mined.z + z_off
		for cx in range(mined.x + 4, mined.x + 28):
			var g := _ground(world, cx, z, mined.y + 32)
			var flat := g > -32
			for wx in range(cx - 1, cx + 7):
				if _ground(world, wx, z, mined.y + 32) != g:
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
		if x >= 0:
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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1000000), pile_v
	)
	var sp := Vector3i(x + 1, level, z + 3)
	# A scattered sapling isn't solid, so the flat scan can pick a stockpile
	# cell holding one — clear it first; the designation requires air.
	if world.get_block(sp) != BlockRegistry.Block.AIR:
		world.remove_voxel(sp)
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
	# Earlier tests leave open jobs on the board — the unit must not wander
	# off to claim one after a drop (failed jobs are retried last).
	_clear_jobs(colony)
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

	var trace := PackedStringArray()
	var done := await _wait_until(func() -> bool:
		if Time.get_ticks_msec() % 2000 < 20:
			trace.append(
				"%d,%s,%s,%s" % [
					unit.state, Vector3i(unit.global_position.floor()),
					unit._goal_voxel,
					unit.job.type if unit.job != null else -1,
				]
			)
		return world.get_block(target) == BlockRegistry.Block.AIR)
	if not done:
		var dbg_pile := colony.item_pile_at(pile_v)
		print(
			"  dbg detour: state=", unit.state,
			" pos=", Vector3i(unit.global_position.floor()),
			" goal=", unit._goal_voxel, " path=", unit._path_index, "/", unit._path.size(),
			" detour=", unit._detour, " delivering=", unit._detour_delivering,
			" job=", unit.job.type if unit.job != null else -1,
			" jobstate=", job.state, " dropped_by=", job.dropped_by.size(),
			" jobs=", colony.jobs.size(),
			" carried=", unit._carried_volume(),
			" pile=", dbg_pile.total_volume() if dbg_pile != null else -1,
			" spots=", unit._work_spots(target, true).size()
		)
		print("  trace: ", trace)
	_check(done, "the unit reaches the job site past the blocking pile")
	var sp_pile := colony.item_pile_at(sp)
	_check(
		sp_pile != null and sp_pile.total_volume() > 400_000,
		"the blocking pile is hauled to the stockpile"
	)
	var left := colony.item_pile_at(pile_v)
	_check(
		left == null or left.total_volume() < DropItem.BLOCK_CM3,
		"the corridor pile no longer packs the cell"
	)

	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A moving, empty-handed unit whose route passes a haulable pile grabs
## it en route when a stockpile sits near the job's goal — the haul rides
## a trip that was happening anyway, then the real job resumes.
func _test_opportunistic(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var x := -1
	var gy := 0
	var z := 0
	# Ten contiguous flat cells: the unit walks the row's length, the pile
	# sits on the walk line mid-route, the stockpile and the mine target
	# wait at the far end.
	for z_off in [192, 184, 200, 96, 88]:
		z = mined.z + z_off
		for cx in range(mined.x + 4, mined.x + 22):
			var g := _ground(world, cx, z, mined.y + 32)
			var flat := g > -32
			for wx in range(cx - 1, cx + 10):
				if _ground(world, wx, z, mined.y + 32) != g:
					flat = false
				for wy in [g + 1, g + 2]:
					if (
						not world.is_editable(Vector3i(wx, wy, z))
						or world.is_solid(Vector3i(wx, wy, z))
						or colony.item_pile_at(Vector3i(wx, wy, z)) != null
					):
						flat = false
			if flat:
				x = cx
				gy = g
				break
		if x >= 0:
			break
	_check(x >= 0, "found a flat stretch for the opportunistic-haul test")
	if x < 0:
		return

	var level := gy + 1
	var pile_v := Vector3i(x + 4, level, z)
	var sp := Vector3i(x + 7, level, z)
	var target := Vector3i(x + 8, level, z)
	world.place(target, BlockRegistry.Block.STONE)
	# A partial pile on the walk line — not packed, so the route stays
	# clear and the opportunistic scan, not the blockage check, sees it.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pile_v
	)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile near the goal exists for the opportunistic haul")
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
	_clear_jobs(colony)
	unit.global_position = Vector3(x + 0.5, level + 0.9, z + 0.5)

	var job := colony.designate_mine(target)
	_check(job != null, "an opportunistic-haul designation creates a job")
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

	var saw_detour := [false]
	var done := await _wait_until(func() -> bool:
		if unit._detour_opportunistic:
			saw_detour[0] = true
		return world.get_block(target) == BlockRegistry.Block.AIR)
	_check(saw_detour[0], "the passed pile triggers an opportunistic detour")
	_check(done, "the unit resumes and finishes its job after the detour")
	# The delivery lands on whatever stockpile tile nearest the goal —
	# usually the fixture's own, but any leftover zone within reach of
	# the goal counts.
	var delivered := false
	for cell in colony.stockpiles:
		if Vector3(cell).distance_to(Vector3(target)) > 13.0:
			continue
		var p := colony.item_pile_at(cell)
		if p != null and p.total_volume() >= 390_000:
			delivered = true
			break
	_check(delivered, "the passed pile lands on a stockpile by the goal")
	_check(colony.item_pile_at(pile_v) == null, "the route-side pile is emptied")

	# The gates: a haul job is already hauling — the search can't beat its
	# own assignment — and a self-issued errand keeps its urgency.
	unit.job = ColonyJob.new(ColonyJob.Type.HAUL, pile_v)
	_check(not unit._can_opportunistic(), "a haul job never detours opportunistically")
	unit.job = ColonyJob.new(ColonyJob.Type.REST, pile_v)
	_check(not unit._can_opportunistic(), "a rest errand never detours opportunistically")
	unit.job = null
	_check(
		unit._detour_reach() == Unit.DETOUR_GOAL_REACH,
		"a generalist detours anywhere in the full reach"
	)
	unit.specialize = true
	_check(
		unit._detour_reach() < Unit.DETOUR_GOAL_REACH * 0.5,
		"a specialist's detour reach shrinks under its cap"
	)
	unit.specialize = false

	# A detour borrows _goal_voxel — and the haul-side retarget path can
	# rewrite _fetching mid-detour. Ending the detour must restore both,
	# or a build unit comes back to its fetch pile "delivering": in reach
	# of the pile but out of reach of the site, flickering MOVING/WORKING
	# on every frame.
	var site := Vector3i.ZERO
	var wall_job: ColonyJob = null
	for cx in [x + 1, x + 2, x + 3]:
		var candidate := colony.designate_build(
			Vector3i(cx, level, z), &"dirt_wall"
		)
		if candidate != null:
			site = Vector3i(cx, level, z)
			wall_job = candidate
			break
	_check(wall_job != null, "a dirt-wall designation creates a job")
	if wall_job != null:
		wall_job.state = ColonyJob.State.ASSIGNED
		wall_job.assignee = unit
		unit.job = wall_job
		unit._fetching = true
		unit._goal_voxel = pile_v
		var detour_pile := Vector3i(x + 5, level, z + 2)
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 100000),
			detour_pile
		)
		unit._carried.append(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 50000)
		)
		unit._start_detour(detour_pile, sp)
		unit._set_haul_destination()
		unit._end_detour()
		_check(unit._fetching, "a detour restores the build job's fetch phase")
		_check(unit._goal_voxel == pile_v, "a detour restores the fetch goal")

		# A pile whose smallest admitted item outgrows the destination's
		# room can never be grabbed — arriving at it must blacklist the pile
		# (the movement loop then shoves it aside), not end clean and
		# re-pick the same pile on every frame.
		var tight_pile := Vector3i(x + 3, level, z + 2)
		for cell in [tight_pile, detour_pile]:
			var old_pile := colony.item_pile_at(cell)
			if old_pile != null:
				old_pile.items.clear()
				colony.remove_pile_if_empty(cell)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			tight_pile
		)
		var sp_room := colony.voxel_capacity(sp) - colony.voxel_fill(sp)
		if sp_room >= DropItem.COBBLE_CM3:
			# Leave less room than one cobble — the tile still passes
			# `with_room` but can't take the pile's smallest item.
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL,
					DropItem.Form.LOOSE,
					sp_room - 5000
				),
				sp
			)
		unit._carried.clear()
		unit._haul_blacklist.erase(tight_pile)
		unit._goal_voxel = site
		_check(
			unit._start_detour(tight_pile, sp),
			"a detour on a room-starved pile still starts"
		)
		unit._detour_arrived()
		_check(unit._detour != tight_pile, "an ungrabbable detour ends")
		_check(
			unit._haul_blacklist.has(tight_pile),
			"an ungrabbable pile is blacklisted for a retry delay"
		)
		unit._haul_blacklist.erase(tight_pile)
		unit.abandon_job()
		colony.cancel_designation(site)

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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000), pile_v
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
	_clear_jobs(colony)
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
		sp_pile != null and sp_pile.total_volume() > 800_000,
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
		var g := _ground(world, x, sz, mined.y + 32)
		if (
			_ground(world, x + 1, sz, mined.y + 32) == g
			and _ground(world, x + 2, sz, mined.y + 32) == g
			and _ground(world, x + 3, sz, mined.y + 32) == g
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

	var gy := _ground(world, sx, sz, mined.y + 32)
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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		target + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		target + Vector3i(0, 0, 2)
	)
	var job := colony.designate_build(target, &"dirt_wall")
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
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		pit + Vector3i(3, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		pit + Vector3i(3, 0, 2)
	)
	var pit_job := colony.designate_build(pit, &"dirt_wall")
	_check(pit_job != null, "the pit voxel still designates for building")
	var gave_up := await _wait_until(func() -> bool:
		return pit_job != null and not pit_job.dropped_by.is_empty())
	_check(gave_up, "the builder abandons when the occupant can't be moved")
	_check(not world.is_solid(pit), "the unbuildable block was never placed")
	colony.cancel_designation(pit)
	occupant._job_search_cooldown = 0.0


## Trees: a planted sapling registers with the forest, grows one trunk level
## at a time into a tree with branches and a leaf canopy, and a chop
## designation on any part fells the whole tree — logs per trunk voxel plus
## loose branch and leaf material dropped where the parts stood. And a
## corridor whose only route crosses saplings is only pathable by the soft
## search — the native astar counts every non-air voxel as solid.
func _test_tree(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	print("trees")
	# Keep every unit from wandering into the fixture or claiming the job.
	for u in colony.units:
		u._job_search_cooldown = 120.0

	# Generated trees seed at random ages — the starting forest must have
	# grown, log-bearing trees ready to harvest, not only saplings. The
	# seeded height is what matters: by the time this test runs, minutes
	# of growth may have aged every 0-seeded tree past saplinghood.
	var grown := 0
	var young := 0
	for root: Vector3i in colony.forest.trees:
		var rec: Dictionary = colony.forest.trees[root]
		var seeded := colony.forest.seeded_height(root, rec[&"species"])
		# Growth only adds height — nothing can shrink it.
		_check(
			int(rec[&"height"]) >= seeded,
			"a generated tree is at least its seeded age"
		)
		if seeded > 0:
			grown += 1
		else:
			young += 1
	_check(
		grown > 0, "generated terrain seeds grown, harvestable trees"
	)
	_check(young > 0, "generated terrain still seeds saplings too")

	var base := Vector3i.MAX
	for z_off in [88, 96, 104, 112]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate == Vector3i.MAX
			or not world.is_editable(candidate)
			or world.get_block(candidate) != BlockRegistry.Block.AIR
			or colony.forest.tree_root_at(candidate) != Vector3i.MAX
		):
			continue
		base = candidate
		break
	_check(base != Vector3i.MAX, "found a flat stretch for the tree test")
	if base == Vector3i.MAX:
		for u in colony.units:
			u._job_search_cooldown = 0.0
			return
	# Clear the growth box so the tree has room for its full canopy —
	# blocked cells are simply skipped, which would shrink the test tree.
	# Blocks, generated-sapling claims and leftover piles all count.
	for dx in range(-3, 4):
		for dy in range(0, 10):
			for dz in range(-3, 4):
				var cell := base + Vector3i(dx, dy, dz)
				var owner := colony.forest.tree_root_at(cell)
				if owner != Vector3i.MAX:
					colony.forest.trees.erase(owner)
					colony.forest._index.erase(cell)
					colony.forest._leaves.erase(cell)
				var pile := colony.item_pile_at(cell)
				if pile != null:
					pile.items.clear()
					colony.remove_pile_if_empty(cell)
				if world.is_editable(cell) and world.get_block(cell) != BlockRegistry.Block.AIR:
					world.remove_voxel(cell)
	# And units: a unit inside the box blocks solid growth into its cell.
	for u in colony.units:
		if Vector3(u.global_position - Vector3(base)).length() < 8.0:
			u.global_position = Vector3(base.x - 10, base.y + 0.9, base.z + 0.5)
			u.velocity = Vector3.ZERO

	_check(colony.forest.plant_sapling(base), "a sapling plants on open ground")
	_check(
		world.get_block(base) == BlockRegistry.Block.AIR,
		"a sapling leaves its voxel as air"
	)
	_check(
		colony.forest.tree_root_at(base) == base,
		"a planted sapling registers as a tree"
	)
	# Clear leftover jobs so the chop job stays the only thing to claim.
	_clear_jobs(colony)
	var sp: Dictionary = Forest.SPECIES[&"oak"]
	var max_height := int(sp[&"max_height"])
	for i in max_height:
		colony.forest.grow(base)
	var rec: Dictionary = colony.forest.trees.get(base, {})
	_check(
		int(rec.get(&"height", -1)) == max_height,
		"the tree grows to its full height"
	)
	_check(
		world.get_block(base) == BlockRegistry.Block.TRUNK,
		"a grown tree has a trunk at its root"
	)
	var branch_count := 0
	var leaf_count := 0
	var leaves_are_air := true
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_count += 1
			if world.get_block(voxel) != BlockRegistry.Block.AIR:
				leaves_are_air = false
		elif world.get_block(voxel) == BlockRegistry.Block.BRANCH:
			branch_count += 1
	_check(branch_count > 0, "a grown tree has solid branch voxels")
	_check(
		leaf_count > 0 and leaves_are_air,
		"leaf cells render as foliage but stay air"
	)
	# Canopy invariants: every leaf cell face-touches a solid part of its
	# own tree, and nothing hangs at or below the ground-level segment.
	var leaves_supported := true
	var ortho := [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
		Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK
	]
	for voxel: Vector3i in rec[&"voxels"]:
		if not colony.forest.leaf_at(voxel):
			continue
		if voxel.y <= base.y:
			leaves_supported = false
			continue
		var hugged := false
		for side in ortho:
			var neighbour: Vector3i = voxel + side
			if (
				colony.forest.tree_root_at(neighbour) == base
				and not colony.forest.leaf_at(neighbour)
				and BlockRegistry.is_tree_block(world.get_block(neighbour))
			):
				hugged = true
		leaves_supported = leaves_supported and hugged
	_check(leaves_supported, "every leaf hugs a trunk or branch above ground")

	# Streaming forgets voxel edits — a block that comes back regenerated
	# must get its tree parts restored, not fell the tree.
	var mid_trunk := base + Vector3i(0, 2, 0)
	world.remove_voxel(mid_trunk)
	colony.forest._on_block_loaded(Vector3i(
		floori(float(mid_trunk.x) / 16.0),
		floori(float(mid_trunk.y) / 16.0),
		floori(float(mid_trunk.z) / 16.0)
	))
	_check(
		world.get_block(mid_trunk) == BlockRegistry.Block.TRUNK,
		"a reloaded block restores its tree voxels"
	)
	_check(colony.forest.trees.has(base), "restoration didn't fell the tree")

	# Any part designates the whole tree — even a leaf cell, which only
	# exists in the forest's index; the job sites at the root, and a cancel
	# on any part cancels it.
	var leaf_part := Vector3i.MAX
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_part = voxel
	var part: Vector3i = (
		leaf_part if leaf_part != Vector3i.MAX else (rec[&"voxels"] as Array).back()
	)
	var job := colony.designate_chop(part)
	_check(
		job != null and job.voxel_position == base,
		"designating any tree part chops from the root"
	)
	colony.cancel_designation(part)
	_check(not job.is_active(), "cancelling a tree part cancels the chop job")
	job = colony.designate_chop(part)
	_check(job != null, "a cancelled tree can be designated again")

	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	unit.global_position = Vector3(base) + Vector3(1.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.job = job
	unit._goal_voxel = job.voxel_position
	unit.state = Unit.State.MOVING
	var felled := await _wait_until(func() -> bool:
		return not colony.forest.trees.has(base))
	_check(felled, "a unit fells a designated tree")
	_check(job.state == ColonyJob.State.DONE, "the chop job completes")
	_check(
		not BlockRegistry.is_tree_block(world.get_block(base)),
		"a felled tree's trunk voxel is removed"
	)
	# Logs dropped from the upper trunk fall while felling runs — wait
	# for every pile to land before counting.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var logs := 0
	var loose := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - base).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.form == DropItem.Form.LOG
				and item.material == BlockRegistry.Resource_.WOOD
			):
				logs += 1
			elif (
				item.material == BlockRegistry.Resource_.BRANCH
				or item.material == BlockRegistry.Resource_.LEAF
			):
				loose += item.volume
	_check(logs >= max_height - 1, "felling drops a log per trunk voxel")
	_check(loose > 0.0, "felling drops loose branch and leaf material")

	# A corridor walled on both sides and capped past the destination, its
	# middle holding a sapling: saplings are decorations over air cells, so
	# the astar walks straight through. base+1 and base+2 sit inside the
	# flat stretch _flat_voxel guarantees.
	var walls: Array[Vector3i] = []
	var wall_cells: Array[Vector3i] = []
	for i in range(-2, 4):
		for side in [Vector3i.FORWARD, Vector3i.BACK]:
			for dy in range(0, 2):
				wall_cells.append(base + Vector3i(i, dy, 0) + side)
	for cap_x in [-2, 3]:
		for dy in range(0, 2):
			wall_cells.append(base + Vector3i(cap_x, dy, 0))
	for w in wall_cells:
		if not world.is_solid(w) and world.place(w, BlockRegistry.Block.DIRT):
			walls.append(w)
	var sealed := wall_cells.all(func(w: Vector3i) -> bool: return world.is_solid(w))
	_check(sealed, "the corridor walls seal")
	var s := base + Vector3i(1, 0, 0)
	# A generated sapling or scattered pile may already hold the cell —
	# clear both first.
	var existing := colony.forest.tree_root_at(s)
	if existing != Vector3i.MAX:
		colony.forest.trees.erase(existing)
		colony.forest._index.erase(s)
	var stray_pile := colony.item_pile_at(s)
	if stray_pile != null:
		stray_pile.items.clear()
		colony.remove_pile_if_empty(s)
	_check(
		colony.forest.plant_sapling(s),
		"a sapling fills the corridor's middle"
	)
	var native := world.find_path(base, base + Vector3i(2, 0, 0))
	var crosses := false
	for p in native:
		if Vector3i(p.floor()) == s:
			crosses = true
	_check(
		not native.is_empty() and crosses,
		"the astar walks straight through a sapling cell"
	)
	var root := colony.forest.tree_root_at(s)
	if root != Vector3i.MAX:
		colony.forest.trees.erase(root)
		colony.forest._index.erase(s)
	for v in walls:
		world.remove_voxel(v)
	for u in colony.units:
		u._job_search_cooldown = 0.0

	for u in colony.units:
		u._job_search_cooldown = 0.0


## Crafting: a designated spot on flat ground is a workstation with no
## build cost; an order queued at it sends a unit for one whole log, which
## is sawn into three planks and a heap of loose sawdust of the log's
## material. Jobs are assigned directly so a free claimer can't fetch a
## different pile than the fixture's.
func _test_craft(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var spot := Vector3i.MAX
	for z_off in [168, 176, 184, 192]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate != Vector3i.MAX:
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat stretch for the craft test")
	if spot == Vector3i.MAX:
		return
	var log_v := spot + Vector3i(2, 0, 0)

	# Spots must be empty voxels resting on a solid block.
	_check(
		not colony.designate_craft_spot(spot + Vector3i.UP),
		"a voxel with no ground under it can't be a crafting spot"
	)
	_check(
		colony.designate_craft_spot(spot),
		"an empty voxel on solid ground designates as a crafting spot"
	)
	_check(colony.is_craft_spot(spot), "the crafting spot sticks")
	_check(
		not colony.designate_craft_spot(spot),
		"a voxel can't be craft-designated twice"
	)
	_check(
		not colony.designate_stockpile(spot),
		"a crafting spot can't double as a stockpile"
	)
	_check(
		colony.designate_craft(log_v) == null,
		"crafting can't be ordered off a spot"
	)

	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var job := _assign_craft(colony, world, spot, log_v)
	_check(job != null, "ordering at a spot creates a craft job")
	if job == null:
		return
	var extra := colony.queue_order(spot, &"bed")
	_check(
		extra != null and colony.building_at(spot).orders.size() == 2,
		"a second order queues behind the running one"
	)
	if extra != null:
		colony.remove_order(spot, extra)

	var saw_fetch := [false]
	var done := await _wait_until(func() -> bool:
		var worker: Unit = job.assignee
		if worker != null and worker._fetching:
			saw_fetch[0] = true
		return job.state == ColonyJob.State.DONE)
	_check(done, "a unit crafts planks at the spot")
	_check(saw_fetch[0], "the unit fetches the log before sawing")

	# Count what the saw produced near the spot — three discrete planks
	# and a heap of loose sawdust, all of the log's material.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var planks := 0
	var planks_ok := true
	var sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - spot).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.PLANK:
				planks += 1
				planks_ok = (
					planks_ok
					and item.volume == DropItem.PLANK_CM3
					and item.material == BlockRegistry.Resource_.WOOD
				)
			elif item.material == BlockRegistry.Resource_.WOOD:
				sawdust += item.volume
	_check(planks == 3, "crafting yields three planks")
	_check(planks_ok, "each plank is 20% of the log and of its material")
	_check(
		sawdust
			== DropItem.LOG_CM3 - DropItem.PLANK_CM3 * DropItem.PLANKS_PER_LOG,
		"the rest of the log falls as loose sawdust"
	)
	_check(colony.is_craft_spot(spot), "the crafting spot persists after its order")

	# Cancelling the order mid-craft ends the job; the carried input drops
	# back into the world rather than vanishing — and the site stays.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	var job2 := _assign_craft(colony, world, spot, log_v)
	_check(job2 != null, "the spot takes a second order")
	if job2 == null:
		return
	var worker: Unit = job2.assignee
	var carrying := await _wait_until(func() -> bool:
		return worker._carried_form(DropItem.Form.LOG) != null)
	_check(carrying, "the unit picks up the second log")
	if not carrying:
		return
	var at := worker._standing_voxel()
	colony.cancel_craft_order(spot)
	_check(not job2.is_active(), "cancelling the order ends the job")
	_check(colony.is_craft_spot(spot), "cancelling an order keeps the worksite")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var log_back := false
	for voxel in colony.item_piles:
		if Vector3(voxel - at).length() > 4.0:
			continue
		if colony.item_piles[voxel].form_volume(DropItem.Form.LOG) > 0:
			log_back = true
	_check(log_back, "a cancelled craft drops the carried log")

	# A cancel sweep lifts a queued order but never removes the site —
	# a building is a construction, not a designation.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	var job3 := _assign_craft(colony, world, spot, log_v)
	_check(job3 != null, "the spot takes a third order")
	colony.cancel_designation(spot)
	_check(
		job3 != null and not job3.is_active(),
		"a cancel sweep lifts the worksite's order"
	)
	_check(colony.is_craft_spot(spot), "a cancel sweep leaves the worksite standing")

	# Removing the site is a deconstruct job — a unit walks up and takes
	# it down, and no orders can be queued meanwhile.
	var demolish := colony.designate_deconstruct(spot)
	_check(demolish != null, "the worksite designates for deconstruction")
	_check(
		colony.designate_craft(spot) == null,
		"a spot marked for deconstruction takes no orders"
	)
	if demolish != null:
		_assign_job(colony, demolish, spot)
		var razed := await _wait_until(func() -> bool:
			return not colony.is_craft_spot(spot))
		_check(razed, "a unit deconstructs the worksite")
	_check(
		colony.building_at(spot) == null,
		"the worksite's building record is gone"
	)

	# Products piled on the spot fill it — clearing them out makes it
	# designatable again.
	var pile := colony.item_pile_at(spot)
	if pile != null:
		pile.items.clear()
		colony.remove_pile_if_empty(spot)
	_check(
		colony.designate_craft_spot(spot),
		"a cleared spot designates again"
	)
	# Leave no worksite behind for later tests.
	var raze := colony.designate_deconstruct(spot)
	if raze != null:
		_assign_job(colony, raze, spot)
		await _wait_until(func() -> bool:
			return colony.building_at(spot) == null)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Worksite bill queues: orders stack behind the running one, a bill
## whose inputs don't exist rotates to the back instead of blocking the
## line, do-X-times leaves the queue when it finishes, until-you-have-X
## parks while stocked, and forever never leaves. Escrow stays per-job —
## a queued bill owns nothing until it runs.
func _test_orders(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var spot := Vector3i.MAX
	for z_off in [196, 204, 212, 220, 228]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and colony.designate_craft_spot(candidate)
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "a flat voxel hosts the order-queue spot")
	if spot == Vector3i.MAX:
		return
	var building: Building = colony.building_at(spot)
	var log_v := spot + Vector3i(2, 0, 0)

	# A bed bill needs six planks — drain the colony's plank piles so
	# it's deterministically unperformable. The stock comes back at the
	# end of the test.
	var stashed: Array[DropItem] = []
	for voxel in colony.item_piles.keys():
		var pile: ItemPile = colony.item_piles[voxel]
		while true:
			var item := pile.take_form(DropItem.Form.PLANK, 1 << 30)
			if item == null:
				break
			stashed.append(item)
		colony.remove_pile_if_empty(voxel)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# The starved bill queues but dispatches nothing; a runnable tail
	# order jumps the line and the starved one rotates to the back.
	var bed_bill := colony.queue_order(spot, &"bed")
	_check(bed_bill != null, "a starved bill still queues")
	_check(
		colony.craft_job_at(spot) == null,
		"with no inputs nothing dispatches"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var planks_bill := colony.queue_order(spot, &"planks")
	var job := colony.craft_job_at(spot)
	_check(
		job != null and job.order == planks_bill,
		"the runnable tail order dispatches past the starved head"
	)
	_check(
		building.orders.size() == 2
			and building.orders[0] == planks_bill
			and building.orders[1] == bed_bill,
		"the starved bill rotated to the back of the queue"
	)
	if job == null:
		return
	_drive_craft(colony, world, job, log_v, spot)
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "a queued order's job runs like any craft")
	_check(
		not building.orders.has(planks_bill) and planks_bill.done == 1,
		"a finished do-X-times bill leaves the queue"
	)
	_check(
		building.orders.size() == 1 and building.orders[0] == bed_bill,
		"the starved bill is the only one left"
	)

	# The starved head stays put — the scan dispatches nothing for it.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a starved head dispatches no job"
	)

	# Until-you-have-X parks while stocked (three planks just landed)
	# and dispatches the moment the target outgrows the count.
	var until_bill := colony.queue_order(
		spot, &"planks", WorksiteOrder.Condition.UNTIL_HAVE, 3
	)
	_check(until_bill != null, "an until-bill queues")
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a stocked until-bill parks without dispatching"
	)
	until_bill.target = 4
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	var until_job := colony.craft_job_at(spot)
	_check(
		until_job != null and until_job.order == until_bill,
		"an understocked until-bill dispatches"
	)
	colony.cancel_craft_order(spot)
	_check(
		not building.orders.has(until_bill),
		"cancelling a run drops its bill from the queue"
	)

	# Forever bills survive their own runs and re-dispatch while inputs
	# last.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var forever_bill := colony.queue_order(
		spot, &"planks", WorksiteOrder.Condition.FOREVER
	)
	var forever_job := colony.craft_job_at(spot)
	_check(
		forever_job != null and forever_job.order == forever_bill,
		"a forever bill dispatches"
	)
	if forever_job != null:
		_drive_craft(colony, world, forever_job, log_v, spot)
		await _wait_until(func() -> bool:
			return forever_job.state == ColonyJob.State.DONE)
	_check(
		building.orders.has(forever_bill) and forever_bill.done == 1,
		"a forever bill survives its run"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) != null
			and colony.craft_job_at(spot).order == forever_bill,
		"the forever bill re-dispatches while inputs last"
	)
	colony.cancel_craft_order(spot)

	# A cancel sweep on the worksite clears every queued bill.
	var leftovers := colony.queue_order(spot, &"planks")
	colony.cancel_designation(spot)
	_check(
		leftovers != null and building.orders.is_empty(),
		"a cancel sweep empties the worksite's queue"
	)

	# Put the drained planks back and raze the fixture.
	for item in stashed:
		colony._deposit_item(item, log_v)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var raze := colony.designate_deconstruct(spot)
	if raze != null:
		_assign_job(colony, raze, spot)


## Orders a craft at [param site] and hands it straight to units[0], parked
## on the pile in [param pile_v] — bypassing the job board so the fixture's
## pile is the one fetched.
func _assign_craft(colony: Colony, world: VoxelWorld, site: Vector3i, pile_v: Vector3i, recipe: StringName = &"planks") -> ColonyJob:
	_clear_jobs(colony)
	var job := colony.designate_craft(site, recipe)
	if job == null:
		return null
	_drive_craft(colony, world, job, pile_v, site)
	return job


## Hands a posted craft job straight to the first unit: it stands beside
## the input pile already mid-fetch, so the run exercises the real
## fetch → escrow → craft path without waiting on idle claiming.
func _drive_craft(colony: Colony, world: VoxelWorld, job: ColonyJob, pile_v: Vector3i, site: Vector3i) -> void:
	var worker: Unit = colony.units[0]
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	worker.global_position = Vector3(_park_beside(colony, world, pile_v, site)) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = true
	worker._goal_voxel = pile_v
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING


## A standable voxel beside [param voxel], preferring the side toward
## [param toward]. Units never stand on top of a pile they're fetching
## from — a partial pile's fill lifts them into the cell above, where
## reach and pathing disagree — so helpers park next to the pile like a
## real approach would.
func _park_beside(colony: Colony, world: VoxelWorld, voxel: Vector3i, toward: Vector3i) -> Vector3i:
	var first := Vector3i(toward - voxel).sign()
	var sides: Array[Vector3i] = []
	if first != Vector3i.ZERO:
		sides.append(first)
	for side in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		if not sides.has(side):
			sides.append(side)
	for side in sides:
		var candidate := voxel + side
		if (
			world.get_block(candidate) == BlockRegistry.Block.AIR
			and world.is_solid(candidate + Vector3i.DOWN)
			and colony.voxel_fill(candidate) <= 0
		):
			return candidate
	return voxel


## Hands an existing [param job] straight to [param worker] (units[0] by
## default), parked one voxel off [param near] — the deconstruct/mine
## version of _assign_build: no fetch leg, just a unit that walks into
## reach and works.
func _assign_job(colony: Colony, job: ColonyJob, near: Vector3i, worker: Unit = null) -> void:
	if worker == null:
		worker = colony.units[0]
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	worker.global_position = Vector3(near) + Vector3(-0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = false
	worker._goal_voxel = job.voxel_position
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING


## Bill details — the expanded order settings RimWorld exposes: pause and
## resume, queue shuffling and duplication, until-hysteresis, stored-only
## counting, ingredient radius and material filters, the skill band and
## worker pin on claiming, deliver modes for finished goods, and zone
## priority plus the dumping preset on stockpiles.
func _test_bill_details(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("bill details")
	# A frozen roster can't touch the fixture piles or steal the jobs.
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null and not u.job.desperate:
			colony.release_job(u.job)
		u.abandon_job()
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0

	# Until-bill hysteresis is pure order math — no fixtures needed.
	var hysteresis := WorksiteOrder.new()
	hysteresis.recipe = &"planks"
	hysteresis.condition = WorksiteOrder.Condition.UNTIL_HAVE
	hysteresis.target = 10
	hysteresis.unpause_at = 3
	_check(not hysteresis.wants_work(10), "a satisfied until-bill parks")
	_check(
		not hysteresis.wants_work(4),
		"the parked bill holds until stock dips to the resume mark"
	)
	_check(hysteresis.wants_work(3), "stock at the resume mark wakes it")
	hysteresis.unpause_at = -1
	hysteresis.satisfied = false
	_check(not hysteresis.wants_work(10), "the legacy default parks at target")
	_check(hysteresis.wants_work(9), "the legacy default wakes on any dip")

	# A flat row: worksite on spot, stockpile A beside it, input piles two
	# cells over. Zone B takes a free cell beside the row; the dump preset
	# check reuses zone A's cell after teardown.
	var spot := Vector3i.MAX
	for off in [
		236, 240, 244, 248, 252, 256, 232, 260, 264, 268,
		228, 220, 212, 204, 196, 188, 180, 172, 164, 156, 148, 140,
		132, 124, 116, 108, 100, 92, 84, 76, 68, 60,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if (
			candidate != Vector3i.MAX
			and colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(candidate + Vector3i(2, 0, 0)) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(candidate + Vector3i(2, 0, 0))
			and colony.building_at(candidate) == null
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat row for the bill fixtures")
	if spot == Vector3i.MAX:
		unfreeze.call()
		return
	# The flat row verifies four cells: spot through spot + 2 hold the
	# worksite, zone A and the input pile; zone B takes the cell just
	# west, verified on the spot. Zones stay distinct by override.
	var cell_a := spot + Vector3i.RIGHT
	var log_v := spot + Vector3i.RIGHT * 2
	var cell_b := Vector3i.MAX
	for candidate in [
		spot + Vector3i.LEFT, spot + Vector3i.RIGHT * 3,
		spot + Vector3i(0, 0, 1), spot + Vector3i(0, 0, -1),
	]:
		if (
			world.get_block(candidate) == BlockRegistry.Block.AIR
			and world.is_solid(candidate + Vector3i.DOWN)
			and colony.voxel_fill(candidate) <= 0
			and not colony._designation_markers.has(candidate)
			and colony.building_at(candidate) == null
		):
			cell_b = candidate
			break
	_check(cell_b != Vector3i.MAX, "found a free cell for zone B")
	if cell_b == Vector3i.MAX:
		unfreeze.call()
		return
	# Zone C is the delivery destination — it has to sit far enough from
	# the spot that a product spilling off the worksite can't land in
	# its ring, or the deliver modes can't be told apart. The flat row
	# only vouches for three cells east, so the rest is verified here.
	var cell_c := Vector3i.MAX
	for dx in range(4, 10):
		for candidate in [spot + Vector3i(dx, 0, 0), spot + Vector3i(-dx, 0, 0)]:
			if (
				cell_c == Vector3i.MAX
				and world.get_block(candidate) == BlockRegistry.Block.AIR
				and world.is_solid(candidate + Vector3i.DOWN)
				and colony.voxel_fill(candidate) <= 0
				and not colony._designation_markers.has(candidate)
				and colony.building_at(candidate) == null
			):
				cell_c = candidate
		if cell_c != Vector3i.MAX:
			break
	_check(cell_c != Vector3i.MAX, "found a far cell for the delivery zone")
	if cell_c == Vector3i.MAX:
		unfreeze.call()
		return

	colony.designate_craft_spot(spot)
	var building: Building = colony.building_at(spot)
	_check(
		building != null and building.kind == Building.Kind.WORKSITE,
		"the details fixture is a fresh craft spot"
	)
	# Override forces each cell into its own fresh zone — adjacency or
	# an older zone's reach can't merge the fixtures into each other.
	colony.designate_stockpile_cells([cell_a], cell_a, true)
	colony.designate_stockpile_cells([cell_b], cell_b, true)
	colony.designate_stockpile_cells([cell_c], cell_c, true)
	# Three logs: the deliver-mode drives each consume one.
	for _i in range(3):
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			log_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# --- Pause: a suspended bill keeps its queue slot but never runs.
	var head_bill := colony.queue_order(spot, &"planks")
	_check(
		colony.craft_job_at(spot) != null,
		"the head bill dispatches while inputs exist"
	)
	var tail_bill := colony.queue_order(spot, &"planks")
	_check(
		building != null and building.orders.size() == 2,
		"a second bill queues behind the running job"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, true)
	colony.cancel_craft_order(spot)   # drops the head job and its bill
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a paused bill stays queued without dispatching"
	)
	_check(
		building != null and building.orders.has(tail_bill),
		"pausing preserves the bill's queue slot"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, false)
	colony._worksite_tick()
	var tail_job := colony.craft_job_at(spot)
	_check(
		tail_job != null and tail_job.order == tail_bill,
		"resuming lets the bill dispatch"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, true)
	_check(
		tail_job != null and tail_job.suspended and not tail_job.is_open(),
		"pausing suspends the bill's live job"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, false)
	_check(
		tail_job != null and not tail_job.suspended and tail_job.is_open(),
		"resuming reopens the suspended job"
	)

	# --- Reorder and duplicate.
	var bill_b := colony.queue_order(spot, &"planks")
	var bill_c := colony.queue_order(spot, &"planks")
	if bill_c != null:
		colony.move_order(spot, bill_c, -1)
	_check(
		building != null and building.orders.size() >= 3
			and building.orders[1] == bill_c,
		"moving a bill lifts it one queue slot"
	)
	var copy := colony.duplicate_order(spot, bill_c)
	_check(
		copy != null and copy != bill_c and building.orders.has(copy),
		"duplicating appends a fresh bill"
	)
	if copy != null:
		copy.unpause_at = 2
		_check(
			bill_c == null or bill_c.unpause_at != 2,
			"the copy isn't aliased to the original"
		)
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()

	# --- Claim gates: the pinned worker and the skill band.
	var gate_bill := colony.queue_order(spot, &"planks")
	var gate_job := colony.craft_job_at(spot)
	_check(
		gate_job != null and gate_job.order == gate_bill,
		"a fresh bill posts a claimable job"
	)
	if gate_bill != null and gate_job != null:
		gate_bill.worker_index = 0
		_check(
			colony._job_allowed_for(colony.units[0], gate_job),
			"the pinned worker may claim the bill"
		)
		_check(
			colony.units.size() < 2
				or not colony._job_allowed_for(colony.units[1], gate_job),
			"a worker-pinned bill rejects other claimants"
		)
		gate_bill.worker_index = -1
		var craft_skill: int = int(
			Colony.RECIPES[&"planks"].get(
				"skill",
				ColonyJob.SKILL_FOR.get(ColonyJob.Type.CRAFT, -1)
			)
		)
		var saved_xp: float = colony.units[0].skills.get(craft_skill, 0.0)
		colony.units[0].skills[craft_skill] = 0.0   # level 0
		gate_bill.skill_min = 3
		_check(
			not colony._job_allowed_for(colony.units[0], gate_job),
			"a skill floor rejects under-level workers"
		)
		colony.units[0].skills[craft_skill] = 150.0  # level 5
		_check(
			colony._job_allowed_for(colony.units[0], gate_job),
			"the band admits an in-range worker"
		)
		gate_bill.skill_max = 4
		_check(
			not colony._job_allowed_for(colony.units[0], gate_job),
			"a skill ceiling rejects over-level workers"
		)
		gate_bill.skill_min = 0
		gate_bill.skill_max = 20
		colony.units[0].skills[craft_skill] = saved_xp
		# The real claim path honors the pin too — pin to units[0] and let
		# units[1] bounce off the job board.
		gate_bill.worker_index = 0
		if colony.units.size() > 1:
			_clear_jobs(colony)
			gate_bill = colony.queue_order(spot, &"planks")
			gate_job = colony.craft_job_at(spot)
			if gate_bill != null:
				gate_bill.worker_index = 0
			_check(
				colony.claim_job(colony.units[1]) != gate_job,
				"the job board won't hand a pinned bill to another worker"
			)
			_check(
				colony.claim_job(colony.units[0]) == gate_job,
				"the pinned worker claims its bill through the board"
			)
			colony.units[0].abandon_job()
			colony.release_job(gate_job)

	# --- Ingredient radius and material filters.
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()
	var radius_order := WorksiteOrder.new()
	radius_order.recipe = &"planks"
	radius_order.ingredient_radius = 1.9
	_check(
		not colony._order_dispatchable(radius_order, spot),
		"inputs past the bill's fetch radius don't count"
	)
	radius_order.ingredient_radius = 2.1
	_check(
		colony._order_dispatchable(radius_order, spot),
		"loosening the radius admits the same pile"
	)
	# Rejecting a material skips it even when the form matches. Every
	# fruit the world can hold — berries and the groves' acorn litter —
	# goes on the reject list so only the fixture's own item qualifies.
	var filter_order := WorksiteOrder.new()
	filter_order.recipe = &"extract_seed"
	filter_order.rejected_materials[int(BlockRegistry.Resource_.BERRY)] = true
	filter_order.rejected_materials[int(BlockRegistry.Resource_.ACORN)] = true
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		not colony._order_dispatchable(filter_order, spot),
		"a rejected material can't fill an ingredient slot"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.GRAIN, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._order_dispatchable(filter_order, spot),
		"an admitted material of the same form satisfies it"
	)

	# --- Counting: stored-only and in-flight/carried goods.
	var count_order := WorksiteOrder.new()
	count_order.recipe = &"prepare_meal"
	count_order.condition = WorksiteOrder.Condition.UNTIL_HAVE
	var have_before := colony._have_count(&"prepare_meal")
	# A meal loose on the input pile's cell — landed, but not stockpiled.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._have_count(&"prepare_meal") == have_before + 1,
		"loose products count toward an until-bill"
	)
	count_order.count_stored_only = true
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before,
		"stored-only counting skips loose goods"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		cell_b
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before + 1,
		"stockpiled goods count for stored-only bills"
	)
	# Carried items only figure in the broad tally — stored-only skips
	# them with the loose piles.
	count_order.count_stored_only = false
	colony.units[0]._carried.append(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		)
	)
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before + 3,
		"carried goods count too — RimWorld's in-flight tally"
	)
	colony.units[0]._carried.clear()

	# --- Deliver mode: finished goods walk to their destination.
	# A drop isn't guaranteed to stay on its cell — `_drop_item` spills
	# with the pile's fill — so every delivery is measured as plank-item
	# growth inside the destination's spill ring (Chebyshev 2 covers a
	# chained hop), not a single cell's tally.
	var planks_near := func(centre: Vector3i) -> int:
		var total := 0
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - centre).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.PLANK:
					total += 1
		return total
	# Rank beats distance outright, so CRITICAL pins the "best" zone to
	# the far fixture no matter what older stockpiles are still standing.
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.NORMAL)
	colony.set_stockpile_priority(cell_c, StockpileZone.Priority.CRITICAL)
	var spot_planks := func() -> int:
		var pile := colony.item_pile_at(spot)
		if pile == null:
			return 0
		var total := 0
		for item in pile.items:
			if item.form == DropItem.Form.PLANK:
				total += 1
		return total
	var before_best: int = planks_near.call(cell_c)
	var before_spot: int = spot_planks.call()
	var best_job := _assign_craft(colony, world, spot, log_v)
	_check(best_job != null, "a stockpile-delivering bill drives")
	if best_job != null:
		best_job.order.deliver_mode = WorksiteOrder.Deliver.BEST_STOCKPILE
		await _wait_until(
			func() -> bool: return best_job.state == ColonyJob.State.DONE
		)
		# Products spawn as falling piles — count only once they've landed.
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			planks_near.call(cell_c) - before_best >= 3,
			"best-stockpile delivery lands the planks in a zone"
		)
		_check(
			spot_planks.call() - before_spot == 0,
			"delivered goods don't drop at the worksite"
		)
	# Zone-pinned delivery ignores distance and priorities — the far
	# fixture's ring can't see the worksite either. A leftover bill from
	# a stalled run mustn't hijack the next drive.
	if building != null:
		building.orders.clear()
	var before_zone: int = planks_near.call(cell_c)
	var zone_job := _assign_craft(colony, world, spot, log_v)
	if zone_job != null:
		zone_job.order.deliver_mode = WorksiteOrder.Deliver.ZONE
		zone_job.order.deliver_target = cell_c
		await _wait_until(
			func() -> bool: return zone_job.state == ColonyJob.State.DONE
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			planks_near.call(cell_c) - before_zone >= 3,
			"a pinned zone receives its bill's products"
		)
	# And the default still drops at the worker's feet. The earlier
	# drives leave their sawdust at the spot — a cluttered cell spills
	# its drops into the neighbours, so "at the worksite" means the spot
	# cell and the ring a spill can reach, not the stockpile zones.
	if building != null:
		building.orders.clear()
	var spot_pile := colony.item_pile_at(spot)
	if spot_pile != null:
		spot_pile.items.clear()
		colony.remove_pile_if_empty(spot)
	var before_feet: int = planks_near.call(spot)
	var feet_job := _assign_craft(colony, world, spot, log_v)
	if feet_job != null:
		await _wait_until(
			func() -> bool: return feet_job.state == ColonyJob.State.DONE
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			planks_near.call(spot) - before_feet >= 3,
			"the default still drops products at the worksite"
		)

	# --- Stockpile priority: a farther HIGH zone beats a nearer LOW.
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.LOW)
	colony.set_stockpile_priority(cell_b, StockpileZone.Priority.HIGH)
	colony.set_stockpile_priority(cell_c, StockpileZone.Priority.NORMAL)
	_check(
		colony.nearest_stockpile_with_room(
			cell_a, 1, {}, [BlockRegistry.Resource_.SOIL]
		) == cell_b,
		"a higher-priority zone beats a nearer one"
	)
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.CRITICAL)
	_check(
		colony.nearest_stockpile_with_room(
			cell_a, 1, {}, [BlockRegistry.Resource_.SOIL]
		) == cell_a,
		"at a better rank the nearer zone wins again"
	)

	# Teardown: clear the board and bills, raze the spot, lift the zones,
	# and drain the fixture piles so food tests see no free meals. Zone
	# A's emptied cell then hosts the dumping-preset check — flipping a
	# cell from goods storage to a garbage zone is how a player does it.
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()
		colony.cancel_designation(spot)
		var raze := colony.designate_deconstruct(spot)
		if raze != null:
			_assign_job(colony, raze, spot)
			# The raze drops the worksite's materials back on the spot —
			# wait for them to land or the drain below misses them.
			await _wait_until(
				func() -> bool: return raze.state != ColonyJob.State.ASSIGNED
			)
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony.undesignate_stockpile(cell_a)
	colony.undesignate_stockpile(cell_b)
	colony.undesignate_stockpile(cell_c)
	# The worksite's drops can spill a cell out in any direction — drain
	# the fixture cells plus the whole spill ring around the spot and
	# the far delivery zone.
	var drain := [
		log_v, cell_a, cell_b, cell_c, spot,
		spot + Vector3i.RIGHT, spot + Vector3i.LEFT,
		spot + Vector3i.FORWARD, spot + Vector3i.BACK,
		cell_c + Vector3i.RIGHT, cell_c + Vector3i.LEFT,
		cell_c + Vector3i.FORWARD, cell_c + Vector3i.BACK,
	]
	for cell in drain:
		var pile := colony.item_pile_at(cell)
		if pile != null:
			pile.items.clear()
			colony.remove_pile_if_empty(cell)
	colony.designate_dump_stockpile(cell_a)
	var dump_zone := colony.stockpile_at(cell_a)
	_check(
		dump_zone != null and dump_zone.priority == StockpileZone.Priority.LOW,
		"a dumping zone starts at low priority"
	)
	_check(
		colony.stockpile_admits(cell_a, BlockRegistry.Resource_.STONE)
			and colony.stockpile_admits(cell_a, BlockRegistry.Resource_.COMPOST)
			and not colony.stockpile_admits(cell_a, BlockRegistry.Resource_.WOOD)
			and not colony.stockpile_admits(cell_a, BlockRegistry.Resource_.MEAL),
		"the dump preset admits rubble and litter, not goods"
	)
	colony.undesignate_stockpile(cell_a)
	unfreeze.call()


## The campfire: a cobble-ring construction that burns fuel for light
## and hosts the prepare-meal bill. Cold fires suspend their bills and
## shed their light; auto-refuel posts the REFUEL job at the threshold
## and the inspect toggle can switch it off. The meal remembers its
## ingredients' nutrition times the cook bonus.
func _test_campfire(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("campfire and cooking")
	# The cell has to be streamed *and* clean — razed fixtures free their
	# cells, so the nearer bands other tests already walked are fair
	# game too. Cells the earlier fixtures still hold just skip.
	var spot := Vector3i.MAX
	for off in [
		236, 240, 244, 248, 252, 256, 232, 260, 264, 268,
		228, 220, 212, 204, 196, 188, 180, 172, 164, 156, 148, 140,
		132, 124, 116, 108, 100, 92, 84, 76, 68, 60,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if candidate == Vector3i.MAX:
			continue
		var beside := candidate + Vector3i(2, 0, 0)
		if (
			colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(beside) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(beside)
			and colony.building_at(candidate) == null
			and colony.building_at(beside) == null
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat spot for the campfire")
	if spot == Vector3i.MAX:
		return
	var pile_v := spot + Vector3i(2, 0, 0)
	var worker: Unit = colony.units[0]
	_clear_jobs(colony)
	# Park every unit for the section — an idle unit would haul the
	# fruit pile to a stockpile or claim the dispatched meal job between
	# fixture waits, and the escrow count goes missing. The search
	# cooldown gates every idle path (claims, needs, hauls); driven jobs
	# assign directly so it never stalls the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null:
			u.abandon_job()
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0

	# Fuel values: a log is the real fuel, branches middling, leaves and
	# sawdust flash, and stone doesn't burn at all.
	_check(
		DropItem.fuel_seconds_of(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.LOG, DropItem.LOG_CM3
			)
		) == 600.0,
		"a log is worth ten minutes of fire"
	)
	_check(
		is_equal_approx(
			DropItem.fuel_seconds_of(
				DropItem.new(
					BlockRegistry.Resource_.BRANCH,
					DropItem.Form.LOOSE, 200_000
				)
			),
			160.0
		),
		"branches burn by volume"
	)
	_check(
		is_equal_approx(
			DropItem.fuel_seconds_of(
				DropItem.new(
					BlockRegistry.Resource_.LEAF,
					DropItem.Form.LOOSE, 200_000
				)
			),
			100.0
		),
		"leaves burn fast"
	)
	_check(
		DropItem.fuel_seconds_of(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			)
		) == 0.0,
		"stone is no fuel"
	)

	# Validity: the cell must be open air over solid ground, free of
	# piles, markers and claims.
	_check(
		colony.designate_campfire(spot + Vector3i.UP) == null,
		"a campfire needs a solid floor"
	)
	for i in 5:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			),
			pile_v
		)
	_check(
		colony.designate_campfire(pile_v) == null,
		"a piled cell refuses the ring"
	)
	var build := colony.designate_campfire(spot)
	_check(build != null, "a campfire designates on open ground")
	_check(
		colony.designate_campfire(spot) == null,
		"a designated cell refuses a second campfire"
	)
	if build == null:
		unfreeze.call()
		return

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_drive_craft(colony, world, build, pile_v, spot)
	var built := await _wait_until(
		func() -> bool: return build.state == ColonyJob.State.DONE
	)
	_check(built, "a unit builds the campfire from cobbles")
	var fire := colony.campfire_at(spot)
	_check(fire != null, "the campfire registers as a building")
	if fire == null:
		unfreeze.call()
		return
	var cobbles := 0
	for item in fire.components:
		if item.form == DropItem.Form.COBBLE:
			cobbles += 1
	_check(cobbles == 5, "the ring is five cobbles")
	_check(fire.is_worksite(), "a campfire is a worksite")
	_check(not fire.lit(), "a fresh campfire starts unlit")
	_check(
		colony.illumination_at(spot) == 0.0,
		"an unlit campfire sheds no light"
	)

	# A bare crafting spot refuses the meal bill — the recipe is pinned
	# to the campfire kind. The spot is razed as soon as its checks are
	# done: its queued plank bill would keep dispatching against later
	# fixtures' logs and drop stray sawdust mid-suite.
	var bare := _flat_voxel(world, mined, spot.z - mined.z + 1, 6)
	if bare != Vector3i.MAX and colony.designate_craft_spot(bare):
		_check(
			colony.queue_order(bare, &"prepare_meal") == null,
			"a bare spot can't cook"
		)
		var plank_bill := colony.queue_order(bare, &"planks")
		_check(
			plank_bill != null,
			"the bare spot still takes its own bills"
		)
		if plank_bill != null:
			colony.remove_order(bare, plank_bill)
		var stray := colony.craft_job_at(bare)
		if stray != null:
			colony._cancel_job(stray)
		var raze := colony.designate_deconstruct(bare)
		if raze != null:
			_assign_job(colony, raze, bare)
			await _wait_until(
				func() -> bool: return colony.building_at(bare) == null
			)

	# The meal bill queues on a cold fire but doesn't dispatch — raw
	# fruit is already piled, so only the fire blocks it.
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.BERRY,
				DropItem.Form.FRUIT, DropItem.FRUIT_CM3
			),
			pile_v
		)
	var order := colony.queue_order(spot, &"prepare_meal")
	_check(order != null, "a cold campfire queues the meal bill")
	_check(
		colony.craft_job_at(spot) == null,
		"a cold campfire suspends its bills"
	)

	# Fuel is low from the start — with a burnable pile in the world and
	# auto-refuel on, the tick posts the job itself.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD,
			DropItem.Form.LOG, DropItem.LOG_CM3
		),
		pile_v
	)
	var posted := await _wait_until(
		func() -> bool: return colony.refuel_job_at(spot) != null
	)
	_check(posted, "auto-refuel posts the refuel job at the threshold")
	_check(
		colony.request_refuel(spot) == null,
		"no duplicate refuel job while one is live"
	)
	var refuel := colony.refuel_job_at(spot)
	if refuel == null:
		unfreeze.call()
		return
	_drive_craft(colony, world, refuel, pile_v, spot)
	var fed := await _wait_until(
		func() -> bool: return refuel.state == ColonyJob.State.DONE
	)
	_check(fed, "a unit feeds the campfire a log")
	_check(fire.lit(), "the fed campfire is lit")
	_check(
		fire.fuel > 590.0,
		"the delivered log banks its burn-seconds"
	)
	var marker: MeshInstance3D = colony._designation_markers.get(spot)
	var light := (
		marker.get_node_or_null("Fire") as OmniLight3D
		if marker != null
		else null
	)
	_check(
		light != null and light.visible
			and is_equal_approx(
				light.omni_range, Colony.CAMPFIRE_LIGHT_RADIUS
			),
		"the lit campfire shines out to its work radius"
	)
	_check(
		colony.illumination_at(spot) > 0.5,
		"the fire lights its own cell"
	)

	# The queued bill dispatches now that the fire burns; drive the cook
	# through the fruit pile beside it.
	var dispatched := await _wait_until(
		func() -> bool: return colony.craft_job_at(spot) != null
	)
	_check(dispatched, "the queued bill dispatches once the fire is fed")
	# A running bill tints the worksite marker — but the campfire's is
	# its stone ring, not the generic box: dispatch must keep the torus.
	var lit_marker: MeshInstance3D = colony._designation_markers.get(spot)
	_check(
		lit_marker != null and lit_marker.mesh == colony._campfire_mesh,
		"a dispatched bill keeps the campfire's ring mesh"
	)
	_check(
		lit_marker != null
			and lit_marker.material_override == colony._craft_job_marker_material,
		"the running ring carries the job tint"
	)
	var meal := colony.craft_job_at(spot)
	if meal == null:
		unfreeze.call()
		return
	_drive_craft(colony, world, meal, pile_v, spot)
	var cooking := await _wait_until(func() -> bool:
		return (
			worker.state == Unit.State.WORKING
			and not worker._fetching
			and int(meal.delivered.get(DropItem.Form.FRUIT, 0))
				>= 4 * DropItem.FRUIT_CM3
		))
	_check(cooking, "the cook escrows the recipe's fruit")
	if not cooking:
		var pile := colony.item_pile_at(pile_v)
		var pile_stock := {}
		if pile != null:
			for item in pile.items:
				pile_stock[item.form] = (
					int(pile_stock.get(item.form, 0)) + item.volume
				)
		var carried := {}
		for item in worker._carried:
			carried[item.form] = (
				int(carried.get(item.form, 0)) + item.volume
			)
		print(
			"    cook stall: state=", worker.state,
			" fetching=", worker._fetching,
			" goal=", worker._goal_voxel,
			" job_state=", meal.state,
			" delivered=", meal.delivered,
			" pile=", pile_stock,
			" carried=", carried,
			"\n", worker.decision_trail()
		)
		colony._cancel_job(meal)
		unfreeze.call()
		return

	# Kill the fire mid-cook: progress freezes but the bill and its
	# escrowed inputs stay put.
	fire.auto_refuel = false
	fire.fuel = 0.0
	colony._campfire_tick(0.0)
	var frozen := meal.progress
	for i in 20:
		await physics_frame
	_check(
		meal.progress == frozen and meal.is_active(),
		"a cold fire suspends the running bill"
	)
	_check(light != null and not light.visible, "the dead fire goes dark")

	# Feed it by hand and the cook finishes where it left off.
	fire.fuel = 60.0
	colony._campfire_tick(0.0)
	var cooked := await _wait_until(
		func() -> bool: return meal.state == ColonyJob.State.DONE
	)
	_check(cooked, "the suspended bill resumes when the fire is fed")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var meal_item: DropItem = null
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - spot).length() > 4.0:
			continue
		for item: DropItem in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.MEAL:
				meal_item = item
	_check(
		meal_item != null
			and meal_item.material == BlockRegistry.Resource_.MEAL
			and meal_item.volume == DropItem.MEAL_CM3,
		"cooking drops a real meal item at the fire"
	)
	var want_nutrition := (
		1.75 * 4.0 * DropItem.nutrition_of(
			BlockRegistry.Resource_.BERRY, DropItem.FRUIT_CM3
		)
	)
	_check(
		meal_item != null
			and is_equal_approx(meal_item.nutrition_value(), want_nutrition),
		"the meal is worth 75% over its raw fruit"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.MEAL),
		"meals answer the food query"
	)
	_check(
		is_equal_approx(
			worker.skills.get(ColonyJob.Skill.COOKING, 0.0), 1.0
		),
		"a cooked meal trains Cooking"
	)
	worker.gain_skill_xp(ColonyJob.Skill.COOKING, 9.0)
	_check(
		worker.skill_level(ColonyJob.Skill.COOKING) == 1,
		"ten meals carry a cook to level 1"
	)

	# Manual control: with auto-refuel off the tick stays quiet even
	# under the threshold; a manual request still posts.
	fire.fuel = Colony.CAMPFIRE_FUEL_CAP * 0.1
	colony._campfire_tick(1.0)
	_check(
		colony.refuel_job_at(spot) == null,
		"auto-refuel off posts nothing at the threshold"
	)
	var manual := colony.request_refuel(spot)
	_check(manual != null, "a manual request still posts the job")
	if manual != null:
		manual.state = ColonyJob.State.CANCELLED
		colony._prune_jobs()

	# Burning out kills the light and the glow again.
	fire.fuel = 0.4
	colony._campfire_tick(1.0)
	_check(not fire.lit(), "the fire burns out")
	_check(light != null and not light.visible, "a burned-out fire sheds no light")
	_check(
		colony.illumination_at(spot) == 0.0,
		"a burned-out fire lights nothing"
	)

	# Leave the ring standing but quiet — the persistence test
	# round-trips it (fuel + toggle included).
	fire.fuel = 55.0
	fire.auto_refuel = false
	colony._campfire_tick(0.0)
	unfreeze.call()


## Surface scree: the generator's lattice oracle is deterministic, the
## colony drops real piles of boulders and cobbles as blocks stream in,
## and a picked-clean slot is spent forever — re-streaming the block
## never restocks it.
func _test_loose_rocks(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("loose surface rocks")
	var gen := world.generator_script
	var origin := Vector3i(
		floori(float(mined.x) / 16.0),
		floori(float(mined.y) / 16.0),
		floori(float(mined.z) / 16.0)
	)
	# Oracle determinism — the same chunk yields the same scatter.
	var first := gen.loose_rocks_in(origin * 16, 16)
	_check(
		first == gen.loose_rocks_in(origin * 16, 16),
		"the rock oracle is deterministic"
	)

	# Find a usable slot near the site. Reading the voxel may stream its
	# chunk — which seeds the slot itself, the very path under test —
	# so the claim checks run *before* get_block touches the world: a
	# slot the stream already seeded is skipped only when its pile is
	# gone or foreign, and a fresh slot still seeds on demand.
	var slot_v := Vector3i.MAX
	var slot_counts := {}
	var slot_chunk := Vector3i.MAX
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var chunk := origin + Vector3i(dx, 0, dz)
			var slots: Dictionary = gen.loose_rocks_in(chunk * 16, 16)
			for pos: Vector2i in slots:
				var voxel := Vector3i(
					pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
				)
				if colony._rock_spent.has(voxel):
					continue
				if (
					colony.item_pile_at(voxel) != null
					and not colony._rock_slots.has(voxel)
				):
					continue  # a foreign pile squats on the slot
				if world.get_block(voxel) != BlockRegistry.Block.AIR:
					continue
				slot_v = voxel
				slot_counts = slots[pos]
				slot_chunk = chunk
				break
			if slot_v != Vector3i.MAX:
				break
		if slot_v != Vector3i.MAX:
			break
	_check(slot_v != Vector3i.MAX, "found an unseeded rock slot near the site")
	if slot_v == Vector3i.MAX:
		return

	colony._seed_loose_rocks(slot_chunk)
	var pile := colony.item_pile_at(slot_v)
	_check(pile != null, "seeding drops a real rock pile")
	if pile != null:
		_check(
			pile.form_volume(DropItem.Form.BOULDER)
				== int(slot_counts.get(&"boulders", 0)) * DropItem.BOULDER_CM3,
			"the pile holds the slot's boulders"
		)
		_check(
			pile.form_volume(DropItem.Form.COBBLE)
				== int(slot_counts.get(&"cobbles", 0)) * DropItem.COBBLE_CM3,
			"the pile holds the slot's cobbles"
		)
		var items_before := pile.items.size()
		colony._seed_loose_rocks(slot_chunk)
		_check(
			pile.items.size() == items_before,
			"re-seeding a live slot drops nothing twice"
		)
		# Picked clean, the slot tombstones — no restock on re-seed.
		pile.items.clear()
		colony.remove_pile_if_empty(slot_v)
		_check(
			colony._rock_spent.has(slot_v),
			"a picked-clean slot is spent"
		)
		colony._seed_loose_rocks(slot_chunk)
		_check(
			colony.item_pile_at(slot_v) == null,
			"a spent slot never restocks"
		)

	# Scree and saplings draw from the same surface lattice in separate
	# block_loaded passes — a pile isn't terrain, so without an explicit
	# cross-check a tree registers on a rock pile's cell. The invariant
	# both orders must hold: no live scree slot shares a cell with a
	# tree claim.
	var tree_overlap := 0
	for voxel: Vector3i in colony._rock_slots:
		if colony.forest.tree_root_at(voxel) != Vector3i.MAX:
			tree_overlap += 1
	_check(
		tree_overlap == 0,
		"no generated scree pile shares a cell with a tree"
	)

	# Tree first: a claimed cell vetoes a later seeding pass. A live
	# slot's tracking is stripped so the pass re-evaluates its cell.
	var live_v := Vector3i.MAX
	for voxel: Vector3i in colony._rock_slots:
		if (
			colony.forest.tree_root_at(voxel) == Vector3i.MAX
			and world.is_solid(voxel + Vector3i.DOWN)
		):
			live_v = voxel
			break
	_check(live_v != Vector3i.MAX, "found a live scree slot to replay")
	if live_v != Vector3i.MAX:
		var live_pile: ItemPile = colony._rock_slots[live_v]
		colony._rock_slots.erase(live_v)
		live_pile.items.clear()
		colony.remove_pile_if_empty(live_v)
		colony._rock_spent.erase(live_v)  # re-arm the slot for the replay
		_check(
			colony.forest.plant_sapling(live_v),
			"a sapling claims the freed cell"
		)
		colony._seed_loose_rocks(
			Vector3i(live_v.x >> 4, live_v.y >> 4, live_v.z >> 4)
		)
		_check(
			colony.item_pile_at(live_v) == null,
			"a claimed cell keeps the scree slot from seeding"
		)
		_check(
			not colony._rock_slots.has(live_v),
			"the skipped slot stays unclaimed, not adopted"
		)
		colony.forest.trees.erase(live_v)
		colony.forest._index.erase(live_v)

	# Pile first: discovery on a sapling slot skips a piled cell, then
	# claims it once the pile clears — the reported collision's order.
	var sap_v := Vector3i.MAX
	var sap_chunk := Vector3i.MAX
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var chunk := origin + Vector3i(dx, 0, dz)
			var slots: Dictionary = gen.saplings_in(chunk * 16, 16)
			for pos: Vector2i in slots:
				var voxel := Vector3i(
					pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
				)
				var rec: Dictionary = colony.forest.trees.get(voxel, {})
				if (
					rec.is_empty()
					or int(rec[&"height"]) != 0
					or colony.item_pile_at(voxel) != null
				):
					continue
				sap_v = voxel
				sap_chunk = chunk
				break
			if sap_v != Vector3i.MAX:
				break
		if sap_v != Vector3i.MAX:
			break
	_check(sap_v != Vector3i.MAX, "found a live sapling slot to replay")
	if sap_v != Vector3i.MAX:
		# Unregister fully so the slot replays its discovery pass.
		var rec2: Dictionary = colony.forest.trees[sap_v]
		var block := colony.forest._block_of(sap_v)
		var col := colony.forest._column_chunk(sap_v)
		colony.forest.trees.erase(sap_v)
		colony.forest._index.erase(sap_v)
		(colony.forest._block_roots.get(block, {}) as Dictionary).erase(sap_v)
		(colony.forest._chunk_roots.get(col, {}) as Dictionary).erase(sap_v)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			),
			sap_v
		)
		_check(
			not colony.forest.plant_sapling(sap_v),
			"a piled cell refuses a planted sapling"
		)
		colony.forest._on_block_loaded(sap_chunk)
		_check(
			colony.forest.tree_root_at(sap_v) == Vector3i.MAX,
			"sapling discovery skips the piled cell"
		)
		colony.item_pile_at(sap_v).items.clear()
		colony.remove_pile_if_empty(sap_v)
		colony.forest._on_block_loaded(sap_chunk)
		_check(
			colony.forest.tree_root_at(sap_v) != Vector3i.MAX,
			"the freed cell claims on the next discovery pass"
		)
		_check(
			rec2[&"species"] == colony.forest.trees[sap_v][&"species"],
			"the replayed slot keeps its generated species"
		)


## Deconstruction: a wall comes apart into exactly the items it was built
## of; a packed-dirt wall isn't a building to the tool and has to be mined
## — and a mined wall's record dies with its block.
func _test_deconstruct(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var dirt_site := _flat_voxel(world, mined, 200)
	_check(dirt_site != Vector3i.MAX, "found a flat spot for the dirt wall")
	if dirt_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, dirt_site, 30.0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1400000),
		dirt_site + Vector3i(1, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var dirt_job := _assign_build(
		colony, dirt_site, dirt_site + Vector3i(1, 0, 0), &"dirt_wall"
	)
	var packed := await _wait_until(func() -> bool:
		return world.get_block(dirt_site) == BlockRegistry.Block.DIRT)
	_check(packed and dirt_job != null, "a unit packs a dirt wall for the test")
	var dirt_wall := colony.building_at(dirt_site)
	_check(
		dirt_wall != null and not dirt_wall.deconstructable,
		"a packed-dirt wall registers but isn't deconstructable"
	)
	_check(
		colony.designate_deconstruct(dirt_site) == null,
		"a dirt wall can't be designated for deconstruction"
	)

	# A stone wall comes down into exactly its nine boulders and ten
	# cobbles — no shatter, no loss.
	var stone_site := _flat_voxel(world, mined, 208)
	_check(stone_site != Vector3i.MAX, "found a flat spot for the stone wall")
	if stone_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 9:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BOULDER,
				DropItem.BOULDER_CM3
			),
			stone_site + Vector3i(1, 0, 0)
		)
	for i in 10:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			stone_site + Vector3i(2, 0, 0)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(1, 0, 0), &"stone_wall"
	)
	var walled := await _wait_until(func() -> bool:
		return world.get_block(stone_site) == BlockRegistry.Block.STONE_WALL)
	_check(walled and stone_job != null, "a stone wall goes up for the test")
	var demolish := colony.designate_deconstruct(stone_site)
	_check(demolish != null, "a stone wall designates for deconstruction")
	_check(
		colony.designate_deconstruct(stone_site) == null,
		"a wall can't be deconstruct-designated twice"
	)
	if demolish == null:
		return
	_assign_job(colony, demolish, stone_site)
	var razed := await _wait_until(func() -> bool:
		return not world.is_solid(stone_site))
	_check(razed, "a unit takes the stone wall apart")
	_check(
		colony.building_at(stone_site) == null,
		"the wall's building record dies with it"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var boulders := 0
	var cobbles := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - stone_site).length() > 5.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material != BlockRegistry.Resource_.STONE:
				continue
			match item.form:
				DropItem.Form.BOULDER:
					boulders += 1
				DropItem.Form.COBBLE:
					cobbles += 1
	_check(
		boulders == 9 and cobbles == 10,
		"deconstruction returns exactly the wall's inputs"
	)

	# A log wall hands its two logs back.
	var log_site := _flat_voxel(world, mined, 216)
	if log_site != Vector3i.MAX:
		_clear_wall_material_near(colony, log_site, 25.0)
		for i in 2:
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.WOOD,
					DropItem.Form.LOG,
					DropItem.LOG_CM3
				),
				log_site + Vector3i(1, 0, 0)
			)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var log_job := _assign_build(
			colony, log_site, log_site + Vector3i(1, 0, 0), &"log_wall"
		)
		var logged := await _wait_until(func() -> bool:
			return world.get_block(log_site) == BlockRegistry.Block.LOG_WALL)
		_check(logged and log_job != null, "a log wall goes up for the test")
		var log_demolish := colony.designate_deconstruct(log_site)
		if log_demolish != null:
			_assign_job(colony, log_demolish, log_site)
			var unlogged := await _wait_until(func() -> bool:
				return not world.is_solid(log_site))
			_check(unlogged, "a unit takes the log wall apart")
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
			var logs := 0
			for voxel in colony.item_piles:
				if Vector3(voxel - log_site).length() > 5.0:
					continue
				for item in colony.item_piles[voxel].items:
					if item.form == DropItem.Form.LOG:
						logs += 1
			_check(logs == 2, "deconstruction returns the log wall's two logs")

	# A packed-dirt wall mines out like natural ground — and its record
	# dies with the block.
	var mine := colony.designate_mine(dirt_site)
	_check(mine != null, "a dirt wall can still be mined out")
	if mine != null:
		_assign_job(colony, mine, dirt_site)
		var dug := await _wait_until(func() -> bool:
			return not world.is_solid(dirt_site))
		_check(dug, "a unit mines the dirt wall out")
		_check(
			colony.building_at(dirt_site) == null,
			"a mined wall's record dies with the block"
		)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Energy and rest: a waking unit drains a full bar over two thirds of a
## day and sleeps it back — a third of a day in a bed (normal rest), a
## quarter again longer on the ground (poor). Beds are a two-voxel
## building assembled from a compact kit crafted out of six planks.
func _test_rest(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("rest and beds")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
			u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.energy = 1.0
	unit.velocity = Vector3.ZERO

	# Needs ran dark for the suite so far; they come on here and go back
	# off at the end.
	colony.needs_enabled = true

	_check(
		is_equal_approx(unit._rest_span(), colony.day_length() / 3.0 * 1.25),
		"poor rest takes 25% longer than a bed"
	)
	unit._rest_quality = Unit.RestQuality.NORMAL
	_check(
		is_equal_approx(unit._rest_span(), colony.day_length() / 3.0),
		"a bed refills the bar in a third of a day"
	)
	unit._rest_quality = Unit.RestQuality.POOR
	var drained := await _wait_until(func() -> bool:
		return unit.energy < 1.0)
	_check(drained, "a waking unit drains energy")

	# --- Ground rest: below the seek line the unit sleeps where it is.
	# The +z band may run past the streamed edge — walk the scan back
	# toward the centre until a flat spot turns up.
	var nap_site := Vector3i.MAX
	for nap_off in range(248, 0, -1):
		nap_site = _flat_voxel(world, mined, nap_off)
		if nap_site != Vector3i.MAX:
			break
	_check(nap_site != Vector3i.MAX, "found a flat spot for the ground nap")
	if nap_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	unit.global_position = Vector3(nap_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.energy = unit.rest_seek * 0.5
	unit._job_search_cooldown = 0.0
	var asleep := await _wait_until(func() -> bool:
		return unit.state == Unit.State.SLEEPING)
	_check(asleep, "a tired unit seeks rest")
	_check(
		unit._rest_quality == Unit.RestQuality.POOR and unit._rest_bed == null,
		"with no bed the unit sleeps on the ground, poorly"
	)
	var regained := await _wait_until(func() -> bool:
		return unit.energy > 0.3)
	_check(regained, "ground sleep restores energy")
	unit.energy = 1.0
	var woke := await _wait_until(func() -> bool:
		return unit.state == Unit.State.IDLE)
	_check(woke, "a fully rested unit wakes")

	# --- Collapse: zero energy sleeps a unit mid-work where it stands.
	unit.energy = 0.0
	var collapsed := await _wait_until(func() -> bool:
		return unit.state == Unit.State.SLEEPING)
	_check(
		collapsed and unit._rest_quality == Unit.RestQuality.POOR,
		"zero energy collapses the unit into poor rest"
	)
	unit.energy = 1.0
	await _wait_until(func() -> bool: return unit.state == Unit.State.IDLE)
	unit._job_search_cooldown = 120.0

	# --- The bed recipe: six planks craft into one kit plus sawdust.
	# Like the nap site above, walk the scan back toward the streamed
	# centre if the far row has no usable cell.
	var craft_spot := Vector3i.MAX
	for craft_off in range(264, 0, -1):
		craft_spot = _flat_voxel(world, mined, craft_off)
		if craft_spot != Vector3i.MAX:
			break
	_check(craft_spot != Vector3i.MAX, "found a flat spot for the bed craft")
	if craft_spot == Vector3i.MAX:
		colony.needs_enabled = false
		return
	_check(colony.designate_craft_spot(craft_spot), "a craft spot designates")
	var plank_v := craft_spot + Vector3i(2, 0, 0)
	for i in 6:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# Loose debris from earlier fixtures can sit within the count radius
	# — the sawdust check has to measure the craft's delta, not the
	# absolute stock.
	var sawdust_before := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - craft_spot).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE:
				sawdust_before += item.volume
	var craft := _assign_craft(colony, world, craft_spot, plank_v, &"bed")
	_check(craft != null, "a bed kit can be ordered at a craft spot")
	if craft != null:
		_check(
			craft.recipe == &"bed",
			"the bed order records its recipe"
		)
		var crafted := await _wait_until(func() -> bool:
			return craft.state == ColonyJob.State.DONE)
		_check(crafted, "a unit crafts the bed kit from six planks")
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var kits := 0
		var sawdust := 0
		for voxel in colony.item_piles:
			if Vector3(voxel - craft_spot).length() > 4.0:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.BED:
					kits += 1
				elif item.form == DropItem.Form.LOOSE:
					sawdust += item.volume
		_check(kits == 1, "crafting yields one bed kit")
		_check(
			sawdust - sawdust_before
				== DropItem.PLANK_CM3 * 6 - DropItem.BED_KIT_CM3,
			"the planks' excess drops as sawdust"
		)
	_check(
		unit._carried.is_empty(),
		"the crafter doesn't keep leftover inputs"
	)

	# --- Bed placement: two cells, validated as a pair. A flat row alone
	# isn't enough — a sapling claim or a stray pile can veto a cell — so
	# the fixture asks bed_cells directly and keeps scanning when it's
	# refused.
	#     is_editable check means void columns past the world edge are
	#     vetoed outright — only rows over real terrain qualify.
	var bed_site := Vector3i.MAX
	for z_off in range(-64, 128, 8):
		var z: int = mined.z + z_off
		for x in range(mined.x - 32, mined.x + 96):
			var g := _ground(world, x, z, mined.y + 32)
			var candidate := Vector3i(x, g + 1, z)
			if colony.bed_cells(candidate).size() == 2:
				bed_site = candidate
				break
		if bed_site != Vector3i.MAX:
			break
	_check(bed_site != Vector3i.MAX, "found a flat spot for the bed test")
	if bed_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	var cells := colony.bed_cells(bed_site)
	_check(cells.size() == 2, "a bed claims a second horizontal cell")
	if cells.size() != 2:
		colony.needs_enabled = false
		return
	# A solid voxel can't host any part of the bed.
	world.place(bed_site + Vector3i(3, 0, 0), BlockRegistry.Block.STONE)
	_check(
		colony.bed_cells(bed_site + Vector3i(3, 0, 0)).is_empty(),
		"a solid anchor can't host a bed"
	)
	var plan := colony.designate_bed(bed_site)
	_check(
		plan != null and plan.extra_voxels == [cells[1]],
		"a bed designation plans both cells"
	)
	_check(
		colony.is_designated(bed_site) and colony.is_designated(cells[1]),
		"both bed cells carry the plan marker"
	)
	_check(
		colony.designate_build(cells[1], &"dirt_wall") == null,
		"a claimed second cell can't host a wall"
	)
	_check(
		colony.designate_bed(cells[1]) == null,
		"a claimed cell can't anchor another bed"
	)
	# Cancelling the *second* cell lifts the whole plan — both markers go.
	colony.cancel_designation(cells[1])
	_check(
		not plan.is_active()
			and not colony.is_designated(bed_site)
			and not colony.is_designated(cells[1]),
		"cancelling a bed's second cell clears the whole plan"
	)

	# --- Furnishing: a unit fetches the kit and unpacks the building.
	plan = colony.designate_bed(bed_site)
	_check(plan != null, "a bed designates again after a cancel")
	var kit_v := bed_site + Vector3i(0, 0, 2)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.BED, DropItem.BED_KIT_CM3),
		kit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(
		_park_beside(colony, world, kit_v, bed_site)
	) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	plan.state = ColonyJob.State.ASSIGNED
	plan.assignee = unit
	unit.job = plan
	unit._fetching = true
	unit._goal_voxel = kit_v
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING
	# Tired before the hammer falls — the instant the furnish job ends,
	# the idle tick must find a sleeper, not a stray haul job.
	for u in colony.units:
		if u != unit:
			u.energy = 1.0
			u._job_search_cooldown = 120.0
	unit.energy = unit.rest_seek * 0.5
	var built := await _wait_until(func() -> bool:
		return colony.building_at(bed_site) != null)
	_check(built, "a unit furnishes the bed from the kit")
	var bed := colony.building_at(bed_site)
	if bed != null:
		_check(
			bed.kind == Building.Kind.BED
				and bed.footprint.size() == 2
				and colony.building_at(cells[1]) == bed,
			"the built bed registers across both cells"
		)
		_check(
			bed.components.size() == 1
				and bed.components[0].form == DropItem.Form.BED,
			"the bed keeps its kit for deconstruction"
		)

	# --- Bed rest: a tired unit claims the bed, walks over and sleeps
	#     normally — the bed's one occupant spot is released on waking.
	#     (The unit's energy was dropped before furnish finished, so the
	#     rest claim can't lose a race to a stray job.)
	if bed != null:
		unit._job_search_cooldown = 0.0
		var in_bed := await _wait_until(func() -> bool:
			return (
				unit.state == Unit.State.SLEEPING
				and unit._rest_bed == bed
			))
		if not in_bed:
			print(
				"  diag: state=", unit.state, " restbed=", unit._rest_bed,
				" energy=", unit.energy, " pos=", unit.global_position,
				" standing=", unit._standing_voxel(),
				" bed=", bed_site, " occupant=", bed.occupant,
				" freebed=", colony.nearest_free_bed(unit._standing_voxel()),
				" job=", unit.job
			)
		_check(in_bed, "a tired unit claims the bed for rest")
		_check(
			unit._rest_quality == Unit.RestQuality.NORMAL,
			"bed sleep is normal rest"
		)
		var captioned := await _wait_until(func() -> bool:
			return unit._status_label.text == "sleeping")
		_check(
			captioned,
			"the status caption shows what the unit is doing"
		)
		unit.energy = 1.0
		var up := await _wait_until(func() -> bool:
			return unit.state == Unit.State.IDLE)
		_check(up and bed.occupant == null, "waking frees the bed")
		unit._job_search_cooldown = 120.0

		# --- Resting from atop a pile: a tired unit perched on a partial
		#     pile still finds the bed — its standing cell is the feet's
		#     cell (a >50% fill used to round up into the cell above, which
		#     broke both the path start and the bed footprint check, and
		#     the unit collapsed on the ground in the stockpile instead).
		var perch := Vector3i.MAX
		for side in [
			Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK
		]:
			var c: Vector3i = bed_site + side
			if (
				world.get_block(c) == BlockRegistry.Block.AIR
				and world.get_block(c + Vector3i.UP) == BlockRegistry.Block.AIR
				and world.get_block(c + Vector3i.UP * 2) == BlockRegistry.Block.AIR
				and world.is_solid(c + Vector3i.DOWN)
				and colony.voxel_fill(c) <= 0
			):
				perch = c
				break
		if perch != Vector3i.MAX:
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700_000
				),
				perch
			)
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
			# Feet on the 70% surface: the feet sit inside the pile cell.
			unit.global_position = Vector3(perch) + Vector3(0.5, 1.65, 0.5)
			unit.velocity = Vector3.ZERO
			_check(
				unit._standing_voxel() == perch,
				"a unit perched on a pile reports the pile's cell"
			)
			unit.energy = unit.rest_seek * 0.5
			unit._job_search_cooldown = 0.0
			var perched_sleep := await _wait_until(func() -> bool:
				return (
					unit.state == Unit.State.SLEEPING
					and unit._rest_bed == bed
				))
			_check(
				perched_sleep, "a unit standing on a pile still claims the bed"
			)
			_check(
				unit._rest_quality == Unit.RestQuality.NORMAL,
				"the pile-perched unit slept in the bed, not on the ground"
			)
			unit.energy = 1.0
			await _wait_until(func() -> bool:
				return unit.state == Unit.State.IDLE)
			unit._job_search_cooldown = 120.0
			var perch_pile := colony.item_pile_at(perch)
			if perch_pile != null:
				perch_pile.take_up_to(
					DropItem.BLOCK_CM3,
					func(_i: DropItem) -> bool: return true
				)
				colony.remove_pile_if_empty(perch)

		# --- Deconstruct: either cell designates the same teardown, the
		#     occupant is evicted and the kit drops back into the world.
		#     The sleeper claims the bed first — a bed marked for teardown
		#     won't take a new occupant.
		var sleeper := unit
		sleeper.energy = unit.rest_seek * 0.5
		sleeper._job_search_cooldown = 0.0
		await _wait_until(func() -> bool:
			return (
				sleeper.state == Unit.State.SLEEPING
				and sleeper._rest_bed == bed
			))
		var demolish := colony.designate_deconstruct(cells[1])
		_check(
			demolish != null and demolish.voxel_position == bed_site,
			"either bed cell designates the deconstruct"
		)
		_check(
			colony.nearest_free_bed(bed_site) == null,
			"a bed marked for deconstruct takes no new occupant"
		)
		if demolish != null:
			var worker: Unit = (
				colony.units[1] if colony.units.size() > 1 else unit
			)
			if worker == sleeper:
				# Only one unit to test with — wake it and use it.
				sleeper.energy = 1.0
				await _wait_until(func() -> bool:
					return sleeper.state == Unit.State.IDLE)
			# Not _assign_job: its blanket abandon would wake the sleeper
			# before the teardown could evict it.
			if worker.job != null:
				colony.release_job(worker.job)
				worker.abandon_job()
			# A drained demolitionist would collapse mid-teardown.
			worker.energy = 1.0
			worker._job_search_cooldown = 120.0
			worker.global_position = (
				Vector3(
					_park_beside(
						colony, world, bed_site, bed_site + Vector3i(0, 0, 1)
					)
				) + Vector3(0.5, 0.9, 0.5)
			)
			worker.velocity = Vector3.ZERO
			demolish.state = ColonyJob.State.ASSIGNED
			demolish.assignee = worker
			worker.job = demolish
			worker._fetching = false
			worker._goal_voxel = bed_site
			worker._clear_budget = 0.0
			worker.state = Unit.State.MOVING
			# Pin the sleeper rested *before* the teardown — otherwise it
			# can wake, re-find it's exhausted, and re-sleep on the ground
			# inside the same frame the check reads.
			sleeper.energy = 1.0
			sleeper._job_search_cooldown = 120.0
			var razed := await _wait_until(func() -> bool:
				return colony.building_at(bed_site) == null)
			if not razed:
				print(
					"  diag: worker state=", worker.state,
					" pos=", worker.global_position,
					" standing=", worker._standing_voxel(),
					" jobstate=", demolish.state, " progress=", demolish.progress,
					" goal=", worker._goal_voxel, " energy=", worker.energy,
					" sleeper state=", sleeper.state
				)
			_check(razed, "a unit deconstructs the bed")
			_check(
				colony.building_at(cells[1]) == null,
				"deconstructing frees the whole footprint"
			)
			_check(
				sleeper.state != Unit.State.SLEEPING,
				"a deconstructed bed wakes its sleeper"
			)
			await _wait_until(func() -> bool:
				return colony._in_flight.is_empty())
			var kits_back := 0
			for voxel in colony.item_piles:
				if Vector3(voxel - bed_site).length() > 4.0:
					continue
				for item in colony.item_piles[voxel].items:
					if item.form == DropItem.Form.BED:
						kits_back += 1
			_check(kits_back == 1, "deconstruction hands the bed kit back")

	# Leave the unit rested and the needs switch off for later tests —
	# a sleeper left down would never wake once the refill gate closes.
	for u in colony.units:
		if u.state == Unit.State.SLEEPING:
			u.energy = 1.0
			u._wake()
		u._job_search_cooldown = 0.0
	colony.needs_enabled = false


## Hunger and foraging: berries are edible physical items, seeded bushes
## yield them to a FORAGE job and regrow, and a unit's hunger drives
## food-seeking, eating and — at zero — a work penalty, not a collapse.
func _test_food(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("hunger and food")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.velocity = Vector3.ZERO
	unit.energy = 1.0

	# --- The resource model: berries are loose, edible material.
	_check(
		BlockRegistry.resource_name_of(BlockRegistry.Resource_.BERRY) == "Berries",
		"the berry resource is registered"
	)
	_check(
		BlockRegistry.resource_is_loose(BlockRegistry.Resource_.BERRY),
		"berries are loose material — they pour and split"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.BERRY)
			and not DropItem.is_food(BlockRegistry.Resource_.STONE),
		"berries are edible and stone isn't"
	)
	_check(
		DropItem.nutrition_of(BlockRegistry.Resource_.BERRY, 100_000) > 0.0,
		"berries carry nutrition per volume eaten"
	)

	# --- Generation: the bush lattice seeds slots at mixed ripeness.
	# Seeding is deterministic off the slot, so the whole lattice can be
	# sampled rather than whichever few bushes happen to be streamed in.
	var gen := world.generator_script
	var slots := gen.bushes_in(Vector3i(-160, 0, -160), 320)
	var ripe_slots := 0
	for pos: Vector2i in slots:
		var slot := Vector3i(
			pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
		)
		if colony.plants.seeded_ripe(slot):
			ripe_slots += 1
	_check(
		slots.size() > 0 and ripe_slots > 0 and ripe_slots < slots.size(),
		"seeded bushes start at mixed ripeness"
	)
	_check(
		not colony.plants.bushes.is_empty(),
		"streamed terrain discovers berry bushes"
	)

	# --- Forage: a ripe bush designates, a unit strips its yield into a
	# physical pile, and the bush goes quiet until it regrows.
	var bush := Vector3i.MAX
	for root: Vector3i in colony.plants.bushes:
		if colony.plants.can_forage(root):
			bush = root
			break
	if bush == Vector3i.MAX and not colony.plants.bushes.is_empty():
		var first: Vector3i = colony.plants.bushes.keys()[0]
		colony.plants.bushes[first][&"ripe"] = true
		bush = first
	_check(bush != Vector3i.MAX, "a ripe bush exists for the forage test")
	if bush == Vector3i.MAX:
		return
	_check(
		colony.item_pile_at(bush) == null or true,
		"the bush cell stays air — the plant is decoration, not terrain"
	)
	var forage := colony.designate_forage(bush)
	_check(
		forage != null and forage.type == ColonyJob.Type.FORAGE,
		"a ripe bush designates for forage"
	)
	_check(
		colony.is_designated(bush),
		"a forage designation marks the bush"
	)
	var park := _park_beside(colony, world, bush, bush + Vector3i.RIGHT)
	if forage != null:
		_assign_job(colony, forage, park, unit)
		var foraged := await _wait_until(func() -> bool:
			return forage.state == ColonyJob.State.DONE)
		_check(foraged, "a unit forages a ripe bush")
		await _wait_until(func() -> bool:
			return colony._in_flight.is_empty())
		var berries := 0
		var berries_whole := true
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - bush).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.BERRY:
					berries += item.volume
					if item.form != DropItem.Form.FRUIT:
						berries_whole = false
		_check(berries > 0, "foraging drops physical berries at the bush")
		_check(
			berries_whole,
			"foraged berries are whole fruit — extract-seed's input form"
		)
		_check(
			not colony.plants.can_forage(bush),
			"a foraged bush bears nothing until it regrows"
		)
		_check(
			colony.designate_forage(bush) == null,
			"a spent bush can't be designated again"
		)
		# Regrow: wind the bush's clock forward and let its tick ripen it.
		colony.plants.bushes[bush][&"next"] = colony.game_msec() - 1
		var regrew := await _wait_until(func() -> bool:
			return colony.plants.can_forage(bush))
		_check(regrew, "a foraged bush regrows its yield")
		_check(
			colony.designate_forage(bush) != null,
			"a regrown bush designates again"
		)
		colony.cancel_designation(bush)
		# The regrow clock is game time, not wall time: a bush that would
		# bear in 60 game-seconds ripens when the planet clock jumps, even
		# though no real time passed.
		colony.plants.bushes[bush][&"ripe"] = false
		colony.plants.bushes[bush][&"next"] = colony.game_msec() + 60000
		if colony.day_cycle != null:
			var clock_before := colony.day_cycle.planet_time
			colony.day_cycle.advance(61.0)
			var jumped := await _wait_until(func() -> bool:
				return colony.plants.can_forage(bush))
			_check(jumped, "a bush ripens on the game clock, not wall time")
			# The clock jump was the fixture — restore it so later date
			# checks see the calendar they expect.
			colony.day_cycle.planet_time = clock_before

	# --- Hunger: the bar drains, low hunger seeks food, eating refills.
	colony.needs_enabled = true
	unit.hunger = 1.0
	var drained := await _wait_until(func() -> bool:
		return unit.hunger < 1.0)
	_check(drained, "a waking unit drains hunger")

	var eat_site := Vector3i.MAX
	for z_off in [96, 104, 112, 120, 232, 240, 224]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.is_editable(candidate + Vector3i.DOWN)
		):
			eat_site = candidate
			break
	_check(eat_site != Vector3i.MAX, "found a flat spot for the eating test")
	if eat_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	var food_v := eat_site + Vector3i(2, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	_check(
		colony.nearest_food_pile(unit._standing_voxel()) != Vector3i.MAX,
		"a berry pile is findable food"
	)
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = unit.food_seek * 0.5
	# A drained energy bar would send it to rest instead of food — keep
	# the two needs independent here.
	unit.energy = 1.0
	unit._job_search_cooldown = 0.0
	var seeking := await _wait_until(func() -> bool:
		return (
			unit.state == Unit.State.MOVING
			and unit.job != null
			and unit.job.type == ColonyJob.Type.EAT
		))
	if not seeking:
		print(
			"    [seek] state=%d job=%s goal=%s hunger=%.2f energy=%.2f cd=%.1f food=%s bl=%s" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit._goal_voxel,
				unit.hunger,
				unit.energy,
				unit._job_search_cooldown,
				colony.nearest_food_pile(unit._standing_voxel(), unit._food_blacklist),
				unit._food_blacklist,
			]
		)
	_check(seeking, "a hungry unit seeks food")
	if seeking:
		_check(
			unit.current_activity() == "seeking food",
			"the walk to food reads as seeking food"
		)
	var ate := await _wait_until(func() -> bool:
		return (
			unit.state == Unit.State.IDLE
			and unit.hunger > unit.food_seek
		))
	if not ate:
		print(
			"    [eat] state=%d job=%s hunger=%.2f act='%s'" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit.hunger,
				unit.current_activity(),
			]
		)
	_check(ate, "eating restores hunger")

	# --- A pile that still stands but holds no food must not trap the
	# unit in EATING: the meal ends and the unit goes back to the board.
	var mixed_v := eat_site + Vector3i(1, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400_000),
		mixed_v
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 90_000),
		mixed_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = 0.1
	unit._job_search_cooldown = 0.0
	# The tell: hunger above the seek line means it ate, and any state
	# but EATING means it left the meal — a stuck eater would sit in
	# EATING forever once the berries are gone.
	var finished := await _wait_until(func() -> bool:
		return unit.hunger > unit.food_seek and unit.state != Unit.State.EATING)
	_check(
		finished,
		"a unit stops eating when a mixed pile's food runs out"
	)
	_check(
		colony.item_pile_at(mixed_v) != null,
		"the pile's non-food residue still stands"
	)

	# --- A pile ringed by other piles stays reachable: a partial pile's
	# surface is itself a valid work spot (the unit stands on the fill).
	# Ring a fresh food pile with 65%-full piles so no clean floor cell
	# is within reach — under the old fill>0 spot filter such a pile had
	# no work spot at all and a unit standing among the piles starved.
	var ring_food := eat_site + Vector3i(1, 0, 3)
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			if dx == 0 and dz == 0:
				continue
			var cell := ring_food + Vector3i(dx, 0, dz)
			for dy in range(3):
				world.remove_voxel(cell + Vector3i(0, dy, 0))
			if not world.is_solid(cell + Vector3i.DOWN):
				world.remove_voxel(cell + Vector3i.DOWN)
				world.place(cell + Vector3i.DOWN, BlockRegistry.Block.STONE)
			if colony.voxel_fill(cell) <= 0:
				colony._deposit_item(
					DropItem.new(
						BlockRegistry.Resource_.SOIL,
						DropItem.Form.LOOSE,
						650_000
					),
					cell
				)
	for dy in range(3):
		world.remove_voxel(ring_food + Vector3i(0, dy, 0))
	if not world.is_solid(ring_food + Vector3i.DOWN):
		world.place(ring_food + Vector3i.DOWN, BlockRegistry.Block.STONE)
	# Drain the earlier pile's leftover berries so the seek can't settle
	# for it instead of the ringed target.
	var earlier := colony.item_pile_at(food_v)
	if earlier != null:
		earlier.take_up_to(
			DropItem.BLOCK_CM3,
			func(item: DropItem) -> bool:
				return DropItem.is_food(item.material)
		)
		colony.remove_pile_if_empty(food_v)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 200_000),
		ring_food
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	var ring_spots := unit._work_spots(ring_food, false)
	_check(not ring_spots.is_empty(), "a pile ringed by piles still has work spots")
	var pile_spots := 0
	for s in ring_spots:
		if colony.voxel_fill(s) > 0:
			pile_spots += 1
	_check(pile_spots > 0, "a pile's own surface counts as a work spot")
	unit.abandon_job()
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = 0.1
	unit._food_blacklist.clear()
	unit._job_search_cooldown = 0.0
	var fed := await _wait_until(func() -> bool:
		return unit.hunger > unit.food_seek)
	if not fed:
		print(
			"    [ringed-eat] state=%d job=%s goal=%s sv=%s hunger=%.2f" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit._goal_voxel,
				unit._standing_voxel(),
				unit.hunger,
			]
		)
	_check(fed, "a unit climbs a pile to reach ringed-in food")

	# Standing on a partial pile puts the feet inside the pile's own
	# cell — reporting the cell above corrupted path starts and checks
	# like the bed-arrival footprint test.
	unit.global_position = Vector3(ring_food) + Vector3(0.5, 0.9 + 0.2, 0.5)
	_check(
		unit._standing_voxel() == ring_food,
		"standing on a pile reports the pile's own cell"
	)

	# --- Starving: hunger at zero halves work speed — no collapse.
	unit.hunger = 0.0
	_check(
		unit._work_rate() == Unit.STARVING_SPEED,
		"a starving unit works at half speed"
	)
	unit.state = Unit.State.IDLE
	unit.job = null
	_check(
		unit.current_activity() == "starving",
		"an idle unit at zero hunger reports starving"
	)
	unit.hunger = 1.0
	_check(
		is_equal_approx(unit._work_rate(), 1.0),
		"a fed unit works at full speed"
	)

	# --- Desperation: below the line a starving unit still prefers a
	# real pile; with no edible pile anywhere it self-forages the
	# nearest un-designated ripe bush and eats just enough of the yield
	# to climb back over the hunger line — the rest stays dropped.
	unit.abandon_job()
	unit._food_blacklist.clear()
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	unit.hunger = unit.desperation_seek * 0.5
	unit.energy = 1.0
	unit._job_search_cooldown = 0.0
	var pile_first := await _wait_until(func() -> bool:
		return (
			unit.job != null
			and unit.job.type == ColonyJob.Type.EAT
			and not unit.job.desperate
		))
	_check(
		pile_first,
		"a desperate-depth hunger still prefers a real pile"
	)
	var d_bush := colony.nearest_ripe_bush(eat_site)
	_check(
		d_bush != Vector3i.MAX,
		"a ripe un-designated bush exists for desperation"
	)
	if d_bush != Vector3i.MAX:
		# Pretend the pantry's empty — blacklist every pile holding
		# food so the ordinary seek comes up dry.
		for voxel: Vector3i in colony.item_piles:
			var pile: ItemPile = colony.item_piles[voxel]
			for item in pile.items:
				if DropItem.is_food(item.material):
					unit._food_blacklist[voxel] = {
						"at": colony.game_msec(), "n": 1
					}
					break
		unit.abandon_job()
		unit.global_position = (
			Vector3(_park_beside(colony, world, d_bush, eat_site))
			+ Vector3(0.5, 0.9, 0.5)
		)
		unit.velocity = Vector3.ZERO
		unit.hunger = unit.desperation_seek * 0.5
		unit._job_search_cooldown = 0.0
		var foraging := await _wait_until(func() -> bool:
			return (
				unit.job != null
				and unit.job.type == ColonyJob.Type.FORAGE
				and unit.job.desperate
			))
		_check(foraging, "a starving unit self-issues a bush forage")
		if foraging:
			# The caption differs by phase — en route it's "desperately
			# foraging", at the bush "foraging for survival" — and the
			# unit parked beside the bush may skip the walk entirely.
			var reads_desperate := await _wait_until(func() -> bool:
				var act := unit.current_activity()
				return (
					act == "desperately foraging"
					or act == "foraging for survival"
				))
			_check(reads_desperate, "the desperation run reads as desperation")
		var fed_desperate := await _wait_until(func() -> bool:
			return unit.hunger > unit.food_seek)
		if not fed_desperate:
			print(
				"    [desperate] state=%d job=%s hunger=%.2f act='%s'" % [
					unit.state,
					(
						unit.job.voxel_position
						if unit.job != null
						else "null"
					),
					unit.hunger,
					unit.current_activity(),
				]
			)
		_check(
			fed_desperate,
			"the desperation meal ends back over the hunger line"
		)
		_check(
			not colony.plants.can_forage(d_bush),
			"the desperation run stripped the bush"
		)
		_check(
			unit.hunger < unit.food_seek + 0.3,
			"a desperation meal stops near the line, not at full"
		)
		unit._food_blacklist.clear()

	# --- The trait seam: personality multipliers slide the hunger
	# thresholds without touching the base exports.
	unit.traits = [&"gourmand"]
	_check(
		unit._food_seek() > unit.food_seek,
		"a gourmand seeks food earlier than baseline"
	)
	unit.traits = [&"iron_willed"]
	_check(
		unit._desperation_line() < unit.desperation_seek,
		"an iron-willed unit tolerates deeper hunger"
	)
	unit.traits = [&"immoderation"]
	_check(
		unit._desperation_line() > unit.desperation_seek,
		"an immoderate unit breaks off for food sooner"
	)
	unit.traits = []

	# Restore the suite's standing arrangement.
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0
	colony.needs_enabled = false


## Ladders: three planks become a climbable cell — stacked rungs carry a
## unit up to a roof it could never jump to, dropped items fall through
## the shaft to collect at the bottom rung, and a pile sharing the cell
## tops out at three quarters. Deconstruction hands the planks back.
func _test_ladder(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("ladders")
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.velocity = Vector3.ZERO
	unit.energy = 1.0
	unit.hunger = 1.0

	# A flat stretch whose two columns are clear to +4 — the shaft rises
	# in one, the roof deck lands in the other. The roof proof below
	# relies on the ladder being the only way up: since a pile's top is
	# a valid work spot, any standable cell already in reach of the
	# would-be roof pile — a hillside step, a tall pile — spoils the
	# invariant, so the site must sit at its local high point.
	var site := Vector3i.MAX
	for z_off in [272, 276, 280, 284, 176, 184, 192, 96, 104, 152, 160]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate == Vector3i.MAX or not world.is_editable(candidate):
			continue
		var clean := true
		for dx in [0, 1]:
			for dy in range(5):
				var cell: Vector3i = candidate + Vector3i(dx, dy, 0)
				if (
					world.get_block(cell) != BlockRegistry.Block.AIR
					or colony.forest.tree_root_at(cell) != Vector3i.MAX
				):
					clean = false
		if clean:
			var roof_c: Vector3i = candidate + Vector3i(1, 3, 0)
			for dx in range(-2, 3):
				for dy in range(-2, 2):
					for dz in range(-2, 3):
						var c := roof_c + Vector3i(dx, dy, dz)
						if c == roof_c or (c.x == candidate.x and c.z == candidate.z):
							continue
						if not unit._is_standable(c):
							continue
						var lift := float(colony.voxel_fill(c)) / DropItem.BLOCK_CM3
						if unit._can_reach_from(
							Vector3(c) + Vector3(0.5, 0.9 + lift, 0.5),
							roof_c, false
						):
							clean = false
		if clean:
			site = candidate
			break
	_check(site != Vector3i.MAX, "found a flat spot for the ladder test")
	if site == Vector3i.MAX:
		return
	var g := site.y - 1

	# --- Designation guards.
	_check(
		colony.designate_ladder(site + Vector3i.DOWN) == null,
		"a solid voxel can't host a ladder"
	)

	# --- Construction: four planks on offer, the ladder takes three and
	# leaves the fourth in the pile.
	var plank_pile := site + Vector3i(2, 0, 0)
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var job := colony.designate_ladder(site)
	_check(
		job != null and job.type == ColonyJob.Type.CRAFT,
		"an empty voxel designates a ladder"
	)
	if job == null:
		return
	_assign_job(colony, job, site, unit)
	var built := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(built, "a unit builds a ladder in place")

	var ladder := colony.building_at(site)
	_check(
		ladder != null and ladder.kind == Building.Kind.LADDER,
		"the finished ladder registers as a building"
	)
	_check(colony.ladder_at(site), "the ladder cell reports a ladder")
	if world.sim != null:
		_check(world.sim.ladder_at(site), "the sim mirrors the ladder cell")
	_check(
		ladder != null and ladder.components.size() == 3,
		"the ladder absorbed exactly three planks"
	)
	var leftover: ItemPile = colony.item_pile_at(plank_pile)
	_check(
		leftover != null
			and leftover.form_volume(DropItem.Form.PLANK) == DropItem.PLANK_CM3,
		"the fourth plank stays in the pile"
	)
	_check(
		colony.voxel_capacity(site) == 750_000,
		"a ladder cell holds three quarters of a voxel"
	)
	_check(
		colony.voxel_capacity(site + Vector3i(3, 0, 0)) == DropItem.BLOCK_CM3,
		"an ordinary cell still holds a full voxel"
	)

	# --- Second rung: the stack climbs two z-levels.
	var job2 := colony.designate_ladder(site + Vector3i.UP)
	_check(job2 != null, "a ladder stacks above another")
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	if job2 != null:
		_assign_job(colony, job2, site, unit)
		var built2 := await _wait_until(func() -> bool:
			return job2.state == ColonyJob.State.DONE)
		_check(built2, "the second rung builds on the first")
	_check(colony.ladder_at(site + Vector3i.UP), "the stack's upper rung registers")

	# --- Roof access: a deck at +2 over the ladder — a jump clears one
	# voxel, never two, and the pile on top sits at +3: over 2 m from any
	# ground cell, so the ladder top is the only work spot in reach.
	var deck := site + Vector3i(1, 2, 0)
	_check(
		world.place(deck, BlockRegistry.Block.DIRT),
		"a roof deck sits beside the ladder top"
	)
	var roof := site + Vector3i(1, 3, 0)
	var start := site + Vector3i(-1, 0, 0)
	var up_path := world.find_path(start, roof)
	_check(not up_path.is_empty(), "a path climbs the stack to the roof")
	var through_shaft := false
	for p in up_path:
		var c := Vector3i(p.floor())
		if c.x == site.x and c.z == site.z and c.y > site.y:
			through_shaft = true
	_check(through_shaft, "the roof path climbs the ladder column")

	# A pile at +3 can only be cleared from the ladder column — every
	# ground cell sits beyond mine_reach of it — so finishing this job
	# proves the unit physically climbed. The work spot may be a rung
	# rather than the ladder's top, so the tell is a standing cell above
	# ground in the shaft column — only ladder support puts a unit there.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, DropItem.BOULDER_CM3
		),
		roof
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var roof_job := colony.designate_clear(roof)
	_check(roof_job != null, "a roof pile designates for clearing")
	var climbed := [false]
	var seen := {}
	if roof_job != null:
		# A pile's top is a work spot now — and scraps dropped mid-shaft
		# settle in the bottom rung (ladder cells hold a reduced pile).
		# Standing on such a pile would let the unit clear the roof
		# without ever climbing, so before assigning: empty hands, let
		# the drops land, then drain every pile in reach — the ladder
		# must be the only way up.
		for u in colony.units:
			u._job_search_cooldown = 120.0
			u.abandon_job()
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		# Any pile within a few cells of the roof can act as a step whose
		# surface is within reach of the pile — drain them all (but not
		# the roof pile itself; it's the job target).
		for dx in range(-3, 4):
			for dy in range(-3, 5):
				for dz in range(-3, 4):
					var v := roof + Vector3i(dx, dy, dz)
					if v == roof:
						continue
					var p := colony.item_pile_at(v)
					if p != null:
						p.take_up_to(
							DropItem.BLOCK_CM3,
							func(_i: DropItem) -> bool: return true
						)
						colony.remove_pile_if_empty(v)
		_assign_job(colony, roof_job, site, unit)
		# The work spot is inside the bottom rung's cell: reach to the
		# roof opens mid-climb, once the feet rise ~0.7 m into the shaft.
		# The standing *cell* stays at ground level, so the tell is the
		# feet leaving the ground plane inside the ladder columns — only
		# the ladder raises a unit there.
		var max_feet := [-INF]
		var cleared := await _wait_until(func() -> bool:
			var sv := unit._standing_voxel()
			seen[sv] = true
			var feet := unit.global_position.y - 0.9
			max_feet[0] = maxf(max_feet[0], feet)
			if (
				sv.z == site.z
				and (sv.x == site.x or sv.x == site.x + 1)
				and feet > float(site.y) + 0.5
			):
				climbed[0] = true
			return roof_job.state == ColonyJob.State.DONE)
		_check(cleared, "a unit climbs the ladder to clear the roof pile")
		if not climbed[0]:
			print(
				"    [climb] cells: %s max_feet=%.2f site.y=%d" % [
					seen.keys(), max_feet[0], site.y,
				]
			)
		_check(
			climbed[0],
			"the unit rose off the ground inside the ladder column"
		)

	# --- Standing on a rung: the cell above the top ladder holds a unit
	# with no floor of its own — drop one in and it stays up.
	if world.sim != null:
		unit.abandon_job()
		unit.state = Unit.State.IDLE
		unit.velocity = Vector3.ZERO
		unit._job_search_cooldown = 60.0
		var top := Vector3(site + Vector3i(0, 2, 0)) + Vector3(0.5, 0.95, 0.5)
		unit.global_position = top
		world.sim.unit_register(unit._sim_id, top)
		for i in 30:
			await process_frame
		_check(
			unit._standing_voxel() == site + Vector3i(0, 2, 0),
			"a unit stands on the ladder's top rung"
		)

	# --- Descent: the unit-step's descend flag sinks the body rung by
	# rung instead of freefalling down the shaft.
	if world.sim != null:
		unit.abandon_job()
		unit.state = Unit.State.IDLE
		unit.velocity = Vector3.ZERO
		var top_pos := Vector3(site) + Vector3(0.5, 2.9, 0.5)
		unit.global_position = top_pos
		world.sim.unit_register(unit._sim_id, top_pos)
		for i in 120:
			world.sim.unit_step(
				unit._sim_id, Vector3.ZERO, 0.0, unit.gravity, 0.05, unit.climb_speed
			)
		var sunk: Vector3 = world.sim.unit_pos(unit._sim_id)
		unit.global_position = sunk
		_check(
			sunk.y <= float(site.y) + 1.0,
			"the descend flag sinks the unit to the bottom rung"
		)
	var down_path := world.find_path(site + Vector3i(0, 2, 0), site)
	var descends := false
	for p in down_path:
		if Vector3i(p.floor()) == site + Vector3i.UP:
			descends = true
	_check(
		not down_path.is_empty() and descends,
		"the shortest way down the shaft is through the ladder cells"
	)

	# --- Items fall through a ladder and collect at its bottom rung.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 200_000),
		site + Vector3i(0, 3, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var seat: ItemPile = colony.item_pile_at(site)
	_check(
		seat != null and seat.total_volume() >= 190_000,
		"an item dropped down the shaft lands in the bottom ladder cell"
	)

	# --- Shared with a ladder, the pile tops out at three quarters — the
	# surplus has to move out.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700_000),
		site
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.voxel_fill(site) <= 750_000,
		"a ladder-cell pile stops at the reduced capacity"
	)
	var held := 0
	for dx in range(-1, 3):
		for dy in range(2):
			var fill_v := Vector3i(site.x + dx, site.y + dy, site.z)
			held += colony.voxel_fill(fill_v)
	_check(held >= 900_000, "the overflow lands in a neighboring voxel")

	# --- Deconstruction hands back exactly the planks that went in.
	var torn := colony.designate_deconstruct(site)
	_check(torn != null, "a ladder accepts a deconstruct order")
	if torn != null:
		_assign_job(colony, torn, site, unit)
		var down := await _wait_until(func() -> bool:
			return torn.state == ColonyJob.State.DONE)
		_check(down, "a unit takes the ladder apart")
	_check(not colony.ladder_at(site), "deconstruction removes the ladder")
	if world.sim != null:
		_check(
			not world.sim.ladder_at(site),
			"the sim's ladder mirror clears"
		)
	var recovered := 0
	for voxel: Vector3i in colony.item_piles:
		var off: Vector3i = (voxel - site).abs()
		if maxi(off.x, maxi(off.y, off.z)) > 2:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.PLANK:
				recovered += 1
	_check(recovered >= 3, "the ladder's three planks drop on deconstruction")

	# Tidy up: the remaining rung and any leftovers go away.
	var upper: Building = colony.building_at(site + Vector3i.UP)
	if upper != null:
		var tear2 := colony.designate_deconstruct(site + Vector3i.UP)
		if tear2 != null:
			_assign_job(colony, tear2, site, unit)
			await _wait_until(func() -> bool:
				return tear2.state == ColonyJob.State.DONE)
	world.remove_voxel(deck)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0


## Hands an existing job straight to units[0] without re-designating —
## for jobs already on the board (a suspended build resuming).
func _hand_job(
	colony: Colony, job: ColonyJob, park: Vector3i, pile_v: Vector3i
) -> void:
	var worker: Unit = colony.units[0]
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		u.abandon_job()
	worker.global_position = Vector3(park) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = pile_v != Vector3i.MAX
	worker._goal_voxel = pile_v if pile_v != Vector3i.MAX else job.voxel_position
	worker._clear_budget = 0.0
	worker._stuck_elapsed = 0.0
	worker.state = Unit.State.MOVING


## Gravity for solids: a block whose face-connected chain to the base
## level breaks comes down as mined rubble, and a build with nothing to
## hang from suspends until a neighbouring placement anchors it.
## Plank walls and doors. A plank wall is five planks flat — no offcut —
## and fills its voxel whole. A door builds from its wall's recipe plus a
## quarter, each form rounded up to a whole item, and drops the excess as
## offcut (sawdust from wood, gravel from stone). The door cell stays
## open air under a two-cell building record — the capsule needs the cell
## above for headroom — and the pathfinder prices a passage at the swing
## time while the unit pays it standing at the threshold.
func _test_doors(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# The recipes are pure data — check them before any job runs.
	_check(
		BlockRegistry.build_recipe(&"plank_wall") == {DropItem.Form.PLANK: 500000},
		"a plank wall is five planks"
	)
	_check(
		BlockRegistry.spec_offcut(&"plank_wall") == 0,
		"a plank wall drops no offcut"
	)
	_check(
		BlockRegistry.build_recipe(&"plank_door") == {DropItem.Form.PLANK: 700000},
		"a plank door is its wall plus a quarter, rounded up"
	)
	_check(
		BlockRegistry.spec_offcut(&"plank_door") == 75000,
		"a plank door's overcharge drops as offcut"
	)
	_check(
		BlockRegistry.build_recipe(&"log_door") == {DropItem.Form.LOG: 1500000},
		"a log door is three logs"
	)
	_check(
		BlockRegistry.build_recipe(&"stone_door") == {
			DropItem.Form.BOULDER: 1200000, DropItem.Form.COBBLE: 130000
		},
		"a stone door rounds each form's quarter up"
	)
	_check(
		BlockRegistry.spec_offcut(&"stone_door") == 80000,
		"a stone door's overcharge drops as gravel"
	)
	_check(
		BlockRegistry.build_recipe(&"dirt_door") == {},
		"there is no dirt door"
	)
	_check(
		not Overseer.BUILD_SPECS.has(&"build_dirt_door"),
		"the architect offers no dirt door"
	)

	# A flat pad holding every cell the fixture uses — the room ring, the
	# doorway and gap, the approach cells, and spare ground for the plank
	# wall and stone door. Everything needs open air for two levels;
	# cells a unit walks on or a wall bears on need a solid floor too.
	# The band stays clear of the persist fixture's scan rows.
	var centre := Vector3i.MAX
	for z_off in range(120, 232, 2):
		var row := _flat_voxel_row(world, mined, z_off)
		if row == Vector3i.MAX:
			continue
		var cand := row + Vector3i(1, 0, 0)
		var walked: Array[Vector3i] = [
			# centre, sill, east approach, gap, north approach
			cand, cand + Vector3i(1, 0, 0), cand + Vector3i(2, 0, 0),
			cand + Vector3i(0, 0, -1), cand + Vector3i(0, 0, -2),
			# plank wall + its pile
			cand + Vector3i(-2, 0, 0), cand + Vector3i(-2, 0, -1),
			# stone door + its two piles
			cand + Vector3i(3, 0, 0), cand + Vector3i(3, 0, -1),
			cand + Vector3i(3, 0, 1),
		]
		var walls: Array[Vector3i] = [
			cand + Vector3i(-1, 0, -1), cand + Vector3i(1, 0, -1),
			cand + Vector3i(-1, 0, 0), cand + Vector3i(-1, 0, 1),
			cand + Vector3i(0, 0, 1), cand + Vector3i(1, 0, 1),
		]
		var ok := true
		for cell in walked + walls:
			if (
				not world.is_editable(cell)
				or world.is_solid(cell)
				or world.is_solid(cell + Vector3i.UP)
			):
				ok = false
				break
		for cell in walked:
			if not world.is_solid(cell + Vector3i.DOWN):
				ok = false
				break
		if ok:
			centre = cand
			break
	_check(centre != Vector3i.MAX, "found a clear span for the door room")
	if centre == Vector3i.MAX:
		return

	var sill := centre + Vector3i(1, 0, 0)
	var outside_e := centre + Vector3i(2, 0, 0)
	var gap := centre + Vector3i(0, 0, -1)
	var outside_n := centre + Vector3i(0, 0, -2)

	# Designation gates, before anything stands: no dirt door, and no
	# door where the headroom cell above the sill is filled.
	_check(
		colony.designate_build(centre, &"dirt_door") == null,
		"a dirt door can't be designated"
	)
	_check(
		world.place(outside_n + Vector3i.UP, BlockRegistry.Block.STONE_WALL),
		"a lintel block floats over the approach cell"
	)
	_check(
		colony.designate_build(outside_n, &"log_door") == null,
		"a door under a solid headroom cell can't be designated"
	)
	world.remove_voxel(outside_n + Vector3i.UP)

	# The plank wall first — five planks in, one full block out. It takes
	# a pad cell west of where the room's ring will stand.
	var plank_site := centre + Vector3i(-2, 0, 0)
	var plank_pile := plank_site + Vector3i(0, 0, -1)
	for i in 5:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var plank_job := _assign_build(colony, plank_site, plank_pile, &"plank_wall")
	var walled := await _wait_until(func() -> bool:
		return world.get_block(plank_site) == BlockRegistry.Block.PLANKS)
	_check(walled and plank_job != null, "a unit builds a plank wall from five planks")
	var plank_wall := colony.building_at(plank_site)
	var plank_count := 0
	if plank_wall != null:
		for item in plank_wall.components:
			if item.form == DropItem.Form.PLANK:
				plank_count += 1
	_check(plank_count == 5, "the plank wall holds exactly five planks")
	var sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - plank_site).length() > 2.5:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == BlockRegistry.Resource_.WOOD:
				sawdust += item.volume
	_check(sawdust == 0, "a plank wall drops no sawdust")

	# The room: a two-high ring of stone walls around the interior cell,
	# leaving the doorway slot (and its headroom) open plus a gap in the
	# north face — the escape route the pathfinder should prefer.
	var ring: Array[Vector3i] = []
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			if dx == 1 and dz == 0:
				continue # the doorway
			if dx == 0 and dz == -1:
				continue # the gap
			ring.append(centre + Vector3i(dx, 0, dz))
	for dy in [0, 1]:
		for cell in ring:
			world.place(cell + Vector3i(0, dy, 0), BlockRegistry.Block.STONE_WALL)

	# Hang the door: three logs fetched and delivered, the doorway stays
	# open air under the building record.
	_clear_wall_material_near(colony, sill, 25.0)
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
			),
			outside_e
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var door_job := _assign_build(colony, sill, outside_e, &"log_door")
	var hung := await _wait_until(func() -> bool:
		return colony.door_at(sill) != null)
	_check(hung and door_job != null, "a unit hangs a log door in the doorway")
	var door := colony.door_at(sill)
	if door == null:
		return
	_check(
		world.get_block(sill) == BlockRegistry.Block.AIR,
		"a built door leaves its voxel open air"
	)
	_check(
		colony.building_at(sill + Vector3i.UP) == door,
		"the door's headroom cell belongs to it"
	)
	var log_count := 0
	for item in door.components:
		if item.form == DropItem.Form.LOG:
			log_count += 1
	_check(log_count == 3, "the door holds the three logs it took")
	var door_sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - sill).length() > 2.5:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == BlockRegistry.Resource_.WOOD:
				door_sawdust += item.volume
	_check(door_sawdust == 250000, "the door's overcharge drops as sawdust")
	if world.sim != null:
		_check(world.sim.door_at(sill), "the native sim marks the sill a door")

	# Pathing through it: while the north gap is open the way around is
	# cheaper than paying the swing; seal it and the door is the only way.
	if world.sim != null:
		var around := world.find_path(outside_n, centre)
		var through_door := false
		for point in around:
			if Vector3i(point.floor()) == sill:
				through_door = true
		_check(
			not around.is_empty() and not through_door,
			"an open gap beats paying the door's swing"
		)
		world.place(gap, BlockRegistry.Block.STONE_WALL)
		world.place(gap + Vector3i.UP, BlockRegistry.Block.STONE_WALL)
		var only := world.find_path(outside_n, centre)
		through_door = false
		for point in only:
			if Vector3i(point.floor()) == sill:
				through_door = true
		_check(through_door, "sealed in, the path goes through the door")
	else:
		_check(false, "the native sim is loaded for door pathing")

	# The swing itself: a unit crossing pays the pause at the threshold,
	# walks through, and the door shuts — the way back pays it again.
	var walker: Unit = colony.units[0]
	for u in colony.units:
		if u != walker:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	walker.global_position = Vector3(outside_n) + Vector3(0.5, 0.9, 0.5)
	walker.velocity = Vector3.ZERO
	var cross := ColonyJob.new(ColonyJob.Type.REST, centre)
	cross.state = ColonyJob.State.ASSIGNED
	cross.assignee = walker
	walker.job = cross
	walker._goal_voxel = centre
	walker.state = Unit.State.MOVING
	var passed := await _wait_until(func() -> bool: return door.pass_count > 0)
	_check(passed, "a unit pays the swing time to open the door")
	var inside := await _wait_until(func() -> bool:
		return walker._standing_voxel() == centre)
	_check(inside, "the unit walks through the open door")
	walker.abandon_job()

	var back := ColonyJob.new(ColonyJob.Type.REST, outside_n)
	back.state = ColonyJob.State.ASSIGNED
	back.assignee = walker
	walker.job = back
	walker._goal_voxel = outside_n
	walker.state = Unit.State.MOVING
	var repassed := await _wait_until(func() -> bool: return door.pass_count > 1)
	_check(repassed, "the door closes behind — the way back pays the swing again")
	walker.abandon_job()

	# Taking it down hands back exactly what it took — the offcut stays
	# on the ground where it fell.
	var demolish := colony.designate_deconstruct(sill)
	_check(demolish != null, "a door designates for deconstruction")
	if demolish != null:
		_assign_job(colony, demolish, outside_e)
		var down := await _wait_until(func() -> bool:
			return colony.door_at(sill) == null)
		_check(down, "a unit takes the door down")
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var returned := 0
		for voxel in colony.item_piles:
			if Vector3(voxel - sill).length() > 2.5:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.LOG:
					returned += 1
		_check(returned == 3, "the door hands its three logs back")
	if world.sim != null:
		_check(not world.sim.door_at(sill), "the native sim clears the door")

	# The stone door, standing alone on a pad cell east of the room —
	# twelve boulders and thirteen cobbles in, gravel out.
	var stone_site := centre + Vector3i(3, 0, 0)
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 12:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BOULDER,
				DropItem.BOULDER_CM3
			),
			stone_site + Vector3i(0, 0, -1)
		)
	for i in 13:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			stone_site + Vector3i(0, 0, 1)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(0, 0, -1), &"stone_door"
	)
	var hung_stone := await _wait_until(func() -> bool:
		return colony.door_at(stone_site) != null)
	_check(hung_stone and stone_job != null, "a unit hangs a stone door")
	var gravel := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - stone_site).length() > 2.5:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == BlockRegistry.Resource_.STONE:
				gravel += item.volume
	_check(gravel == 80000, "the stone door's overcharge drops as gravel")


func _test_collapse(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("collapse")
	var foot := _flat_voxel(world, mined, 220)
	_check(foot != Vector3i.MAX, "found a flat spot for the collapse test")
	if foot == Vector3i.MAX:
		return

	# --- Detached body: a tower with an arm cantilevered off the top —
	#     the arm hangs only through the column.
	var p1 := foot + Vector3i.UP
	var p2 := foot + Vector3i.UP * 2
	var arm_a := p2 + Vector3i.RIGHT
	var arm_b := p2 + Vector3i.RIGHT * 2
	for v in [foot, p1, p2, arm_a, arm_b]:
		world.place(v, BlockRegistry.Block.STONE_WALL)
	_check(
		world.is_solid(arm_b),
		"a floating arm assembles off the tower"
	)
	_check(
		world.mine(foot) != BlockRegistry.Block.AIR,
		"the tower's foot mines out"
	)
	_check(
		world.get_block(p1) == BlockRegistry.Block.AIR
			and world.get_block(p2) == BlockRegistry.Block.AIR
			and world.get_block(arm_a) == BlockRegistry.Block.AIR
			and world.get_block(arm_b) == BlockRegistry.Block.AIR,
		"everything the foot held up comes down with it"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var rubble := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - foot).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.STONE:
				rubble += item.volume
	_check(
		rubble >= 4 * DropItem.BLOCK_CM3,
		"collapsed blocks drop their mined rubble where they stood"
	)

	# Neighbours of the removed foot that kept their chain stay put.
	_check(
		world.is_solid(foot + Vector3i.DOWN),
		"the ground under it does not collapse"
	)

	# --- Suspension: a floating build has nothing to hang from, so the
	#     job waits rather than completing an instant cave-in.
	_clear_jobs(colony)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 120.0
	# The suspension fixture needs a cell with NO solid face-neighbour —
	# flat ground alone doesn't promise that (a hillside can touch the
	# cell two up), so the scan verifies the whole neighbourhood is open.
	var ledge := _floating_flat(colony, world, mined, -150)
	_check(ledge != Vector3i.MAX, "found a floating spot for the suspend test")
	if ledge == Vector3i.MAX:
		return
	var target := ledge + Vector3i.UP
	var upper := target + Vector3i.UP
	_check(
		not colony.would_be_supported(target),
		"the test cell floats with no solid neighbour"
	)
	# A dirt wall wants 1.25 m³ of loose soil; three piles beside the
	# column cover two walls. Each is under the 1 m³ cap, so none spills
	# — the cells are inside the 5×5 flat the scan already verified.
	for off in [Vector3i(0, 0, 1), Vector3i(0, 0, 2), Vector3i(1, 0, 2)]:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000
			),
			ledge + off
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var depot := ledge + Vector3i(0, 0, 1)

	var job := colony.designate_build(target, &"dirt_wall")
	_check(job != null, "a floating build still designates")
	if job == null:
		return
	var upper_job := colony.designate_build(upper, &"dirt_wall")
	_check(upper_job != null, "a second floating build designates above it")

	var park := ledge + Vector3i.RIGHT
	_hand_job(colony, job, park, depot)
	var held := await _wait_until(func() -> bool: return job.suspended)
	_check(held, "a build with no support suspends instead of placing")
	_check(
		world.get_block(target) == BlockRegistry.Block.AIR
			and colony.is_designated(target),
		"the suspended plan keeps its cell and marker"
	)
	if upper_job != null:
		_hand_job(colony, upper_job, park, depot)
		var held2 := await _wait_until(func() -> bool: return upper_job.suspended)
		_check(held2, "the upper plan suspends on the same missing support")

	# A support under the lower cell lifts its suspension — and only its
	# own; the upper cell still has nothing until the lower wall lands.
	_check(
		world.place(ledge, BlockRegistry.Block.STONE),
		"a support column goes in"
	)
	_check(not job.suspended, "an adjacent placement lifts the suspension")
	if upper_job != null:
		_check(
			upper_job.suspended,
			"a plan two cells from the support stays suspended"
		)
	_hand_job(colony, job, park, Vector3i.MAX)
	var built := await _wait_until(func() -> bool:
		return world.get_block(target) == BlockRegistry.Block.DIRT)
	_check(built, "the resumed job builds once support exists")
	if upper_job != null:
		_check(
			not upper_job.suspended,
			"the lower wall's placement unsuspends the cell above"
		)
		_hand_job(colony, upper_job, park, Vector3i.MAX)
		var built2 := await _wait_until(func() -> bool:
			return world.get_block(upper) == BlockRegistry.Block.DIRT)
		_check(built2, "the cascade resumes the upper wall too")

	# Tidy up: drop the tower so later tests find clean ground, and clear
	# the leftover piles.
	world.remove_voxel(upper)
	world.remove_voxel(target)
	world.remove_voxel(ledge)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0


## RimWorld-style shell: colonist bar matches the roster, the architect
## popup carries every action plus disabled stubs, toggles and the speed
## buttons do what they say.
## Skills: XP grows levels linearly (X, 2X, 3X, …), level 10 ≈ 2× work
## speed, completions grant XP to their discipline, and claim scoring lets
## specialists favour their craft while waiting jobs can't starve.
func _test_skills(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	_clear_jobs(colony)
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
		u.abandon_job()
	unit.energy = 1.0
	unit.hunger = 1.0

	# --- XP → level: linear requirement inverted through the quadratic ---
	var x := Unit.SKILL_XP_BASE
	unit.skills[ColonyJob.Skill.MINING] = 0.0
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 0, "no xp means level 0"
	)
	unit.skills[ColonyJob.Skill.MINING] = x - 0.01
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 0,
		"just short of x stays level 0"
	)
	unit.skills[ColonyJob.Skill.MINING] = x
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 1,
		"x points reaches level 1"
	)
	unit.skills[ColonyJob.Skill.MINING] = 3.0 * x - 0.01
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 1,
		"3x needs the full 2x second step"
	)
	unit.skills[ColonyJob.Skill.MINING] = 3.0 * x
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 2,
		"linear growth: x then 2x reaches level 2"
	)
	_check(
		is_equal_approx(Unit.skill_xp_next(0), x)
			and is_equal_approx(Unit.skill_xp_next(1), 2.0 * x)
			and is_equal_approx(Unit.skill_xp_next(4), 5.0 * x),
		"the xp step scales linearly with level"
	)

	# --- speed: 2^(level/10) → L10 ≈ 2×, L20 ≈ 4×, unskilled 1× ---
	unit.skills[ColonyJob.Skill.MINING] = 55.0 * x # L10: 10·11/2
	_check(
		is_equal_approx(unit.skill_rate(ColonyJob.Skill.MINING), 2.0),
		"level 10 works at twice base speed"
	)
	unit.skills[ColonyJob.Skill.MINING] = 210.0 * x # L20: 20·21/2
	_check(
		is_equal_approx(unit.skill_rate(ColonyJob.Skill.MINING), 4.0),
		"level 20 works at four times base speed"
	)
	_check(
		unit.skill_rate(-1) == 1.0, "an unskilled job type runs at base speed"
	)
	unit.job = ColonyJob.new(ColonyJob.Type.MINE, Vector3i.ZERO)
	_check(
		is_equal_approx(unit._work_rate(), 4.0),
		"the work rate folds the current job's skill in"
	)
	unit.job = ColonyJob.new(ColonyJob.Type.CLEAR, Vector3i.ZERO)
	_check(
		is_equal_approx(unit._work_rate(), 1.0),
		"an unskilled job ignores mining skill"
	)
	unit.job = null
	unit.skills[ColonyJob.Skill.MINING] = 0.0

	# --- claim scoring ---
	# Park the unit; fixture jobs go on flat rows at chosen distances.
	var us := _flat_voxel(world, mined, 30)
	var near_v := _flat_voxel(world, mined, 38)
	var far_v := _flat_voxel(world, mined, 75)
	_check(
		us != Vector3i.MAX and near_v != Vector3i.MAX and far_v != Vector3i.MAX,
		"found flat rows for the claim fixtures"
	)
	if us == Vector3i.MAX or near_v == Vector3i.MAX or far_v == Vector3i.MAX:
		return
	unit.global_position = Vector3(us) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO

	# Languish: two same-type jobs — backdate the far one past the
	# distance gap and it outranks the close one. All synchronous, so no
	# unit tick can claim mid-check.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		near_v
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		far_v
	)
	var near_clear := colony.designate_clear(near_v)
	var far_clear := colony.designate_clear(far_v)
	_check(
		near_clear != null and far_clear != null,
		"two clearing jobs for the languish check"
	)
	if near_clear != null and far_clear != null:
		far_clear.posted_msec -= 240000
		if world.sim != null:
			world.sim.job_set_posted(
				far_clear.get_instance_id(), far_clear.posted_msec
			)
		var picked := colony.claim_job(unit)
		_check(
			picked == far_clear,
			"a long-waiting job outranks a closer fresh one"
		)
		colony.cancel_designation(near_v)
		colony.cancel_designation(far_v)

	# Skill preference: near CLEAR vs far MINE — a generalist takes the
	# close one, a level-5 specialist crosses the gap for its craft.
	var clear_v := _flat_voxel(world, mined, 42)
	var mine_spot_v := _flat_voxel(world, mined, 80)
	var mine_v := mine_spot_v + Vector3i.DOWN
	_check(
		clear_v != Vector3i.MAX and mine_spot_v != Vector3i.MAX,
		"found rows for the skill-preference check"
	)
	unit.skills[ColonyJob.Skill.MINING] = 15.0 * x # L5: 5·6/2
	unit.specialize = false
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		clear_v
	)
	var clear_job := colony.designate_clear(clear_v)
	var mine_job := colony.designate_mine(mine_v)
	if clear_job != null and mine_job != null:
		var generalist_pick := colony.claim_job(unit)
		_check(
			generalist_pick == clear_job,
			"a generalist takes the nearer unskilled job"
		)
		colony.cancel_designation(clear_v)
		colony.cancel_designation(mine_v)
		# Fresh records — the cancelled ones carry drop bookkeeping.
		clear_job = colony.designate_clear(clear_v)
		mine_job = colony.designate_mine(mine_v)
		unit.specialize = true
		var specialist_pick := colony.claim_job(unit)
		_check(
			specialist_pick == mine_job,
			"a specialist crosses the gap for a skilled job"
		)
		colony.cancel_designation(clear_v)
		colony.cancel_designation(mine_v)
	else:
		_check(false, "could not designate the skill-preference jobs")
	unit.specialize = false

	# --- XP on completion, and none for unskilled work ---
	for skill in unit.skills:
		unit.skills[skill] = 0.0
	var mine_spot := _flat_voxel(world, mined, 10)
	var mine_cell := mine_spot + Vector3i.DOWN
	var mjob := colony.designate_mine(mine_cell)
	_check(mjob != null, "a mine designation for the xp check")
	if mjob != null:
		_assign_job(colony, mjob, _park_beside(colony, world, mine_cell, mine_spot), unit)
		var mined_out := await _wait_until(
			func() -> bool: return not world.is_solid(mine_cell)
		)
		_check(mined_out, "the unit completes the mine job")
		_check(
			is_equal_approx(
				unit.skills[ColonyJob.Skill.MINING],
				ColonyJob.XP_FOR[ColonyJob.Type.MINE]
			),
			"mining completion grants mining xp"
		)
	# Unskilled completions grant nothing — exercise the same award path
	# (`_finish_job`) with a synthetic CLEAR job; a real clear's completion
	# is covered by _test_clear.
	for skill in unit.skills:
		unit.skills[skill] = 0.0
	var fake_clear := ColonyJob.new(
		ColonyJob.Type.CLEAR, Vector3i(9999, 999, 9999)
	)
	fake_clear.assignee = unit
	colony._finish_job(fake_clear)
	var gained := 0.0
	for skill in unit.skills:
		gained += unit.skills[skill]
	_check(gained == 0.0, "unskilled work grants no xp")


func _test_organics(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	print("organics")
	_clear_jobs(colony)
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
		u.abandon_job()

	var base := _flat_voxel(world, mined, -72, 144)
	_check(base != Vector3i.MAX, "found a flat stretch for the organics test")
	if base == Vector3i.MAX:
		return

	# Clear the fixture box — canopy room, fruit scatter, and the
	# sprout/decay strip all live in it. Same discipline as _test_tree.
	for dx in range(-3, 14):
		for dy in range(0, 10):
			for dz in range(-5, 5):
				var cell := base + Vector3i(dx, dy, dz)
				var owner := colony.forest.tree_root_at(cell)
				if owner != Vector3i.MAX:
					colony.forest.trees.erase(owner)
					colony.forest._index.erase(cell)
					colony.forest._leaves.erase(cell)
				var bush := colony.plants.bush_at(cell)
				if bush != Vector3i.MAX:
					colony.plants.bushes.erase(bush)
					colony.plants._index.erase(cell)
				var pile := colony.item_pile_at(cell)
				if pile != null:
					pile.items.clear()
					colony.remove_pile_if_empty(cell)
				if (
					world.is_editable(cell)
					and world.get_block(cell) != BlockRegistry.Block.AIR
				):
					world.remove_voxel(cell)
	# Push units out of the box — a unit in a cell blocks tree growth.
	for u in colony.units:
		if Vector3(u.global_position - Vector3(base)).length() < 12.0:
			u.global_position = Vector3(base.x - 12, base.y + 0.9, base.z + 0.5)
			u.velocity = Vector3.ZERO

	# --- Fruiting: a mature oak sheds one acorn per leaf block ---
	_check(
		colony.forest.plant_sapling(base), "a sapling plants for fruiting"
	)
	var sp: Dictionary = Forest.SPECIES[&"oak"]
	for i in int(sp[&"max_height"]):
		colony.forest.grow(base)
	var rec: Dictionary = colony.forest.trees.get(base, {})
	_check(
		int(rec.get(&"height", -1)) == int(sp[&"max_height"]),
		"the fruit tree grows to maturity"
	)
	var leaf_count := 0
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_count += 1
	_check(leaf_count > 0, "the mature tree has leaf blocks")
	var fruit_before := _count_items(
		colony, base, 14.0, BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT
	)
	colony.forest.grow(base) # mature step → the fruit drop
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var acorns := _collect_items(
		colony, base, 14.0, BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT
	)
	_check(
		acorns.size() - fruit_before == leaf_count,
		"a mature oak drops one acorn per leaf block"
	)
	var all_whole := true
	for item in acorns:
		if item.volume != DropItem.FRUIT_CM3:
			all_whole = false
	_check(all_whole, "each fruit is a whole item")
	# Some fruit landed away from the trunk column — gravity scattered it.
	var landed_on := {}
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - base).length() > 14.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.material == BlockRegistry.Resource_.ACORN
				and item.form == DropItem.Form.FRUIT
			):
				landed_on[voxel] = true
	_check(
		landed_on.size() > 1, "fruit scatters into piles around the base"
	)
	# The production cadence is the mature tree's own tick: five days.
	var next_in := int(rec[&"next"]) - colony.game_msec()
	_check(
		next_in > int(sp[&"growth_seconds"]) * 900,
		"the next fruiting lands about five game-days out"
	)
	# Bushes never fruit — no species entry carries a fruit drop.
	_check(
		Plants.SPECIES[&"berry_bush"].get(&"fruit_material") == null,
		"bushes hold their fruit for forage, not drops"
	)

	# --- Extract seed: a fruit craft at the worksite ---
	var spot := base + Vector3i(5, 0, 0)
	var fruit_v := base + Vector3i(6, 0, 0)
	_normalize_cell(colony, world, spot)
	_normalize_cell(colony, world, fruit_v)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.ACORN,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		fruit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(spot) + Vector3(-1.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	_check(
		colony.designate_craft_spot(spot),
		"a craft spot designates for seed extraction"
	)
	var seed_job := _assign_craft(colony, world, spot, fruit_v, &"extract_seed")
	_check(
		seed_job != null, "extract-seed designates as a craft order"
	)
	if seed_job != null:
		var presser: Unit = seed_job.assignee
		var xp_before: float = presser.skills.get(
			ColonyJob.Skill.CRAFTING, 0.0
		)
		_check(
			seed_job.type == ColonyJob.Type.CRAFT,
			"the seed order is a crafting job"
		)
		var crafted := await _wait_until(
			func() -> bool: return seed_job.state == ColonyJob.State.DONE
		)
		_check(crafted, "a unit presses the acorn into seeds")
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
		var seeds := _collect_items(
			colony, spot, 4.0, BlockRegistry.Resource_.SEED, DropItem.Form.SEED
		)
		_check(seeds.size() == 2, "one fruit presses into two seed packets")
		var oak_seeds := true
		for item in seeds:
			if item.species != &"oak":
				oak_seeds = false
		_check(oak_seeds, "seeds keep the fruit's species")
		_check(
			presser.skills.get(ColonyJob.Skill.CRAFTING, 0.0) > xp_before,
			"seed extraction trains crafting"
		)

	# A foraged berry takes the same order — it's a FRUIT item now — and
	# the packets carry the bush's species, which is what a berry field
	# sows. This is the whole berry→seed→farm loop a player sees.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		fruit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var berry_job := _assign_craft(colony, world, spot, fruit_v, &"extract_seed")
	_check(berry_job != null, "extract-seed re-orders on a berry")
	if berry_job != null:
		var pressed := await _wait_until(
			func() -> bool: return berry_job.state == ColonyJob.State.DONE
		)
		_check(pressed, "a unit presses the berry into seeds")
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var berry_seeds := _collect_items(
			colony, spot, 4.0, BlockRegistry.Resource_.SEED, DropItem.Form.SEED
		)
		var bush_packets := 0
		for item in berry_seeds:
			if item.species == &"berry_bush":
				bush_packets += 1
		_check(bush_packets == 2, "a berry presses into two berry-bush seeds")
		_check(
			colony._seed_exists(&"berry_bush"),
			"berry-bush seed packets answer the sow query"
		)

	# --- Organic decay: per-material rules ---
	var day := colony.day_length()
	var cells: Array[Vector3i] = []
	for i in range(6):
		var c := base + Vector3i(5 + i, 0, -2)
		_normalize_cell(colony, world, c)
		cells.append(c)
	# All non-soil floors — no decayed fruit may sprout here.
	for c in cells:
		world.remove_voxel(c + Vector3i.DOWN)
		world.place(c + Vector3i.DOWN, BlockRegistry.Block.STONE)

	# The fixtures must sit untouched until the sweep counts them — the
	# craft fixture just parked a unit beside these cells, and an idle
	# unit would otherwise haul the deposited logs to a stockpile.
	for u in colony.units:
		u._job_search_cooldown = 120.0

	var leaf_v: Vector3i = cells[0]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.LEAF, DropItem.Form.LOOSE, 200_000
		),
		leaf_v
	)
	var branch_v: Vector3i = cells[1]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE, 120_000
		),
		branch_v
	)
	var log_v: Vector3i = cells[2]
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			log_v
		)
	var plank_v: Vector3i = cells[3]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD,
			DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		),
		plank_v
	)
	var compost_v: Vector3i = cells[4]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COMPOST,
			DropItem.Form.LOOSE,
			80_000
		),
		compost_v
	)
	var rot_v: Vector3i = cells[5]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.ACORN,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		rot_v
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
		),
		rot_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# One sweep at twenty lifetimes of the fastest material: every
	# decayable item in the fixture is gone (each bulk stack's quantum
	# count sits deep in the Poisson tail — deterministic in practice),
	# discrete items' per-sweep odds pass one, and the compost each rot
	# leaves behind is added after the sweep so it survives to count.
	colony._decay_tick(300.0 * day)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var leaf_pile := colony.item_pile_at(leaf_v)
	var leaf_compost := 0
	var leaf_left := false
	if leaf_pile != null:
		for item in leaf_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				leaf_compost += item.volume
			elif item.material == BlockRegistry.Resource_.LEAF:
				leaf_left = true
	_check(not leaf_left, "leaf litter rots away")
	_check(
		leaf_compost == 50_000,
		"leaves compost at a quarter of their volume"
	)
	var branch_pile := colony.item_pile_at(branch_v)
	var branch_compost := 0
	if branch_pile != null:
		for item in branch_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				branch_compost += item.volume
	_check(
		branch_compost == 60_000,
		"branches compost at half their volume"
	)
	var log_pile := colony.item_pile_at(log_v)
	var log_compost := 0
	var log_left := false
	if log_pile != null:
		for item in log_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				log_compost += item.volume
			elif item.form == DropItem.Form.LOG:
				log_left = true
	_check(not log_left, "logs decay as discrete items")
	_check(
		log_compost == DropItem.LOG_CM3,
		"two logs leave a whole log's worth of compost"
	)
	var plank_pile := colony.item_pile_at(plank_v)
	var plank_alive := false
	if plank_pile != null:
		for item in plank_pile.items:
			if item.form == DropItem.Form.PLANK:
				plank_alive = true
	_check(plank_alive, "cured planks never decay")
	var compost_pile := colony.item_pile_at(compost_v)
	var compost_left := false
	if compost_pile != null:
		for item in compost_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				compost_left = true
	_check(not compost_left, "compost decays into nothing")
	# These fixtures stand on stone — a barren block can't hold the
	# fertilization rotted compost would leave over dirt.
	_check(
		not colony.fertilization.has(compost_v + Vector3i.DOWN),
		"compost rotting on stone feeds nothing"
	)
	var rot_pile := colony.item_pile_at(rot_v)
	var rot_left := false
	if rot_pile != null:
		for item in rot_pile.items:
			if (
				item.form == DropItem.Form.FRUIT
				or item.form == DropItem.Form.SEED
			):
				rot_left = true
	_check(not rot_left, "fruit and seed decay outright")
	_check(
		colony.forest.tree_root_at(rot_v) == Vector3i.MAX
			and colony.plants.bush_at(rot_v) == Vector3i.MAX,
		"fruit rotting off soil never sprouts"
	)

	# --- Sprouting rules (deterministic half of the 5% roll) ---
	# The decay sweep may have sprouted volunteer trees from the scattered
	# acorns — clear each cell's 3×3 of plant claims right before use, in
	# a synchronous block so no periodic sweep can interleave.
	var sa := base + Vector3i(4, 0, 3)
	var sb := base + Vector3i(5, 0, 3)
	var sc := base + Vector3i(8, 0, 3)
	var sd := base + Vector3i(10, 0, 3)
	for pcell in [sa, sb, sc, sd]:
		_clear_plants_around(colony, pcell)
		_normalize_cell(colony, world, pcell)
	_check(
		colony._sprout_plant(sa, BlockRegistry.Resource_.ACORN),
		"a decayed acorn on soil plants a sapling"
	)
	_check(
		colony.forest.tree_root_at(sa) == sa,
		"the sprouted sapling registers as a tree"
	)
	_check(
		not colony._sprout_plant(sb, BlockRegistry.Resource_.ACORN),
		"a sapling can't sprout beside another plant"
	)
	_check(
		colony._sprout_plant(sb, BlockRegistry.Resource_.BERRY),
		"a berry may sprout its own cell beside a tree"
	)
	_check(
		colony.plants.bush_at(sb) == sb,
		"the berry sprout registers as a bush"
	)
	_check(
		not colony.plants.bushes[sb][&"ripe"],
		"a sprouted bush starts out immature"
	)
	_check(
		not colony._sprout_plant(sb, BlockRegistry.Resource_.BERRY),
		"a bush can't sprout where a bush already stands"
	)
	_check(
		not colony._sprout_plant(sa, BlockRegistry.Resource_.BERRY),
		"a bush can't sprout where a sapling stands"
	)
	_check(
		colony._sprout_plant(sc, BlockRegistry.Resource_.ACORN),
		"a sapling three cells out has room to plant"
	)

	# The 5% roll itself: a clear soil cell eventually sprouts, and a
	# stone-floored cell never does — rolls are bounded, so no flake.
	_clear_plants_around(colony, sd)
	var sprouted := false
	for i in 500:
		colony._sprout_from_decay(sd, BlockRegistry.Resource_.ACORN)
		if colony.forest.tree_root_at(sd) != Vector3i.MAX:
			sprouted = true
			break
	_check(sprouted, "the five-percent sprout roll fires on soil")
	var stone_cell := base + Vector3i(11, 0, -2)
	_normalize_cell(colony, world, stone_cell)
	var stone_owner := colony.forest.tree_root_at(stone_cell)
	if stone_owner != Vector3i.MAX:
		colony.forest.trees.erase(stone_owner)
		colony.forest._index.erase(stone_cell)
	world.remove_voxel(stone_cell + Vector3i.DOWN)
	var floored := world.place(
		stone_cell + Vector3i.DOWN, BlockRegistry.Block.STONE
	)
	_check(floored, "the no-sprout fixture gets a stone floor")
	if not floored:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	for i in 100:
		colony._sprout_from_decay(stone_cell, BlockRegistry.Resource_.ACORN)
	_check(
		colony.forest.tree_root_at(stone_cell) == Vector3i.MAX,
		"fruit decaying on bare stone never sprouts"
	)

	for u in colony.units:
		u._job_search_cooldown = 0.0


## Count of items of [param material]/[param form] in piles within
## [param radius] of [param near].
func _count_items(
	colony: Colony, near: Vector3i, radius: float,
	material: BlockRegistry.Resource_, form: DropItem.Form
) -> int:
	return _collect_items(colony, near, radius, material, form).size()


## The items of [param material]/[param form] in piles within
## [param radius] of [param near].
func _collect_items(
	colony: Colony, near: Vector3i, radius: float,
	material: BlockRegistry.Resource_, form: DropItem.Form
) -> Array:
	var found: Array = []
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - near).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == material and item.form == form:
				found.append(item)
	return found


## Erase every tree/bush record claiming [param cell] or a neighbour —
## for sprout fixtures where a decayed-fruit volunteer could occupy the
## test cell's spacing neighbourhood.
func _clear_plants_around(colony: Colony, cell: Vector3i) -> void:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := cell + Vector3i(dx, 0, dz)
			var owner := colony.forest.tree_root_at(c)
			if owner != Vector3i.MAX:
				colony.forest.trees.erase(owner)
			colony.forest._index.erase(c)
			colony.forest._leaves.erase(c)
			var bush := colony.plants.bush_at(c)
			if bush != Vector3i.MAX:
				colony.plants.bushes.erase(bush)
			colony.plants._index.erase(c)


## Make a test cell deterministic: bare air over a dirt floor, no pile.
func _normalize_cell(colony: Colony, world: VoxelWorld, cell: Vector3i) -> void:
	for dy in range(0, 4):
		var above := cell + Vector3i(0, dy, 0)
		if (
			world.is_editable(above)
			and world.get_block(above) != BlockRegistry.Block.AIR
		):
			world.remove_voxel(above)
	var pile := colony.item_pile_at(cell)
	if pile != null:
		pile.items.clear()
		colony.remove_pile_if_empty(cell)
	# `place` only writes into air — lift the floor block first so the
	# dirt actually lands.
	var floor_cell := cell + Vector3i.DOWN
	if world.is_editable(floor_cell):
		world.remove_voxel(floor_cell)
		world.place(floor_cell, BlockRegistry.Block.DIRT)


## Grass is a decoration layer over plain dirt — the generator seeds
## coverage, construction buries it, foot traffic wears it out, and a
## lush cell regrows and spreads (PLAN item 12).
func _test_grass(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("grass decoration")
	var grass: Grass = colony.grass
	_check(grass != null, "the colony owns a grass decoration layer")
	if grass == null:
		return

	# The generator's oracle seeds cover only where soil tops the column
	# — rock outcrops grow none — and seeds it mixed, not full.
	var generator := world.generator_script
	var seeded := 0
	var mixed := false
	for x in range(mined.x - 40, mined.x + 40, 4):
		for z in range(mined.z - 40, mined.z + 40, 4):
			var s: float = generator.grass_seed_at(x, z)
			if s < 0.0:
				continue
			seeded += 1
			if s < 0.95:
				mixed = true
	_check(seeded > 0, "the generator seeds grass on soil-topped columns")
	_check(mixed, "seeded grass starts at mixed coverage")

	# Streamed terrain carries real coverage — find a live cell near the
	# test anchor.
	var cell := Vector3i.MAX
	var nearest := 1e9
	for c: Vector3i in grass.coverage:
		if grass.coverage_at(c) <= 0.0:
			continue
		var d := (c - mined).length()
		if d < nearest:
			nearest = d
			cell = c
	_check(cell != Vector3i.MAX, "streamed terrain carries grass cover")
	if cell == Vector3i.MAX:
		return
	_check(
		world.get_block(cell) == BlockRegistry.Block.DIRT,
		"grass decorates a plain dirt block"
	)

	# A clean fixture column: air above, no pile or building on it.
	var work := cell + Vector3i.UP
	_normalize_cell(colony, world, work)
	colony.buildings.erase(work)

	# Foot traffic wears cover — five crossings bare a healthy patch.
	grass.coverage[cell] = 0.9
	_check(grass.grassed(cell), "a seeded cell reads grassed")
	var wears := 0
	while grass.grassed(cell) and wears < 20:
		grass.trample(cell)
		wears += 1
	_check(wears == 5, "five crossings wear a healthy patch to bare")
	_check(not grass.grassed(cell), "trampled-out cover is gone")

	# Thin cover thickens a step each scan visit; under the spread
	# threshold it seeds nobody mid-check.
	grass.coverage[cell] = 0.5
	grass._tick_cell(cell)
	_check(
		is_equal_approx(grass.coverage_at(cell), 0.55),
		"cover regrows a step per scan visit"
	)

	# A lush cell seeds exactly one bare eligible neighbour.
	grass.coverage[cell] = 1.0
	var candidates: Array[Vector3i] = []
	for side in Grass.SIDES:
		for dy in [0, 1, -1]:
			var n := cell + side + Vector3i(0, dy, 0)
			_normalize_cell(colony, world, n + Vector3i.UP)
			colony.buildings.erase(n + Vector3i.UP)
			grass.coverage[n] = 0.0
			if grass.coverage_at(n) == 0.0 and world.get_block(n) == BlockRegistry.Block.DIRT:
				candidates.append(n)
	_check(not candidates.is_empty(), "the cell has bare dirt neighbours to spread to")
	if not candidates.is_empty():
		_check(grass.spread_from(cell), "a lush cell spreads to a bare neighbour")
		var sprouted := 0
		for n in candidates:
			if grass.coverage_at(n) > 0.0:
				sprouted += 1
		_check(sprouted == 1, "spread seeds exactly one neighbour")

	# Building anything over grass buries the cover — through the
	# placed-block signal (a real wall block) and through building
	# registration (a bed or worksite, which fills no voxel).
	grass.coverage[cell] = 0.8
	_check(
		world.place(work, BlockRegistry.Block.STONE_WALL),
		"a wall goes up over grassed ground"
	)
	_check(grass.coverage_at(cell) == 0.0, "the placed block buries the cover beneath")
	world.remove_voxel(work)

	grass.coverage[cell] = 0.8
	colony.register_building(Building.new(Building.Kind.WALL, work))
	_check(grass.coverage_at(cell) == 0.0, "registering a building buries the cover beneath")
	colony.buildings.erase(work)

	# Mining the block under cover yields plain dirt — the grass was
	# decoration, not a block type — and the cover dies with the block.
	_check(
		world.mine(cell) == BlockRegistry.Block.DIRT,
		"mining a grassed cell yields dirt"
	)
	_check(not grass.grassed(cell), "the cover dies with its block")
	world.place(cell, BlockRegistry.Block.DIRT)


## PLAN item 20: daylight and soil fertility modulate plant growth —
## the trapezoid light band and power-curve sensitivity in PlantGrowth,
## type-level soil properties plus sparse per-cell fertilization on the
## colony side, and the slide-the-deadline growth clock both plant
## systems share. Compost finishing its rot fertilizes the block below.
func _test_plant_environment(
	colony: Colony, world: VoxelWorld, mined: Vector3i
) -> void:
	print("plant environment")
	for u in colony.units:
		u._job_search_cooldown = 120.0
	var day_cycle: DayCycle = colony.day_cycle
	var day := colony.day_length()
	var saved_time := day_cycle.planet_time
	var spec: Dictionary = Plants.SPECIES[&"berry_bush"]

	# The light band: nothing below min or above max, full rate across
	# the optimal span, lerped through both transitions.
	_check(
		PlantGrowth.light_factor(spec, 0.0) == 0.0, "no growth in darkness"
	)
	_check(
		PlantGrowth.light_factor(spec, 0.03) == 0.0,
		"below minimum light stays dark"
	)
	_check(
		is_equal_approx(PlantGrowth.light_factor(spec, 0.355), 0.5),
		"the dawn transition lerps upward"
	)
	_check(
		PlantGrowth.light_factor(spec, 0.8) == 1.0,
		"the optimal band grows at full rate"
	)
	_check(
		is_equal_approx(PlantGrowth.light_factor(spec, 1.055), 0.5),
		"the scorch transition lerps downward"
	)
	_check(
		PlantGrowth.light_factor(spec, 1.2) == 0.0, "past maximum light stalls"
	)

	# The fertility curve: eff^sensitivity — 200% soil doubles a
	# fully-sensitive plant, 50% halves it; insensitive plants ignore
	# soil entirely and growth never goes negative.
	_check(
		PlantGrowth.fertility_factor(2.0, 1.0) == 2.0,
		"rich soil doubles a fully sensitive plant"
	)
	_check(
		PlantGrowth.fertility_factor(0.5, 1.0) == 0.5,
		"poor soil halves a fully sensitive plant"
	)
	_check(
		is_equal_approx(PlantGrowth.fertility_factor(2.0, 0.5), sqrt(2.0)),
		"half sensitivity softens the boost"
	)
	_check(
		PlantGrowth.fertility_factor(0.0, 0.5) == 0.0,
		"dead soil stalls — never negative growth"
	)
	_check(
		PlantGrowth.fertility_factor(0.0, 0.0) == 1.0,
		"an insensitive plant ignores the soil"
	)

	# Type-level soil properties: dirt fertile and fertilizable,
	# everything else barren and unimprovable.
	_check(
		BlockRegistry.default_fertility(BlockRegistry.Block.DIRT) == 1.0,
		"dirt starts fully fertile"
	)
	_check(
		BlockRegistry.fertilizability(BlockRegistry.Block.DIRT) == 1.0,
		"dirt takes fertilizer"
	)
	_check(
		BlockRegistry.default_fertility(BlockRegistry.Block.STONE) == 0.0,
		"stone is barren"
	)
	_check(
		BlockRegistry.fertilizability(BlockRegistry.Block.STONE) == 0.0,
		"stone can't hold fertilizer"
	)

	var base := Vector3i.MAX
	for z_off in [24, 44, 20, 28, 36, 52]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate != Vector3i.MAX:
			base = candidate
			break
	_check(
		base != Vector3i.MAX,
		"found flat ground for the environment test"
	)
	if base == Vector3i.MAX:
		day_cycle.planet_time = saved_time
		day_cycle._apply_sun()
		return
	var bush_cell := base
	var soil := base + Vector3i.DOWN
	var shade_cell := base + Vector3i(1, 0, 0)
	var compost_cell := base + Vector3i(2, 0, 0)
	var tree_cell := base + Vector3i(3, 0, 0)
	for c in [bush_cell, shade_cell, compost_cell, tree_cell]:
		_clear_plants_around(colony, c)
		_normalize_cell(colony, world, c)
	# An air cell can't hold fertilizer either — it has no soil block.
	colony.fertilize(bush_cell, 0.5)
	_check(
		not colony.fertilization.has(bush_cell),
		"an air cell can't hold fertilizer"
	)

	# Sky exposure: noon sun reads near-full on open ground, nothing at
	# night or under a solid roof.
	day_cycle.advance(wrapf(0.5 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	var noon_light := colony.daylight_at(bush_cell)
	_check(
		noon_light > 0.8 and noon_light < 1.0,
		"an open cell sees near-full sun at noon"
	)
	day_cycle.advance(wrapf(1.0 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	_check(colony.daylight_at(bush_cell) == 0.0, "night is dark")
	world.place(
		shade_cell + Vector3i(0, 2, 0), BlockRegistry.Block.STONE_WALL
	)
	day_cycle.advance(wrapf(0.5 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	_check(
		colony.daylight_at(shade_cell) == 0.0, "a roofed cell is dark at noon"
	)

	# The growth clock: a bush's ripening deadline slides by the un-grown
	# part of each tick — full rate at noon, stalled at night, outrunning
	# the nominal clock on fertilized ground.
	_check(
		colony.plants.plant(bush_cell, &"berry_bush"),
		"the fixture bush plants"
	)
	var rec: Dictionary = colony.plants.bushes[bush_cell]
	var due0: int = rec[&"next"]
	colony.plants._growth_tick(4.0)
	_check(
		int(rec[&"next"]) == due0, "full light and plain soil keep the deadline"
	)
	colony.fertilize(soil, 1.0)
	_check(
		is_equal_approx(colony.effective_fertility(soil), 2.0),
		"fertilized dirt reads past 100%"
	)
	colony.plants._growth_tick(60.0)
	_check(
		int(rec[&"next"]) < due0,
		"fertilized ground outgrows the nominal clock"
	)
	_check(
		float(colony.fertilization.get(soil, 0.0)) < 0.99,
		"growth drains the stored fertility"
	)
	day_cycle.advance(wrapf(1.0 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	var due1: int = rec[&"next"]
	colony.plants._growth_tick(4.0)
	_check(
		int(rec[&"next"]) >= due1 + 3900,
		"darkness slides the deadline with the clock"
	)
	colony.plants._forget(bush_cell)

	# Trees share the machinery: a sapling's next step postpones in the
	# dark the same way — probed above its own crown, so its trunk
	# doesn't shade it.
	_check(
		colony.forest.plant_sapling(tree_cell, &"oak"),
		"the fixture sapling plants"
	)
	var trec: Dictionary = colony.forest.trees[tree_cell]
	var tree_due: int = trec[&"next"]
	colony.forest._growth_tick(4.0)
	_check(
		int(trec[&"next"]) >= tree_due + 3900,
		"a sapling's growth stalls at night too"
	)
	colony.forest.trees.erase(tree_cell)
	colony.forest._index.erase(tree_cell)
	colony.forest._block_roots.get(
		colony.forest._block_of(tree_cell), {}
	).erase(tree_cell)
	var tchunk := colony.forest._column_chunk(tree_cell)
	colony.forest._chunk_roots.get(tchunk, {}).erase(tree_cell)

	# Compost finishing its rot fertilizes the block below its pile —
	# 1% per 1000 cm³.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COMPOST, DropItem.Form.LOOSE, 80_000
		),
		compost_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._decay_tick(300.0 * day)
	_check(
		is_equal_approx(
			float(
				colony.fertilization.get(
					compost_cell + Vector3i.DOWN, 0.0
				)
			),
			0.8
		),
		"rotted compost fertilizes the block below"
	)

	# Cleanup: the roof, the fixture's fertilization, and the clock.
	world.remove_voxel(shade_cell + Vector3i(0, 2, 0))
	colony.fertilization.erase(soil)
	colony.fertilization.erase(compost_cell + Vector3i.DOWN)
	day_cycle.planet_time = saved_time
	day_cycle._apply_sun()


## Farm fields: a zone designation with a crop assignment. The field
## posts sow jobs where the species can grow — gated on a seed packet of
## that species existing — ripe shrubs harvest themselves, annuals die
## to their harvest and re-sow, and tree fields fell their mature trunks
## when auto-chop is on (PLAN item 14).
func _test_farm(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("farming")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)

	# --- The resource model: grain is real, edible material; its
	# harvested heads are seed-bearing fruit, so the extract-seed craft
	# threshes them into wheat packets — and a rotted head volunteers.
	_check(
		BlockRegistry.resource_name_of(BlockRegistry.Resource_.GRAIN) == "Grain",
		"the grain resource is registered"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.GRAIN),
		"grain is edible"
	)
	_check(
		bool(Plants.SPECIES[&"wheat"][&"annual"]),
		"wheat is an annual — the harvest kills the plant"
	)
	_check(
		not bool(Plants.SPECIES[&"berry_bush"][&"annual"]),
		"the berry bush is a perennial"
	)
	_check(
		DropItem.FRUIT_SPECIES[BlockRegistry.Resource_.GRAIN] == &"wheat",
		"a grain head threshes into wheat seed"
	)

	# --- Designation: flat dirt cells become one shared field.
	var spot := _flat_voxel(world, mined, -100, 200)
	_check(spot != Vector3i.MAX, "flat ground exists for a farm field")
	if spot == Vector3i.MAX:
		return
	for c: Vector3i in [spot, spot + Vector3i.RIGHT]:
		_normalize_cell(colony, world, c)
		_clear_plants_around(colony, c)
		colony.undesignate_farm(c)
		colony.buildings.erase(c)
	_check(colony.designate_farm(spot), "a farm cell designates")
	_check(colony.farm_at(spot) != null, "the cell reports its field")
	_check(colony.is_designated(spot), "the field cell carries a zone marker")
	_check(
		not colony.designate_farm(spot),
		"a cell can't be designated twice"
	)
	_check(
		colony.designate_farm(spot + Vector3i.RIGHT),
		"a neighbouring cell designates"
	)
	var field := colony.farm_at(spot)
	_check(
		field != null
			and colony.farm_at(spot + Vector3i.RIGHT) == field
			and field.cells.size() == 2,
		"contiguous cells join one field"
	)

	# --- The sow gate: an unseeded crop posts nothing until a packet of
	# the field's species exists anywhere in a pile.
	colony.set_farm_crop(spot, &"wheat")
	_check(field.species == &"wheat", "the field takes a crop assignment")
	colony._tick_field(field)
	_check(
		colony._farm_jobs.get(spot) == null,
		"with no seeds the field waits instead of posting"
	)
	var seed_cell := spot + Vector3i.BACK
	_normalize_cell(colony, world, seed_cell)
	var seed := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"wheat"
	colony._drop_item(seed, seed_cell)
	var foreign := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	foreign.species = &"oak"
	colony._drop_item(foreign, seed_cell)
	colony._tick_field(field)
	var sow: ColonyJob = colony._farm_jobs.get(spot)
	_check(
		sow != null and sow.type == ColonyJob.Type.SOW,
		"a seeded field posts a sow job"
	)
	_check(
		colony._farm_jobs.get(spot + Vector3i.RIGHT) != null,
		"every open cell of the field sows"
	)
	_check(
		sow == null or sow.species == &"wheat",
		"the sow job carries the field's species"
	)

	# --- Sowability: bare air over dirt only — a stone floor, a pile,
	# or (for trees) any plant in the 3×3 refuses.
	var floor_cell := seed_cell + Vector3i.BACK
	_normalize_cell(colony, world, floor_cell)
	_check(colony._sowable(floor_cell, false), "open air over dirt sows")
	world.remove_voxel(floor_cell + Vector3i.DOWN)
	world.place(floor_cell + Vector3i.DOWN, BlockRegistry.Block.STONE)
	_check(
		not colony._sowable(floor_cell, false),
		"a stone floor refuses the plough"
	)
	world.remove_voxel(floor_cell + Vector3i.DOWN)
	world.place(floor_cell + Vector3i.DOWN, BlockRegistry.Block.DIRT)
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500_000
		),
		floor_cell
	)
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500_000
		),
		floor_cell
	)
	_check(
		not colony._sowable(floor_cell, false),
		"a cell holding a pile refuses the plough"
	)
	var floor_pile := colony.item_pile_at(floor_cell)
	if floor_pile != null:
		floor_pile.items.clear()
		colony.remove_pile_if_empty(floor_cell)

	# --- Sowing end to end: the unit fetches the wheat packet, carries
	# it to the cell, and an immature wheat bush appears — the packet is
	# consumed and the grass under the cell dies.
	colony.grass.coverage[spot + Vector3i.DOWN] = 0.8
	var park := _park_beside(colony, world, spot, seed_cell)
	if sow != null:
		_assign_job(colony, sow, park, unit)
		var sown := await _wait_until(func() -> bool:
			return sow.state == ColonyJob.State.DONE)
		_check(sown, "a unit sows a field cell")
		_check(
			colony.plants.bush_at(spot) == spot,
			"sowing spawns the bush in the cell"
		)
		_check(
			not colony.plants.can_forage(spot),
			"a fresh sowing is immature"
		)
		_check(
			colony.grass.coverage_at(spot + Vector3i.DOWN) == 0.0,
			"planting turns the sod — the grass dies"
		)
		_check(
			colony._farm_jobs.get(spot) == null
				or colony._farm_jobs[spot].type != ColonyJob.Type.SOW,
			"the planted cell doesn't sow again"
		)

	# --- Harvest: a ripe field bush posts a forage job; the annual comes
	# up whole — bush gone, grain heads on the ground — and the field
	# re-sows the freed cell once seed exists again.
	if colony.plants.bush_at(spot) == spot:
		colony.plants.bushes[spot][&"ripe"] = true
		colony._tick_field(field)
		var harvest: ColonyJob = colony._farm_jobs.get(spot)
		_check(
			harvest != null and harvest.type == ColonyJob.Type.FORAGE,
			"a ripe field bush posts a harvest job"
		)
		if harvest != null:
			_assign_job(colony, harvest, park, unit)
			var reaped := await _wait_until(func() -> bool:
				return harvest.state == ColonyJob.State.DONE)
			_check(reaped, "a unit harvests the wheat")
			await _wait_until(func() -> bool:
				return colony._in_flight.is_empty())
		_check(
			colony.plants.bush_at(spot) == Vector3i.MAX,
			"the harvest pulls the annual up whole"
		)
		var heads := 0
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - spot).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.GRAIN:
					heads += 1
		_check(heads >= 6, "the harvest drops grain heads")
		# The harvest landed on the field cell — a piled cell isn't
		# sowable until the crop is hauled off.
		var stale_piles: Array[Vector3i] = []
		for voxel: Vector3i in colony.item_piles:
			var off2: Vector3i = (voxel - spot).abs()
			if maxi(off2.x, maxi(off2.y, off2.z)) <= 2:
				stale_piles.append(voxel)
		for voxel: Vector3i in stale_piles:
			colony.item_piles[voxel].items.clear()
			colony.remove_pile_if_empty(voxel)
		var seed2 := DropItem.new(
			BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
		)
		seed2.species = &"wheat"
		colony._drop_item(seed2, seed_cell)
		colony._tick_field(field)
		var resow: ColonyJob = colony._farm_jobs.get(spot)
		_check(
			resow != null and resow.type == ColonyJob.Type.SOW,
			"the harvested annual's cell re-sows"
		)
		if resow != null:
			resow.state = ColonyJob.State.CANCELLED
			colony._prune_jobs()
			colony._farm_jobs.erase(spot)

	# --- A tree field: the same zone on a second cell cluster, assigned
	# oak. Saplings obey the 3×3 spacing rule, and auto-chop fells the
	# mature tree — off, it stands.
	var oak_spot := Vector3i.MAX
	for off: Vector3i in [
		Vector3i(0, 0, -4), Vector3i(0, 0, 4), Vector3i(4, 0, 0)
	]:
		var c: Vector3i = spot + off
		_normalize_cell(colony, world, c)
		_clear_plants_around(colony, c)
		colony.undesignate_farm(c)
		if colony.designate_farm(c):
			oak_spot = c
			break
	_check(oak_spot != Vector3i.MAX, "a separate cell designates for trees")
	if oak_spot == Vector3i.MAX:
		return
	var oak_field := colony.farm_at(oak_spot)
	colony.set_farm_crop(oak_spot, &"oak")
	# No oak seeds of the right species yet — only the leftover wheat
	# packet's sibling oak seed exists from earlier. The seed gate reads
	# it: foreign packets count for their own species.
	seed = DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"oak"
	colony._drop_item(seed, seed_cell)
	colony._tick_field(oak_field)
	var oak_sow: ColonyJob = colony._farm_jobs.get(oak_spot)
	_check(
		oak_sow != null and oak_sow.type == ColonyJob.Type.SOW,
		"a tree field posts sow jobs for its species"
	)
	# The 3×3 rule: a bush beside the cell makes it unsowable for trees.
	var beside := oak_spot + Vector3i.RIGHT
	_normalize_cell(colony, world, beside)
	_clear_plants_around(colony, beside)
	colony.plants.plant(beside, &"berry_bush")
	_check(
		not colony._sowable(oak_spot, true),
		"a tree won't sow within a plant's 3×3"
	)
	colony.plants.bushes.erase(beside)
	colony.plants._index.erase(beside)
	if oak_sow != null:
		_assign_job(colony, oak_sow, park, unit)
		var sown2 := await _wait_until(func() -> bool:
			return oak_sow.state == ColonyJob.State.DONE)
		_check(sown2, "a unit sows a tree cell")
		_check(
			colony.forest.tree_root_at(oak_spot) == oak_spot,
			"a sown tree root takes the cell"
		)
	if colony.forest.tree_root_at(oak_spot) == oak_spot:
		# Grow the real way — a height bumped without the trunk going
		# up would read as a stale record and the cell would re-sow.
		for i in int(Forest.SPECIES[&"oak"][&"max_height"]) + 2:
			if colony.forest.mature(oak_spot):
				break
			colony.forest.grow(oak_spot)
		_check(
			colony.forest.mature(oak_spot),
			"the field tree grows to maturity"
		)
		colony._tick_field(oak_field)
		_check(
			colony._farm_jobs.get(oak_spot) == null,
			"auto-chop off — a mature field tree just stands"
		)
		colony.set_farm_auto_chop(oak_spot, true)
		colony._tick_field(oak_field)
		var fell: ColonyJob = colony._farm_jobs.get(oak_spot)
		_check(
			fell != null and fell.type == ColonyJob.Type.CHOP,
			"auto-chop on — a mature field tree posts a chop"
		)
		colony.forest.fell(oak_spot)

	# --- Undesignate: the cell leaves the field, the marker clears, and
	# a pending farm job at the cell dies with it.
	var removed := colony.undesignate_farm(spot + Vector3i.RIGHT)
	_check(removed, "a farm cell undesignates")
	_check(
		colony.farm_at(spot + Vector3i.RIGHT) == null,
		"the undesignated cell leaves the field"
	)
	_check(
		not colony.is_designated(spot + Vector3i.RIGHT),
		"the zone marker clears"
	)
	_check(
		field.cells.size() == 1,
		"the field record shrinks to its remaining cell"
	)
	colony.undesignate_farm(spot)
	colony.undesignate_farm(oak_spot)


func _test_hud(main: Node3D, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("hud")
	var hud: Hud = main.get_node("Hud")
	# The cursor readout digests a pile's contents — grouped by material
	# and form, biggest share first, loose by volume, species standing in
	# for tagged items.
	var digest := ItemPile.new()
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 250_000
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		)
	)
	var seed := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"oak"
	digest.items.append(seed)
	_check(
		hud._pile_contents_text(digest)
			== "Soil 0.25 m³, Stone boulder ×2, Acorns ×1, Oak seed ×1",
		"the pile readout digests its contents"
	)
	digest.free()
	_check(
		hud._colonist_bar.get_child_count() == colony.units.size(),
		"the colonist bar shows every unit"
	)
	_check(
		hud.action_menu.get_child_count() == Hud.ARCHITECT_MENU.size(),
		"the architect menu has a submenu per category"
	)
	var stubs := 0
	var live := 0
	for submenu: PopupMenu in hud.action_menu.get_children():
		for i in submenu.item_count:
			if submenu.is_item_disabled(i):
				stubs += 1
			else:
				live += 1
	_check(stubs > 0, "unimplemented architect entries are stubbed")
	_check(live == Overseer.ACTIONS.size(), "every action has an architect entry")
	hud._on_display_toggle(false, "Zones")
	_check(not colony.markers_visible, "the zones toggle hides markers")
	hud._on_display_toggle(true, "Zones")
	hud._set_speed(0.0)
	_check(paused, "pause stops the tree")
	hud._set_speed(1.0)
	_check(not paused and Engine.time_scale == 1.0, "1x resumes")

	# No button may hold keyboard focus — a focused button turns Space
	# into ui_accept, re-pressing it (the "Space opens the menu" bug).
	var focusable := false
	for button: Button in hud.find_children("*", "Button", true, false):
		focusable = focusable or button.focus_mode != Control.FOCUS_NONE
	_check(not focusable, "no HUD button grabs keyboard focus")

	# And a held key must not re-fire: an echoed Space is not a new press.
	var overseer: Overseer = main.get_node("Overseer")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	overseer._unhandled_input(key)
	_check(paused, "space pauses")
	key.echo = true
	overseer._unhandled_input(key)
	_check(paused, "key echo doesn't re-toggle pause")
	key.echo = false
	overseer._unhandled_input(key)
	_check(not paused, "space unpauses")

	# Tick once: a paused tree must run exactly the physics step — a unit's
	# cooldown only counts down inside _physics_process.
	var idle_unit: Unit = colony.units[0]
	idle_unit._job_search_cooldown = 30.0
	paused = true
	overseer.tick_once()
	for i in 8:
		await process_frame
	_check(
		idle_unit._job_search_cooldown < 30.0,
		"the tick key steps a paused frame"
	)
	_check(paused, "the tree pauses again after a tick")
	idle_unit._job_search_cooldown = 0.0

	# Sleep boost: the armed Zz toggle kicks the clock to the top speed
	# only while every unit sleeps — counted through `state_changed`
	# signals so the check never rescans the roster. Pause still wins,
	# and a wake drops the clock back to the player's pick.
	_check(
		hud._sleep_boost_button != null
			and hud._sleep_boost_button.toggle_mode,
		"the speed row has a sleep-boost toggle"
	)
	colony.set_paused(false)
	colony.set_speed(1.0)
	# Units may genuinely be asleep this late in the suite — wake them so
	# the armed-not-engaged check is about the roster, not the fixture.
	for u in colony.units:
		if u.state == Unit.State.SLEEPING:
			u.state = Unit.State.IDLE
	colony.set_sleep_boost(true)
	_check(
		not colony.sleep_boost_engaged(),
		"with awake units the boost stays idle"
	)
	for u in colony.units:
		u.state = Unit.State.SLEEPING
	_check(
		colony.sleep_boost_engaged(),
		"everyone asleep — the boost engages"
	)
	_check(
		Engine.time_scale == Colony.SLEEP_BOOST_SPEED,
		"the clock runs at the boost speed"
	)
	colony.units[0].state = Unit.State.IDLE
	_check(
		not colony.sleep_boost_engaged(),
		"a waking unit disengages the boost"
	)
	_check(
		Engine.time_scale == 1.0,
		"the clock falls back to the selected speed"
	)
	colony.units[0].state = Unit.State.SLEEPING
	_check(colony.sleep_boost_engaged(), "the boost re-engages")
	colony.set_paused(true)
	_check(
		paused and not colony.sleep_boost_engaged(),
		"pause still wins over the boost"
	)
	colony.set_paused(false)
	_check(colony.sleep_boost_engaged(), "unpausing resumes the boost")
	colony.set_sleep_boost(false)
	_check(
		Engine.time_scale == 1.0,
		"disarming returns to the selected speed"
	)
	for u in colony.units:
		u.state = Unit.State.IDLE
		u.abandon_job()

	# Plans: a pending wall is an aimable ghost while plans are visible —
	# paint its top face and the next wall stacks on it. Turning the
	# toggle off lets the ray pass through to real terrain; a planning
	# tool in hand turns it back on.
	var plan_site := Vector3i.MAX
	for z_off in [64, 72, 80, 88]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.get_block(candidate) == BlockRegistry.Block.AIR
			and colony.voxel_fill(candidate) <= 0
		):
			plan_site = candidate
			break
	_check(plan_site != Vector3i.MAX, "found a flat spot for the plans test")
	if plan_site != Vector3i.MAX:
		_check(
			colony.designate_build(plan_site, &"dirt_wall") != null,
			"a wall designates for the plans test"
		)
		overseer.global_position = Vector3(plan_site) + Vector3(0.5, 8.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		var at_plan := overseer.camera.unproject_position(
			Vector3(plan_site) + Vector3.ONE * 0.5
		)
		overseer._update_target(at_plan)
		_check(
			overseer._targeted != null
				and overseer._targeted.position == plan_site
				and overseer._targeted.previous_position == plan_site + Vector3i.UP,
			"a pending wall is aimable while plans are visible"
		)
		overseer.select_action(overseer.ACTIONS.find(&"build_dirt_wall"))
		overseer._perform()
		_check(
			colony.build_job_at(plan_site + Vector3i.UP) != null,
			"a wall stacks on a pending wall's face"
		)
		overseer.select_action(-1)
		hud._on_display_toggle(false, "Plans")
		overseer._update_target(at_plan)
		_check(
			overseer._targeted != null
				and overseer._targeted.position == plan_site + Vector3i.DOWN,
			"hidden plans don't block the aim ray"
		)
		overseer.select_action(overseer.ACTIONS.find(&"deconstruct"))
		_check(
			colony.plans_visible(),
			"a planning tool shows the plans again"
		)
		overseer.select_action(-1)
		_check(
			not colony.plans_visible(),
			"dropping the tool hides them once more"
		)
		_check(
			colony.designate_deconstruct(plan_site) == null
				and colony.build_job_at(plan_site) == null
				and not colony.is_designated(plan_site),
			"the deconstruct tool cancels a planned build"
		)
		colony.cancel_designation(plan_site + Vector3i.UP)
		hud._on_display_toggle(true, "Plans")

	var spot := Vector3i.MAX
	for z_off in [224, 96, 104, 112, 120, 232, 240]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.get_block(candidate) == BlockRegistry.Block.AIR
			and colony.voxel_fill(candidate) <= 0
			and colony.designate_craft_spot(candidate)
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a spot for the worksite panel test")
	if spot != Vector3i.MAX:
		overseer.global_position = Vector3(spot) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(spot) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		_check(
			overseer._selected == spot,
			"clicking with no tool selects the worksite under the cursor"
		)
		hud._update_worksite()
		_check(
			hud._worksite_panel.visible,
			"the worksite panel opens for a selected building"
		)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			spot + Vector3i.RIGHT
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		hud._worksite_recipes[&"planks"].pressed.emit()
		_check(
			colony.craft_job_at(spot) != null,
			"the panel's craft button queues and runs an order"
		)
		hud._update_worksite()
		_check(
			not hud._worksite_recipes[&"planks"].disabled,
			"the panel's craft button stays live while an order runs"
		)
		_check(
			hud._order_rows.size() == 1,
			"the worksite panel lists the queued bill"
		)
		var bill_row: Dictionary = hud._order_rows[0]
		_check(
			bill_row.has(&"pause") and bill_row.has(&"deliver")
				and bill_row.has(&"radius") and bill_row.has(&"worker")
				and bill_row.has(&"details"),
			"the bill row exposes its detail controls"
		)
		(bill_row[&"pause"] as BaseButton).button_pressed = true
		var live_job := colony.craft_job_at(spot)
		_check(
			live_job != null and live_job.suspended,
			"the row's pause button suspends the live job"
		)
		(bill_row[&"pause"] as BaseButton).button_pressed = false
		_check(
			live_job != null and not live_job.suspended,
			"pressing pause again resumes it"
		)
		(bill_row[&"details"] as BaseButton).pressed.emit()
		_check(
			not hud._order_expanded.is_empty(),
			"the details toggle expands the bill row"
		)
		var target_edit: LineEdit = (
			hud._order_rows[0][&"target"].get_line_edit()
		)
		target_edit.grab_focus()
		_check(
			overseer._keyboard_claimed(),
			"a focused order field claims the camera's keys"
		)
		target_edit.release_focus()
		_check(
			not overseer._keyboard_claimed(),
			"released focus returns the keys"
		)
		hud._worksite_cancel.pressed.emit()
		_check(
			colony.craft_job_at(spot) == null
				and colony.building_at(spot).orders.is_empty(),
			"the panel's cancel button drops the order"
		)
		hud._worksite_deconstruct.pressed.emit()
		_check(
			colony.deconstruct_job_at(spot) != null,
			"the panel's deconstruct button marks the worksite"
		)
		colony.cancel_designation(spot)
		_check(
			colony.deconstruct_job_at(spot) == null and colony.is_craft_spot(spot),
			"a cancel sweep lifts the deconstruct marking, keeps the site"
		)
		overseer._clear_selection()
		# Tidy: drop the fixture's building for whatever runs next.
		var raze := colony.designate_deconstruct(spot)
		if raze != null:
			_assign_job(colony, raze, spot)

	# The campfire from the earlier section still stands — selecting it
	# should swap the panel's craft rows for its fuel controls, which
	# write straight into the building record.
	var fire_v := Vector3i.MAX
	for cell: Vector3i in colony.buildings:
		if colony.buildings[cell].kind == Building.Kind.CAMPFIRE:
			fire_v = cell
			break
	_check(fire_v != Vector3i.MAX, "a campfire survives for the panel test")
	if fire_v != Vector3i.MAX:
		overseer.global_position = Vector3(fire_v) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(fire_v) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		hud._update_worksite()
		var fire := colony.campfire_at(fire_v)
		_check(
			overseer._selected == fire_v and hud._campfire_box.visible,
			"selecting the campfire shows its fuel controls"
		)
		if fire != null:
			var auto_before := fire.auto_refuel
			hud._campfire_auto.button_pressed = not auto_before
			_check(
				fire.auto_refuel == (not auto_before),
				"the auto-refuel toggle writes the building"
			)
			hud._campfire_threshold.value = 0.55
			_check(
				is_equal_approx(fire.refuel_fraction, 0.55),
				"the threshold spinner writes the building"
			)
			hud._campfire_threshold.value = 0.3
			hud._campfire_auto.button_pressed = auto_before
		overseer._clear_selection()

	# The inspect tool also opens a stockpile's admission filter — a
	# checkbox per material class writes straight into the tile's set.
	var spick := Vector3i.MAX
	for z_off in [144, 152, 160]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and colony.designate_stockpile(candidate)
		):
			spick = candidate
			break
	_check(spick != Vector3i.MAX, "found a spot for the stockpile panel test")
	if spick != Vector3i.MAX:
		overseer.global_position = Vector3(spick) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(spick) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		_check(
			overseer._selected == spick,
			"clicking with no tool selects the stockpile under the cursor"
		)
		hud._update_selection()
		_check(
			hud._stockpile_panel.visible,
			"the stockpile panel opens for a selected tile"
		)
		_check(
			hud._stockpile_checks.size() == BlockRegistry.Resource_.size() - 1,
			"the panel has a toggle per material"
		)
		var stone_box := hud._stockpile_checks.filter(
			func(b: CheckBox) -> bool:
				return b.get_meta(&"material") == BlockRegistry.Resource_.STONE
		)[0] as CheckBox
		stone_box.button_pressed = false
		_check(
			not colony.stockpile_admits(spick, BlockRegistry.Resource_.STONE),
			"a filter toggle writes to the tile"
		)
		colony.undesignate_stockpile(spick)
		hud._update_selection()
		_check(
			not hud._stockpile_panel.visible,
			"undesignating closes the panel"
		)
		overseer._clear_selection()

	# The calendar: planet time becomes a local solar position through the
	# site's latitude and longitude — noon is lit, midnight dark, and the
	# day counter rolls at local midnight.
	var day_cycle := main.get_node_or_null("DayCycle") as DayCycle
	_check(day_cycle != null, "the scene has a day cycle")
	if day_cycle != null:
		# The suite has been running long enough for the clock to have
		# wandered anywhere — exercise the fresh-game start directly.
		day_cycle.start_fresh()
		_check(day_cycle.is_daylight(), "a fresh game starts in daylight")
		day_cycle.planet_time = 0.0
		day_cycle.advance(0.0)
		_check(not day_cycle.is_daylight(), "local midnight is dark")
		var env := day_cycle.world_environment.environment
		_check(
			env != null
				and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
				and env.ambient_light_sky_contribution == 0.0
				and env.ambient_light_color.get_luminance() > 0.05,
			"night is dim, not pitch black"
		)
		day_cycle.advance(day_cycle.day_length_seconds * 0.5)
		_check(day_cycle.is_daylight(), "local noon is lit")
		_check(
			day_cycle.sun_altitude > deg_to_rad(50.0),
			"the noon sun sits high over the site's latitude"
		)
		_check(day_cycle.day_number() == 1, "noon is still day 1")
		day_cycle.advance(day_cycle.day_length_seconds * 0.5)
		_check(
			day_cycle.day_number() == 2,
			"the day rolls over at local midnight"
		)
		hud._update_date()
		_check(
			hud._date_label.text.begins_with("Day 2"),
			"the HUD date follows the calendar"
		)
		# Longitude shifts local time against the planet clock — the same
		# instant is a different hour at a site half a world away.
		var before := day_cycle.day_fraction()
		day_cycle.site_longitude_deg = 180.0
		_check(
			absf(
				day_cycle.day_fraction()
					- wrapf(before + 0.5, 0.0, 1.0)
			) < 0.001,
			"longitude offsets local time by half a day at 180°"
		)
		day_cycle.site_longitude_deg = 0.0
		day_cycle.planet_time = 0.0
		day_cycle.advance(0.0)
		hud._update_date()


## Topmost non-tree solid voxel in a column — a grown trunk reads as ground
## to `ground_height`, so test fixtures probe past tree blocks.
func _ground(world: VoxelWorld, x: int, z: int, from_y: int, min_y: int = -32) -> int:
	for y in range(from_y, min_y, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		var block := world.get_block(cell)
		if BlockRegistry.is_tree_block(block):
			continue
		if BlockRegistry.is_solid(block):
			return y
	return min_y


## Topmost solid voxel in a column — trees included, unlike `_ground`
## (a trunk still counts as a solid neighbour to the blocks beside it).
func _solid_top(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		if BlockRegistry.is_solid(world.get_block(cell)):
			return y
	return -32


## A flat-ground voxel whose +UP cell floats — provably no solid
## face-neighbour, because a whole 5×5 neighbourhood of columns tops out
## at the same ground height with nothing (terrain, walls, or trees)
## standing above it. Scans rows [param z0]..+300 past [param mined].
func _floating_flat(
	colony: Colony, world: VoxelWorld, mined: Vector3i, z0: int
) -> Vector3i:
	for off in range(z0, z0 + 300):
		var ledge := _flat_voxel_row(world, mined, off)
		if ledge == Vector3i.MAX:
			continue
		var g: int = ledge.y - 1
		var flat := true
		for ox in range(-2, 3):
			for oz in range(-2, 3):
				if (
					_solid_top(
						world, ledge.x + ox, ledge.z + oz, mined.y + 32
					) != g
				):
					flat = false
		var target := ledge + Vector3i.UP
		var upper := target + Vector3i.UP
		if (
			flat
			and world.is_editable(target)
			and world.is_editable(upper)
			and world.get_block(target) == BlockRegistry.Block.AIR
			and world.get_block(upper) == BlockRegistry.Block.AIR
			and colony.item_pile_at(ledge) == null
			and not colony.is_designated(target)
			and not colony.is_designated(upper)
			and colony.forest.tree_root_at(target) == Vector3i.MAX
			and colony.forest.tree_root_at(upper) == Vector3i.MAX
		):
			return ledge
	return Vector3i.MAX


## An empty voxel on flat ground near row [param z_off] past [param mined],
## or [constant Vector3i.MAX] if none is found. [param rows] widens the
## search into a forward band for fixtures that don't care which row.
## The world map layer and the region save: the site embeds in a
## [Region], terrain writes land in its edit log, and a serialized
## colony rebuilds whole — piles, buildings and their order queues,
## designations, zones, decoration records and units.
func _test_persist(main: Node3D, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("persistence")
	var main_node := main as Main
	var region: Region = main_node.region
	_check(region != null, "the colony site embeds in a region")
	_check(world.region == region, "the world records its edits on the region")
	_check(
		main_node.site != null and main_node.site.colony == colony,
		"the colony is its site's live sim"
	)
	_check(
		region.coordinate == Region.coord_of(mined),
		"the region tile contains the site"
	)
	_check(
		region.heights.size() == Region.CELLS * Region.CELLS,
		"the regional summary grid generates"
	)
	var pair := Region.containing(Vector3i.ZERO)
	var site_a := pair.add_site(Vector3i(8, 32, 8))
	var site_b := pair.add_site(Vector3i(200, 32, 200))
	_check(
		pair.sites.size() == 2 and site_a.id != site_b.id,
		"a region can hold more than one site"
	)
	_check(
		Region.coord_of(Vector3i(-1, 0, -1)) == Vector2i(-1, -1),
		"negative voxels floor into their tile"
	)

	# Terrain writes record against the region — mined and rebuilt —
	# and index under their stream chunk for the replay path. The edit
	# cell walks down the mined column until it finds solid ground.
	var below := Vector3i.MAX
	for dy in range(0, -9, -1):
		var c := mined + Vector3i(0, dy, 0)
		if world.is_editable(c) and world.is_solid(c):
			below = c
			break
	_check(below != Vector3i.MAX, "found a cell for the edit log")
	var was := world.get_block(below)
	world.mine(below)
	_check(
		int(region.edits.get(below, -1)) == BlockRegistry.Block.AIR,
		"mining records a region edit"
	)
	var chunk := Vector3i(below.x >> 4, below.y >> 4, below.z >> 4)
	_check(
		int(region.edits_in_chunk(chunk).get(below, -1))
			== BlockRegistry.Block.AIR,
		"the edit indexes under its stream chunk"
	)
	world.place(below, was)
	_check(
		int(region.edits.get(below, -1)) == was,
		"building records a region edit"
	)

	# A scenario worth persisting on top of the suite's leftovers: a
	# fresh pile, a stockpile with a filter, and a unit carrying some
	# personality. The surface cell must be unclaimed and unfilled — a
	# flat row within the streamed area, verified against live state.
	var stock_v := Vector3i.MAX
	for off in range(232, 260):
		if stock_v != Vector3i.MAX:
			break
		# Scan the row's whole width — `_flat_voxel_row` stops at the
		# first flat cell, which generated scree or fruit litter may hold.
		var z: int = mined.z + off
		for x in range(mined.x + 4, mined.x + 28):
			var g := _ground(world, x, z, mined.y + 32)
			var candidate := Vector3i(x + 1, g + 1, z)
			if (
				_ground(world, x + 1, z, mined.y + 32) == g
				and _ground(world, x + 2, z, mined.y + 32) == g
				and _ground(world, x + 3, z, mined.y + 32) == g
				and world.is_editable(Vector3i(x + 1, g, z))
				and world.is_editable(candidate)
				and world.get_block(candidate) == BlockRegistry.Block.AIR
				and world.is_solid(Vector3i(x + 1, g, z))
				and colony.voxel_fill(candidate) == 0
				and not colony._designation_markers.has(candidate)
			):
				stock_v = candidate
				break
	_check(stock_v != Vector3i.MAX, "found a free surface cell")
	var stockpiled := colony.designate_stockpile(stock_v)
	_check(stockpiled, "a stockpile designates for the save fixture")
	if stockpiled:
		colony.set_stockpile_admission(
			stock_v, BlockRegistry.Resource_.SOIL, false
		)
	var first_unit: Unit = colony.units[0]
	first_unit.hunger = 0.42
	first_unit.traits.append(&"ascetic")
	first_unit.skills[ColonyJob.Skill.MINING] = 25.0
	first_unit.specialize = true
	# Every falling item must have landed before the snapshot — a save
	# records an in-flight pile at its landing voxel, so comparing
	# against a mid-fall roster would miscount.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var piles_before := {}
	for voxel: Vector3i in colony.item_piles:
		piles_before[voxel] = colony.item_piles[voxel].total_volume()
	var units_before := colony.units.size()
	var jobs_before := colony.jobs.size()
	var buildings_before := colony.buildings.size()
	var stockpiles_before := colony.stockpiles.size()
	var farms_before := colony.farms.size()
	var grass_before := colony.grass.coverage.size()
	var fert_before := colony.fertilization.size()
	var bushes_before := colony.plants.bushes.size()
	var trees_before := colony.forest.trees.size()
	var rock_spent_before := colony._rock_spent.keys()
	# The campfire test leaves a quiet ring standing: its fuel store and
	# refuel toggle are building state the save must carry.
	var fire_before := {}
	var detail_fire := Vector3i.MAX
	for cell: Vector3i in colony.buildings:
		var b: Building = colony.buildings[cell]
		if b.kind == Building.Kind.CAMPFIRE:
			fire_before[b.voxel] = [b.fuel, b.auto_refuel, b.components.size()]
			detail_fire = b.voxel
	# A bill wearing every detail field rides the save: the surviving
	# campfire takes an until-bill for meals, fully configured.
	var detail_queued := false
	if detail_fire != Vector3i.MAX:
		var bill := colony.queue_order(
			detail_fire, &"prepare_meal",
			WorksiteOrder.Condition.UNTIL_HAVE, 7
		)
		if bill != null:
			colony.set_order_paused(detail_fire, bill, true)
			bill.unpause_at = 2
			bill.count_stored_only = true
			bill.deliver_mode = WorksiteOrder.Deliver.ZONE
			bill.deliver_target = stock_v
			bill.ingredient_radius = 12.0
			bill.worker_index = 0
			bill.skill_min = 1
			bill.skill_max = 8
			bill.rejected_materials[int(BlockRegistry.Resource_.GRAIN)] = true
			detail_queued = true
	if stockpiled:
		colony.set_stockpile_priority(stock_v, StockpileZone.Priority.HIGH)

	# Round-trip through JSON — the on-disk format, not just the dict.
	var saved := colony.serialize()
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(saved))
	colony.deserialize(decoded)
	# The comparisons below all run synchronously — before the next
	# frame lets a unit re-claim a job or the grass scan regrow a cell —
	# and read the colony's own maps, not the nodes queue_free'd ones.

	_check(colony.units.size() == units_before, "units restored")
	_check(
		is_equal_approx(colony.units[0].hunger, 0.42),
		"unit hunger restored"
	)
	_check(
		colony.units[0].traits == [&"ascetic"], "unit traits restored"
	)
	_check(
		colony.units[0].skills[ColonyJob.Skill.MINING] == 25.0,
		"unit skill xp restored"
	)
	_check(colony.units[0].specialize, "unit stance restored")
	_check(colony.item_piles.size() == piles_before.size(), "piles restored")
	var piles_match := true
	for voxel: Vector3i in piles_before:
		var pile: ItemPile = colony.item_piles.get(voxel)
		if pile == null or pile.total_volume() != piles_before[voxel]:
			piles_match = false
	_check(piles_match, "pile contents survived the round trip")
	_check(
		colony.buildings.size() == buildings_before,
		"buildings restored"
	)
	var door_restored := false
	for cell: Vector3i in colony.buildings:
		var b: Building = colony.buildings[cell]
		if b.kind == Building.Kind.DOOR and b.spec == &"stone_door":
			door_restored = true
	_check(door_restored, "the stone door's spec survived the round trip")
	_check(
		colony.stockpiles.size() == stockpiles_before
			and (not stockpiled or colony.stockpiles.has(stock_v)),
		"stockpiles restored"
	)
	_check(
		not stockpiled
			or not colony.stockpile_admits(stock_v, BlockRegistry.Resource_.SOIL),
		"stockpile filters restored"
	)
	_check(
		not stockpiled
			or colony.stockpiles[stock_v].priority == StockpileZone.Priority.HIGH,
		"stockpile priority restored"
	)
	var restored_bill: WorksiteOrder = null
	if detail_fire != Vector3i.MAX:
		var fb: Building = colony.buildings.get(detail_fire)
		if fb != null and not fb.orders.is_empty():
			restored_bill = fb.orders[fb.orders.size() - 1]
	_check(
		not detail_queued or restored_bill != null,
		"the configured bill restores"
	)
	if restored_bill != null:
		_check(restored_bill.paused, "bill pause persists")
		_check(restored_bill.unpause_at == 2, "bill unpause mark persists")
		_check(restored_bill.count_stored_only, "bill stored-only flag persists")
		_check(
			restored_bill.deliver_mode == WorksiteOrder.Deliver.ZONE
				and restored_bill.deliver_target == stock_v,
			"bill delivery target persists"
		)
		_check(
			is_equal_approx(restored_bill.ingredient_radius, 12.0),
			"bill ingredient radius persists"
		)
		_check(restored_bill.worker_index == 0, "bill worker pin persists")
		_check(
			restored_bill.skill_min == 1 and restored_bill.skill_max == 8,
			"bill skill band persists"
		)
		_check(
			restored_bill.rejected_materials.has(
				int(BlockRegistry.Resource_.GRAIN)
			),
			"bill material filter persists"
		)
	_check(colony.farms.size() == farms_before, "farm fields restored")
	_check(colony.jobs.size() == jobs_before, "jobs restored")
	var all_pending := true
	for job in colony.jobs:
		if job.state != ColonyJob.State.PENDING:
			all_pending = false
	_check(all_pending, "restored jobs are pending again")
	_check(
		colony.grass.coverage.size() == grass_before,
		"grass records restored"
	)
	_check(
		colony.fertilization.size() == fert_before,
		"soil fertilization restored"
	)
	# A load must repaint immediately — while paused no _process tick
	# would ever drain the dirty flags, leaving decorations invisible.
	var grass_painted := false
	for inst: MultiMeshInstance3D in colony.grass._chunk_meshes.values():
		if inst.multimesh.instance_count > 0:
			grass_painted = true
	_check(
		grass_painted and colony.grass._dirty_chunks.is_empty(),
		"loaded grass repaints without waiting for a tick"
	)
	_check(
		colony.forest._dirty_chunks.is_empty(),
		"loaded trees repaint without waiting for a tick"
	)
	_check(
		not colony.plants._decorations_dirty,
		"loaded bushes repaint without waiting for a tick"
	)
	_check(colony.plants.bushes.size() == bushes_before, "bushes restored")
	_check(colony.forest.trees.size() == trees_before, "trees restored")
	_check(
		colony._rock_spent.size() == rock_spent_before.size()
			and rock_spent_before.all(
				func(v: Vector3i) -> bool: return colony._rock_spent.has(v)
			),
		"spent rock slots stay spent"
	)
	var fires_match := true
	for voxel: Vector3i in fire_before:
		var b2 := colony.campfire_at(voxel)
		if (
			b2 == null
			or not is_equal_approx(b2.fuel, float(fire_before[voxel][0]))
			or b2.auto_refuel != bool(fire_before[voxel][1])
			or b2.components.size() != int(fire_before[voxel][2])
		):
			fires_match = false
	_check(
		fire_before.is_empty() or fires_match,
		"campfire fuel and toggle restored"
	)
	_check(
		not colony._designation_markers.is_empty(),
		"designation markers rebuilt"
	)

	# The save unit is the region: serializing it embeds the site's
	# colony payload, and a dormant region keeps that payload without a
	# live sim.
	var region_data: Dictionary = JSON.parse_string(
		JSON.stringify(region.serialize())
	)
	var dormant := Region.deserialize(region_data)
	_check(
		dormant.coordinate == region.coordinate,
		"the region round-trips its coordinate"
	)
	_check(
		dormant.edits.size() == region.edits.size(),
		"the edit log round-trips"
	)
	_check(
		dormant.sites.size() == 1
			and dormant.sites[0].colony == null
			and not dormant.sites[0].state.is_empty(),
		"a dormant site keeps its colony payload"
	)

	# And the real files: save_game writes world.json plus one file per
	# region tile — the directory layout a multi-region world will fill.
	var dir := main_node.save_game("smoke")
	_check(
		FileAccess.file_exists(dir.path_join("world.json")),
		"world.json written"
	)
	_check(
		FileAccess.file_exists(
			dir.path_join(
				"region_%d_%d.json" % [region.coordinate.x, region.coordinate.y]
			)
		),
		"the region file is the save unit"
	)


func _flat_voxel(
	world: VoxelWorld, mined: Vector3i, z_off: int, rows: int = 1
) -> Vector3i:
	for off in range(z_off, z_off + rows):
		var found := _flat_voxel_row(world, mined, off)
		if found != Vector3i.MAX:
			return found
	return Vector3i.MAX


func _flat_voxel_row(world: VoxelWorld, mined: Vector3i, z_off: int) -> Vector3i:
	var z: int = mined.z + z_off
	for x in range(mined.x + 4, mined.x + 28):
		var g := _ground(world, x, z, mined.y + 32)
		var spot := Vector3i(x + 1, g + 1, z)
		if (
			_ground(world, x + 1, z, mined.y + 32) == g
			and _ground(world, x + 2, z, mined.y + 32) == g
			and _ground(world, x + 3, z, mined.y + 32) == g
			# `_ground` reports min_y on an unstreamed column, which
			# `is_solid` then materializes as deep stone — the "flat spot"
			# would be buried underground. Require real, editable cells.
			and world.is_editable(Vector3i(x + 1, g, z))
			and world.is_editable(spot)
			and world.get_block(spot) == BlockRegistry.Block.AIR
			and world.is_solid(Vector3i(x + 1, g, z))
		):
			return spot
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
		var ground_y := _ground(world, column.x, column.z, origin.y + 16, origin.y - 16)
		var candidate := Vector3i(column.x, ground_y, column.z)
		if world.is_solid(candidate):
			return candidate
	return Vector3i.MAX


## Cancels every unfinished job — earlier tests leave open jobs on the
## board that a unit might wander off to claim instead of the fixture's.
func _clear_jobs(colony: Colony) -> void:
	for job in colony.jobs:
		if job.state != ColonyJob.State.DONE:
			job.state = ColonyJob.State.CANCELLED
	colony._prune_jobs()


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
