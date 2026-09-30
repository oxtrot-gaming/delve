class_name VoxelWorld
extends VoxelTerrain

## The mineable world. Wraps [VoxelTerrain] with the game's block vocabulary:
## block queries, digging, building and voxel grid pathfinding.

signal block_mined(position: Vector3i, block_id: int)
signal block_placed(position: Vector3i, block_id: int)
## Fired once per cell as an unsupported block comes out — carries the id
## the cell held, so listeners can drop the mined-equivalent rubble.
signal block_collapsed(position: Vector3i, block_id: int)
## Fires on every terrain write — mined, placed, collapsed or silently
## erased — carrying the cell's NEW block id. The semantic signals above
## answer "what happened"; this one answers "what does the terrain look
## like now", which is all the region's persistence edit log needs.
signal block_edited(position: Vector3i, block_id: int)

const Blocks := BlockRegistry.Block
const DLog := preload("res://scripts/dlog.gd")

@export var world_seed: int = 1337

## The world-map tile this terrain belongs to — the persistence unit
## the edit log records into and replays from. Set by Main at boot.
var region: Region = null
var generator_script: WorldGenerator
var _tool: VoxelTool
var _astar := VoxelAStarGrid3D.new()
## Native voxel mirror (DelveSim) when the delve_native extension is
## loaded — the sim's flat-array stand-in for VoxelTool queries and the
## native fill-aware A*. Null without the extension; every use falls back.
var sim: RefCounted = null
## Re-entrancy guard for collapse: a doomed set is computed whole, so the
## removals it performs don't each start their own support check.
var _in_collapse := false


func _ready() -> void:
	var blocky_mesher := VoxelMesherBlocky.new()
	blocky_mesher.library = BlockRegistry.build_library()
	mesher = blocky_mesher

	# WorldGenerator is the runnable generator AND the column oracle; it
	# forwards block fills to the compiled DelveGenerator when the
	# delve_native extension is loaded, and fills them itself otherwise.
	generator_script = WorldGenerator.new()
	generator_script.world_seed = world_seed
	generator = generator_script

	_tool = get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_TYPE
	_tool.mode = VoxelTool.MODE_SET

	_astar.set_terrain(self)

	# The region's edit log records every write and replays onto each
	# streamed block. The replay connection must run before Colony's own
	# block_loaded handlers, so the decorations they seed already see the
	# edited terrain — VoxelWorld readies before Colony in scene order.
	block_loaded.connect(_replay_chunk_edits)
	block_edited.connect(_on_block_edited)

	if ClassDB.class_exists(&"DelveSim"):
		var delve_sim: RefCounted = ClassDB.instantiate(&"DelveSim")
		if delve_sim.configure(generator_script.native_generator()):
			sim = delve_sim
			block_loaded.connect(sim.on_block_loaded)
			block_unloaded.connect(sim.on_block_unloaded)
			# With sim-owned unit motion nothing queries physics space —
			# unit raycasts go through VoxelTool, pile occupancy through
			# pile_fill. Skipping colliders keeps ~200 bodies from
			# broadphasing against terrain trimeshes every tick.
			generate_collisions = false
			DLog.log("DelveSim configured")


## Replays the region's edit log onto a freshly streamed block —
## [param chunk] is the block coord block_loaded reports, not a voxel.
## The same path a save-load restore takes, and the fix for chunk-unload
## amnesia: the streamer never persisted edits, so without this a
## re-streamed chunk would regenerate pristine. Silent by design —
## decoration systems seed from the edited state in their own
## block_loaded handlers, which run after this one.
func _replay_chunk_edits(chunk: Vector3i) -> void:
	if region == null:
		return
	for voxel: Vector3i in region.edits_in_chunk(chunk):
		var block_id: int = region.edits[voxel]
		if _tool.get_voxel(voxel) == block_id:
			continue
		_tool.value = block_id
		_tool.do_point(voxel)
		if sim != null:
			sim.set_block(voxel, block_id)


func _on_block_edited(voxel: Vector3i, block_id: int) -> void:
	if region != null:
		region.record_edit(voxel, block_id)


func voxel_tool() -> VoxelTool:
	return _tool


func get_block(position: Vector3i) -> int:
	return _tool.get_voxel(position)


func is_solid(position: Vector3i) -> bool:
	# The native mirror answers from a flat array (and knows terrain the
	# streamer hasn't reached yet); VoxelTool is the fallback oracle.
	if sim != null:
		return sim.is_solid(position)
	return BlockRegistry.is_solid(get_block(position))


## True when the voxels around [param position] are loaded and safe to edit.
func is_editable(position: Vector3i) -> bool:
	return _tool.is_area_editable(AABB(Vector3(position), Vector3.ONE))


## Removes the block at [param position] and reports what was removed.
## Returns [constant BlockRegistry.Block.AIR] if there was nothing to mine.
func mine(position: Vector3i) -> int:
	var block_id := get_block(position)
	if not BlockRegistry.is_solid(block_id) or not is_editable(position):
		return Blocks.AIR
	_tool.value = Blocks.AIR
	_tool.do_point(position)
	if sim != null:
		sim.set_block(position, Blocks.AIR)
	block_mined.emit(position, block_id)
	block_edited.emit(position, Blocks.AIR)
	_collapse_around(position)
	return block_id


func place(position: Vector3i, block_id: int) -> bool:
	if is_solid(position) or not is_editable(position):
		return false
	_tool.value = block_id
	_tool.do_point(position)
	if sim != null:
		sim.set_block(position, block_id)
	block_placed.emit(position, block_id)
	block_edited.emit(position, block_id)
	return true


## Removes whatever sits at [param position] — even a solid block — without
## spawning drops or firing the mined signal. Growth and felling manage
## their own debris; callers settle any pile resting on the voxel.
func remove_voxel(position: Vector3i) -> void:
	if not is_editable(position):
		return
	var was_solid := is_solid(position)
	_tool.value = Blocks.AIR
	_tool.do_point(position)
	if sim != null:
		sim.set_block(position, Blocks.AIR)
	block_edited.emit(position, Blocks.AIR)
	if was_solid:
		_collapse_around(position)


## Structural support: a solid block stays up iff a chain of face-adjacent
## solids connects it to the base level (bedrock) or a living tree. This
## runs after a cell became air — only removals can break a chain, so the
## check is event-driven rather than a routine scan. The removed cell's
## neighbours are re-proven component by component; a whole detached body
## comes down at once and the rubble lands where each block stood.
func _collapse_around(removed: Vector3i) -> void:
	if _in_collapse:
		return
	_in_collapse = true
	var doomed: Array[Vector3i] = []
	if sim != null:
		for cell in sim.collapse_check(removed):
			doomed.append(cell)
	else:
		doomed = _unsupported_fallback(removed)
	for cell in doomed:
		var block_id := get_block(cell)
		if block_id == Blocks.AIR or not is_editable(cell):
			continue
		_tool.value = Blocks.AIR
		_tool.do_point(cell)
		if sim != null:
			sim.set_block(cell, Blocks.AIR)
		block_collapsed.emit(cell, block_id)
		block_edited.emit(cell, Blocks.AIR)
	_in_collapse = false


## The no-sim support flood — same rule as DelveSim.collapse_check: a
## component of face-connected solids anchors on bedrock, a tree block,
## the uneditable frontier, or the flood cap; otherwise it's doomed.
func _unsupported_fallback(removed: Vector3i) -> Array[Vector3i]:
	const DIRS6 := [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN,
		Vector3i.UP, Vector3i.BACK, Vector3i.FORWARD,
	]
	const CAP := 4096
	var bedrock: int = generator_script.bedrock_height
	var doomed: Array[Vector3i] = []
	var seen := {}
	var anchored := {}
	for dir in DIRS6:
		var seed: Vector3i = removed + dir
		if seen.has(seed) or not is_editable(seed) or not is_solid(seed):
			continue
		var queue: Array[Vector3i] = [seed]
		var local := {seed: true}
		var ok := false
		while not queue.is_empty() and not ok:
			var cell: Vector3i = queue.pop_front()
			if cell.y <= bedrock or BlockRegistry.is_tree_block(get_block(cell)):
				ok = true
				break
			for d in DIRS6:
				var next: Vector3i = cell + d
				if local.has(next):
					continue
				if anchored.has(next):
					ok = true
					break
				if seen.has(next):
					continue
				if not is_editable(next):
					ok = true
					break
				if not is_solid(next):
					continue
				local[next] = true
				queue.append(next)
			if local.size() > CAP:
				ok = true
				break
		for k in local:
			seen[k] = true
			if ok:
				anchored[k] = true
			else:
				doomed.append(k)
	return doomed


## Casts a ray through the voxels, e.g. from the camera to the terrain.
func raycast(origin: Vector3, direction: Vector3, max_distance: float = 64.0) -> VoxelRaycastResult:
	return _tool.raycast(origin, direction, max_distance)


## Highest solid voxel at or below [param from_y] in a column, or [code]from_y[/code]
## when the column is not loaded yet. [param skip_trees] ignores trunks and
## branches — for callers that mean the terrain, not the canopy.
func ground_height(x: int, z: int, from_y: int = 96, min_y: int = -32, skip_trees := false) -> int:
	for y in range(from_y, min_y, -1):
		var position := Vector3i(x, y, z)
		if not is_editable(position):
			continue
		if not is_solid(position):
			continue
		if skip_trees and BlockRegistry.is_tree_block(get_block(position)):
			continue
		return y
	return min_y


## Estimated surface height from the generator alone. Cheap, ignores edits, and
## works before the area is loaded (useful to place spawns).
func predicted_surface_height(x: int, z: int) -> int:
	return generator_script.surface_height(x, z)


## True if a unit can stand at [param position]: solid floor, two free voxels.
func is_standable(position: Vector3i) -> bool:
	if sim != null:
		return sim.is_standable(position)
	return (
		is_solid(position + Vector3i.DOWN)
		and not is_solid(position)
		and not is_solid(position + Vector3i.UP)
	)


## Grid path between two standing positions, empty when no path exists.
## With [param avoid_packed], the native pathfinder also routes around
## voxels packed full of items (ignored by the engine fallback, which
## never saw piles).
func find_path(
	from_position: Vector3i, to_position: Vector3i, margin: int = 24, avoid_packed := false
) -> PackedVector3Array:
	var path := PackedVector3Array()
	if sim != null:
		for voxel_position in sim.find_path(from_position, to_position, avoid_packed, margin):
			path.append(voxel_position + Vector3(0.5, 0.0, 0.5))
	else:
		var min_corner := Vector3i(
			mini(from_position.x, to_position.x), mini(from_position.y, to_position.y), mini(from_position.z, to_position.z)
		) - Vector3i.ONE * margin
		var max_corner := Vector3i(
			maxi(from_position.x, to_position.x), maxi(from_position.y, to_position.y), maxi(from_position.z, to_position.z)
		) + Vector3i.ONE * margin
		_astar.set_region(AABB(Vector3(min_corner), Vector3(max_corner - min_corner)))

		for voxel_position in _astar.find_path(from_position, to_position):
			path.append(Vector3(voxel_position) + Vector3(0.5, 0.0, 0.5))
	# VoxelAStarGrid3D omits the destination voxel; the unit still has to walk there.
	if not path.is_empty():
		path.append(Vector3(to_position) + Vector3(0.5, 0.0, 0.5))
	return path
