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

enum Form { LOOSE, BOULDER, COBBLE, LOG, PLANK, BED }

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
## inedible. A berry serving of ~0.1 m³ is a meal.
const NUTRITION_PER_CM3: Dictionary = {
	BlockRegistry.Resource_.BERRY: 0.0000045,
}

## The material class this item is made of (soil, stone, iron, ...).
var material: BlockRegistry.Resource_
var form: Form
## Volume in cubic centimetres.
var volume: int


func _init(item_material: BlockRegistry.Resource_, item_form: Form, item_volume: int) -> void:
	material = item_material
	form = item_form
	volume = item_volume


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
	return 0


## True when items of [param material] can be eaten.
static func is_food(material: BlockRegistry.Resource_) -> bool:
	return NUTRITION_PER_CM3.has(material)


## Hunger restored by eating [param volume] cm³ of [param material].
static func nutrition_of(material: BlockRegistry.Resource_, volume: int) -> float:
	return float(NUTRITION_PER_CM3.get(material, 0.0)) * volume


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
