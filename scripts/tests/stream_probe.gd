extends SceneTree

## One-off diagnostic: how many stream-block loads fire at boot, and what
## each subsystem's per-block handler costs on the main thread.

var _blocks := 0
var _grass_us := 0
var _forest_us := 0
var _plants_us := 0
var _replay_us := 0
var _colony: Colony
var _world: VoxelWorld


func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_world = main.get_node("VoxelWorld")
	_colony = main.get_node("Colony")
	_world.block_loaded.connect(_on_block_loaded, CONNECT_DEFERRED)
	await process_frame
	var t0 := Time.get_ticks_msec()
	var deadline := t0 + 120_000
	while _colony.units.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	print("PROBE|time_to_units_ms|%d" % (Time.get_ticks_msec() - t0))
	print("PROBE|blocks_loaded|%d" % _blocks)
	print("PROBE|grass_handler_ms|%.1f" % (_grass_us / 1000.0))
	print("PROBE|forest_handler_ms|%.1f" % (_forest_us / 1000.0))
	print("PROBE|plants_handler_ms|%.1f" % (_plants_us / 1000.0))
	print("PROBE|replay_handler_ms|%.1f" % (_replay_us / 1000.0))
	print("PROBE|grass_cells|%d" % _colony.grass.coverage.size())
	print("PROBE|grass_pending|%d" % _colony.grass._pending.size())
	print("PROBE|forest_trees|%d" % _colony.forest.trees.size())
	print("PROBE|plants_bushes|%d" % _colony.plants.bushes.size())
	var t := Time.get_ticks_usec()
	_colony.grass._refresh_decorations()
	print("PROBE|grass_refresh_ms|%.2f" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	_colony.forest._refresh_decorations()
	print("PROBE|forest_refresh_ms|%.2f" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	_colony.plants._refresh_decorations()
	print("PROBE|plants_refresh_ms|%.2f" % ((Time.get_ticks_usec() - t) / 1000.0))
	quit(0)


func _on_block_loaded(origin: Vector3i) -> void:
	_blocks += 1
	if _colony.grass == null:
		return
	var t := Time.get_ticks_usec()
	_colony.grass._on_block_loaded(origin)
	_grass_us += Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	_colony.forest._on_block_loaded(origin)
	_forest_us += Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	_colony.plants._on_block_loaded(origin)
	_plants_us += Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	_world._replay_chunk_edits(origin)
	_replay_us += Time.get_ticks_usec() - t
