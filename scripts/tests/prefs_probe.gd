extends SceneTree

## Focused check for the item-69 unit tastes: preference roll, the
## meal/bed/seat/worn/art reads, made_of provenance, sculpture depicts.
##
##     godot --headless --path . --script res://scripts/tests/prefs_probe.gd

var _fails := 0


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok: %s" % label)
	else:
		_fails += 1
		print("  FAIL: %s" % label)


func _ground(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		if world.is_solid(Vector3i(x, y, z)):
			return y
	return -32


func _initialize() -> void:
	_run()


func _run() -> void:
	DataPackage.install(&"vanilla", &"dev")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")
	for i in 600:
		await process_frame
		if colony.units.size() > 0:
			break
	if colony.units.is_empty():
		print("PROBE: no units")
		quit(1)
		return
	if world.sim != null:
		world.sim.water_set_paused(true)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	colony.auto_home = false

	var unit: Unit = colony.units[0]
	unit._job_search_cooldown = 600.0
	unit.abandon_job()
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 600.0

	# --- the roll
	print("roll")
	_check(
		unit.preferences.size() >= Unit.PREFERENCE_MIN
			and unit.preferences.size() <= Unit.PREFERENCE_MAX,
		"spawn rolled a handful of tastes: %s" % unit.preferences
	)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.CLOTH): 1,
		Unit.pref_key_species(&"wolf"): 1,
		Unit.pref_key_material(BlockRegistry.Resource_.MARBLE): -1,
	}
	print("  text: %s" % unit.preferences_text())
	_check(
		unit.preferences_text() == "Likes: cotton cloth, wolf · Dislikes: marble",
		"preferences_text lists both ends"
	)

	# --- serialize round-trip
	var data := unit.serialize()
	var clone: Unit = colony.spawn_unit(
		Vector3i(unit.global_position) + Vector3i(3, 0, 0)
	)
	clone.deserialize(data, colony)
	clone._job_search_cooldown = 600.0
	_check(
		clone.preferences == unit.preferences,
		"tastes round-trip: %s" % clone.preferences
	)
	colony.units.erase(clone)
	clone.queue_free()

	# --- a flat pad
	var mined := Vector3i(unit.global_position)
	var pad := Vector3i.MAX
	for z in range(mined.z + 6, mined.z + 30):
		var g := _ground(world, mined.x + 20, z, mined.y + 24)
		var spot := Vector3i(mined.x + 20, g + 1, z)
		if world.get_block(spot) == BlockRegistry.Block.AIR:
			pad = spot
			break
	if pad == Vector3i.MAX:
		print("PROBE: no pad")
		quit(1)
		return
	var stand := pad
	unit.global_position = Vector3(stand) + Vector3(0.5, 0.02, 0.5)

	# --- the plate
	print("plate")
	var stew := DropItem.new(
		BlockRegistry.Resource_.MEAL,
		DropItem.Form.MEAL, DropItem.form_volume(DropItem.Form.MEAL)
	)
	stew.nutrition = 0.5
	stew.made_of = [
		{&"material": int(BlockRegistry.Resource_.MEAT), &"species": &"wolf"},
		{&"material": int(BlockRegistry.Resource_.BERRY), &"species": &""},
	]
	colony._deposit_item(stew, stand)
	unit.preferences = {Unit.pref_key_species(&"wolf"): 1}
	unit._thoughts.clear()
	unit.hunger = 0.5
	unit.job = ColonyJob.new(ColonyJob.Type.EAT, stand)
	unit.state = Unit.State.EATING
	unit._tick_eating(1.0)
	_check(
		unit._thoughts.has(&"ate_favourite"),
		"wolf stew for a wolf-fan: %s" % [unit._thoughts.keys()]
	)
	_check(
		not unit._thoughts.has(&"ate_disfavoured"),
		"no complaint on the liked plate"
	)

	var gruel := DropItem.new(
		BlockRegistry.Resource_.MEAL,
		DropItem.Form.MEAL, DropItem.form_volume(DropItem.Form.MEAL)
	)
	gruel.nutrition = 0.5
	gruel.made_of = [
		{&"material": int(BlockRegistry.Resource_.MEAT), &"species": &"rabbit"},
	]
	colony._deposit_item(gruel, stand)
	unit.preferences = {Unit.pref_key_species(&"rabbit"): -1}
	unit._thoughts.clear()
	unit.hunger = 0.5
	unit.job = ColonyJob.new(ColonyJob.Type.EAT, stand)
	unit.state = Unit.State.EATING
	unit._tick_eating(1.0)
	_check(
		unit._thoughts.has(&"ate_disfavoured"),
		"rabbit stew for a rabbit-hater: %s" % [unit._thoughts.keys()]
	)

	# --- the bed
	print("bed")
	var bed := Building.new(Building.Kind.BED, stand + Vector3i(1, 0, 0))
	bed.spec = &"bed"
	bed.material = BlockRegistry.Resource_.MARBLE
	bed.footprint.append(bed.voxel + Vector3i(0, 0, 1))
	colony.register_building(bed)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.MARBLE): 1,
	}
	unit._thoughts.clear()
	unit._rest_bed = bed
	unit._rest_quality = Unit.RestQuality.NORMAL
	unit._wake()
	_check(
		unit._thoughts.has(&"favoured_material"),
		"marble bed for a marble-fan: %s" % [unit._thoughts.keys()]
	)
	colony._teardown_building(bed.voxel)

	# --- the seat and table at the meal
	var table := Building.new(Building.Kind.TABLE, stand + Vector3i(1, 0, 0))
	table.spec = &"table_1x2"
	table.material = BlockRegistry.Resource_.MARBLE
	table.footprint.append(table.voxel + Vector3i(0, 0, 1))
	colony.register_building(table)
	var chair := Building.new(Building.Kind.SEAT, stand + Vector3i(-1, 0, 0))
	chair.spec = &"dining_chair"
	chair.material = BlockRegistry.Resource_.SLATE
	colony.register_building(chair)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.MARBLE): 1,
		Unit.pref_key_material(BlockRegistry.Resource_.SLATE): -1,
	}
	unit._thoughts.clear()
	unit._meal_ate = true
	unit._meal_voxel = stand
	unit._finish_meal()
	_check(
		unit._thoughts.has(&"favoured_material")
			and unit._thoughts.has(&"disfavoured_material"),
		"marble table + slate chair each earn their say: %s"
			% [unit._thoughts.keys()]
	)

	# --- worn
	print("worn")
	var shirt := DropItem.new(
		BlockRegistry.Resource_.CLOTH, DropItem.Form.GARMENT, 20_000
	)
	shirt.spec = &"tribalwear"
	unit.worn.append(shirt)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.CLOTH): 1,
	}
	_check(
		unit._state_thought_on(&"wearing_liked"),
		"cotton shirt reads liked"
	)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.CLOTH): -1,
	}
	_check(
		unit._state_thought_on(&"wearing_disliked"),
		"cotton shirt reads sour to a cloth-hater"
	)
	unit.worn.clear()

	# --- the carved work
	print("art")
	var statue := Building.new(Building.Kind.DECOR, stand + Vector3i(2, 0, 0))
	statue.spec = &"sculpture"
	statue.material = BlockRegistry.Resource_.MARBLE
	statue.depicts = &"wolf"
	colony.register_building(statue)
	unit.preferences = {Unit.pref_key_species(&"wolf"): 1}
	_check(
		unit._state_thought_on(&"admired_art"),
		"wolf statue admired by a wolf-fan"
	)
	_check(
		not unit._state_thought_on(&"resented_art"),
		"and not resented"
	)
	unit.preferences = {
		Unit.pref_key_material(BlockRegistry.Resource_.MARBLE): -1,
	}
	_check(
		unit._state_thought_on(&"resented_art"),
		"marble statue resented by a marble-hater"
	)
	unit.preferences = {
		Unit.pref_key_species(&"wolf"): 1,
		Unit.pref_key_material(BlockRegistry.Resource_.MARBLE): -1,
	}
	_check(
		unit._state_thought_on(&"admired_art")
			and unit._state_thought_on(&"resented_art"),
		"a wolf in marble earns both ends"
	)
	print("  label: %s" % statue.label())
	_check(
		statue.label() == "fair Sculpture of a wolf",
		"the work's label names its subject"
	)

	# --- a real carve sets depicts
	var carve_site := pad + Vector3i(0, 0, 4)
	var carve_job := ColonyJob.new(ColonyJob.Type.CRAFT, carve_site)
	carve_job.recipe = &"small_sculpture"
	carve_job.material = BlockRegistry.Resource_.GRANITE
	colony.complete_construct(carve_job)
	var carved: Building = colony.buildings.get(carve_site)
	_check(
		carved != null and carved.depicts != &"",
		"a finished carving takes a subject: %s" % (
			"none" if carved == null else carved.depicts
		)
	)

	# --- item provenance round-trip
	var loaded := DropItem.deserialize(stew.serialize())
	_check(
		loaded.made_of.size() == 2
			and loaded.made_of[0][&"species"] == &"wolf",
		"the stew's made_of survives serialize"
	)

	print("PROBE %s" % ("PASSED" if _fails == 0 else "FAILED %d" % _fails))
	quit(0 if _fails == 0 else 1)
