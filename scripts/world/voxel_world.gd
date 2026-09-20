class_name VoxelWorld
extends VoxelTerrain

## The mineable world. Wraps [VoxelTerrain] with the game's block vocabulary:
## block queries, digging, building and voxel grid pathfinding.

signal block_mined(position: Vector3i, block_id: int)
signal block_placed(position: Vector3i, block_id: int)

const Blocks := BlockRegistry.Block

@export var world_seed: int = 1337

var generator_script: WorldGenerator
var _tool: VoxelTool
var _astar := VoxelAStarGrid3D.new()


func _ready() -> void:
	var blocky_mesher := VoxelMesherBlocky.new()
	blocky_mesher.library = BlockRegistry.build_library()
	mesher = blocky_mesher

	generator_script = WorldGenerator.new()
	generator_script.world_seed = world_seed
	generator = generator_script

	_tool = get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_TYPE
	_tool.mode = VoxelTool.MODE_SET

	_astar.set_terrain(self)


func voxel_tool() -> VoxelTool:
	return _tool


func get_block(position: Vector3i) -> int:
	return _tool.get_voxel(position)


func is_solid(position: Vector3i) -> bool:
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
	block_mined.emit(position, block_id)
	return block_id


func place(position: Vector3i, block_id: int) -> bool:
	if is_solid(position) or not is_editable(position):
		return false
	_tool.value = block_id
	_tool.do_point(position)
	block_placed.emit(position, block_id)
	return true


## Casts a ray through the voxels, e.g. from the camera to the terrain.
func raycast(origin: Vector3, direction: Vector3, max_distance: float = 64.0) -> VoxelRaycastResult:
	return _tool.raycast(origin, direction, max_distance)


## Highest solid voxel at or below [param from_y] in a column, or [code]from_y[/code]
## when the column is not loaded yet.
func ground_height(x: int, z: int, from_y: int = 96, min_y: int = -32) -> int:
	for y in range(from_y, min_y, -1):
		var position := Vector3i(x, y, z)
		if not is_editable(position):
			continue
		if is_solid(position):
			return y
	return min_y


## Estimated surface height from the generator alone. Cheap, ignores edits, and
## works before the area is loaded (useful to place spawns).
func predicted_surface_height(x: int, z: int) -> int:
	return generator_script.surface_height(x, z)


## True if a unit can stand at [param position]: solid floor, two free voxels.
func is_standable(position: Vector3i) -> bool:
	return (
		is_solid(position + Vector3i.DOWN)
		and not is_solid(position)
		and not is_solid(position + Vector3i.UP)
	)


## Grid path between two standing positions, empty when no path exists.
func find_path(from_position: Vector3i, to_position: Vector3i, margin: int = 24) -> PackedVector3Array:
	var min_corner := Vector3i(
		mini(from_position.x, to_position.x), mini(from_position.y, to_position.y), mini(from_position.z, to_position.z)
	) - Vector3i.ONE * margin
	var max_corner := Vector3i(
		maxi(from_position.x, to_position.x), maxi(from_position.y, to_position.y), maxi(from_position.z, to_position.z)
	) + Vector3i.ONE * margin
	_astar.set_region(AABB(Vector3(min_corner), Vector3(max_corner - min_corner)))

	var path := PackedVector3Array()
	for voxel_position in _astar.find_path(from_position, to_position):
		path.append(Vector3(voxel_position) + Vector3(0.5, 0.0, 0.5))
	# VoxelAStarGrid3D omits the destination voxel; the unit still has to walk there.
	if not path.is_empty():
		path.append(Vector3(to_position) + Vector3(0.5, 0.0, 0.5))
	return path
