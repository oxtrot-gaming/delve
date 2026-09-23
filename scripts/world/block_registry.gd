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
	TRUNK,
	BRANCH,
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
	BRANCH,
	LEAF,
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
	{&"name": "Trunk", &"color": Color(0.42, 0.30, 0.16), &"hardness": 1.5, &"drop": Resource_.WOOD},
	{&"name": "Branch", &"color": Color(0.50, 0.38, 0.20), &"hardness": 1.0, &"drop": Resource_.BRANCH},
]

const RESOURCE_NAMES: Dictionary = {
	Resource_.SOIL: "Soil",
	Resource_.STONE: "Stone",
	Resource_.COAL: "Coal",
	Resource_.IRON: "Iron",
	Resource_.GOLD: "Gold",
	Resource_.WOOD: "Wood",
	Resource_.BRANCH: "Branches",
	Resource_.LEAF: "Leaves",
}

## Material classes that drop as loose fill rather than rock fragments.
const LOOSE_RESOURCES: Array[Resource_] = [
	Resource_.SOIL, Resource_.WOOD, Resource_.BRANCH, Resource_.LEAF
]

const RESOURCE_COLORS: Dictionary = {
	Resource_.SOIL: Color(0.45, 0.32, 0.20),
	Resource_.STONE: Color(0.50, 0.50, 0.53),
	Resource_.COAL: Color(0.18, 0.18, 0.20),
	Resource_.IRON: Color(0.72, 0.52, 0.40),
	Resource_.GOLD: Color(0.85, 0.72, 0.25),
	Resource_.WOOD: Color(0.62, 0.45, 0.25),
	Resource_.BRANCH: Color(0.50, 0.38, 0.20),
	Resource_.LEAF: Color(0.25, 0.48, 0.18),
}

## Blocks a grown (or growing) tree is made of — [Forest] tracks them.
## Saplings and leaves are not blocks: they live as decorations over air
## voxels so they never block movement or pathing.
const TREE_BLOCKS: Array[Block] = [Block.TRUNK, Block.BRANCH]

static func is_solid(block_id: int) -> bool:
	return block_id != Block.AIR


static func is_tree_block(block_id: int) -> bool:
	return block_id in TREE_BLOCKS


static func block_name(block_id: int) -> String:
	return BLOCKS[block_id][&"name"]


static func hardness(block_id: int) -> float:
	return BLOCKS[block_id][&"hardness"]


static func drop_of(block_id: int) -> Resource_:
	return BLOCKS[block_id][&"drop"]


static func resource_name_of(resource: Resource_) -> String:
	return RESOURCE_NAMES.get(resource, "None")


static func resource_color(resource: Resource_) -> Color:
	return RESOURCE_COLORS.get(resource, Color.MAGENTA)


## True for soft material classes (soil) that drop as one loose item rather
## than shattering into boulders and cobbles.
static func resource_is_loose(resource: Resource_) -> bool:
	return resource in LOOSE_RESOURCES


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
