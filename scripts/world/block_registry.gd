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
	STONE_WALL,
	LOG_WALL,
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
	BERRY,
	ACORN,
	SEED,
	COMPOST,
	GRAIN,
	MEAL,
}

const BLOCKS: Array[Dictionary] = [
	{&"name": "Air", &"color": Color(0, 0, 0, 0), &"hardness": 0.0, &"drop": Resource_.NONE},
	# `fertility`/`fertilizability` are the block-type soil properties:
	# the first is a plant's baseline effective fertility (1.0 = full),
	# the second whether the cell can store added fertilization at all.
	# Both default to 0 for blocks that omit them — only dirt grows.
	{&"name": "Dirt", &"color": Color(0.45, 0.32, 0.20), &"hardness": 1.0, &"drop": Resource_.SOIL, &"fertility": 1.0, &"fertilizability": 1.0},
	{&"name": "Grass", &"color": Color(0.30, 0.55, 0.22), &"hardness": 1.0, &"drop": Resource_.SOIL},
	{&"name": "Stone", &"color": Color(0.50, 0.50, 0.53), &"hardness": 2.5, &"drop": Resource_.STONE},
	{&"name": "Coal Ore", &"color": Color(0.18, 0.18, 0.20), &"hardness": 3.0, &"drop": Resource_.COAL},
	{&"name": "Iron Ore", &"color": Color(0.72, 0.52, 0.40), &"hardness": 4.0, &"drop": Resource_.IRON},
	{&"name": "Gold Ore", &"color": Color(0.85, 0.72, 0.25), &"hardness": 5.0, &"drop": Resource_.GOLD},
	{&"name": "Planks", &"color": Color(0.62, 0.45, 0.25), &"hardness": 1.5, &"drop": Resource_.WOOD},
	{&"name": "Trunk", &"color": Color(0.42, 0.30, 0.16), &"hardness": 1.5, &"drop": Resource_.WOOD},
	{&"name": "Branch", &"color": Color(0.50, 0.38, 0.20), &"hardness": 1.0, &"drop": Resource_.BRANCH},
	{&"name": "Stone Wall", &"color": Color(0.56, 0.56, 0.60), &"hardness": 2.0, &"drop": Resource_.STONE},
	{&"name": "Log Wall", &"color": Color(0.55, 0.40, 0.22), &"hardness": 1.5, &"drop": Resource_.WOOD},
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
	Resource_.BERRY: "Berries",
	Resource_.ACORN: "Acorns",
	Resource_.SEED: "Seeds",
	Resource_.COMPOST: "Compost",
	Resource_.GRAIN: "Grain",
	Resource_.MEAL: "Meals",
}

## Material classes that drop as loose fill rather than rock fragments.
const LOOSE_RESOURCES: Array[Resource_] = [
	Resource_.SOIL, Resource_.WOOD, Resource_.BRANCH, Resource_.LEAF,
	Resource_.BERRY, Resource_.COMPOST, Resource_.GRAIN
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
	Resource_.BERRY: Color(0.72, 0.15, 0.20),
	Resource_.ACORN: Color(0.55, 0.38, 0.15),
	Resource_.SEED: Color(0.75, 0.68, 0.45),
	Resource_.COMPOST: Color(0.20, 0.14, 0.08),
	Resource_.GRAIN: Color(0.85, 0.72, 0.30),
	Resource_.MEAL: Color(0.80, 0.55, 0.30),
}

## Blocks a grown (or growing) tree is made of — [Forest] tracks them.
## Saplings and leaves are not blocks: they live as decorations over air
## voxels so they never block movement or pathing.
const TREE_BLOCKS: Array[Block] = [Block.TRUNK, Block.BRANCH]

## What a "build" job can put up: spec name → the construction. A wall
## spec carries the block it becomes and its recipe — the cm³ of each
## item form it takes. Soil compacts at the usual 125% drop volume; a
## stone wall is nine boulders and ten cobbles, a log wall two logs —
## both a flat cubic metre. A plank wall is five planks and also fills
## its voxel whole, with no offcut.
## A door spec names the wall it derives from (`door_of`): its recipe is
## the wall's plus a quarter, each form rounded up to a whole item, and
## the excess past the exact 25% drops at the site as offcut — sawdust
## for wood, gravel for stone. Tamped dirt can't be hinged, so there is
## no dirt door.
const BUILD_SPECS: Dictionary = {
	&"dirt_wall": {
		&"material": Resource_.SOIL,
		&"block": Block.DIRT,
		&"recipe": {DropItem.Form.LOOSE: 1_250_000},
	},
	&"stone_wall": {
		&"material": Resource_.STONE,
		&"block": Block.STONE_WALL,
		&"recipe": {DropItem.Form.BOULDER: 900_000, DropItem.Form.COBBLE: 100_000},
	},
	&"log_wall": {
		&"material": Resource_.WOOD,
		&"block": Block.LOG_WALL,
		&"recipe": {DropItem.Form.LOG: 1_000_000},
	},
	&"plank_wall": {
		&"material": Resource_.WOOD,
		&"block": Block.PLANKS,
		&"recipe": {DropItem.Form.PLANK: 500_000},
	},
	&"stone_door": {&"material": Resource_.STONE, &"door_of": &"stone_wall"},
	&"log_door": {&"material": Resource_.WOOD, &"door_of": &"log_wall"},
	&"plank_door": {&"material": Resource_.WOOD, &"door_of": &"plank_wall"},
}

## The wall spec a bare material name refers to — the log wall is wood's
## canonical wall; the plank wall must be asked for by spec.
const WALL_SPEC_FOR: Dictionary = {
	Resource_.SOIL: &"dirt_wall",
	Resource_.STONE: &"stone_wall",
	Resource_.WOOD: &"log_wall",
}

static func is_solid(block_id: int) -> bool:
	return block_id != Block.AIR


static func is_tree_block(block_id: int) -> bool:
	return block_id in TREE_BLOCKS


static func block_name(block_id: int) -> String:
	return BLOCKS[block_id][&"name"]


static func hardness(block_id: int) -> float:
	return BLOCKS[block_id][&"hardness"]


## The type's baseline soil fertility — what a plant on this block gets
## before any per-cell fertilization (1.0 = 100%). Type-level only;
## the colony's `fertilization` map holds the per-cell additions.
static func default_fertility(block_id: int) -> float:
	return BLOCKS[block_id].get(&"fertility", 0.0)


## Whether cells of this type can store fertilization — 0 means added
## fertilizer is lost (stone, walls, air).
static func fertilizability(block_id: int) -> float:
	return BLOCKS[block_id].get(&"fertilizability", 0.0)


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


## The material class a build spec consumes — what a job's fetch filters
## piles by. All the wood specs share WOOD; the recipe's forms are what
## tell a plank wall apart from a log wall.
static func spec_material(spec: StringName) -> Resource_:
	return BUILD_SPECS.get(spec, {}).get(&"material", Resource_.NONE)


## True for door specs — a passable building in the cell instead of a
## terrain block.
static func spec_is_door(spec: StringName) -> bool:
	return BUILD_SPECS.get(spec, {}).has(&"door_of")


## The block a wall spec builds; doors place no block — their cell stays
## open air with a building record over it.
static func spec_block(spec: StringName) -> Block:
	if spec_is_door(spec):
		return Block.AIR
	return BUILD_SPECS.get(spec, {}).get(&"block", Block.DIRT)


## A spec's recipe: item form → the cm³ of it the construction needs.
## A wall's is its table entry; a door's derives from its wall — each
## form's volume plus a quarter, rounded up to a whole item of that
## form. Duplicated because callers decrement the dict as items arrive.
static func build_recipe(spec: StringName) -> Dictionary:
	var entry: Dictionary = BUILD_SPECS.get(spec, {})
	var base: StringName = entry.get(&"door_of", &"")
	var wall: Dictionary = BUILD_SPECS.get(base, entry)
	var recipe: Dictionary = wall.get(&"recipe", {})
	if base == &"":
		return recipe.duplicate()
	var door: Dictionary = {}
	for form in recipe:
		var step := DropItem.form_volume(form)
		door[form] = ceili(float(recipe[form]) * 1.25 / step) * step
	return door


## Cubic centimetres one construction of [param spec] consumes. Unknown
## specs return INF_CM3 so a caller that asks before committing keeps
## fetching.
static func spec_volume_for(spec: StringName) -> int:
	var recipe := build_recipe(spec)
	if recipe.is_empty():
		return DropItem.INF_CM3
	var total := 0
	for volume in recipe.values():
		total += int(volume)
	return total


## The cm³ a door recipe over-delivers past the exact quarter surcharge —
## what drops at the site as offcut (sawdust, gravel) when it's built.
static func spec_offcut(spec: StringName) -> int:
	var entry: Dictionary = BUILD_SPECS.get(spec, {})
	var base: StringName = entry.get(&"door_of", &"")
	if base == &"":
		return 0
	var wall_total := spec_volume_for(base)
	var door_total := spec_volume_for(spec)
	return door_total - wall_total * 5 / 4


## True when [param item] can go into the construction [param spec]
## describes — material class matches and the form is one the recipe
## takes. With an empty spec, any wall-capable item counts — loose soil,
## stone boulders and cobbles (gravel is too fine to stack) and whole
## logs or planks.
static func item_fits_spec(item: DropItem, spec: StringName) -> bool:
	if spec != &"":
		var want := spec_material(spec)
		return (
			item.material == want
			and build_recipe(spec).has(item.form)
		)
	# No committed spec: any material that builds a wall.
	if item.material == Resource_.SOIL:
		return item.form == DropItem.Form.LOOSE
	if item.material == Resource_.WOOD:
		return (
			item.form == DropItem.Form.LOG
			or item.form == DropItem.Form.PLANK
		)
	return (
		item.material == Resource_.STONE
		and (
			item.form == DropItem.Form.BOULDER
			or item.form == DropItem.Form.COBBLE
		)
	)


## Material-keyed conveniences kept for callers that think in wall
## materials rather than build specs — they resolve through the
## material's canonical wall.
static func wall_block_for(material: Resource_) -> Block:
	return spec_block(WALL_SPEC_FOR.get(material, &""))


## A wall's recipe of [param material]: item form → the cm³ of it the wall
## needs. Empty for materials that can't build one.
static func wall_recipe(material: Resource_) -> Dictionary:
	return build_recipe(WALL_SPEC_FOR.get(material, &""))


## Cubic centimetres of [param material] one wall block consumes.
## Uncommitted jobs query NONE: INF_CM3 keeps them fetching until a
## material commits.
static func wall_volume_for(material: Resource_) -> int:
	if material == Resource_.NONE:
		return DropItem.INF_CM3
	return spec_volume_for(WALL_SPEC_FOR.get(material, &""))


## True when [param item] can go into a wall as [param material] — or as
## any wall material when NONE. Loose soil, stone boulders and cobbles
## (gravel is too fine to stack), whole logs and planks count.
static func item_fits_wall(item: DropItem, material: Resource_) -> bool:
	if material == Resource_.NONE:
		return item_fits_spec(item, &"")
	for spec in BUILD_SPECS:
		if spec_material(spec) == material and item_fits_spec(item, spec):
			return true
	return false


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
