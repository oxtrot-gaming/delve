class_name WorldGenerator
extends VoxelGeneratorScript

## Procedural terrain for the colony: a rolling surface of grass and dirt over
## stone, with caves and depth-dependent ore veins.
##
## Runs on Voxel Tools' generation threads, so it must only touch its own data.
## It is written in GDScript for readability; a [VoxelGeneratorGraph] resource
## is the faster option once the ruleset stabilizes.

const Blocks := BlockRegistry.Block

@export var world_seed: int = 1337:
	set(value):
		world_seed = value
		_configure_noise()

## Altitude of the average terrain surface, in voxels.
@export var base_height: int = 32
## Peak-to-trough amplitude of the surface, in voxels.
@export var terrain_amplitude: float = 18.0
## Thickness of the dirt layer under the grass.
@export var soil_depth: int = 4
## Everything below this altitude is solid, so the world has a floor.
@export var bedrock_height: int = -64

var _height_noise := FastNoiseLite.new()
var _cave_noise := FastNoiseLite.new()
var _ore_noise := FastNoiseLite.new()

## Ore type, minimum depth below the surface, rarity threshold (higher is rarer).
## Ordered from rarest to most common: the first match wins.
var _ore_rules: Array[Dictionary] = [
	{&"block": Blocks.GOLD_ORE, &"min_depth": 28, &"threshold": 0.86},
	{&"block": Blocks.IRON_ORE, &"min_depth": 12, &"threshold": 0.74},
	{&"block": Blocks.COAL_ORE, &"min_depth": 4, &"threshold": 0.62},
]


func _init() -> void:
	_configure_noise()


func _configure_noise() -> void:
	_height_noise.seed = world_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_height_noise.frequency = 0.006
	_height_noise.fractal_octaves = 4

	_cave_noise.seed = world_seed + 1
	_cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave_noise.frequency = 0.035

	_ore_noise.seed = world_seed + 2
	_ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ore_noise.frequency = 0.09


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


## Surface altitude (the y of the topmost solid voxel) at a world column.
func surface_height(x: int, z: int) -> int:
	return base_height + int(_height_noise.get_noise_2d(float(x), float(z)) * terrain_amplitude)


func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if lod != 0:
		return

	var size := out_buffer.get_size()
	var max_surface := base_height + int(ceil(terrain_amplitude))
	if origin_in_voxels.y > max_surface:
		out_buffer.fill(Blocks.AIR, VoxelBuffer.CHANNEL_TYPE)
		return

	for rx in size.x:
		var x := origin_in_voxels.x + rx
		for rz in size.z:
			var z := origin_in_voxels.z + rz
			var height := surface_height(x, z)
			for ry in size.y:
				var y := origin_in_voxels.y + ry
				var block := _block_at(x, y, z, height)
				if block != Blocks.AIR:
					out_buffer.set_voxel(block, rx, ry, rz, VoxelBuffer.CHANNEL_TYPE)

	out_buffer.compress_uniform_channels()


func _block_at(x: int, y: int, z: int, height: int) -> int:
	if y > height:
		return Blocks.AIR
	if y <= bedrock_height:
		return Blocks.STONE

	var depth := height - y
	if depth > 2 and _is_cave(x, y, z):
		return Blocks.AIR

	if depth == 0:
		return Blocks.GRASS
	if depth < soil_depth:
		return Blocks.DIRT

	var ore := _ore_at(x, y, z, depth)
	return ore if ore != Blocks.AIR else Blocks.STONE


func _is_cave(x: int, y: int, z: int) -> bool:
	return absf(_cave_noise.get_noise_3d(float(x), float(y) * 2.0, float(z))) < 0.05


func _ore_at(x: int, y: int, z: int, depth: int) -> int:
	var value := absf(_ore_noise.get_noise_3d(float(x), float(y), float(z)))
	for rule in _ore_rules:
		if depth >= int(rule[&"min_depth"]) and value > float(rule[&"threshold"]):
			return int(rule[&"block"])
	return Blocks.AIR
