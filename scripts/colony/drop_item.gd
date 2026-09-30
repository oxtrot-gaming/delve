class_name DropItem
extends RefCounted

## One piece of loose material dropped when a block is mined.
##
## Mining yields items totalling 125% of the block's volume: soft material
## drops as a single loose item, hard material shatters into a random mix of
## boulders and cobbles topped up with a loose balance (gravel). Every item
## keeps the mined block's material class.
##
## Volumes are integer cubic centimetres — 1 m³ = 1,000,000 cm³ — so pile
## fill, splits and capacity math are exact: no epsilon anywhere.

enum Form { LOOSE, BOULDER, COBBLE, LOG, PLANK, BED, FRUIT, SEED, MEAL }

const CM3_PER_M3 := 1_000_000
const BLOCK_CM3 := CM3_PER_M3
const DROP_CM3 := BLOCK_CM3 * 5 / 4
const BOULDER_CM3 := 100_000
const COBBLE_CM3 := 10_000
## One felled log; a log wall is two of them stood on end.
const LOG_CM3 := 500_000
## One plank: 20% of a log. Three planks and the rest sawdust make a log.
const PLANK_CM3 := LOG_CM3 / 5
const PLANKS_PER_LOG := 3
## One fruit item — a small handful of berries, an acorn, a grain head.
## Discrete, like a log: fruit never merges into bulk. Sized so a
## cooked meal (~0.01 m³) is a few fruits, not the ~50 kg the old
## 25-litre serving implied.
const FRUIT_CM3 := 2_500
## One seed packet — what an extract-seed order yields per fruit; small
## enough that two still mass less than the fruit they came from.
const SEED_CM3 := 1_000
## One cooked meal — a ~0.01 m³ serving, roughly a 1,600-calorie plate
## at the rescaled food density. Discrete: meals never merge into bulk.
const MEAL_CM3 := 10_000
## An uninstalled bed as a strapped kit — a single carryable item.
## PROVISIONAL: this is the "furniture packs down small" fiction — the
## built bed spans two voxels while its kit fits in one (and under the
## carry capacity). If we switch to a large-item warehouse instead, this
## constant and the bed recipe's output volume are the only places that
## know the kit is compact; the plumbing treats it like any other item.
const BED_KIT_CM3 := 400_000
## "Effectively infinite" volume — returned for materials that can't build
## a wall, so uncommitted jobs keep fetching until a material commits.
const INF_CM3 := 1_000_000_000_000

## Boulder/cobble count ranges. Kept low enough that their combined volume
## always leaves room for a positive loose balance.
const MIN_BOULDERS := 3
const MAX_BOULDERS := 9
const MIN_COBBLES := 5
const MAX_COBBLES := 30

## Hunger restored per cm³ eaten, per material class — absent entries are
## inedible. The serving rescale shrank food items ~10×, so the density
## went up ~10× to compensate: a meal's worth of raw fruit (~0.01 m³)
## still restores a real meal. Meals are the exception: each carries its
## computed value in [member nutrition] — this entry is only a fallback.
const NUTRITION_PER_CM3: Dictionary = {
	BlockRegistry.Resource_.BERRY: 0.000045,
	# Raw grain eats leaner than berries — processing it is the cooking
	# chain's job when that exists.
	BlockRegistry.Resource_.GRAIN: 0.000035,
	# Fallback for a meal whose provenance was lost (old saves) — about
	# 75% over the raw berry rate, matching the prepare-meal bonus.
	BlockRegistry.Resource_.MEAL: 0.000079,
}

## Campfire fuel, per material class — burn-seconds per cm³ for bulk
## fuels, with whole-item burn times in [constant FUEL_SECONDS_PER_ITEM]
## for discrete forms. Leaves and sawdust flash off fast; a split of
## branches carries a fire through a day; a log is the real fuel.
const FUEL_SECONDS_PER_CM3: Dictionary = {
	BlockRegistry.Resource_.LEAF: 0.0005,
	# Loose wood is sawdust and offcuts — same rate as leaves.
	BlockRegistry.Resource_.WOOD: 0.0005,
	BlockRegistry.Resource_.BRANCH: 0.0008,
}
const FUEL_SECONDS_PER_ITEM: Dictionary = {
	Form.LOG: 600.0,
}

## Fruit material → the species a sprouting fruit becomes: oak acorns
## grow into oak saplings, berries into berry bushes — and a grain head
## rots into volunteer wheat, since the grain is the seed. The same map
## tells the extract-seed craft which species its packets carry. Kept on
## the item side so both [Forest] and [Plants] can ask without owning
## the map.
const FRUIT_SPECIES: Dictionary = {
	BlockRegistry.Resource_.ACORN: &"oak",
	BlockRegistry.Resource_.BERRY: &"berry_bush",
	BlockRegistry.Resource_.GRAIN: &"wheat",
}

## Organic decay, per material (and form where it matters) — game-days
## until the item is gone on average. Bulk ([enum Form.LOOSE]) stacks
## shed random quanta per sweep; every other form is a discrete item
## decaying whole at a per-tick chance. `compost` is the fraction of the
## decayed volume that survives as compost; `spawn` marks fruits whose
## disappearance may sprout a plant on soil. Planks are cured and absent
## on purpose, as is every mineral.
const DECAY_RULES: Array[Dictionary] = [
	{&"material": BlockRegistry.Resource_.ACORN, &"days": 10.0, &"spawn": true},
	{&"material": BlockRegistry.Resource_.BERRY, &"days": 10.0, &"spawn": true},
	{&"material": BlockRegistry.Resource_.SEED, &"days": 60.0},
	# Dry grain keeps better than fresh fruit but still rots eventually —
	# and a rotted grain head can volunteer-sprout wheat on soil, since
	# the grain is the seed.
	{
		&"material": BlockRegistry.Resource_.GRAIN, &"days": 30.0,
		&"spawn": true,
	},
	{
		&"material": BlockRegistry.Resource_.LEAF, &"days": 15.0,
		&"compost": 0.25,
	},
	# Loose wood is sawdust and offcuts — the same rule as leaves.
	{
		&"material": BlockRegistry.Resource_.WOOD, &"form": Form.LOOSE,
		&"days": 15.0, &"compost": 0.25,
	},
	{
		&"material": BlockRegistry.Resource_.BRANCH, &"days": 60.0,
		&"compost": 0.5,
	},
	{
		&"material": BlockRegistry.Resource_.WOOD, &"form": Form.LOG,
		&"days": 120.0, &"compost": 0.5,
	},
	{&"material": BlockRegistry.Resource_.COMPOST, &"days": 60.0},
	# A cooked meal keeps longer than raw fruit, but it still spoils.
	{&"material": BlockRegistry.Resource_.MEAL, &"days": 20.0},
]


## The decay rule covering [param item], or an empty Dictionary for
## materials that never rot.
static func decay_rule(item: DropItem) -> Dictionary:
	for rule: Dictionary in DECAY_RULES:
		if int(rule[&"material"]) != item.material:
			continue
		if rule.has(&"form") and int(rule[&"form"]) != item.form:
			continue
		return rule
	return {}

## The material class this item is made of (soil, stone, iron, ...).
var material: BlockRegistry.Resource_
var form: Form
## Volume in cubic centimetres.
var volume: int
## The plant species this item came from — carried by seeds so farming
## can plant what the fruit promised. Empty for everything else.
var species: StringName = &""
## Explicit hunger restoration, overriding the per-material rate when
## set (non-negative). A cooked meal carries the value its ingredients
## summed to, times the cook bonus — the meal's provenance lives on the
## item itself since meal material has no ingredient memory.
var nutrition := -1.0


func _init(item_material: BlockRegistry.Resource_, item_form: Form, item_volume: int) -> void:
	material = item_material
	form = item_form
	volume = item_volume


## Serialized form: [material, form, volume_cm3, species, nutrition].
func serialize() -> Array:
	return [int(material), int(form), volume, String(species), nutrition]


static func deserialize(data: Array) -> DropItem:
	var item := DropItem.new(int(data[0]), int(data[1]), int(data[2]))
	item.species = StringName(data[3]) if data.size() > 3 else &""
	item.nutrition = float(data[4]) if data.size() > 4 else -1.0
	return item


## Display name for a form — the resources list's "log ×2" / "boulder ×4".
static func form_name(form: Form) -> String:
	match form:
		Form.LOOSE:
			return "loose"
		Form.BOULDER:
			return "boulder"
		Form.COBBLE:
			return "cobble"
		Form.LOG:
			return "log"
		Form.PLANK:
			return "plank"
		Form.BED:
			return "bed kit"
		Form.FRUIT:
			return "fruit"
		Form.SEED:
			return "seed"
		Form.MEAL:
			return "meal"
	return "item"


## The canonical cm³ of one item of [param form] — what recipes count
## inputs in. Loose material has no standard size (it pours), so it
## returns 0; recipes take it by volume instead of count.
static func form_volume(form: Form) -> int:
	match form:
		Form.BOULDER:
			return BOULDER_CM3
		Form.COBBLE:
			return COBBLE_CM3
		Form.LOG:
			return LOG_CM3
		Form.PLANK:
			return PLANK_CM3
		Form.BED:
			return BED_KIT_CM3
		Form.FRUIT:
			return FRUIT_CM3
		Form.SEED:
			return SEED_CM3
		Form.MEAL:
			return MEAL_CM3
	return 0


## True when items of [param material] can be eaten.
static func is_food(material: BlockRegistry.Resource_) -> bool:
	return NUTRITION_PER_CM3.has(material)


## Hunger restored by eating [param volume] cm³ of [param material].
static func nutrition_of(material: BlockRegistry.Resource_, volume: int) -> float:
	return float(NUTRITION_PER_CM3.get(material, 0.0)) * volume


## Hunger restored by eating this whole item — its explicit nutrition
## when one was computed (a cooked meal), else the material rate.
func nutrition_value() -> float:
	if nutrition >= 0.0:
		return nutrition
	return nutrition_of(material, volume)


## Burn-seconds of campfire fuel this item is worth — 0 for things that
## don't burn. Discrete fuels rate per item; bulk fuels per cm³. The
## campfire's fetch scores piles on this total: a half-dry leaf pile
## feeds a fire for a breath while one log carries it for days.
static func fuel_seconds_of(item: DropItem) -> float:
	var per_item := float(FUEL_SECONDS_PER_ITEM.get(item.form, 0.0))
	if per_item > 0.0:
		return per_item
	if item.form != Form.LOOSE:
		return 0.0
	return float(FUEL_SECONDS_PER_CM3.get(item.material, 0.0)) * item.volume


## The stack of items dropped when [param block_id] is mined. Empty for blocks
## with no drop.
static func for_block(block_id: int) -> Array[DropItem]:
	var drops: Array[DropItem] = []
	var material_class := BlockRegistry.drop_of(block_id)
	if material_class == BlockRegistry.Resource_.NONE:
		return drops

	# A log wall is its two logs stood on end — breaking one hands them
	# back, plus the usual loose 25% as splinters.
	if block_id == BlockRegistry.Block.LOG_WALL:
		drops.append(DropItem.new(material_class, Form.LOG, LOG_CM3))
		drops.append(DropItem.new(material_class, Form.LOG, LOG_CM3))
		drops.append(DropItem.new(material_class, Form.LOOSE, 250_000))
		return drops

	if BlockRegistry.resource_is_loose(material_class):
		drops.append(DropItem.new(material_class, Form.LOOSE, DROP_CM3))
		return drops

	var boulders := randi_range(MIN_BOULDERS, MAX_BOULDERS)
	var cobbles := randi_range(MIN_COBBLES, MAX_COBBLES)
	for i in boulders:
		drops.append(DropItem.new(material_class, Form.BOULDER, BOULDER_CM3))
	for i in cobbles:
		drops.append(DropItem.new(material_class, Form.COBBLE, COBBLE_CM3))
	var gravel := DROP_CM3 - boulders * BOULDER_CM3 - cobbles * COBBLE_CM3
	if gravel > 0:
		drops.append(DropItem.new(material_class, Form.LOOSE, gravel))
	return drops
