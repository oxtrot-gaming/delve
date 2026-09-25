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

enum Form { LOOSE, BOULDER, COBBLE, LOG }

const CM3_PER_M3 := 1_000_000
const BLOCK_CM3 := CM3_PER_M3
const DROP_CM3 := BLOCK_CM3 * 5 / 4
const BOULDER_CM3 := 100_000
const COBBLE_CM3 := 10_000
## "Effectively infinite" volume — returned for materials that can't build
## a wall, so uncommitted jobs keep fetching until a material commits.
const INF_CM3 := 1_000_000_000_000

## Boulder/cobble count ranges. Kept low enough that their combined volume
## always leaves room for a positive loose balance.
const MIN_BOULDERS := 3
const MAX_BOULDERS := 9
const MIN_COBBLES := 5
const MAX_COBBLES := 30

## The material class this item is made of (soil, stone, iron, ...).
var material: BlockRegistry.Resource_
var form: Form
## Volume in cubic centimetres.
var volume: int


func _init(item_material: BlockRegistry.Resource_, item_form: Form, item_volume: int) -> void:
	material = item_material
	form = item_form
	volume = item_volume


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
		drops.append(DropItem.new(material_class, Form.LOG, 500_000))
		drops.append(DropItem.new(material_class, Form.LOG, 500_000))
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
