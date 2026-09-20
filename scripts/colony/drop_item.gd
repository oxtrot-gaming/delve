class_name DropItem
extends RefCounted

## One piece of loose material dropped when a block is mined.
##
## Mining yields items totalling 125% of the block's volume: soft material
## drops as a single loose item, hard material shatters into a random mix of
## boulders and cobbles topped up with a loose balance (gravel). Every item
## keeps the mined block's material class.

enum Form { LOOSE, BOULDER, COBBLE }

const BLOCK_VOLUME := 1.0
const DROP_VOLUME := BLOCK_VOLUME * 1.25
const BOULDER_VOLUME := 0.1
const COBBLE_VOLUME := 0.01

## Boulder/cobble count ranges. Kept low enough that their combined volume
## always leaves room for a positive loose balance.
const MIN_BOULDERS := 3
const MAX_BOULDERS := 9
const MIN_COBBLES := 5
const MAX_COBBLES := 30

## The material class this item is made of (soil, stone, iron, ...).
var material: BlockRegistry.Resource_
var form: Form
var volume: float


func _init(item_material: BlockRegistry.Resource_, item_form: Form, item_volume: float) -> void:
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

	if BlockRegistry.resource_is_loose(material_class):
		drops.append(DropItem.new(material_class, Form.LOOSE, DROP_VOLUME))
		return drops

	var boulders := randi_range(MIN_BOULDERS, MAX_BOULDERS)
	var cobbles := randi_range(MIN_COBBLES, MAX_COBBLES)
	for i in boulders:
		drops.append(DropItem.new(material_class, Form.BOULDER, BOULDER_VOLUME))
	for i in cobbles:
		drops.append(DropItem.new(material_class, Form.COBBLE, COBBLE_VOLUME))
	var gravel := DROP_VOLUME - boulders * BOULDER_VOLUME - cobbles * COBBLE_VOLUME
	if gravel > 0.0:
		drops.append(DropItem.new(material_class, Form.LOOSE, gravel))
	return drops
