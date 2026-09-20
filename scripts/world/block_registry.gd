class_name BlockRegistry
extends RefCounted

## Central definition of every voxel type in the game.
##
## Block ids are the values stored in [constant VoxelBuffer.CHANNEL_TYPE] and are
## also the indices of the models inside the generated [VoxelBlockyLibrary], so
## the order of [constant BLOCKS] is part of the save format.

enum Block {
	AIR,
	DIRT,
	GRASS,
	STONE,
	COAL_ORE,
	IRON_ORE,
	GOLD_ORE,
	PLANKS,
}

## Resource yielded when a block is mined. AIR means "nothing".
enum Resource_ {
	NONE,
	SOIL,
	STONE,
	COAL,
	IRON,
	GOLD,
	WOOD,
}

const BLOCKS: Array[Dictionary] = [
	{&"name": "Air", &"color": Color(0, 0, 0, 0), &"hardness": 0.0, &"drop": Resource_.NONE},
	{&"name": "Dirt", &"color": Color(0.45, 0.32, 0.20), &"hardness": 1.0, &"drop": Resource_.SOIL},
	{&"name": "Grass", &"color": Color(0.30, 0.55, 0.22), &"hardness": 1.0, &"drop": Resource_.SOIL},
	{&"name": "Stone", &"color": Color(0.50, 0.50, 0.53), &"hardness": 2.5, &"drop": Resource_.STONE},
	{&"name": "Coal Ore", &"color": Color(0.18, 0.18, 0.20), &"hardness": 3.0, &"drop": Resource_.COAL},
	{&"name": "Iron Ore", &"color": Color(0.72, 0.52, 0.40), &"hardness": 4.0, &"drop": Resource_.IRON},
	{&"name": "Gold Ore", &"color": Color(0.85, 0.72, 0.25), &"hardness": 5.0, &"drop": Resource_.GOLD},
	{&"name": "Planks", &"color": Color(0.62, 0.45, 0.25), &"hardness": 1.5, &"drop": Resource_.WOOD},
]

const RESOURCE_NAMES: Dictionary = {
	Resource_.SOIL: "Soil",
	Resource_.STONE: "Stone",
	Resource_.COAL: "Coal",
	Resource_.IRON: "Iron",
	Resource_.GOLD: "Gold",
	Resource_.WOOD: "Wood",
}

static func is_solid(block_id: int) -> bool:
	return block_id != Block.AIR


static func block_name(block_id: int) -> String:
	return BLOCKS[block_id][&"name"]


static func hardness(block_id: int) -> float:
	return BLOCKS[block_id][&"hardness"]


static func drop_of(block_id: int) -> Resource_:
	return BLOCKS[block_id][&"drop"]


static func resource_name_of(resource: Resource_) -> String:
	return RESOURCE_NAMES.get(resource, "None")


## Builds the blocky library used by [VoxelMesherBlocky]. One opaque cube model
## per block type, tinted through a per-model material.
static func build_library() -> VoxelBlockyLibrary:
	var library := VoxelBlockyLibrary.new()
	for block_id in BLOCKS.size():
		var definition: Dictionary = BLOCKS[block_id]
		var model: VoxelBlockyModel
		if block_id == Block.AIR:
			model = VoxelBlockyModelEmpty.new()
		else:
			var cube := VoxelBlockyModelCube.new()
			cube.set_material_override(0, _make_material(definition[&"color"]))
			model = cube
		model.resource_name = definition[&"name"]
		library.add_model(model)
	library.bake()
	return library


static func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material
