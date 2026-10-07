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
	HEMATITE_ORE,
	NATIVE_GOLD_ORE,
	PLANKS,
	TRUNK,
	BRANCH,
	STONE_WALL,
	LOG_WALL,
	CLAY,
	MALACHITE_ORE,
	CASSITERITE_ORE,
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
	CORPSE,
	MEAT,
	LEATHER,
	BONE,
	SCRAPS,
	ANTLER,
	TUSK,
	MEDICINE,
	CLAY,
	CHARCOAL,
	HEMATITE,
	MALACHITE,
	CASSITERITE,
	NATIVE_GOLD,
	COPPER,
	TIN,
	COTTON,
	CLOTH,
}

const BLOCKS: Array[Dictionary] = [
	{&"name": "Air", &"color": Color(0, 0, 0, 0), &"hardness": 0.0, &"drop": Resource_.NONE},
	# `fertility`/`fertilizability` are the block-type soil properties:
	# the first is a plant's baseline effective fertility (1.0 = full),
	# the second whether the cell can store added fertilization at all.
	# Both default to 0 for blocks that omit them — only dirt grows.
	# `beauty` is the per-exposed-face value rooms and units read —
	# scaled well below RimWorld's per-tile numbers because a voxel
	# room presents ~6 surfaces per floor cell, not one.
	{&"name": "Dirt", &"color": Color(0.45, 0.32, 0.20), &"hardness": 1.0, &"drop": Resource_.SOIL, &"fertility": 1.0, &"fertilizability": 1.0, &"beauty": -0.10},
	{&"name": "Grass", &"color": Color(0.30, 0.55, 0.22), &"hardness": 1.0, &"drop": Resource_.SOIL, &"beauty": 0.05},
	{&"name": "Stone", &"color": Color(0.50, 0.50, 0.53), &"hardness": 2.5, &"drop": Resource_.STONE, &"beauty": 0.08},
	{&"name": "Coal measures", &"color": Color(0.18, 0.18, 0.20), &"hardness": 3.0, &"drop": Resource_.COAL},
	{&"name": "Hematite in stone", &"color": Color(0.60, 0.32, 0.24), &"hardness": 4.0, &"drop": Resource_.HEMATITE, &"beauty": 0.10},
	{&"name": "Native gold in stone", &"color": Color(0.85, 0.72, 0.25), &"hardness": 5.0, &"drop": Resource_.NATIVE_GOLD, &"beauty": 0.15},
	{&"name": "Planks", &"color": Color(0.62, 0.45, 0.25), &"hardness": 1.5, &"drop": Resource_.WOOD, &"beauty": 0.12},
	{&"name": "Trunk", &"color": Color(0.42, 0.30, 0.16), &"hardness": 1.5, &"drop": Resource_.WOOD},
	{&"name": "Branch", &"color": Color(0.50, 0.38, 0.20), &"hardness": 1.0, &"drop": Resource_.BRANCH},
	{&"name": "Stone Wall", &"color": Color(0.56, 0.56, 0.60), &"hardness": 2.0, &"drop": Resource_.STONE, &"beauty": 0.10},
	{&"name": "Log Wall", &"color": Color(0.55, 0.40, 0.22), &"hardness": 1.5, &"drop": Resource_.WOOD, &"beauty": 0.05},
	# Dirt's sterile twin: mines and hauls the same but grows no grass,
	# no crops — what bloomeries are built from (PLAN item 42).
	{&"name": "Clay", &"color": Color(0.58, 0.46, 0.34), &"hardness": 1.0, &"drop": Resource_.CLAY, &"beauty": -0.02},
	{&"name": "Malachite in stone", &"color": Color(0.20, 0.55, 0.35), &"hardness": 4.0, &"drop": Resource_.MALACHITE, &"beauty": 0.10},
	{&"name": "Cassiterite in stone", &"color": Color(0.32, 0.27, 0.22), &"hardness": 4.5, &"drop": Resource_.CASSITERITE, &"beauty": 0.10},
]

## Ore-bearing blocks — a mineral intrusion embedded in country rock.
## `mineral`/`host` are the resources mining splits the drops between,
## `share` the mineral fraction of the block's volume (hematite's 0.5
## means half a cubic metre of ore per mined voxel); `metal` and
## `furnace` name the smelt output and the building it runs in —
## recipes live in [constant Colony.RECIPES], this is the material
## truth they look up. Coal smelts to nothing — it IS the fuel; gold
## waits on the crucible. Later, biome layers give intrusions a
## layer-specific `host` (hematite in chert instead of in stone).
const ORES: Dictionary = {
	Block.COAL_ORE: {
		&"mineral": Resource_.COAL, &"host": Resource_.STONE,
		&"share": 0.30,
	},
	Block.HEMATITE_ORE: {
		&"mineral": Resource_.HEMATITE, &"host": Resource_.STONE,
		&"share": 0.50, &"metal": Resource_.IRON, &"furnace": &"bloomery",
	},
	Block.NATIVE_GOLD_ORE: {
		&"mineral": Resource_.NATIVE_GOLD, &"host": Resource_.STONE,
		&"share": 0.01, &"metal": Resource_.GOLD, &"furnace": &"crucible",
	},
	Block.MALACHITE_ORE: {
		&"mineral": Resource_.MALACHITE, &"host": Resource_.STONE,
		&"share": 0.80, &"metal": Resource_.COPPER, &"furnace": &"pit",
	},
	Block.CASSITERITE_ORE: {
		&"mineral": Resource_.CASSITERITE, &"host": Resource_.STONE,
		&"share": 0.05, &"metal": Resource_.TIN, &"furnace": &"pit",
	},
}

## Every resource a boulder or cobble can be made of — crushed at the
## crafting spot (stone and each intrusion mineral) and the list the
## crush bills enumerate. Order is the UI's.
const CRUSHABLE_MATERIALS: Array[Resource_] = [
	Resource_.STONE, Resource_.COAL, Resource_.HEMATITE,
	Resource_.MALACHITE, Resource_.CASSITERITE, Resource_.NATIVE_GOLD,
]

const RESOURCE_NAMES: Dictionary = {
	Resource_.SOIL: "Soil",
	Resource_.STONE: "Stone",
	Resource_.COAL: "Coal",
	Resource_.WOOD: "Wood",
	Resource_.BRANCH: "Branches",
	Resource_.LEAF: "Leaves",
	Resource_.BERRY: "Berries",
	Resource_.ACORN: "Acorns",
	Resource_.SEED: "Seeds",
	Resource_.COMPOST: "Compost",
	Resource_.GRAIN: "Grain",
	Resource_.MEAL: "Meals",
	Resource_.CORPSE: "Corpse",
	Resource_.MEAT: "Meat",
	Resource_.LEATHER: "Leather",
	Resource_.BONE: "Bones",
	Resource_.SCRAPS: "Butchering scraps",
	Resource_.ANTLER: "Antlers",
	Resource_.TUSK: "Tusks",
	Resource_.MEDICINE: "Heal-all bundles",
	Resource_.CLAY: "Clay",
	Resource_.CHARCOAL: "Charcoal",
	Resource_.HEMATITE: "Hematite",
	Resource_.MALACHITE: "Malachite",
	Resource_.CASSITERITE: "Cassiterite",
	Resource_.NATIVE_GOLD: "Native gold",
	Resource_.COPPER: "Raw copper",
	Resource_.TIN: "Raw tin",
	Resource_.IRON: "Raw iron",
	Resource_.GOLD: "Raw gold",
	Resource_.COTTON: "Raw cotton",
	Resource_.CLOTH: "Cotton cloth",
}

## Material classes that drop as loose fill rather than rock fragments.
## Clay and the smelted metals are loose goods — they pour like soil;
## intrusion minerals are rock and shatter into boulders and cobbles.
const LOOSE_RESOURCES: Array[Resource_] = [
	Resource_.SOIL, Resource_.CLAY, Resource_.WOOD, Resource_.BRANCH,
	Resource_.LEAF, Resource_.BERRY, Resource_.COMPOST, Resource_.GRAIN,
	Resource_.CHARCOAL, Resource_.IRON, Resource_.COPPER,
	Resource_.TIN, Resource_.GOLD,
]

const RESOURCE_COLORS: Dictionary = {
	Resource_.SOIL: Color(0.45, 0.32, 0.20),
	Resource_.CLAY: Color(0.58, 0.46, 0.34),
	Resource_.STONE: Color(0.50, 0.50, 0.53),
	Resource_.COAL: Color(0.18, 0.18, 0.20),
	Resource_.HEMATITE: Color(0.60, 0.32, 0.24),
	Resource_.MALACHITE: Color(0.20, 0.55, 0.35),
	Resource_.CASSITERITE: Color(0.32, 0.27, 0.22),
	Resource_.NATIVE_GOLD: Color(0.85, 0.72, 0.25),
	Resource_.IRON: Color(0.55, 0.50, 0.48),
	Resource_.COPPER: Color(0.72, 0.42, 0.25),
	Resource_.TIN: Color(0.70, 0.72, 0.74),
	Resource_.GOLD: Color(0.85, 0.72, 0.25),
	Resource_.CHARCOAL: Color(0.12, 0.11, 0.10),
	Resource_.WOOD: Color(0.62, 0.45, 0.25),
	Resource_.BRANCH: Color(0.50, 0.38, 0.20),
	Resource_.LEAF: Color(0.25, 0.48, 0.18),
	Resource_.BERRY: Color(0.72, 0.15, 0.20),
	Resource_.ACORN: Color(0.55, 0.38, 0.15),
	Resource_.SEED: Color(0.75, 0.68, 0.45),
	Resource_.COMPOST: Color(0.20, 0.14, 0.08),
	Resource_.GRAIN: Color(0.85, 0.72, 0.30),
	Resource_.MEAL: Color(0.80, 0.55, 0.30),
	Resource_.CORPSE: Color(0.60, 0.30, 0.28),
	Resource_.MEAT: Color(0.72, 0.28, 0.25),
	Resource_.LEATHER: Color(0.45, 0.32, 0.20),
	Resource_.BONE: Color(0.88, 0.85, 0.72),
	Resource_.SCRAPS: Color(0.50, 0.32, 0.28),
	Resource_.ANTLER: Color(0.82, 0.78, 0.66),
	Resource_.TUSK: Color(0.92, 0.88, 0.75),
	Resource_.MEDICINE: Color(0.40, 0.62, 0.45),
	# Raw cotton is the fluffy boll — a paler off-white than the
	# woven bolt it becomes.
	Resource_.COTTON: Color(0.92, 0.90, 0.80),
	Resource_.CLOTH: Color(0.80, 0.74, 0.60),
}

## Bulk density in kilograms per litre (kg/L ≈ g/cm³), per material —
## what turns an item's cm³ into the mass a hauler must lift. Ores are
## rock matrix, not refined metal, so they sit under their element's
## pure density; wood floats around half a kilo per litre; flesh and
## food hover at water. Anything absent defaults to stone — a new
## material errs heavy rather than light so hauling surprises read as
## "this is dense", not "this is free".
const RESOURCE_DENSITY: Dictionary = {
	Resource_.SOIL: 1.6,
	Resource_.CLAY: 1.8,
	Resource_.STONE: 2.6,
	Resource_.COAL: 1.4,
	# Intrusion minerals sit around common ore-matrix densities; the
	# smelted metals drop as loose granules of the element itself.
	Resource_.HEMATITE: 4.2,
	Resource_.MALACHITE: 3.9,
	Resource_.CASSITERITE: 5.0,
	Resource_.NATIVE_GOLD: 6.0,
	Resource_.IRON: 4.0,
	Resource_.COPPER: 4.2,
	Resource_.TIN: 3.8,
	Resource_.GOLD: 4.0,
	# Charcoal is feather-light — most of its mass burned off already.
	Resource_.CHARCOAL: 0.4,
	Resource_.WOOD: 0.6,
	Resource_.BRANCH: 0.45,
	Resource_.LEAF: 0.15,
	Resource_.BERRY: 0.9,
	Resource_.ACORN: 0.9,
	Resource_.SEED: 0.75,
	Resource_.COMPOST: 1.0,
	Resource_.GRAIN: 0.8,
	Resource_.MEAL: 1.0,
	Resource_.CORPSE: 1.05,
	Resource_.MEAT: 1.05,
	Resource_.LEATHER: 0.95,
	Resource_.BONE: 1.9,
	Resource_.SCRAPS: 0.9,
	Resource_.ANTLER: 1.8,
	Resource_.TUSK: 1.9,
	# Dried herbs — very light: a bundle is a small armful of stems.
	Resource_.MEDICINE: 0.3,
	# Cotton is the lightest thing a pile holds — raw bolls are mostly
	# air, and even the woven bolt weighs less than wood.
	Resource_.COTTON: 0.2,
	Resource_.CLOTH: 0.35,
}


## Kilograms per litre for [param resource] — the hauling conversion.
static func density_of(resource: Resource_) -> float:
	return float(RESOURCE_DENSITY.get(resource, 2.6))

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

## Flooring specs — thin coverings laid on any exposed face of a solid
## block, floor wall or ceiling alike (PLAN item 34). Fields:
##   `label`    player-facing name — the overlay reads as the same
##              material whatever face it's on
##   `material` resource class the recipe's items must carry
##   `recipe`   item form → cm³ the face consumes — far thinner than a
##              wall block, so one plank or a handful of cobbles covers
##              a square metre
##   `beauty`   the face's beauty once covered — replacing the block's
##              `beauty` entry in room and sight-line scores
##   `color`    the decoration quad's tint
const FLOOR_SPECS: Dictionary = {
	&"packed_dirt": {
		&"label": "Packed earth",
		&"material": Resource_.SOIL,
		&"recipe": {DropItem.Form.LOOSE: 100_000},
		&"beauty": 0.02,
		&"color": Color(0.52, 0.40, 0.27),
	},
	&"flagstone": {
		&"label": "Flagstone",
		&"material": Resource_.STONE,
		&"recipe": {DropItem.Form.COBBLE: 60_000},
		&"beauty": 0.12,
		&"color": Color(0.56, 0.56, 0.60),
	},
	&"plank_floor": {
		&"label": "Plank floor",
		&"material": Resource_.WOOD,
		&"recipe": {DropItem.Form.PLANK: DropItem.PLANK_CM3},
		&"beauty": 0.25,
		&"color": Color(0.66, 0.48, 0.28),
	},
}

## Recreation buildings — furniture a bored colonist uses for a while.
## The construction inputs live in [constant Colony.RECIPES] (a `builds`
## entry like the campfire's); this table carries the use side: the
## player-facing label, the activity's gerund for the status caption,
## the tolerance kind the session feeds (repeating one kind yields less,
## RimWorld-style), the power multiplier on its fill rate, the session
## length in seconds, and whether the building's cell must see the sky
## — a telescope under a roof is furniture nobody uses.
const REC_SPECS: Dictionary = {
	&"horseshoe_pin": {
		&"label": "Horseshoe pin",
		&"activity": "playing horseshoes",
		&"kind": &"dexterity",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.10,
	},
	&"hoopstone_ring": {
		&"label": "Hoopstone ring",
		&"activity": "playing hoopstone",
		&"kind": &"dexterity",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.10,
	},
	&"ur_board": {
		&"label": "Game-of-Ur board",
		&"activity": "playing the game of Ur",
		&"kind": &"cerebral",
		&"power": 0.8,
		&"seconds": 16.0,
		&"beauty": 0.20,
	},
	&"tafl_table": {
		&"label": "Tafl table",
		&"activity": "playing tafl",
		&"kind": &"cerebral",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.20,
	},
	&"billiards_table": {
		&"label": "Billiards table",
		&"activity": "playing billiards",
		&"kind": &"dexterity",
		&"power": 1.3,
		&"seconds": 16.0,
		&"beauty": 0.30,
	},
	&"poker_table": {
		&"label": "Poker table",
		&"activity": "playing poker",
		&"kind": &"cerebral",
		&"power": 1.3,
		&"seconds": 16.0,
		&"beauty": 0.30,
	},
	&"telescope": {
		&"label": "Telescope",
		&"activity": "studying the sky through the telescope",
		&"kind": &"telescope",
		&"power": 1.2,
		&"seconds": 16.0,
		&"beauty": 0.30,
		&"sky": true,
	},
	&"harp": {
		&"label": "Harp",
		&"activity": "playing the harp",
		&"kind": &"music",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.40,
	},
	&"harpsichord": {
		&"label": "Harpsichord",
		&"activity": "playing the harpsichord",
		&"kind": &"music",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.50,
	},
	&"piano": {
		&"label": "Piano",
		&"activity": "playing the piano",
		&"kind": &"music",
		&"power": 1.0,
		&"seconds": 16.0,
		&"beauty": 0.60,
	},
}


## Every placeable furnishing — beds, seats, tables, shelves, lighting
## and decor. The recipe side (inputs and knowledge gates) lives in
## [constant Colony.RECIPES] under the same key; this table carries the
## built side: `class` names the Building.Kind a piece registers as
## (resolved by [constant Colony.FURNITURE_CLASSES]), `size` is the
## footprint in cells (either orientation), and the rest are the
## mechanics each class reads — `sleeps`/`rest`/`medical` for beds,
## `burns`/`watts`/`light`/`radius`/`grow` for lamps, `beauty` for what
## pleases a room, `bed_bonus`/`research_bonus` for the aura pieces.
const FURNITURE_SPECS: Dictionary = {
	# Sleeping — free spots first, then carried bedrolls, then the
	# gated furniture line: the joiner's craft is medieval knowledge.
	&"sleeping_spot": {
		&"label": "Sleeping spot",
		&"class": &"bed", &"size": Vector2i(1, 1),
		&"sleeps": 1, &"rest": 0.9,
	},
	&"double_sleeping_spot": {
		&"label": "Double sleeping spot",
		&"class": &"bed", &"size": Vector2i(2, 1),
		&"sleeps": 2, &"rest": 0.9,
	},
	&"bedroll": {
		&"label": "Bedroll",
		&"class": &"bed", &"size": Vector2i(1, 1),
		&"sleeps": 1, &"rest": 0.95,
	},
	&"double_bedroll": {
		&"label": "Double bedroll",
		&"class": &"bed", &"size": Vector2i(2, 1),
		&"sleeps": 2, &"rest": 0.95,
	},
	&"bed": {
		&"label": "Bed",
		&"class": &"bed", &"size": Vector2i(1, 2),
		&"sleeps": 1, &"rest": 1.0, &"beauty": 0.08,
	},
	&"double_bed": {
		&"label": "Double bed",
		&"class": &"bed", &"size": Vector2i(2, 2),
		&"sleeps": 2, &"rest": 1.0, &"beauty": 0.12,
	},
	&"royal_bed": {
		&"label": "Royal bed",
		&"class": &"bed", &"size": Vector2i(2, 2),
		&"sleeps": 2, &"rest": 1.15, &"beauty": 0.6,
	},
	&"hospital_bed": {
		&"label": "Hospital bed",
		&"class": &"bed", &"size": Vector2i(1, 2),
		&"sleeps": 1, &"rest": 1.05, &"medical": true,
		&"beauty": 0.05,
	},
	&"animal_bed": {
		&"label": "Animal bed",
		&"class": &"decor", &"size": Vector2i(1, 1),
		&"animal": true,
	},
	# Seating — the stool is a log on end; proper chairs are joinery.
	&"stool": {
		&"label": "Stool",
		&"class": &"seat", &"size": Vector2i(1, 1),
	},
	&"dining_chair": {
		&"label": "Dining chair",
		&"class": &"seat", &"size": Vector2i(1, 1),
	},
	&"armchair": {
		&"label": "Armchair",
		&"class": &"seat", &"size": Vector2i(1, 1),
		&"beauty": 0.10,
	},
	&"couch": {
		&"label": "Couch",
		&"class": &"seat", &"size": Vector2i(2, 1),
		&"beauty": 0.10,
	},
	# Tables — the four RimWorld footprints.
	&"table_1x2": {
		&"label": "Table (1×2)",
		&"class": &"table", &"size": Vector2i(1, 2),
	},
	&"table_2x2": {
		&"label": "Table (2×2)",
		&"class": &"table", &"size": Vector2i(2, 2),
	},
	&"table_2x4": {
		&"label": "Table (2×4)",
		&"class": &"table", &"size": Vector2i(2, 4),
	},
	&"table_3x3": {
		&"label": "Table (3×3)",
		&"class": &"table", &"size": Vector2i(3, 3),
	},
	# Storage furniture — shelf cells hold twice the floor's fill and
	# keep it off the mud; the small shelf is one cell of the same.
	&"shelf": {
		&"label": "Shelf",
		&"class": &"shelf", &"size": Vector2i(1, 2),
	},
	&"small_shelf": {
		&"label": "Small shelf",
		&"class": &"shelf", &"size": Vector2i(1, 1),
	},
	# Comfort auras — the bedroom pieces multiply a bed's rest, the
	# bookcases speed the research bench they stand beside.
	&"end_table": {
		&"label": "End table",
		&"class": &"decor", &"size": Vector2i(1, 1),
		&"bed_bonus": 0.05,
	},
	&"dresser": {
		&"label": "Dresser",
		&"class": &"decor", &"size": Vector2i(1, 2),
		&"bed_bonus": 0.10,
	},
	&"small_bookcase": {
		&"label": "Small bookcase",
		&"class": &"decor", &"size": Vector2i(1, 1),
		&"research_bonus": 0.10,
	},
	&"bookcase": {
		&"label": "Bookcase",
		&"class": &"decor", &"size": Vector2i(1, 2),
		&"research_bonus": 0.20,
	},
	&"plant_pot": {
		&"label": "Plant pot",
		&"class": &"decor", &"size": Vector2i(1, 1),
		&"beauty": 0.15,
	},
	# Lighting — the torch lamp burns like a campfire; the wired lamps
	# draw on the power net. The sun lamp's light feeds crops.
	&"torch_lamp": {
		&"label": "Torch lamp",
		&"class": &"lamp", &"size": Vector2i(1, 1),
		&"burns": true, &"light": 0.9, &"radius": 7,
	},
	&"standing_lamp": {
		&"label": "Standing lamp",
		&"class": &"lamp", &"size": Vector2i(1, 1),
		&"watts": 75, &"light": 0.9, &"radius": 7,
	},
	&"floodlight": {
		&"label": "Floodlight",
		&"class": &"lamp", &"size": Vector2i(1, 2),
		&"watts": 300, &"light": 0.95, &"radius": 11,
	},
	&"sun_lamp": {
		&"label": "Sun lamp",
		&"class": &"lamp", &"size": Vector2i(1, 2),
		&"watts": 1000, &"light": 1.0, &"radius": 9,
		&"grow": true,
	},
}


## The furniture spec for [param spec_id], or an empty Dictionary for a
## key the catalogue doesn't know.
static func furniture_spec(spec_id: StringName) -> Dictionary:
	return FURNITURE_SPECS.get(spec_id, {})


## The furniture spec's display label — "Bed", "Table (2×2)".
static func furniture_label(spec_id: StringName) -> String:
	return String(FURNITURE_SPECS.get(spec_id, {}).get(&"label", spec_id))


## The recreation-building spec's display label.
static func rec_label(spec: StringName) -> String:
	return REC_SPECS.get(spec, {}).get(&"label", "Recreation")


## The activity's gerund for a status caption — "playing horseshoes".
static func rec_activity_label(spec: StringName) -> String:
	return REC_SPECS.get(spec, {}).get(&"activity", "relaxing")


## The tolerance kind the activity feeds — doing the same kind twice in
## a row returns less.
static func rec_kind(spec: StringName) -> StringName:
	return REC_SPECS.get(spec, {}).get(&"kind", &"solitary")


## The recreation multiplier on the session's fill rate.
static func rec_power(spec: StringName) -> float:
	return REC_SPECS.get(spec, {}).get(&"power", 1.0)


## The recreation building's face-value beauty for room scoring and
## sight lines — 0 for entries that omit it.
static func rec_beauty(spec: StringName) -> float:
	return float(REC_SPECS.get(spec, {}).get(&"beauty", 0.0))


## Seconds a session at the building lasts.
static func rec_seconds(spec: StringName) -> float:
	return REC_SPECS.get(spec, {}).get(&"seconds", 16.0)


## Whether the building's cell must see the sky — telescopes only.
static func rec_needs_sky(spec: StringName) -> bool:
	return REC_SPECS.get(spec, {}).get(&"sky", false)

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


## Representative toughness of a material class — what a thing built
## out of it (a barricade, a bed, a furnace) stands up to. Numbers track
## the blocks the material shapes: stone walls outlast log walls, a
## packed-dirt mound barely slows a fight.
const MATERIAL_HARDNESS: Dictionary = {
	Resource_.SOIL: 1.0,
	Resource_.CLAY: 1.0,
	Resource_.BRANCH: 1.0,
	Resource_.WOOD: 1.5,
	Resource_.STONE: 2.5,
	Resource_.COAL: 3.0,
	Resource_.HEMATITE: 4.0,
	Resource_.MALACHITE: 4.0,
	Resource_.CASSITERITE: 4.5,
	Resource_.NATIVE_GOLD: 5.0,
	Resource_.CHARCOAL: 2.0,
	Resource_.IRON: 6.0,
	Resource_.COPPER: 5.0,
	Resource_.TIN: 5.0,
	Resource_.GOLD: 4.0,
}


static func material_hardness(res: int) -> float:
	return float(MATERIAL_HARDNESS.get(res, 1.0))


## How readily a thing catches and feeds fire — an ignition/spread
## weight, not a fuel rating. Wood burns, stone and soil don't;
## charcoal is practically made of fire. Blocks consult their drop's
## material class by default (a log wall burns like wood); per-block
## entries in [constant BLOCK_FLAMMABILITY] override.
const MATERIAL_FLAMMABILITY: Dictionary = {
	Resource_.SOIL: 0.0,
	Resource_.STONE: 0.0,
	Resource_.CLAY: 0.0,
	Resource_.COMPOST: 0.3,
	Resource_.CORPSE: 0.2,
	Resource_.MEAT: 0.1,
	Resource_.LEATHER: 0.4,
	Resource_.BONE: 0.1,
	Resource_.ANTLER: 0.2,
	Resource_.WOOD: 1.0,
	Resource_.BRANCH: 0.9,
	Resource_.LEAF: 1.1,
	Resource_.CHARCOAL: 1.4,
	Resource_.BERRY: 0.1,
	Resource_.ACORN: 0.2,
	Resource_.SEED: 0.3,
	Resource_.GRAIN: 0.5,
	Resource_.MEAL: 0.1,
}

## Per-block overrides where the block's drop undersells it — a dirt
## mound drops soil but is no fuel either way; the wood walls are the
## entries that matter.
const BLOCK_FLAMMABILITY: Dictionary = {
	Block.PLANKS: 0.8,
	Block.TRUNK: 1.0,
	Block.BRANCH: 0.9,
	Block.LOG_WALL: 1.0,
}


## How fire-prone a block is — 0 never catches (dirt, stone, ore,
## clay). Fire reads this for spread targets and burn times.
static func flammability(block_id: int) -> float:
	if BLOCK_FLAMMABILITY.has(block_id):
		return float(BLOCK_FLAMMABILITY[block_id])
	var drop: int = BLOCKS[block_id].get(&"drop", Resource_.NONE)
	return float(MATERIAL_FLAMMABILITY.get(drop, 0.0))


## How fire-prone a thing made of the material is — buildings and item
## piles rate themselves off this.
static func material_flammability(res: int) -> float:
	return float(MATERIAL_FLAMMABILITY.get(res, 0.0))


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


## True for blocks holding a mineral intrusion — their mine drops split
## between the mineral and its country rock per the ore's `share`.
static func is_ore(block_id: int) -> bool:
	return ORES.has(block_id)


## The ore spec for [param block_id] — mineral, host rock and share —
## or an empty Dictionary for country rock.
static func ore_spec(block_id: int) -> Dictionary:
	return ORES.get(block_id, {})


## The intrusion mineral an ore block carries, or NONE for plain rock —
## scree piles and mining drops name materials through this.
static func ores_mineral(block_id: int) -> Resource_:
	return ORES.get(block_id, {}).get(&"mineral", Resource_.NONE)


## Clay pours, hauls and stacks exactly like soil — it just can't grow
## anything. Wherever an unpinned soil input or build spec asks for
## dirt, clay counts.
static func soil_like(resource: Resource_) -> bool:
	return resource == Resource_.SOIL or resource == Resource_.CLAY


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


## A floor spec's recipe: item form → the cm³ of it one face consumes.
## Duplicated because callers decrement the dict as items arrive.
static func floor_recipe(spec: StringName) -> Dictionary:
	var entry: Dictionary = FLOOR_SPECS.get(spec, {})
	var recipe: Dictionary = entry.get(&"recipe", {})
	return recipe.duplicate()


## True when [param item] can go into the floor covering [param spec]
## describes — material class matches and the form is one the recipe
## takes.
static func item_fits_floor(item: DropItem, spec: StringName) -> bool:
	if not FLOOR_SPECS.has(spec):
		return false
	var want: Resource_ = FLOOR_SPECS[spec].get(&"material", Resource_.NONE)
	var material_ok := (
		soil_like(item.material) if want == Resource_.SOIL
		else item.material == want
	)
	return material_ok and floor_recipe(spec).has(item.form)


## The per-face beauty a [param spec] covering carries — what a covered
## face contributes to room scores and sight-line beauty instead of the
## bare block's value.
static func floor_beauty(spec: StringName) -> float:
	return float(FLOOR_SPECS.get(spec, {}).get(&"beauty", 0.0))


## The decoration quad's tint for a [param spec] covering.
static func floor_color(spec: StringName) -> Color:
	return FLOOR_SPECS.get(spec, {}).get(&"color", Color(0.5, 0.5, 0.5))


## Player-facing name of a floor spec.
static func floor_label(spec: StringName) -> String:
	return str(FLOOR_SPECS.get(spec, {}).get(&"label", spec))


## Per-exposed-face beauty of a block type — 0 for entries that omit
## it (air, coal, wood structure). A covered face reads the covering's
## beauty instead of this.
static func block_beauty(block_id: int) -> float:
	if block_id < 0 or block_id >= BLOCKS.size():
		return 0.0
	return float(BLOCKS[block_id].get(&"beauty", 0.0))


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
		var material_ok := (
			soil_like(item.material) if want == Resource_.SOIL
			else item.material == want
		)
		return material_ok and build_recipe(spec).has(item.form)
	# No committed spec: any material that builds a wall.
	if soil_like(item.material):
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
