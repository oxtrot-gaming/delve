extends SceneTree

## Dead-snag and orphan-tree regression.
##
## A killed tree keeps its record after the canopy sheds and stays
## choppable — dead wood is still wood. A fell that runs while part of
## the tree sits in unstreamed terrain must not leave orphan blocks: the
## record owns those cells, so the clear lands in the region edit log.
## And a snag that already lost its record (saves from before the fix)
## still designates, prices, and fells through the normal chop path.
##
##     godot --headless --path . --script res://scripts/tests/tree_snag_probe.gd

var _failures: PackedStringArray = []


func _initialize() -> void:
	_run()


func _check(ok: bool, message: String) -> void:
	if ok:
		print("  ok: ", message)
	else:
		_failures.append(message)
		printerr("  FAILED: ", message)


func _run() -> void:
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var world: VoxelWorld = main.world
	var colony: Colony = main.colony
	var forest: Forest = colony.forest
	for u in colony.units:
		u._job_search_cooldown = 1e9

	var base := _open_spot(world, colony, forest, main.site.bounds)
	_check(base != Vector3i.MAX, "found open ground for the tree test")
	if base == Vector3i.MAX:
		_finish()
		return

	# Grow a full oak and kill it — the canopy sheds to compost but the
	# snag keeps its record and its wood.
	_check(forest.plant_sapling(base), "a sapling plants")
	var sp: Dictionary = Forest.species_table()[&"oak"]
	for i in int(sp[&"max_height"]):
		forest.grow(base)
	forest._kill(base)
	var rec: Dictionary = forest.trees[base]
	forest._shed_canopy(base, rec, sp)
	_check(rec.get(&"dead", false), "the killed tree is marked dead")
	_check(forest.trees.has(base), "a dead snag keeps its record")
	_check(
		forest.tree_root_at(base) == base,
		"a dead snag still resolves by root"
	)
	var dead_job := colony.designate_chop(base + Vector3i.UP)
	_check(
		dead_job != null and dead_job.voxel_position == base,
		"a dead snag is choppable from any part"
	)
	_check(
		forest.tree_work(base) > 0.0,
		"a dead snag prices its remaining wood"
	)

	# Fell it — the blocks go, the slot is tombstoned, drops land.
	forest.fell(base)
	_check(not forest.trees.has(base), "felling erases the record")
	_check(
		not BlockRegistry.is_tree_block(world.get_block(base)),
		"felling removes the trunk block"
	)
	_check(forest._destroyed.has(base), "felling tombstones the slot")

	# Orphan snag: blocks a record no longer owns — the leftover state a
	# pre-fix save carries. Designating must produce a chop job, price
	# the work, and fell the snag through the same path.
	var orphan := base
	if world.get_block(orphan) != BlockRegistry.Block.AIR:
		orphan = _open_spot(world, colony, forest, main.site.bounds)
	_check(orphan != Vector3i.MAX, "found open ground for the orphan snag")
	if orphan == Vector3i.MAX:
		_finish()
		return
	var cells: Array[Vector3i] = [
		orphan, orphan + Vector3i.UP, orphan + Vector3i.UP * 2
	]
	world.place(cells[0], BlockRegistry.Block.TRUNK)
	world.place(cells[1], BlockRegistry.Block.TRUNK)
	world.place(cells[2], BlockRegistry.Block.BRANCH)
	_check(
		forest.tree_root_at(orphan) == Vector3i.MAX,
		"an orphan snag has no record"
	)
	var orphan_job := colony.designate_chop(cells[1])
	_check(orphan_job != null, "an orphan snag designates for chopping")
	if orphan_job == null:
		_finish()
		return
	_check(
		orphan_job.extra_voxels.size() == cells.size(),
		"the orphan job carries the whole snag"
	)
	_check(
		forest.tree_work(orphan) > 0.0,
		"an orphan snag prices its blocks"
	)
	forest.fell(orphan)
	var left := 0
	for voxel in cells:
		if BlockRegistry.is_tree_block(world.get_block(voxel)):
			left += 1
	_check(left == 0, "felling an orphan snag removes its blocks")
	# Drops launched from the snag settle through the pile flight queue.
	for i in 600:
		if colony._in_flight.is_empty():
			break
		await process_frame
	var logs := 0
	var branches := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - orphan).length() > 6.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.form == DropItem.Form.LOG
				and item.material == BlockRegistry.Resource_.WOOD
			):
				logs += 1
			elif item.material == BlockRegistry.Resource_.BRANCH:
				branches += item.volume
	_check(logs >= 2, "an orphan snag drops a log per trunk voxel")
	_check(branches > 0.0, "an orphan snag drops its branches")

	# The leak itself: an owned cell in unstreamed terrain can't be read
	# or written live — the fell must log the clear so stream-in can't
	# resurrect the block.
	var far := Vector3i(orphan.x + 500, 60, orphan.z + 500)
	if world.is_editable(far):
		far = _unstreamed_cell(world, main.site.bounds)
	_check(
		not world.is_editable(far),
		"found an unstreamed cell for the edit-log check"
	)
	if not world.is_editable(far):
		world.remove_voxel_recorded(far)
		_check(
			int(world.region.edits.get(far, -1))
				== BlockRegistry.Block.AIR,
			"an unstreamed fell records the clear in the edit log"
		)

	_finish()


## Open, editable air over solid ground inside [param bounds] — no tree,
## no pile, room overhead for a canopy.
func _open_spot(
	world: VoxelWorld, colony: Colony, forest: Forest, bounds: Rect2i
) -> Vector3i:
	for x in range(bounds.position.x + 4, bounds.end.x - 4, 3):
		for z in range(bounds.position.y + 4, bounds.end.y - 4, 3):
			var y := world.ground_height(x, z)
			if y <= -32:
				continue
			var cell := Vector3i(x, y + 1, z)
			if not world.is_editable(cell):
				continue
			if world.get_block(cell) != BlockRegistry.Block.AIR:
				continue
			if forest.tree_root_at(cell) != Vector3i.MAX:
				continue
			if colony.item_pile_at(cell) != null:
				continue
			var clear := true
			for dy in range(1, 4):
				var above := cell + Vector3i(0, dy, 0)
				if world.get_block(above) != BlockRegistry.Block.AIR:
					clear = false
			if clear:
				return cell
	return Vector3i.MAX


## A voxel outside the streamed set — walks outward past the site edge
## until `is_editable` gives up.
func _unstreamed_cell(world: VoxelWorld, bounds: Rect2i) -> Vector3i:
	var x := bounds.end.x + 64
	var z := bounds.get_center().y
	while world.is_editable(Vector3i(x, 60, z)) and x < bounds.end.x + 4096:
		x += 64
	return Vector3i(x, 60, z)


func _finish() -> void:
	if _failures.is_empty():
		print("TREE SNAG PROBE PASSED")
		quit(0)
	else:
		printerr("%d failure(s)" % _failures.size())
		quit(1)
